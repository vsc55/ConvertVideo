<#
    Subtitle.psm1 - Seleccion de subtitulos por idioma (simetrico con el audio).
    Fase ASK: elige que pistas conservar. El multiplex las mapea con sus metadatos.
#>

function Test-CvSubtitleUsable {
    <#
        $true si el subtitulo tiene un codec que FFMPEG PUEDE LEER (copiar/convertir). $false si el
        codec_name viene vacio / 'none' / 'unknown': p.ej. S_TEXT/WEBVTT que el demuxer de Matroska de
        esta build no mapea y ffprobe reporta como "Subtitle: none". Copiar (o convertir) uno de esos con
        ffmpeg hace fallar el comando entero ("Subtitle codec 0 is not supported"); hay que RESCATARLO con
        mkvextract (ver Resolve-CvSubtitleAction).
    #>
    param([Parameter(Mandatory)]$Stream)
    $c = [string]$Stream.codec_name
    return (-not [string]::IsNullOrWhiteSpace($c)) -and ($c.ToLower() -notin @('none', 'unknown'))
}

function Resolve-CvSubtitleAction {
    <#
        Decide QUE hacer con un subtitulo, segun si ffmpeg lo puede leer y la lista encode.subtitles.toSrt
        (Context.SubtitlesToSrt, codecs a convertir a SRT):
          'copy'    = legible y NO en la lista -> se copia tal cual.
          'srt'     = legible y en la lista    -> se transcodifica a SubRip ('-c:s srt', ffmpeg lo lee).
          'rescue'  = ilegible por ffmpeg (WEBVTT embebido) en un MKV y 'webvtt' esta en la lista -> se
                      extrae con mkvextract a un temporal y ffmpeg lo convierte a srt en el mismo comando.
          'discard' = ilegible y no rescatable (contenedor no Matroska o 'webvtt' no esta en la lista):
                      se ignora (copiarlo tumbaria toda la conversion).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Stream)
    $toSrt = @($Context.SubtitlesToSrt)
    if (Test-CvSubtitleUsable $Stream) {
        $c = "$($Stream.codec_name)".ToLower()
        if ($toSrt -contains $c) { return 'srt' }
        return 'copy'
    }
    # Ilegible por ffmpeg: solo rescatable si es Matroska (mkvextract) y 'webvtt' esta en la lista
    # (el unico caso real de codec ilegible es el WEBVTT embebido).
    $fmt = "$($Info.format.format_name)".ToLower()
    if (($fmt -match 'matroska|webm') -and ($toSrt -contains 'webvtt')) { return 'rescue' }
    return 'discard'
}

function Get-SubtitleStreams {
    <# TODAS las pistas de subtitulo del archivo (la decision de copiar/convertir/rescatar/descartar la
       toma Resolve-CvSubtitleAction en Select-Subtitles). #>
    param([Parameter(Mandatory)]$Info)
    @($Info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
}

function Invoke-CvSubtitleExtract {
    <#
        Fase WORKER (I/O): extrae con mkvextract los subtitulos marcados 'Rescue' del MKV a temporales
        .vtt y los devuelve con la ruta del temporal en '.File' (para que el emisor los mapee como input
        EXTRA y ffmpeg los convierta a srt). Los demas subtitulos se devuelven sin tocar. Fail-soft POR
        PISTA: si mkvextract falta o falla, se OMITE ese subtitulo (no la conversion). Devuelve
        @{ Subs = [subs, los rescatados con .File]; Temps = [rutas temporales a borrar al terminar] }.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, $Subtitles)
    $mkx    = "$($Context.MkvExtract)"
    $tmpDir = [System.IO.Path]::GetTempPath()
    $out    = @()
    $temps  = @()
    foreach ($s in @($Subtitles | Where-Object { $_ })) {
        if (-not ($s.PSObject.Properties['Rescue'] -and [bool]$s.Rescue)) { $out += $s; continue }
        if ([string]::IsNullOrWhiteSpace($mkx) -or -not (Test-Path -LiteralPath $mkx)) {
            Write-CvLog 'SUB' ("[AVISO] - mkvextract no disponible; se omite el subtitulo rescatado (pista {0})." -f $s.Index) -Indent 3
            continue
        }
        $tmp = Join-Path $tmpDir ("cv-sub-{0}.vtt" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $r = Invoke-ToolCapture -Exe $mkx -Arguments @('tracks', $File, ("{0}:{1}" -f [int]$s.Index, $tmp)) -Context $Context
        if (($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0)) {
            $s2 = $s.PSObject.Copy(); $s2 | Add-Member -NotePropertyName File -NotePropertyValue $tmp -Force
            $out += $s2
            $temps += $tmp
        } else {
            Write-CvLog 'SUB' ("[AVISO] - No se pudo rescatar el subtitulo (pista {0}, codigo {1}); se omite." -f $s.Index, $r.ExitCode) -Indent 3
            if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
        }
    }
    return @{ Subs = @($out); Temps = @($temps) }
}

function Test-SubForced {
    <# Detecta si un subtitulo es "forzado" (para dialogo en otro idioma). #>
    param([Parameter(Mandatory)]$Stream)
    if ($Stream.PSObject.Properties['disposition'] -and $Stream.disposition -and $Stream.disposition.forced -eq 1) { return $true }
    $t = Get-Tag $Stream 'title'
    if ($t -and ($t -match 'forzad|forced')) { return $true }
    return $false
}

function Test-SubDefault {
    <# Lee el flag 'default' (pista predefinida) original del subtitulo. #>
    param([Parameter(Mandatory)]$Stream)
    return ($Stream.PSObject.Properties['disposition'] -and $Stream.disposition -and $Stream.disposition.default -eq 1)
}

function ConvertTo-SubSel {
    <#
        Objeto de seleccion de subtitulo para guardar en el job.
        -Default: $true/$false lo fuerza; si se omite ($null) se conserva el flag
        'default' ORIGINAL de la pista (asi un forzado que ya era predefinido lo sigue siendo).
    #>
    param([Parameter(Mandatory)]$Stream, [object]$Default = $null, [object]$Forced = $null, [string]$Action = 'copy')
    $isDefault = if ($null -ne $Default) { [bool]$Default } else { (Test-SubDefault $Stream) }
    $isForced  = if ($null -ne $Forced)  { [bool]$Forced }  else { (Test-SubForced $Stream) }
    # Accion (Resolve-CvSubtitleAction): 'srt' = transcodificar a SubRip; 'rescue' = ademas hay que
    # extraerlo con mkvextract (ffmpeg no lo lee del contenedor); 'copy' = tal cual. ToSrt = srt|rescue.
    $codec = if ($Action -eq 'rescue') { 'webvtt' } else { "$($Stream.codec_name)" }
    [pscustomobject]@{
        Index   = [int]$Stream.index
        Lang    = (Get-Tag $Stream 'language')
        Title   = (Get-Tag $Stream 'title')
        Codec   = $codec
        Forced  = $isForced
        Default = $isDefault
        ToSrt   = ($Action -in @('srt', 'rescue'))
        Rescue  = ($Action -eq 'rescue')
    }
}

function Split-CvSubtitlesByRole {
    <#
        Clasifica los subtitulos (de un idioma) en FORZADOS y COMPLETOS. Primero por flag/titulo
        (Test-SubForced, fiable cuando existe); si NINGUNO esta marcado y hay 2+, se decide por
        TAMAÑO (nº de cues, Get-CvSubtitleCueCount): los notablemente mas pequeños (< 50% del
        maximo) son forzados. Con una sola pista -> completa. Devuelve @{ Forced; Complete }.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Subs)
    $pref = @($Subs)
    $flagged = @($pref | Where-Object { Test-SubForced $_ })
    if ($flagged.Count -gt 0) {
        return @{
            Forced   = $flagged
            Complete = @($pref | Where-Object { -not (Test-SubForced $_) })
        }
    }
    if ($pref.Count -ge 2) {
        $counts = @{}
        foreach ($s in $pref) { $counts[[int]$s.index] = (Get-CvSubtitleCueCount -Context $Context -File $Info.format.filename -Index ([int]$s.index) -Stream $s) }
        $known = @($counts.Values | Where-Object { $_ -ge 0 })
        if ($known.Count -ge 1) {
            $max = ($known | Measure-Object -Maximum).Maximum
            if ($max -gt 0) {
                $f = @($pref | Where-Object { $counts[[int]$_.index] -ge 0 -and $counts[[int]$_.index] -lt ($max * 0.5) })
                return @{
                    Forced   = $f
                    Complete = @($pref | Where-Object { $f -notcontains $_ })
                }
            }
        }
    }
    return @{
        Forced   = @()
        Complete = $pref
    }
}

function Show-SubtitlePreview {
    <#
        Reproduce el video CON un subtitulo concreto superpuesto (ffplay -sst s:N), para distinguir
        entre varios subtitulos (p. ej. normal vs SDH) antes de elegir. Por defecto desde el principio
        y sin limite (preview.start/seconds).
        -SubPos: posicion 0-based entre las pistas de subtitulo.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [int]$SubPos, [string]$Label = 'SUBTITULO', [int]$Start = -1, [int]$Seconds = -1, [double]$Duration = 0
    )
    Write-CvLog 'SUB' ("[TEST] - Reproduciendo con {0}; se cierra solo o pulsa ESC/Q" -f $Label) -Indent 3
    Invoke-CvPreview -Context $Context -File $File -ExtraArgs @('-sst', ("s:{0}" -f $SubPos)) -Label $Label -Start $Start -Seconds $Seconds -Duration $Duration
}

function Show-SubtitleContent {
    <#
        Extrae una pista de subtitulo de texto a un .srt temporal y lo abre con el programa
        asociado de Windows (o Notepad). Las pistas de imagen (PGS/VobSub) no se pueden ver
        como texto: se avisa y no se extrae.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$Stream)
    $idx   = [int]$Stream.index
    $codec = "$($Stream.codec_name)".ToLower()
    $textCodecs = @(
        'subrip'
        'srt'
        'ass'
        'ssa'
        'mov_text'
        'webvtt'
        'text'
        'eia_608'
        'subviewer'
    )
    if ($codec -notin $textCodecs) {
        Write-Host ("   La pista {0} es de imagen ({1}); no se puede ver como texto." -f $idx, $codec) -ForegroundColor Yellow
        return
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_sub_{0}_{1}.srt" -f ([System.IO.Path]::GetFileNameWithoutExtension($File)), $idx)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
    [void](Invoke-ToolCapture -Exe $Context.FFmpeg -Arguments @('-hide_banner','-loglevel','error','-y','-i',$File,'-map',"0:$idx",'-c:s','srt',$tmp) -Context $Context)
    if (Test-Path -LiteralPath $tmp) {
        Write-CvLog 'SUB' ("[TEST] - Abriendo subtitulo {0} en el editor de texto..." -f $idx) -Indent 3
        try { Start-Process -FilePath $tmp } catch { try { Start-Process -FilePath 'notepad.exe' -ArgumentList $tmp } catch {} }
    } else {
        Write-Host ("   No se pudo extraer la pista {0}." -f $idx) -ForegroundColor Yellow
    }
}

function Select-SubtitlesKeep {
    <#
        Fallback cuando hay subtitulos pero NINGUNO en el idioma preferido: muestra todos
        (idioma, codec, nº de cues) y deja elegir CUALES conservar (uno o varios). Se puede
        reproducir el video con un subtitulo ('P N', con segundo de inicio opcional) antes de
        elegir. Devuelve los SubSel elegidos (conservando idioma y disposition original),
        forzados primero. ENTER (vacio) = no conservar ninguno.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Subs)
    $streams = @($Subs)
    $file = $Info.format.filename
    $dur  = Get-MediaDuration $Info
    $cues = @{}
    foreach ($s in $streams) { $cues[[int]$s.index] = (Get-CvSubtitleCueCount -Context $Context -File $file -Index ([int]$s.index) -Stream $s) }
    $to = Get-CvPromptTimeout $Context 'subtitle'   # auto-aceptar por inactividad (0 = off; al expirar = ninguno)

    while ($true) {
        $lines = @()
        foreach ($s in $streams) {
            $t = Get-Tag $s 'title'; $tt = ''; if ($t) { $tt = "'$t'" }
            $c = $cues[[int]$s.index]; $ctxt = if ($c -ge 0) { "$c cues" } else { '? cues' }
            $act = Resolve-CvSubtitleAction -Context $Context -Info $Info -Stream $s
            $cod = if ($act -eq 'rescue') { 'webvtt (rescate->srt)' } elseif ($act -eq 'srt') { "$($s.codec_name) (->srt)" } else { "$($s.codec_name)" }
            $lines += ("[{0}] idioma={1} codec={2} ({3}) {4}" -f $s.index, (Get-Tag $s 'language'), $cod, $ctxt, $tt)
        }
        Show-Menu -Title 'SUBTITULOS (ninguno del idioma preferido) - elige cuales conservar:' -Lines ($lines + @(
            '',
            "Indices separados por espacio (ej '3 5'). Marca el FORZADO con * (ej '*3 5' = conservar 3 y 5,",
            "  forzado = 3); sin *, el forzado se detecta del origen (flag/titulo).",
            "'P N'=reproducir / 'V N'=ver texto / T=todos / ENTER=ninguno")) -Indent 3
        $a = (Read-CvMenuLine '   [SUB] - Opcion' $to).Trim()
        if ($a -eq '') { Write-Host ''; return @() }
        # 'V N' = ver el contenido del subtitulo N (extrae a .srt y abre con el editor asociado).
        $mView = [regex]::Match($a, '^[Vv]\s*(\d+)$')
        if ($mView.Success) {
            $vi = [int]$mView.Groups[1].Value
            $m = $streams | Where-Object { [int]$_.index -eq $vi } | Select-Object -First 1
            if ($m) { Show-SubtitleContent -Context $Context -File $file -Stream $m }
            else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }
        $play = ConvertFrom-CvPlayCommand $a
        if ($play) {
            $m = $streams | Where-Object { [int]$_.index -eq $play.Index } | Select-Object -First 1
            if ($m) { Show-SubtitlePreview -Context $Context -File $file -SubPos (Get-SubtitleStreamPos -Info $Info -Index $play.Index) -Label ("SUBTITULO {0}" -f $play.Index) -Start $play.Start -Duration $dur }
            else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }
        # Tokens: 'N' conserva; '*N' ademas marca ese subtitulo como FORZADO (override). 'T' = todos.
        $forcedSet = @{}
        if ($a -match '^[Tt]$') { $chosen = $streams }
        else {
            $idx = @(); $bad = $false
            foreach ($tok in @($a -split '[,\s]+' | Where-Object { $_ -ne '' })) {
                $m = [regex]::Match($tok, '^(\*?)(\d+)$')
                if (-not $m.Success) { $bad = $true; break }
                $n = [int]$m.Groups[2].Value
                if ($idx -notcontains $n) { $idx += $n }
                if ($m.Groups[1].Value -eq '*') { $forcedSet[$n] = $true }
            }
            $chosen = @($streams | Where-Object { $idx -contains [int]$_.index })
            if ($bad -or $chosen.Count -eq 0) { Write-Host '   Indices no validos.' -ForegroundColor Yellow; continue }
        }
        Write-Host ''
        # -Forced $true si el usuario lo marco con '*'; si no ($null), se detecta del origen (Test-SubForced).
        # -Action (Resolve-CvSubtitleAction): copy/srt/rescue por pista (los 'discard' ya se filtraron antes).
        $sel = @($chosen | ForEach-Object { ConvertTo-SubSel $_ -Forced $(if ($forcedSet.ContainsKey([int]$_.index)) { $true } else { $null }) -Action (Resolve-CvSubtitleAction -Context $Context -Info $Info -Stream $_) })
        return @(@($sel | Where-Object { $_.Forced }) + @($sel | Where-Object { -not $_.Forced }))
    }
}

function Select-Subtitles {
    <#
        Subtitulos a conservar. En el idioma preferido se clasifican en FORZADOS y COMPLETOS
        (por flag/titulo o, si no, por tamaño; ver Split-CvSubtitlesByRole) y se conservan TODOS,
        SIN menu: los forzados con disposition default+forced (titulo "Forzados" lo pone el
        multiplex), los completos sin flags ni titulo. Orden: forzados antes que completos.
        Si hay subtitulos pero NINGUNO del idioma preferido, se PREGUNTA cuales conservar.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info, [ref]$Manual = $null)

    # Accion por pista (Resolve-CvSubtitleAction): copy / srt / rescue / discard. Los 'discard' (codec
    # ilegible y no rescatable) se IGNORAN aqui, con aviso, para que no entren en el job ni tumben la
    # conversion. El resto sigue el flujo normal llevando su accion.
    $actions = @{}
    $subs    = @()
    $discard = 0
    foreach ($s in @(Get-SubtitleStreams -Info $Info)) {
        $act = Resolve-CvSubtitleAction -Context $Context -Info $Info -Stream $s
        if ($act -eq 'discard') { $discard++; continue }
        $actions[[int]$s.index] = $act
        $subs += $s
    }
    if ($discard -gt 0) {
        Write-CvLog 'SUB' ("[AVISO] - {0} subtitulo(s) con codec ilegible se ignoran (no se pueden copiar; p.ej. WEBVTT sin 'webvtt' en encode.subtitles.toSrt, o contenedor no-MKV)." -f $discard) -Indent 3
    }
    if ($subs.Count -eq 0) { if ($Context.Debug) { Write-CvLog 'SUB' '[INFO] - El archivo no tiene subtitulos utilizables' }; return @() }

    $pref = @($subs | Where-Object { Test-CvLanguage (Get-Tag $_ 'language') $Context.SubLangs })
    if ($pref.Count -eq 0) {
        Write-CvLog 'SUB' ("[AVISO] - Ningun subtitulo en el idioma preferido ({0}); elige cuales conservar." -f ($Context.SubLangs | Select-Object -First 1)) -Indent 3
        if ($null -ne $Manual) { $Manual.Value = $true }
        return (Select-SubtitlesKeep -Context $Context -Info $Info -Subs $subs)
    }

    $roles    = Split-CvSubtitlesByRole -Context $Context -Info $Info -Subs $pref
    $forced   = @($roles.Forced)
    $complete = @($roles.Complete)
    if ($complete.Count -gt 1) {
        Write-CvLog 'SUB' ("[AVISO] - {0} subtitulos completos en el idioma preferido; se conservan todos (ninguno marcado como principal)." -f $complete.Count) -Indent 3
    }

    # Forzados primero (default+forced); luego completos (sin default ni forced). Cada uno lleva su accion.
    $result = @()
    foreach ($s in $forced)   { $result += (ConvertTo-SubSel $s -Forced $true  -Default $true  -Action $actions[[int]$s.index]) }
    foreach ($s in $complete) { $result += (ConvertTo-SubSel $s -Forced $false -Default $false -Action $actions[[int]$s.index]) }

    if ($Context.Debug) {
        foreach ($r in $result) {
            $rol = if ($r.Forced) { 'forzado' } else { 'completo' }
            $cv  = if ($r.Rescue) { ' -> rescatar+srt' } elseif ($r.ToSrt) { ' -> srt' } else { '' }
            Write-CvLog 'SUB' ("[INFO] - Pista {0} ({1}, {2}) - {3}{4}" -f $r.Index, $r.Lang, $r.Codec, $rol, $cv)
        }
    }
    return $result
}

Export-ModuleMember -Function *
