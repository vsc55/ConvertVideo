<#
    Multiplex.psm1 - Union final de las pistas en un MKV.
    Espejo de process_multiplex.cmd. Mejora: copia los subtitulos del original si existen.
#>

function Resolve-CvMuxInputIndex {
    <#
        Indices de input del multiplex. El input 0 es el video; los N audios recodificados van como
        inputs 1..N; el ORIGINAL (subs/adjuntos/capitulos/audio copy) va al final. Devuelve {Orig;Chap}:
        Orig = indice del original (1 + N audios temporales); Chap = fuente de capitulos (el original si
        el video se recodifico, o el input 0 en modo copy, donde el propio video ya es el original).
    #>
    param([int]$TempAudioCount, [bool]$IsEncode)
    $orig = 1 + $TempAudioCount
    [pscustomobject]@{
        Orig = $orig
        Chap = $(if ($IsEncode) { $orig } else { 0 })
    }
}

function Get-CvSubtitleMapArgs {
    <#
        Args de mapeo de los SUBTITULOS del comando final, compartidos por el multiplex y la ejecucion
        en una pasada. Por cada sub (en orden): -map <ii>:<si>? + language + title ('Forzados' si forzado,
        '' si completo) + disposition (default/forced/'0') + codec por pista ('-c:s:N' = 'srt' si el sub
        se convierte a SubRip, 'copy' si no). El indice de salida (:s:N) va 0..K-1.
        $InputIndex = input que aporta los subs EMBEBIDOS (0 en una pasada; el original en el multiplex).
        Cada sub puede traer '.InputIndex' (input propio, p.ej. un temporal rescatado) y '.File' (si es un
        fichero externo -> se mapea su pista 0). '.ToSrt' -> '-c:s:N srt'. PURA. Vacio -> array vacio.
    #>
    param($Subtitles, [int]$InputIndex)
    $a  = @()
    $oi = 0
    foreach ($s in @($Subtitles | Where-Object { $_ })) {
        $ii = if ($s.PSObject.Properties['InputIndex'] -and $null -ne $s.InputIndex) { [int]$s.InputIndex } else { $InputIndex }
        $si = if ($s.PSObject.Properties['File'] -and "$($s.File)") { 0 } else { [int]$s.Index }   # fichero externo = pista 0
        $a += @('-map', ("{0}:{1}?" -f $ii, $si))
        $a += @(('-metadata:s:s:{0}' -f $oi), ("language={0}" -f $(if ($s.Lang) { $s.Lang } else { 'und' })))
        $a += @(('-metadata:s:s:{0}' -f $oi), ("title={0}" -f $(if ($s.Forced) { 'Forzados' } else { '' })))
        $disp = @(); if ($s.Default) { $disp += 'default' }; if ($s.Forced) { $disp += 'forced' }
        $a += @(('-disposition:s:{0}' -f $oi), $(if ($disp.Count -gt 0) { $disp -join '+' } else { '0' }))
        $a += @(('-c:s:{0}' -f $oi), $(if ($s.PSObject.Properties['ToSrt'] -and [bool]$s.ToSrt) { 'srt' } else { 'copy' }))
        $oi++
    }
    return ,$a
}

function Resolve-CvSubtitleInputs {
    <#
        Para los subtitulos con FICHERO EXTERNO ('.File', p.ej. un temporal rescatado con mkvextract) asigna
        un '-i' propio a partir de $NextInput y les fija '.InputIndex'. Devuelve @{ Inputs = @('-i',file,...)
        en orden; Subs = [subs, los externos ya con .InputIndex] }. Los subs EMBEBIDOS (sin .File) se
        devuelven sin tocar (usaran el InputIndex base del emisor). PURA (no toca disco).
    #>
    param($Subtitles, [int]$NextInput)
    $inputs = @()
    $subs   = @()
    $idx    = $NextInput
    foreach ($s in @($Subtitles | Where-Object { $_ })) {
        if ($s.PSObject.Properties['File'] -and "$($s.File)") {
            $inputs += @('-i', "$($s.File)")
            $s2 = $s.PSObject.Copy(); $s2 | Add-Member -NotePropertyName InputIndex -NotePropertyValue $idx -Force
            $subs += $s2
            $idx++
        } else {
            $subs += $s
        }
    }
    return @{ Inputs = @($inputs); Subs = @($subs) }
}

function Get-CvAttachmentMapArgs {
    <#
        Args de mapeo de los ADJUNTOS elegidos del comando final, compartidos por el multiplex y la
        ejecucion en una pasada. Por cada adjunto: -map <InputIndex>:<index>? + filename/mimetype
        RE-FIJADOS (el '-map_metadata -1' los borra y Matroska EXIGE 'filename'). $InputIndex = input que
        los aporta (0 en una pasada; el original en el multiplex). PURA. Vacio -> array vacio.
    #>
    param($Attachments, [int]$InputIndex)
    $a  = @()
    $aj = 0
    foreach ($att in @($Attachments | Where-Object { $_ })) {
        $a += @('-map', ("{0}:{1}?" -f $InputIndex, [int]$att.index))
        $fn = "$(Get-Tag $att 'filename')"; $mt = "$(Get-Tag $att 'mimetype')"
        if ($fn) { $a += @(('-metadata:s:t:{0}' -f $aj), ("filename={0}" -f $fn)) }
        if ($mt) { $a += @(('-metadata:s:t:{0}' -f $aj), ("mimetype={0}" -f $mt)) }
        $aj++
    }
    return ,$a
}

function Get-CvMultiplexArgs {
    <#
        Construye (PURO: sin ejecutar ni tocar disco) el array de argumentos ffmpeg del multiplexado a
        partir de un PLAN con las piezas ya resueltas (las decisiones de I/O —que temporal de video/audio
        existe— las toma Invoke-Multiplex y las pasa aqui). El Plan tiene:
          File; Out; VideoSrc; Vmap; TempAudio[]; CopyAudio[]; LegacyCopy; Subs[]; KeepAtt[];
          OrigInput; ChapInput; NeedOrig; HasSubs.
        Golden-testeable. El mapeo de subs/adjuntos usa la misma fuente unica que la una-pasada.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Plan)
    $ffArgs = @('-hide_banner','-y','-threads',"$($Context.Threads)")
    $ffArgs += @('-i',$Plan.VideoSrc)                                       # input 0 = video
    foreach ($a in $Plan.TempAudio) { $ffArgs += @('-i', "$($a.File)") }    # inputs 1..M = audios recodificados
    if ($Plan.NeedOrig) { $ffArgs += @('-i',$Plan.File) }                   # input N = original (subs/adjuntos/capitulos/audio copy)
    # Subtitulos con fichero externo (rescatados a temporal): un input propio a partir del siguiente libre
    # (video + audios recodificados + original). Resolve-CvSubtitleInputs fija su .InputIndex.
    $nextIn = 1 + $Plan.TempAudio.Count + $(if ($Plan.NeedOrig) { 1 } else { 0 })
    $subIn  = Resolve-CvSubtitleInputs -Subtitles $Plan.Subs -NextInput $nextIn
    $ffArgs += @($subIn.Inputs)

    # Limpiar TODOS los metadatos heredados de una sola vez: '-map_metadata -1' global tambien
    # vacia los tags de cada pista (ENCODER/_STATISTICS obsoletos que se copian al recodificar el
    # video, VENDOR_ID/HANDLER_NAME que anade el contenedor .m4a). '-fflags +bitexact' evita
    # ademas que ffmpeg escriba su propia etiqueta ENCODER global. Despues re-fijamos solo lo
    # que queremos (titulo/idioma/disposition). '-map_chapters' conserva los capitulos del original.
    $ffArgs += @('-map_metadata','-1','-fflags','+bitexact','-map_chapters',"$($Plan.ChapInput)")
    $ffArgs += @('-metadata','title=')

    # mapeo video: titulo en blanco, idioma indefinido. Encode -> '0:v:0'; copy -> pista elegida por
    # su indice absoluto ('0:<VideoIndex>') salvo desconocido, que cae a '0:v:0'.
    $ffArgs += @('-map',$Plan.Vmap,'-metadata:s:v','title=','-metadata:s:v','language=und')

    # ----- AUDIO (multipista) -----
    # La lista ya viene con la DEFAULT primero (la ordena el worker). Se mapea cada pista, se fija el
    # idioma y la disposition (default segun el flag). El TITULO lo resuelve Resolve-CvAudioTitle:
    # por defecto en BLANCO; si encode.audioKeepTitle=$true, el del ORIGEN (por indice de la pista).
    $ao = 0
    if ($Plan.TempAudio.Count -gt 0) {
        # Audios recodificados: cada uno es el input ($ao+1), pista a:0 de ese input.
        foreach ($a in $Plan.TempAudio) {
            $ffArgs += @('-map', ("{0}:a:0" -f ($ao + 1)))
            $ffArgs += @(('-metadata:s:a:{0}' -f $ao), ("language={0}" -f $(if ($a.Lang) { $a.Lang } else { 'und' })))
            $ffArgs += @(('-metadata:s:a:{0}' -f $ao), ("title={0}" -f (Resolve-CvAudioTitle -Keep $Context.AudioKeepTitle -Info $Info -Index ([int]$a.Index))))
            $ffArgs += @(('-disposition:a:{0}' -f $ao), $(if ($a.Default) { 'default' } else { '0' }))
            $ao++
        }
    }
    elseif ($Plan.CopyAudio.Count -gt 0) {
        # Audios en COPIA: por indice absoluto del original (input OrigInput), sin recodificar.
        foreach ($a in $Plan.CopyAudio) {
            $ffArgs += @('-map', ("{0}:{1}?" -f $Plan.OrigInput, [int]$a.Index))
            $ffArgs += @(('-metadata:s:a:{0}' -f $ao), ("language={0}" -f $(if ($a.Lang) { $a.Lang } else { 'und' })))
            $ffArgs += @(('-metadata:s:a:{0}' -f $ao), ("title={0}" -f (Resolve-CvAudioTitle -Keep $Context.AudioKeepTitle -Info $Info -Index ([int]$a.Index))))
            $ffArgs += @(('-disposition:a:{0}' -f $ao), $(if ($a.Default) { 'default' } else { '0' }))
            $ao++
        }
    }
    elseif ($Plan.HasOrigAudio) {
        # copy CLASICO (monopista): primera pista de audio del ORIGINAL (input OrigInput), conservando sus
        # metadatos. OJO: NO es siempre el input 0 — con vídeo RECODIFICADO el input 0 es el temporal de
        # vídeo (creado con -an, sin pista de audio), y el original va en OrigInput. Usar 0 aqui hacia
        # fallar ffmpeg ("Stream map '0:a:0' matches no streams") en el combo recodificar-video + copy-audio.
        # Solo se emite si el original TIENE audio; una fuente MUDA da salida solo-vídeo (si no, tanto el
        # -map como el -map_metadata:s:a:0 apuntarian a un stream inexistente y ffmpeg abortaria con -22).
        $ffArgs += @('-map', ("{0}:a:0?" -f $Plan.OrigInput), '-map_metadata:s:a:0', ("{0}:s:a:0" -f $Plan.OrigInput))
    }

    # mapeo subtitulos (idioma + titulo Forzados/'' + disposition + codec por pista) y adjuntos
    # (filename/mimetype), fuente unica compartida con la ejecucion en una pasada. Los subs EMBEBIDOS
    # vienen del original; los rescatados, de su input externo (.InputIndex ya fijado). El codec de subs
    # va por pista ('-c:s:N srt|copy' dentro de Get-CvSubtitleMapArgs), asi que no hay '-c:s copy' global.
    $ffArgs += (Get-CvSubtitleMapArgs   -Subtitles $subIn.Subs     -InputIndex $Plan.OrigInput)
    $ffArgs += (Get-CvAttachmentMapArgs -Attachments $Plan.KeepAtt -InputIndex $Plan.OrigInput)

    $ffArgs += @('-c:v','copy','-c:a','copy')
    if ($Plan.KeepAtt.Count -gt 0) { $ffArgs += @('-c:t','copy') }
    # Modo pruebas: acotar la salida final. Imprescindible en perfil copy (el video se copia del
    # original a longitud COMPLETA, mientras el audio recodificado ya viene a TestLimit); tambien
    # recorta subtitulos/capitulos al mismo tramo. En encode el video ya es corto (-t es inocuo).
    if ($Context.TestLimit -gt 0) { $ffArgs += @('-t',"$($Context.TestLimit)") }
    $ffArgs += @('-f','matroska',$Plan.Out)
    return ,$ffArgs
}

function Invoke-Multiplex {
    <#
        Une video (temporal recodificado o el original si es copy) + audio (m4a) en Convertido\<name>_fix.mkv.
        Devuelve $true si crea la salida. Resuelve las decisiones de I/O (que temporales existen) y delega
        la construccion del comando en Get-CvMultiplexArgs (puro, golden-testeable).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$Info,
        [bool]$VideoSkipped = $false,
        [bool]$AudioSkipped = $false,
        $Subtitles = @(),
        # Pistas de audio a incluir (multipista): [{Source='temp'|'copy'; File; Index; Lang; Title; Default}].
        # La DEFAULT va PRIMERO (asi las ordena el worker). Vacio + AudioSkipped -> copy clasico de 0:a:0.
        $AudioTracks = @(),
        [int]$VideoIndex = -1
    )
    $name  = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $out   = Get-OutputPath $Context $name
    $tmp   = Get-CvTempPaths -Context $Context -Name $name
    $vTmp  = $tmp.Video

    # Fuente de video: recodificado si existe, si no el original (caso copy).
    $videoSrc = if (Test-Path -LiteralPath $vTmp) { $vTmp } else { $File }

    # Pistas de audio: recodificadas (temporal por pista) vs copia (indice del original).
    $audioT    = @($AudioTracks | Where-Object { $_ })
    $tempAudio = @($audioT | Where-Object { "$($_.Source)" -eq 'temp' -and (Test-Path -LiteralPath "$($_.File)") })
    $copyAudio = @($audioT | Where-Object { "$($_.Source)" -eq 'copy' })
    # copy CLASICO (sin lista de pistas): AudioSkipped y ninguna pista -> se copia 0:a:0 del original.
    $legacyCopy = (($audioT.Count -eq 0) -and $AudioSkipped)

    # Subtitulos seleccionados en la fase preparar (filtramos posibles nulos del JSON). Los ilegibles
    # marcados 'Rescue' (WEBVTT) se extraen con mkvextract a temporales ANTES del comando; se anaden como
    # inputs extra y ffmpeg los convierte a srt. Fail-soft por pista. Se borran al terminar ($sx.Temps).
    $sx      = Invoke-CvSubtitleExtract -Context $Context -File $File -Subtitles @($Subtitles | Where-Object { $_ })
    $subs    = @($sx.Subs)
    $hasSubs = $subs.Count -gt 0
    # Adjuntos del original a conservar (fuentes/caratulas segun config; por defecto ninguno).
    $keepAtt = @(Select-Attachments -Context $Context -Info $Info)

    # El original ($File) hace falta como input si aporta subtitulos/adjuntos, si el video se recodifico
    # (el intermedio se creo con -map_chapters -1, asi que los CAPITULOS se toman del original), o si hay
    # audio en modo COPIA (se toma del original) o el copy clasico 0:a:0. En copy el video ya es el
    # original (input 0). Los audios recodificados van como inputs 1..M (uno por pista).
    $isEncode = (Test-Path -LiteralPath $vTmp)
    $needCopyAudio = ($copyAudio.Count -gt 0) -or $legacyCopy
    $needOrig = $hasSubs -or ($keepAtt.Count -gt 0) -or $isEncode -or $needCopyAudio
    # Indices de input (original / fuente de capitulos): Resolve-CvMuxInputIndex.
    $mi = Resolve-CvMuxInputIndex -TempAudioCount $tempAudio.Count -IsEncode $isEncode
    # mapeo video: encode -> '0:v:0'; copy -> pista elegida por indice absoluto (o '0:v:0' si desconocido).
    $vmap = if ($isEncode -or ($VideoIndex -lt 0)) { '0:v:0' } else { "0:$VideoIndex" }

    $plan = [pscustomobject]@{
        File       = $File
        Out        = $out
        VideoSrc   = $videoSrc
        Vmap       = $vmap
        TempAudio  = $tempAudio
        CopyAudio  = $copyAudio
        LegacyCopy = $legacyCopy
        Subs       = $subs
        KeepAtt    = $keepAtt
        OrigInput  = $mi.Orig
        ChapInput  = $mi.Chap
        NeedOrig   = $needOrig
        HasSubs    = $hasSubs
        # ¿El original tiene audio? (para el copy clásico: una fuente MUDA da salida solo-vídeo).
        HasOrigAudio = (@(Get-AudioStreams -Info $Info).Count -gt 0)
    }
    $ffArgs = Get-CvMultiplexArgs -Context $Context -Info $Info -Plan $plan

    Start-CvStep $Context 'MULTIPLEX' 'Uniendo pistas...'
    $code = Invoke-ToolShow -Exe $Context.FFmpeg -Arguments $ffArgs -Context $Context
    # Borrar los temporales de subtitulos rescatados (se hayan usado o no).
    foreach ($t in @($sx.Temps)) { if (Test-Path -LiteralPath $t) { Remove-Item -Force -LiteralPath $t -ErrorAction SilentlyContinue } }
    $ok = (($code -eq 0) -and (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0))
    $mbTxt = if ($ok) { ("({0} MB)" -f [math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)) } else { '' }
    Stop-CvStep $Context 'MULTIPLEX' $ok -Extra $mbTxt -OkMsg ("[OK] - {0}  {1}" -f (Split-Path $out -Leaf), $mbTxt) -FailMsg ("[ERR] - ffmpeg devolvio codigo {0}" -f $code)
    if (-not $ok) {
        # Borrar la salida parcial para no darla por buena ni bloquear el reintento.
        if (Test-Path -LiteralPath $out) { Remove-Item -Force -LiteralPath $out -ErrorAction SilentlyContinue }
        return $false
    }
    # Limpiar las etiquetas DURATION que anade el muxer de Matroska (mkvpropedit).
    Remove-CvMkvTags -Context $Context -File $out
    return $true
}

function Remove-CvMkvTags {
    <#
        Elimina TODAS las etiquetas del MKV con mkvpropedit (MKVToolNix), sin recodificar y
        conservando Cues/duracion/dispositions. Quita los tags 'DURATION' por pista que el
        muxer de ffmpeg escribe al cerrar el fichero (ffmpeg no tiene flag para omitirlos).
        Se controla con config 'postprocess.stripTags' y la ruta 'postprocess.mkvpropedit'.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File)
    if (-not $Context.StripTags) { return }
    $mpe = "$($Context.MkvPropEdit)"
    # Si no es un override manual y falta, descargar mkvtoolnix (y su extractor 7zr) la 1a vez.
    if ((-not (Test-Path -LiteralPath $mpe)) -and [string]::IsNullOrWhiteSpace("$($Context.MkvPropEditOverride)")) {
        $app = Get-CvAppDescriptor -Context $Context -Name 'mkvtoolnix'
        if ($app) { [void](Confirm-CvTool -Context $Context -Name 'mkvtoolnix' -Version "$($app.selected)") }
    }
    if ([string]::IsNullOrWhiteSpace($mpe) -or -not (Test-Path -LiteralPath $mpe)) {
        Write-CvLog 'MULTIPLEX' '[AVISO] - mkvpropedit no disponible: quedan las etiquetas DURATION'
        return
    }
    Start-CvStep $Context 'MULTIPLEX' 'Limpiando etiquetas con mkvpropedit...'
    $r = Invoke-ToolCapture -Exe $mpe -Arguments @($File, '--tags', 'all:') -Context $Context
    Stop-CvStep $Context 'MULTIPLEX' ($r.ExitCode -eq 0) -OkMsg '[TAGS] - [OK] - Etiquetas eliminadas' -FailMsg ("[AVISO] - mkvpropedit devolvio codigo {0}; las etiquetas pueden seguir" -f $r.ExitCode)
}

Export-ModuleMember -Function *
