<#
    OnePass.psm1 - Ejecucion en UNA sola pasada de ffmpeg (BETA).

    Funde las tres etapas del pipeline clasico (Audio -> Video -> Multiplex, cada una un proceso ffmpeg
    con temporales .m4a/.mka/.mkv) en un UNICO comando ffmpeg con -filter_complex: reencoda el video
    (crop/scale), recodifica y sincroniza el audio (adelay + downmix + loudnorm) y copia subtitulos,
    adjuntos y capitulos del original, escribiendo directamente Convertido\<name>_fix.mkv. Ahorra los
    temporales intermedios y dos arranques de ffmpeg.

    Solo aplica en un subconjunto de casos (Test-CvOnePassEligible); en el resto se usa el pipeline por
    etapas. Activador beta con doble llave: test.betaOnePass (Context.BetaOnePass), off por defecto.
#>

function Test-CvOnePassEligible {
    <#
        Decide si un job puede convertirse en UNA sola pasada. Devuelve {Ok=[bool]; Reason=[string]}
        (Reason = por que NO, para el log). Requisitos:
          - test.betaOnePass activo (doble llave beta).
          - Video y audio se CODIFICAN (ni video.skip ni audio.skip: 'copy' va por etapas).
          - Sincronia por 'adelay' (el modo clasico genera un WAV intermedio -> 2 pasadas).
          - Volumen 'loudnorm' (una pasada) o 'peak' (mide con volumedetect en una pasada de analisis
            previa —barata, como el pipeline por etapas— y aplica 'volume=XdB' en el filtergraph). Solo
            'aacgain' queda fuera: aplica ReplayGain sobre el .m4a intermedio, que en una pasada no existe.
          - Sin tone-mapping HDR->SDR (usa un hw device Vulkan/libplacebo que complica el filtergraph).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Job, [Parameter(Mandatory)]$Prof)
    if (-not $Context.BetaOnePass) { return [pscustomobject]@{ Ok = $false; Reason = 'beta desactivada (test.betaOnePass)' } }
    if ([bool]$Job.video.skip)     { return [pscustomobject]@{ Ok = $false; Reason = 'video en modo copy' } }
    if ([bool]$Job.audio.skip)     { return [pscustomobject]@{ Ok = $false; Reason = 'audio en modo copy' } }
    if (-not $Context.SyncAdelay)  { return [pscustomobject]@{ Ok = $false; Reason = 'sincronia clasica (WAV), no adelay' } }
    $codec = "$($Prof.AudioCodec)".ToLower(); if (-not $codec) { $codec = 'aac' }
    $vm = Resolve-CvVolumeMethod -Method $Context.VolumeMethod -Codec $codec
    if ($vm.Method -notin @('loudnorm','peak')) { return [pscustomobject]@{ Ok = $false; Reason = ("volumen '{0}' (loudnorm/peak)" -f $vm.Method) } }
    if ([bool]$Job.video.hdr -and ("$($Context.TonemapHdr)".ToLower() -ne 'off')) { return [pscustomobject]@{ Ok = $false; Reason = 'tone-mapping HDR->SDR (requiere hw device)' } }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Get-CvOnePassArgs {
    <#
        Construye (PURO: sin ejecutar ni loguear) el array de argumentos ffmpeg de la ejecucion unica.
        Un solo '-i' (el original) y un '-filter_complex' con la rama de video (crop -> scale) y una
        rama por pista de audio (adelay + downmix + loudnorm). Mapea el video/audio filtrados + los
        subtitulos/adjuntos/capitulos copiados del original, limpia los metadatos heredados
        ('-map_metadata -1 -fflags +bitexact') y re-fija idioma/titulo/disposition por pista. Es el
        espejo, fundido, de Invoke-VideoRun + Invoke-AudioRun + Invoke-Multiplex.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$Out,
        # Filtro de volumen POR PISTA (alineado a spec.Audio), resuelto en runtime por Invoke-CvOnePass
        # cuando el metodo es 'peak' (mide el pico y calcula la ganancia). Si no se pasa, se usa el
        # loudnorm del spec para todas (metodo 'loudnorm').
        [string[]]$VolumeFilters = $null,
        # Subtitulos ya resueltos por el worker (con los rescatados extraidos a temporales, .File). Si no
        # se pasan, se usan los del spec (sin rescate). Permite que el worker haga la extraccion (I/O).
        $Subtitles = $null
    )
    # Todas las DECISIONES (video/audio/subs/adjuntos/codecs) salen del spec de render (fuente unica,
    # Resolve-CvRenderSpec); aqui solo se EMITE el comando de una pasada a partir de el.
    $spec = Resolve-CvRenderSpec -Context $Context -Prof $Prof -Job $Job -Info $Info

    # ----- rama de VIDEO (crop -> scale; sin tonemap: la elegibilidad excluye HDR) -----
    $fc = @()
    if ($spec.Video.Filters.Count -gt 0) {
        $fc  += ("[{0}]{1}[v]" -f $spec.Video.SrcPad, ($spec.Video.Filters -join ','))
        $vmap = '[v]'
    } else {
        $vmap = $spec.Video.SrcPad
    }

    # ----- ramas de AUDIO (una por pista) -----
    $aMaps   = @()   # -map + metadata + disposition por pista de salida
    $aCodec  = @()   # -ac:a:N / -ar:a:N / -b:a:N por pista (cada una con sus canales de origen)
    for ($ti = 0; $ti -lt $spec.Audio.Count; $ti++) {
        $tr = $spec.Audio[$ti]
        # Rama del filtro (fuente unica Get-CvAudioFilterChain): sincronia (adelay) -> downmix (pan) ->
        # volumen. El filtro de volumen es el loudnorm del spec, salvo que se pasen VolumeFilters (metodo
        # 'peak': 'volume=XdB' o '' si no hay ganancia). Si la rama queda vacia (peak sin ganancia, sin
        # sync ni downmix) se usa 'anull' para conservar la etiqueta [aN] que exige el filtergraph.
        $volF  = if ($null -ne $VolumeFilters) { "$($VolumeFilters[$ti])" } else { $spec.Loudnorm }
        $syncF = if ($tr.Sync -gt 0) { Get-CvAdelayFilter ([double]$tr.Sync) } else { '' }
        $parts = Get-CvAudioFilterChain -SyncFilter $syncF -DownmixPan $tr.DownmixPan -VolumeFilter $volF
        $chainStr = if (@($parts).Count -gt 0) { @($parts) -join ',' } else { 'anull' }
        $fc += ("[0:{0}]{1}[a{2}]" -f $tr.Index, $chainStr, $ti)

        $aMaps += @('-map', ("[a{0}]" -f $ti))
        $aMaps += @(('-metadata:s:a:{0}' -f $ti), ("language={0}" -f $tr.Lang))
        $aMaps += @(('-metadata:s:a:{0}' -f $ti), ("title={0}" -f $tr.Title))
        $aMaps += @(('-disposition:a:{0}' -f $ti), $(if ($tr.Default) { 'default' } else { '0' }))

        # Opciones de codec POR PISTA (-ac:a:N etc.): cada pista puede tener distintos canales de origen.
        $aCodec += @(('-ac:a:{0}' -f $ti), "$($tr.Channels)", ('-ar:a:{0}' -f $ti), "$($tr.Ar)")
        if ($tr.Bitrate) { $aCodec += @(('-b:a:{0}' -f $ti), "$($tr.Bitrate)") }
    }

    # Subtitulos: los del worker (con rescatados ya extraidos a temporales) o, si no, los del spec.
    # Los que tienen fichero externo (.File) reciben un input propio a partir del 1 (el 0 es el original).
    $subsIn  = if ($null -ne $Subtitles) { @($Subtitles | Where-Object { $_ }) } else { @($spec.Subtitles) }
    $subIn   = Resolve-CvSubtitleInputs -Subtitles $subsIn -NextInput 1
    $hasSubs = @($subIn.Subs).Count -gt 0

    # ----- ensamblar el comando -----
    $ff  = @('-hide_banner','-y','-threads',"$($Context.Threads)",'-i',$File)
    $ff += @($subIn.Inputs)   # inputs extra: un fichero por subtitulo rescatado (temporal .vtt)
    $ff += @('-filter_complex', ($fc -join ';'))
    # Limpiar TODOS los metadatos heredados (global + por pista) y fijar los capitulos del original
    # (input 0). '+bitexact' evita que ffmpeg escriba su propia etiqueta ENCODER global.
    $ff += @('-map_metadata','-1','-fflags','+bitexact','-map_chapters','0','-metadata','title=')
    # video
    $ff += @('-map',$vmap,'-metadata:s:v','title=','-metadata:s:v','language=und')
    # audio (mapas + metadatos por pista)
    $ff += $aMaps
    # subtitulos y adjuntos: misma fuente unica que el multiplex (Get-CvSubtitleMapArgs /
    # Get-CvAttachmentMapArgs). Los adjuntos vienen del input 0; los subs, del 0 (embebidos) o de su
    # input externo (rescatados, .InputIndex ya fijado por Resolve-CvSubtitleInputs). El codec por pista
    # ('-c:s:N srt|copy') lo emite Get-CvSubtitleMapArgs, asi que no se pone un '-c:s copy' global.
    $ff += (Get-CvSubtitleMapArgs   -Subtitles $subIn.Subs        -InputIndex 0)
    $ff += (Get-CvAttachmentMapArgs -Attachments $spec.Attachments -InputIndex 0)
    # codecs: video (Get-VideoArgs) + audio (codec global; -ac/-ar/-b:a por pista) + copy subs/adjuntos.
    $ff += (Get-VideoArgs -Context $Context -Prof $Prof -Anim $spec.Video.Anim)
    $ff += @('-c:a',$spec.AudioCodec)
    if ($spec.AacCoder) { $ff += @('-aac_coder', $spec.AacCoder) }   # coder AAC nativo (config)
    $ff += $aCodec
    # (el codec de subtitulos va por pista en Get-CvSubtitleMapArgs: '-c:s:N srt|copy')
    if ($spec.Attachments.Count -gt 0) { $ff += @('-c:t','copy') }
    # Modo pruebas: acotar la salida a los primeros TestLimit segundos.
    if ($spec.TestLimit -gt 0) { $ff += @('-t',"$($spec.TestLimit)") }
    $ff += @('-f','matroska',$Out)
    return ,$ff
}

function Invoke-CvOnePass {
    <#
        Ejecuta la conversion en UNA sola pasada y escribe directamente Convertido\<name>_fix.mkv.
        Devuelve $true si crea la salida. Muestra progreso en vivo (como Invoke-VideoRun) y, al terminar,
        limpia las etiquetas DURATION con mkvpropedit (Remove-CvMkvTags). Fail-hard: si ffmpeg falla,
        borra la salida parcial y devuelve $false (el worker reintenta segun su politica).
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Job,
        [double]$Duration = 0
    )
    $name = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $out  = Get-OutputPath $Context $name

    # Subtitulos: rescatar los ilegibles (WEBVTT) a temporales con mkvextract ANTES del comando; se pasan
    # al emisor como inputs extra y ffmpeg los convierte a srt en la misma pasada. Fail-soft por pista.
    $sx   = Invoke-CvSubtitleExtract -Context $Context -File $File -Subtitles $Job.subtitles
    $subs = @($sx.Subs)

    # Volumen 'peak': una pasada de ANALISIS previa por pista (volumedetect) para calcular la ganancia
    # ('volume=XdB'); el resto (video+audio+mux) sigue siendo UN solo comando. 'loudnorm' no mide (es
    # dinamico en el propio filtergraph). Los VolumeFilters resueltos se pasan al emisor.
    $codec  = "$($Prof.AudioCodec)".ToLower(); if (-not $codec) { $codec = 'aac' }
    $method = (Resolve-CvVolumeMethod -Method $Context.VolumeMethod -Codec $codec).Method
    $volFilters = $null
    if ($method -eq 'peak') {
        $spec   = Resolve-CvRenderSpec -Context $Context -Prof $Prof -Job $Job -Info $Info
        $target = [double]$Context.PeakTarget
        $inv    = [System.Globalization.CultureInfo]::InvariantCulture
        $volFilters = @()
        foreach ($tr in $spec.Audio) {
            $measure = @('-i',$File,'-map',("0:{0}" -f $tr.Index),'-vn','-sn','-map_chapters','-1')
            if ($Context.TestLimit -gt 0) { $measure += @('-t',"$($Context.TestLimit)") }
            Start-CvStep $Context 'UNA-PASADA' 'Analizando volumen...'
            $peak = Get-MaxVolume -Context $Context -InputArgs $measure
            $peakTxt = if ($null -ne $peak) { '(pico {0} dB)' -f $peak } else { '(pico desconocido)' }
            Stop-CvStep $Context 'UNA-PASADA' $true -Extra $peakTxt -OkMsg ("[OK] - Volumen analizado {0}" -f $peakTxt)
            $gain = if ($null -ne $peak -and $peak -lt $target) { [math]::Round($target - $peak, 1) } else { 0.0 }
            $volFilters += $(if ($gain -gt 0) { 'volume={0}dB:precision=fixed' -f $gain.ToString($inv) } else { '' })
        }
    }
    $ff = if ($null -ne $volFilters) {
        Get-CvOnePassArgs -Context $Context -Prof $Prof -File $File -Info $Info -Job $Job -Out $out -VolumeFilters $volFilters -Subtitles $subs
    } else {
        Get-CvOnePassArgs -Context $Context -Prof $Prof -File $File -Info $Info -Job $Job -Out $out -Subtitles $subs
    }

    # Total del progreso: duracion (+ el mayor silencio de sincronia, que alarga la pista), acotado a -t.
    $aTracks = @(Get-CvJobAudioTracks -Audio $Job.audio)
    $maxSync = 0.0
    foreach ($t in $aTracks) { if ([double]$t.Sync -gt $maxSync) { $maxSync = [double]$t.Sync } }
    $total = [double]$Duration + $maxSync
    if ($Context.TestLimit -gt 0) { $total = [math]::Min($total, [double]$Context.TestLimit) }

    $global:CvLastToolError = $null   # el modo progreso lo rellena; se vuelca al log si ffmpeg falla
    if ($Context.Progress -and -not $Context.Debug -and $total -gt 0) {
        $code = Invoke-ToolProgress -Exe $Context.FFmpeg -Arguments $ff -Context $Context -Label 'Una sola pasada (video+audio)...' -TotalSeconds $total -ShowQ
    } else {
        Start-CvStep $Context 'UNA-PASADA' 'Codificando en una sola pasada...'
        $code = Invoke-ToolShow -Exe $Context.FFmpeg -Arguments $ff -Context $Context
    }
    # Borrar los temporales de subtitulos rescatados (se hayan usado o no).
    foreach ($t in @($sx.Temps)) { if (Test-Path -LiteralPath $t) { Remove-Item -Force -LiteralPath $t -ErrorAction SilentlyContinue } }
    $ok = (($code -eq 0) -and (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0))
    if (-not $ok) {
        Stop-CvStep $Context 'UNA-PASADA' $false -FailMsg ("[ERR] - ffmpeg devolvio codigo {0}" -f $code)
        Show-CvToolError -Context $Context -Category 'UNA-PASADA' -Name $name -Tool 'ffmpeg-onepass'
        if (Test-Path -LiteralPath $out) { Remove-Item -Force -LiteralPath $out -ErrorAction SilentlyContinue }
        return $false
    }
    $mb = [math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
    Stop-CvStep $Context 'UNA-PASADA' $true -OkMsg ("[OK] - {0}  ({1} MB)" -f (Split-Path $out -Leaf), $mb)
    # Limpiar las etiquetas DURATION que anade el muxer de Matroska (igual que el multiplex clasico).
    Remove-CvMkvTags -Context $Context -File $out
    return $true
}

Export-ModuleMember -Function *
