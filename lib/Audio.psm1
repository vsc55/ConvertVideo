<#
    Audio.psm1 - Fase ASK (seleccion de pista + sincronia) y RUN (extraccion + volumen).
    La normalizacion de volumen se hace midiendo el pico con volumedetect de ffmpeg
    (independiente del locale) y aplicando ganancia al recodificar.
#>

function Get-CvChannelLayout {
    <# Nombre de layout de ffmpeg para N canales (para aformat/aevalsrc del audio de salida). #>
    param([int]$Channels)
    switch ($Channels) {
        1 { 'mono' }; 2 { 'stereo' }; 6 { '5.1' }; 8 { '7.1' }
        default { 'stereo' }
    }
}

function Resolve-CvAudioChannels {
    <#
        Canales de salida: el perfil (AudioChannels) manda si los fija (>=1); si no, el global. <1 -> 2.
        'audioChannels' es un MAXIMO: si SourceChannels>=1 y el objetivo supera al origen, se limita al
        del origen (NO upmix). SourceChannels=0 (desconocido) -> no limita. Devuelve {Channels;Target;
        Capped}: Target = objetivo antes del tope, Channels = final, Capped = $true si se limito.
    #>
    param($ProfChannels, [int]$GlobalChannels, [int]$SourceChannels = 0)
    $t = if ($null -ne $ProfChannels -and [int]$ProfChannels -ge 1) { [int]$ProfChannels } else { [int]$GlobalChannels }
    if ($t -lt 1) { $t = 2 }
    $ch = $t; $capped = $false
    if ($SourceChannels -ge 1 -and $ch -gt $SourceChannels) { $ch = $SourceChannels; $capped = $true }
    [pscustomobject]@{
        Channels = $ch
        Target   = $t
        Capped   = $capped
    }
}

function Resolve-CvDownmixMode {
    <# Modo de downmix 5.1->estereo: el del perfil si lo fija (no vacio), si no el global. En minusculas. #>
    param($ProfMode, $GlobalMode)
    if ("$ProfMode" -ne '') { return "$ProfMode".ToLower() }
    return "$GlobalMode".ToLower()
}

function Resolve-CvAudioTrackPlan {
    <#
        DECISION por pista de audio, compartida por el pipeline por etapas (Invoke-AudioRun) y la
        ejecucion en una pasada (Get-CvOnePassArgs): canales de salida (MAXIMO, sin upmix) + si procede
        el downmix 5.1->estereo con VOZ REFORZADA (beta, doble llave) y su filtro 'pan'. PURA (no ffmpeg,
        no logging): el aviso de canales capados y las lineas de downmix las emite cada llamador con estos
        campos. Devuelve {Channels;Target;Capped;DownmixMode;WantDialogue;Downmix;DownmixPan}.
          - WantDialogue = se pidio voz reforzada (ch=2 + origen 5.1 + downmixMode='dialogue'); Downmix =
            WantDialogue Y el beta activo (Context.BetaDownmix). DownmixPan = filtro 'pan' si Downmix, si no ''.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof, [int]$SourceChannels = 0, [bool]$Is51 = $false)
    $chInfo = Resolve-CvAudioChannels -ProfChannels $Prof.AudioChannels -GlobalChannels $Context.AudioChannels -SourceChannels $SourceChannels
    $ch     = $chInfo.Channels
    $dmMode = Resolve-CvDownmixMode $Prof.DownmixMode $Context.DownmixMode
    $coeffs = if ($null -ne $Prof.DownmixCoeffs) { $Prof.DownmixCoeffs } else { $Context.DownmixCoeffs }
    $wantDialogue = ($ch -eq 2) -and $Is51 -and ($dmMode -eq 'dialogue')
    $downmix      = $wantDialogue -and $Context.BetaDownmix
    $pan          = if ($downmix) { Get-CvDownmixPan -Coeffs $coeffs } else { '' }
    [pscustomobject]@{
        Channels     = $ch
        Target       = $chInfo.Target
        Capped       = $chInfo.Capped
        DownmixMode  = $dmMode
        WantDialogue = $wantDialogue
        Downmix      = $downmix
        DownmixPan   = $pan
    }
}

function Get-CvDownmixPan {
    <#
        Filtro 'pan' del downmix 5.1->estereo con VOZ REFORZADA, de los coeficientes {Center;Front;
        Surround}. c2=central (dialogos), c0/c1=frontales, c4/c5=surrounds (indices validos para 5.1 y
        5.1(side)); el LFE (c3) se descarta. Formato invariante de locale (punto decimal, para ffmpeg).
    #>
    param([Parameter(Mandatory)]$Coeffs)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $cc = ([double]$Coeffs.Center).ToString($inv)
    $cf = ([double]$Coeffs.Front).ToString($inv)
    $cs = ([double]$Coeffs.Surround).ToString($inv)
    'pan=stereo|c0={0}*c2+{1}*c0+{2}*c4|c1={0}*c2+{1}*c1+{2}*c5' -f $cc, $cf, $cs
}

function Resolve-CvVolumeMethod {
    <#
        Metodo de volumen final: si -Method no es valido (Get-CvVolumeMethods) cae al default de config
        (encode.audio.volume.method). 'aacgain' solo aplica a AAC (ReplayGain sobre .m4a): con otro codec
        cae TAMBIEN al default de config ('loudnorm', filtro valido para cualquier codec; antes caia al
        fijo 'peak', hoy LEGACY). Devuelve {Method; AacgainDowngraded} (=$true si se cambio aacgain por
        el codec, para avisar en el worker).
    #>
    param([string]$Method, [string]$Codec)
    $def = "$((Get-CvConfigDefaults).encode.audio.volume.method)"
    # Destino del degradado de aacgain: el default de config, salvo que el propio default fuera
    # 'aacgain' (se caeria sobre si mismo) -> el 1o del catalogo, que nunca es aacgain.
    $fb = if ($def -eq 'aacgain') { (Get-CvVolumeMethodValues)[0] } else { $def }
    $m = "$Method".ToLower()
    if ($m -notin (Get-CvVolumeMethodValues)) { $m = $def }
    $downgraded = $false
    if ($m -eq 'aacgain' -and "$Codec".ToLower() -ne 'aac') { $m = $fb; $downgraded = $true }
    [pscustomobject]@{
        Method            = $m
        AacgainDowngraded = $downgraded
    }
}

function Get-CvAdelayFilter {
    <# Filtro de retardo de la sincronia en una pasada: 'adelay=<ms>:all=1' (ms enteros redondeados). #>
    param([double]$Sync)
    'adelay={0}:all=1' -f [int][math]::Round($Sync * 1000)
}

function Get-CvLoudnormFilter {
    <#
        Filtro 'loudnorm' (normalizacion EBU R128, una pasada) con I/TP/LRA en formato INVARIANTE de
        locale (punto decimal, para ffmpeg). Fuente unica: la usan el pipeline por etapas (Invoke-AudioRun)
        y la ejecucion en una pasada (Get-CvOnePassArgs).
    #>
    param([double]$I, [double]$TP, [double]$LRA)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    'loudnorm=I={0}:TP={1}:LRA={2}' -f $I.ToString($inv), $TP.ToString($inv), $LRA.ToString($inv)
}

function Get-CvAudioFilterChain {
    <#
        Ensambla, EN ORDEN, la rama de filtros de una pista de audio: sincronia (adelay) -> downmix
        (pan voz reforzada) -> volumen (loudnorm/volume). Devuelve un array con los filtros no vacios
        (el llamador lo une con ','); vacio si no hay ninguno. Funcion PURA: cada parte se calcula fuera
        (el metodo de volumen difiere por ruta: loudnorm inline, peak con ganancia medida, aacgain post),
        aqui solo se ordena. Fuente unica del ORDEN, compartida por Invoke-AudioRun y Get-CvOnePassArgs.
    #>
    param([string]$SyncFilter = '', [string]$DownmixPan = '', [string]$VolumeFilter = '')
    $parts = @()
    if ($SyncFilter)   { $parts += $SyncFilter }
    if ($DownmixPan)   { $parts += $DownmixPan }
    if ($VolumeFilter) { $parts += $VolumeFilter }
    return ,$parts
}

function Get-AudioInitDelay {
    <# Devuelve el pts_time del primer frame de audio (desfase inicial) o 0. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, [int]$Index)
    $r = Invoke-ToolCapture -Exe $Context.FFmpeg -Arguments @(
        '-hide_banner','-i',$File,'-map',"0:$Index",'-af','ashowinfo','-f','alaw','-frames:a','1','-y','NUL'
    ) -Context $Context
    $m = [regex]::Match($r.StdErr, 'pts_time:\s*(\d+(\.\d+)?)')
    if ($m.Success) {
        $v = ConvertTo-InvDouble $m.Groups[1].Value
        if ($null -ne $v) { return $v }
    }
    return 0.0
}

function Get-CvStreamEndPts {
    <#
        pts_time del ULTIMO paquete de un stream, leyendo solo cerca del final (barato, por indice).
        $Stream = especificador ffprobe ('v:0' o el indice absoluto '1'). $Duration = duracion del
        contenedor (para saber desde donde leer). $What = etiqueta para el mensaje de consola (que se
        esta analizando). Devuelve 0 si no se puede leer. Avisa en consola porque tarda un poco (abre
        el archivo por indice cerca del final) y muestra [OK] con el fin detectado al terminar.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Stream, [double]$Duration = 0, [string]$What = 'pista')
    $from = [int][Math]::Max(0, $Duration - 40)
    Write-CvLog 'AUDIO' ("[SYNC] - Analizando fin de {0} (leyendo la cola del archivo)..." -f $What) -Indent 3
    $r = Invoke-ToolCapture -Exe $Context.FFprobe -Arguments @(
        '-v', 'error'
        '-select_streams', $Stream
        '-show_entries', 'packet=pts_time'
        '-read_intervals', ("{0}%+45" -f $from)
        '-of', 'csv=p=0'
        $File
    ) -Context $Context
    $vals = @("$($r.StdOut)" -split "`r?`n" | ForEach-Object { ConvertTo-InvDouble ($_.Trim()) } | Where-Object { $null -ne $_ })
    if ($vals.Count) {
        $max = ($vals | Measure-Object -Maximum).Maximum
        Write-CvLog 'AUDIO' ("[SYNC] - Fin de {0}: {1}s [OK]" -f $What, (Format-CvNumber $max)) -Indent 3
        return $max
    }
    Write-CvLog 'AUDIO' ("[SYNC] - Fin de {0}: sin datos (no se pudo leer la cola)" -f $What) -Indent 3
    return 0.0
}

function Resolve-CvAudioAhead {
    <#
        Detecta un AUDIO ADELANTADO por la cola: si el audio ACABA >= $Threshold segundos ANTES que el
        video (con inicios alineados), el audio va adelantado ~esa diferencia y habria que RETRASARLO.
        Devuelve el retardo sugerido (redondeado a centesimas) o 0 si no aplica (umbral 0, datos
        invalidos, o el audio no acaba suficientemente antes). PURA (sin ffmpeg): se le pasan los fines.
    #>
    param([double]$VideoEnd, [double]$AudioEnd, [double]$Threshold)
    if ($Threshold -le 0 -or $VideoEnd -le 0 -or $AudioEnd -le 0) { return 0.0 }
    $diff = $VideoEnd - $AudioEnd
    if ($diff -ge $Threshold) { return [Math]::Round($diff, 2) }
    return 0.0
}

function Show-CvSyncPreview {
    <#
        Previsualiza el desfase de audio reproduciendo la FUENTE directamente con ffplay (no recodifica
        ningun clip ni limita la duracion por defecto: reproduce desde $At hasta el final o hasta que se
        cierra con q/ESC). (1) ORIGINAL: la pista tal cual (se oye el desfase). (2) CORREGIDO (solo si
        $Delay > 0): el MISMO punto con el audio retrasado $Delay s via el filtro 'adelay' -exactamente
        lo que aplica el worker-, de modo que video(W) suena con audio(W-$Delay); los primeros ~$Delay s
        de audio son silencio (la cola previa no forma parte del retardo). Con $Delay = 0 solo se
        reproduce el clip "sin retardo" (util para confirmar un falso positivo). Fail-soft. Un tope de
        duracion opcional sale de -Seconds (>0) o de preview.syncSeconds (0 = sin limite, por defecto).
        $Index = indice absoluto de la pista de audio en el fichero.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, [int]$Index, [double]$Delay, [double]$At = 0, [int]$Seconds = 0)
    $fp = "$($Context.FFplay)"
    if ([string]::IsNullOrWhiteSpace($fp) -or -not (Test-Path -LiteralPath $fp)) { Write-CvLog 'AUDIO' '[SYNC] - No se puede previsualizar (ffplay no disponible).' -Indent 3; return }
    # Tope de duracion: por defecto SIN limite (preview.syncSeconds = 0); -Seconds (>0) o la config lo
    # pueden acotar puntualmente. 0 => Invoke-CvPreview no pone -t (reproduce hasta el final o hasta q/ESC).
    $secs   = if ($Seconds -gt 0) { $Seconds } else { [int]$Context.PreviewSyncSeconds }
    $start  = [int][Math]::Floor([Math]::Max(0.0, $At))
    $astSel = @('-ast', "$Index")   # selecciona la pista de audio por su indice absoluto
    if ($Delay -gt 0) {
        Write-CvLog 'AUDIO' ("[SYNC] - Preview 1/2: ORIGINAL (desde {0}s; el audio va adelantado). Cierra con q/ESC." -f $start) -Indent 3
        Invoke-CvPreview -Context $Context -File $File -ExtraArgs $astSel -Label 'SYNC original' -Start $start -Seconds $secs
        $ms = [int][Math]::Round($Delay * 1000)
        Write-CvLog 'AUDIO' ("[SYNC] - Preview 2/2: CORREGIDO (audio retrasado {0}s; los primeros ~{0}s en silencio). Cierra con q/ESC." -f (Format-CvNumber $Delay)) -Indent 3
        Invoke-CvPreview -Context $Context -File $File -ExtraArgs ($astSel + @('-af', ("adelay={0}:all=1" -f $ms))) -Label 'SYNC corregido' -Start $start -Seconds $secs
    } else {
        Write-CvLog 'AUDIO' ("[SYNC] - Preview: SIN RETARDO (audio tal cual, desde {0}s). Cierra con q/ESC." -f $start) -Indent 3
        Invoke-CvPreview -Context $Context -File $File -ExtraArgs $astSel -Label 'SYNC sin retardo' -Start $start -Seconds $secs
    }
}

function Show-AudioPreview {
    <#
        Reproduce una pista de audio concreta con FFplay para revisarla (por defecto desde el
        principio y sin limite; inicio/duracion configurables en preview.start/seconds).
        -AudioPos: posicion 0-based entre las pistas de AUDIO (se selecciona con '-ast a:N').
        -AudioOnly: sin ventana de video ('-nodisp'); si no, muestra el video con esa pista.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [int]$AudioPos, [string]$Label = 'AUDIO', [switch]$AudioOnly, [int]$Start = -1, [int]$Seconds = -1, [double]$Duration = 0
    )
    $extra = @('-ast', ("a:{0}" -f $AudioPos))
    if ($AudioOnly) { $extra += '-nodisp' }
    $modo = if ($AudioOnly) { 'solo audio' } else { 'video + audio' }
    Write-CvLog 'AUDIO' ("[TEST] - Reproduciendo {0} ({1}); se cierra solo o pulsa ESC/Q" -f $Label, $modo) -Indent 3
    Invoke-CvPreview -Context $Context -File $File -ExtraArgs $extra -Label $Label -Start $Start -Seconds $Seconds -Duration $Duration
}

function Format-CvAudioLine {
    <#
        Linea de una pista de audio para los menus de seleccion: indice, idioma, codec, canales,
        BITRATE (via Get-CvAudioBitrate: stream.bit_rate o tag BPS) y titulo. $Mark = '*' marca la
        recomendada/por defecto. El bitrate ayuda a decidir entre pistas del mismo idioma.
    #>
    param([Parameter(Mandatory)]$Stream, [string]$Mark = ' ')
    $lang  = Get-Tag $Stream 'language'
    $title = Get-Tag $Stream 'title'
    $br    = Get-CvAudioBitrate $Stream
    $brTxt = if ($null -ne $br) { '{0}k' -f [math]::Round($br / 1000) } else { '?' }
    $titleTxt = if ($title) { "'$title'" } else { '' }
    ("{0} [{1}] idioma={2} codec={3} canales={4} bitrate={5} {6}" -f $Mark, $Stream.index, $lang, $Stream.codec_name, $Stream.channels, $brTxt, $titleTxt)
}

function Select-AudioInteractive {
    <#
        Menu para elegir pista de audio cuando hay ambiguedad (2+ del idioma preferido).
        Permite REPRODUCIR cada una ('P N' = video+audio, 'A N' = solo audio, con segundo de
        inicio opcional) para distinguirlas antes de elegir. Devuelve el objeto de seleccion.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$AudioStreams, [int]$DefaultIndex, [double]$Duration = 0
    )
    $streams = @($AudioStreams)
    # Posicion 0-based de cada pista de audio (para '-ast a:N' en la reproduccion).
    $posByIndex = @{}
    for ($i = 0; $i -lt $streams.Count; $i++) { $posByIndex[[int]$streams[$i].index] = $i }
    $to = Get-CvPromptTimeout $Context 'audio'   # auto-aceptar por inactividad (0 = off)

    $lines = @()
    foreach ($s in $streams) {
        $mark = ' '; if ([int]$s.index -eq $DefaultIndex) { $mark = '*' }
        $lines += (Format-CvAudioLine -Stream $s -Mark $mark)
    }
    Show-Menu -Title 'SELECCIONAR PISTA DE AUDIO (mismo idioma) [* = por defecto = mejor calidad]:' -Lines $lines -Indent 3
    while ($true) {
        $a = (Read-CvMenuLine ("   [AUDIO] - Indice / 'P N'=video+audio / 'A N'=solo audio (opc. seg inicio: 'P N 300') [{0}]" -f $DefaultIndex) $to).Trim()
        if ($a -eq '') { $a = "$DefaultIndex" }

        # Reproducir para revisar: 'P N' (video+audio) o 'A N' (solo audio); 3er numero opcional.
        $play = ConvertFrom-CvPlayCommand $a -AllowAudioOnly
        if ($play) {
            if ($posByIndex.ContainsKey($play.Index)) {
                Show-AudioPreview -Context $Context -File $File -AudioPos $posByIndex[$play.Index] -Label ("PISTA {0}" -f $play.Index) -AudioOnly:$play.AudioOnly -Start $play.Start -Duration $Duration
            } else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }

        $n = 0
        if ([int]::TryParse($a, [ref]$n)) {
            $match = $streams | Where-Object { [int]$_.index -eq $n } | Select-Object -First 1
            if ($match) { Write-Host ''; return (ConvertTo-AudioSel $match) }
        }
        Write-Host '   Indice no valido.' -ForegroundColor Yellow
    }
}

function Select-AudioMulti {
    <#
        [multipista] Cuando hay 2+ pistas del idioma preferido: lista SOLO esas, deja
        REPRODUCIR cada una ('P N'=video+audio, 'A N'=solo audio) y elige en UN prompt CUALES
        conservar y CUAL predeterminada. La default se marca con '*' (ej '*3 5' = conservar 3 y 5,
        default = 3). Sin '*', la default es la preseleccionada si esta en el set, si no la 1a
        conservada. ENTER = solo la preseleccionada. T = todas. Devuelve la lista de selecciones
        {Index,Language,Channels,Is51,Default}, con la DEFAULT PRIMERO y el resto en orden de listado.
        -AllStreams = todas las de audio (para la posicion 0-based de la reproduccion); -PrefStreams =
        las del idioma preferido (las que se listan/eligen).
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$AllStreams, [Parameter(Mandatory)]$PrefStreams,
        [int]$DefaultIndex, [double]$Duration = 0
    )
    $all  = @($AllStreams)
    $pref = @($PrefStreams)
    # Posicion 0-based de cada pista de audio entre TODAS (para '-ast a:N' en la reproduccion).
    $posByIndex = @{}
    for ($i = 0; $i -lt $all.Count; $i++) { $posByIndex[[int]$all[$i].index] = $i }
    $prefIdx = @($pref | ForEach-Object { [int]$_.index })
    $to = Get-CvPromptTimeout $Context 'audio'   # auto-aceptar por inactividad (0 = off)

    while ($true) {
        $lines = @()
        foreach ($s in $pref) {
            $mark = ' '; if ([int]$s.index -eq $DefaultIndex) { $mark = '*' }
            $lines += (Format-CvAudioLine -Stream $s -Mark $mark)
        }
        # Ejemplos alineados por columnas con PadRight (no con espacios a mano, que no cuadran).
        $cw = 47   # ancho de la columna del texto antes de 'ej:' (deja hueco tras el texto mas largo)
        $hint = @(
            '',
            "Elige QUE pistas conservar y CUAL sera la predeterminada (el resto se descarta):",
            ("  {0}ej: {1}-> conserva la 1 y la 3"                 -f '- Indices a conservar separados por espacio.'.PadRight($cw), '1 3'.PadRight(6)),
            ("  {0}ej: {1}-> conserva la 1 y la 3, predeterminada = 3" -f '- Marca la PREDETERMINADA con *.'.PadRight($cw), '*3 1'.PadRight(6)),
            "  - [ENTER] = solo la preseleccionada (*)   -   T = todas   -   'P N'/'A N' = previsualizar (video / solo audio)"
        )
        Show-Menu -Title "CONSERVAR PISTAS DE AUDIO (idioma preferido)   [* = predeterminada]:" -Lines ($lines + $hint) -Indent 3
        $a = (Read-CvMenuLine ("   [AUDIO] - Pistas a conservar (* = predeterminada) [{0}]" -f ('*{0}' -f $DefaultIndex)) $to).Trim()

        # Reproducir para revisar.
        $play = ConvertFrom-CvPlayCommand $a -AllowAudioOnly
        if ($play) {
            if ($posByIndex.ContainsKey($play.Index)) {
                Show-AudioPreview -Context $Context -File $File -AudioPos $posByIndex[$play.Index] -Label ("PISTA {0}" -f $play.Index) -AudioOnly:$play.AudioOnly -Start $play.Start -Duration $Duration
            } else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }

        # ENTER = solo la preseleccionada; T = todas.
        $keep = @(); $defIdx = $DefaultIndex
        if ($a -eq '') {
            $keep = @($DefaultIndex)
        }
        elseif ($a -match '^[Tt]$') {
            $keep = @($prefIdx)
        }
        else {
            # Tokens: '*N' marca la default; 'N' conserva. Solo indices del idioma preferido.
            $markDef = $null; $bad = $false
            foreach ($tok in @($a -split '[,\s]+' | Where-Object { $_ -ne '' })) {
                $m = [regex]::Match($tok, '^(\*?)(\d+)$')
                if (-not $m.Success) { $bad = $true; break }
                $n = [int]$m.Groups[2].Value
                if ($prefIdx -notcontains $n) { $bad = $true; break }
                if ($m.Groups[1].Value -eq '*') { $markDef = $n }
                if ($keep -notcontains $n) { $keep += $n }
            }
            if ($bad -or $keep.Count -eq 0) { Write-Host '   Indices no validos (usa solo los del idioma preferido).' -ForegroundColor Yellow; continue }
            if ($null -ne $markDef) { $defIdx = $markDef }
        }
        # La default debe estar en el set: si no se marco o no esta, cae a la preseleccionada (si se
        # conserva) o a la 1a conservada.
        if ($keep -notcontains $defIdx) { $defIdx = if ($keep -contains $DefaultIndex) { $DefaultIndex } else { $keep[0] } }

        Write-Host ''
        # Construir selecciones: DEFAULT primero, resto en orden de listado del idioma preferido.
        $ordered = @($defIdx) + @($keep | Where-Object { $_ -ne $defIdx })
        $result = @()
        foreach ($idx in $ordered) {
            $s = $pref | Where-Object { [int]$_.index -eq $idx } | Select-Object -First 1
            $sel = ConvertTo-AudioSel $s
            $result += [pscustomobject]@{
                Index    = $sel.Index
                Language = $sel.Language
                Channels = $sel.Channels
                Is51     = $sel.Is51
                Default  = ($idx -eq $defIdx)
            }
        }
        return $result
    }
}

function Select-AudioFallback {
    <#
        Cuando NO hay ninguna pista en el idioma preferido: muestra la lista de pistas,
        deja REPRODUCIR (video+audio o solo audio) para confirmar cual es, y luego pregunta
        que IDIOMA asignar (el que trae la pista, otro codigo, o 'und'), porque el tag de
        idioma puede ser una errata. Devuelve un objeto de seleccion {Index,Language,Channels,Is51}.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$AudioStreams, [int]$DefaultIndex, [double]$Duration = 0
    )
    $streams = @($AudioStreams)
    # Posicion 0-based de cada pista de audio (para '-ast a:N' en la reproduccion).
    $posByIndex = @{}
    for ($i = 0; $i -lt $streams.Count; $i++) { $posByIndex[[int]$streams[$i].index] = $i }
    $to = Get-CvPromptTimeout $Context 'audio'   # auto-aceptar por inactividad (0 = off)

    # ---- 1) Elegir pista (con opcion de reproducir para confirmar) ----
    $chosen = $null
    while ($null -eq $chosen) {
        $lines = @()
        foreach ($s in $streams) {
            $mark = ' '; if ([int]$s.index -eq $DefaultIndex) { $mark = '*' }
            $lines += (Format-CvAudioLine -Stream $s -Mark $mark)
        }
        Show-Menu -Title 'SELECCIONAR PISTA DE AUDIO (ningun idioma preferido) [* = descarte]:' -Lines $lines -Indent 3
        $a = (Read-CvMenuLine ("   [AUDIO] - Indice / 'P N'=video+audio / 'A N'=solo audio (opc. seg inicio: 'P N 300') [{0}]" -f $DefaultIndex) $to).Trim()
        if ($a -eq '') { $a = "$DefaultIndex" }

        # Reproducir para revisar: 'P N' (video+audio) o 'A N' (solo audio); 3er numero = segundo
        # de inicio opcional (para buscar dialogo cuando el punto por defecto no tiene voces).
        $play = ConvertFrom-CvPlayCommand $a -AllowAudioOnly
        if ($play) {
            if ($posByIndex.ContainsKey($play.Index)) {
                Show-AudioPreview -Context $Context -File $File -AudioPos $posByIndex[$play.Index] -Label ("PISTA {0}" -f $play.Index) -AudioOnly:$play.AudioOnly -Start $play.Start -Duration $Duration
            } else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }

        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $posByIndex.ContainsKey($n)) {
            $ok = (Read-CvMenuLine ("   Usar la pista {0}? (ENTER=si / N=volver a la lista)" -f $n) $to).Trim()
            if ($ok -match '^[Nn]$') { continue }
            $chosen = $streams | Where-Object { [int]$_.index -eq $n } | Select-Object -First 1
            continue
        }
        Write-Host '   Indice no valido.' -ForegroundColor Yellow
    }

    $sel = ConvertTo-AudioSel $chosen
    # ---- 2) Idioma a asignar (el tag puede ser una errata) ----
    $trackLang = if ($sel.Language) { "$($sel.Language)" } else { '' }
    $lang = 'und'
    while ($true) {
        if ($trackLang) {
            $r = (Read-CvMenuLine ("   [AUDIO] - Idioma a asignar: [ENTER]='{0}' / [O]tro codigo / [U]nd" -f $trackLang) $to).Trim()
        } else {
            $r = (Read-CvMenuLine '   [AUDIO] - La pista no trae idioma: [O]tro codigo / [ENTER]=und' $to).Trim()
        }
        if ($r -eq '')            { $lang = if ($trackLang) { $trackLang } else { 'und' }; break }
        if ($r -match '^[Uu]$')   { $lang = 'und'; break }
        if ($r -match '^[Oo]$') {
            $c = (Read-Host '   Codigo de idioma ISO 639-2 (ej: spa, eng, fre)').Trim()
            if ($c -ne '') { $lang = $c.ToLower(); break }
            continue
        }
        # Permitir teclear el codigo directamente (2-3 letras).
        if ($r -match '^[A-Za-z]{2,3}$') { $lang = $r.ToLower(); break }
        Write-Host '   Opcion no valida.' -ForegroundColor Yellow
    }
    Write-Host ''
    # Devolver la seleccion con el idioma ELEGIDO (no el del tag original).
    return [pscustomobject]@{
        Index    = $sel.Index
        Language = $lang
        Channels = $sel.Channels
        Is51     = $sel.Is51
    }
}

function Invoke-AudioAsk {
    <#
        Devuelve @{ Skip; Tracks=[{Index,Is51,Sync,Lang,Default}]; Manual }. La pista DEFAULT va PRIMERO
        en Tracks. Monopista (encode.multiAudio=$false o <2 pistas del idioma): Tracks tiene 1 elemento.
        Multipista (encode.multiAudio=$true —por defecto— y 2+ pistas del idioma): se eligen varias y cual default.
        En copy (Skip=$true) las Tracks NO se recodifican: el multiplex las copia (o, si Tracks esta
        vacio, cae al comportamiento clasico 0:a:0).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof, [Parameter(Mandatory)]$Info)
    $res    = [ordered]@{
        Skip   = $false
        Tracks = @()
        Manual = $false
    }
    $isCopy = ($Prof.AudioEncoder -eq 'copy')
    $file   = $Info.format.filename
    $adur   = Get-MediaDuration $Info

    $aud = @(Get-AudioStreams -Info $Info)
    if ($aud.Count -eq 0) {
        if ($Context.Debug) { Write-CvLog 'AUDIO' '[SKIP] - No se ha detectado pista de audio' }
        $res.Skip = $true
        return [pscustomobject]$res
    }

    $prefTracks  = @($aud | Where-Object { Test-CvLanguage (Get-Tag $_ 'language') $Context.AudioLangs })
    # Multipista: toggle MultiAudio (encode.multiAudio) y 2+ pistas del idioma preferido.
    $doMulti = ($Context.MultiAudio -and $prefTracks.Count -ge 2)

    # copy SIN multipista -> comportamiento clasico: no se elige nada; el multiplex copia 0:a:0.
    if ($isCopy -and -not $doMulti) {
        if ($Context.Debug) { Write-CvLog 'AUDIO' '[SKIP] - Se copiara la pista de audio original' }
        $res.Skip = $true
        return [pscustomobject]$res
    }

    # ---- Seleccion de pista(s) ----
    $sels = @()   # lista de {Index,Language,Channels,Is51,Default}
    if ($doMulti) {
        # MULTIPISTA (beta): conservar varias del idioma preferido + elegir la predeterminada.
        $preDef = Select-CvDefaultAudio $prefTracks
        Write-CvLog 'AUDIO' ("[INFO] - {0} pistas en el idioma preferido; elige cuales conservar y la predeterminada." -f $prefTracks.Count) -Indent 3
        $sels = @(Select-AudioMulti -Context $Context -File $file -AllStreams $aud -PrefStreams $prefTracks -DefaultIndex ([int]$preDef.index) -Duration $adur)
        $res.Manual = $true
    }
    else {
        # MONOPISTA (como siempre): mejor pista, con menu si hay ambiguedad / fallback si no hay idioma.
        $sel = Select-AudioStream -Info $Info -PrefLangs $Context.AudioLangs
        if ($prefTracks.Count -gt 1) {
            $sel = Select-AudioInteractive -Context $Context -File $file -AudioStreams $aud -DefaultIndex $sel.Index -Duration $adur
            $res.Manual = $true   # varias del idioma preferido
        }
        elseif ($prefTracks.Count -eq 0) {
            Write-CvLog 'AUDIO' ("[AVISO] - No hay pista de audio en el idioma preferido ({0}); elige una manualmente." -f ($Context.AudioLangs -join '/')) -Indent 3
            $sel = Select-AudioFallback -Context $Context -File $file -AudioStreams $aud -DefaultIndex $sel.Index -Duration $adur
            $res.Manual = $true   # no habia idioma preferido
        }
        $lang = if ($sel.Language) { "$($sel.Language)" } else { 'und' }
        $sels = @([pscustomobject]@{
            Index    = $sel.Index
            Language = $lang
            Channels = $sel.Channels
            Is51     = $sel.Is51
            Default  = $true
        })
    }

    # copy CON multipista: se copian las pistas elegidas (no se recodifican).
    if ($isCopy) {
        $res.Skip = $true
        if ($Context.Debug) { Write-CvLog 'AUDIO' '[SKIP] - Se copiaran las pistas de audio elegidas (perfil copy)' }
    }

    # ---- Sincronia audio/video POR PISTA (solo si se recodifica; en copy no aplica) ----
    # Fin del video (barato, por indice): sirve para detectar un audio ADELANTADO (acaba antes que el
    # video con inicios alineados). Solo si esta activa la deteccion (encode.audioSyncThreshold > 0).
    $videoEnd = 0.0
    if (-not $isCopy -and $Context.AudioSyncThreshold -gt 0) {
        $videoEnd = Get-CvStreamEndPts -Context $Context -File $file -Stream 'v:0' -Duration $adur -What 'video'
    }
    $tracks = @()
    foreach ($s in $sels) {
        $lang = if ($s.Language) { "$($s.Language)" } else { 'und' }
        $sync = 0.0
        if (-not $isCopy) {
            $delay = Get-AudioInitDelay -Context $Context -File $file -Index $s.Index
            $lbl = if ($sels.Count -gt 1) { (" (pista {0}, {1})" -f $s.Index, $lang) } else { '' }
            if ($delay -gt 0) {
                # CASO 1: el audio EMPIEZA mas tarde (start_time > 0). NO es una desincronia: los timestamps
                # del origen ya estan alineados (solo no hay sonido en ese primer tramo). Compensarlo con
                # silencio SOLO hace falta si la ruta PIERDE los timestamps al procesar la pista: eso ocurre
                # unicamente en el modo WAV clasico (syncAdelay = false), porque el WAV no guarda marcas de
                # tiempo. Con syncAdelay = true (por defecto, y obligatorio en una-pasada) ffmpeg CONSERVA el
                # offset -tanto en el filter_complex de una-pasada como en el temporal .m4a/.mka de etapas-,
                # asi que anadir el silencio lo DUPLICARIA y dejaria el audio $delay s tarde (desincronia real
                # en la salida, con la fuente correcta). Verificado con ffprobe/silencedetect.
                if ($Context.SyncAdelay) {
                    Write-CvLog 'AUDIO' ("[SYNC] - El audio empieza {0}s mas tarde que el video{1}: offset ya conservado por ffmpeg, no se compensa." -f $delay, $lbl) -Indent 3
                }
                else {
                    Write-CvLog 'AUDIO' ("[SYNC] - El audio empieza {0}s mas tarde que el video{1} (modo WAV clasico: hay que compensarlo)" -f $delay, $lbl) -Indent 3
                    $ans = (Read-CvLine -Prompt ("   [AUDIO] [SYNC] - Silencio a anadir al inicio en seg [{0}] (ENTER=usar / 0=ninguno)" -f $delay) -TimeoutSec (Get-CvPromptTimeout $Context 'sync')).Trim()
                    $res.Manual = $true   # se pregunto por el silencio de sincronia
                    if ($ans -eq '') { $sync = $delay }
                    else { $v = ConvertTo-InvDouble $ans; if ($null -ne $v) { $sync = $v } }
                    Write-Host ''
                }
            }
            else {
                # CASO 2: el audio ACABA antes que el video (inicios alineados) -> parece ADELANTADO; se
                # sugiere retrasarlo esa diferencia. Se PREGUNTA (default = detectado, con preview A/B).
                $audioEnd = if ($videoEnd -gt 0) { Get-CvStreamEndPts -Context $Context -File $file -Stream "$($s.Index)" -Duration $adur -What ("audio pista {0}" -f $s.Index) } else { 0.0 }
                $ahead = Resolve-CvAudioAhead -VideoEnd $videoEnd -AudioEnd $audioEnd -Threshold $Context.AudioSyncThreshold
                if ($ahead -gt 0) {
                    Write-CvLog 'AUDIO' ("[SYNC] - El audio acaba {0}s antes que el video{1}: parece ADELANTADO ~{0}s." -f $ahead, $lbl) -Indent 3
                    # Flujo: (1) preguntar el retardo -> ENTER/timeout usa el detectado (o el ultimo tecleado);
                    # (2) PREVIEW FORZOSO del valor definido en (1) -> nunca se acepta sin haberlo visto/oido;
                    # (3) confirmar -> aceptar sigue; rechazar (N) vuelve a (1) a definir otro. El punto de
                    # muestreo del preview se recalcula segun el valor (At >= valor -> audio de origen valido).
                    $timeout = Get-CvPromptTimeout $Context 'audioSync'
                    $cur = $ahead
                    $prevOf = { param($d) Show-CvSyncPreview -Context $Context -File $file -Index ([int]$s.Index) -Delay $d -At ([Math]::Max($d + 5, [Math]::Min($adur * 0.15, [Math]::Max(0, $adur - 60)))) }
                    $res.Manual = $true
                    $decided = $false
                    while (-not $decided) {
                        # PASO 1: retardo a usar (ENTER/timeout = detectado o ultimo). CUALQUIER valor -incluido
                        # 0 (ninguno)- pasa por preview + confirmacion: no hay atajo que salga del loop sin validar.
                        $ans = (Read-CvLine -Prompt ("   [AUDIO] [SYNC] - Retardo a anadir al audio en seg [{0}] (ENTER=usar {0} / 0=ninguno / <seg>=otro)" -f (Format-CvNumber $cur)) -TimeoutSec $timeout).Trim()
                        if ($ans -ne '') { $v = ConvertTo-InvDouble $ans; if ($null -eq $v) { continue }; $cur = $v }
                        # PASO 2: preview forzoso del valor definido (con 0 = "sin retardo", tal cual).
                        & $prevOf $cur
                        # PASO 3: confirmar. SIN timeout (lectura bloqueante): el loop NO sale hasta que se
                        # confirma explicitamente que suena bien -> el preview puede durar mas que el timeout
                        # y no debe auto-aceptar mientras se escucha. ENTER/S = aceptar; N = volver a definir;
                        # P = repetir preview.
                        $confirmed = $false
                        while (-not $confirmed) {
                            $ok = (Read-CvLine -Prompt ("   [AUDIO] [SYNC] - Suena bien? Aceptar retardo de {0}s? (ENTER/S=aceptar / N=definir otro / P=repetir preview)" -f (Format-CvNumber $cur))).Trim()
                            if ($ok -match '^[Pp]$') { & $prevOf $cur; continue }
                            if ($ok -match '^[Nn]$') { $confirmed = $true }                     # vuelve al paso 2
                            elseif ($ok -eq '' -or $ok -match '^[Ss]$') { $sync = $cur; $decided = $true; $confirmed = $true }   # aceptar
                            # cualquier otra tecla: re-pregunta (no acepta a ciegas)
                        }
                    }
                    Write-Host ''
                }
                elseif ($Context.Debug) {
                    Write-CvLog 'AUDIO' ("[SYNC] - Audio y video alineados [OK] (pista {0})" -f $s.Index)
                }
            }
        }
        $tracks += [pscustomobject]@{
            Index   = [int]$s.Index
            Is51    = [bool]$s.Is51
            Sync    = [double]$sync
            Lang    = $lang
            Default = [bool]$s.Default
        }
        if ($Context.Debug) { Write-CvLog 'AUDIO' ("[INFO] - Pista {0} (idioma={1}, canales={2}, default={3})" -f $s.Index, $lang, $s.Channels, $s.Default) }
    }
    $res.Tracks = @($tracks)
    return [pscustomobject]$res
}

function Get-MaxVolume {
    <# Mide el pico (max_volume, dB) de una fuente descrita por sus args de entrada. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string[]]$InputArgs)
    $a = @('-hide_banner') + $InputArgs + @('-af','volumedetect','-f','null','-')
    $r = Invoke-ToolCapture -Exe $Context.FFmpeg -Arguments $a -Context $Context
    $m = [regex]::Match($r.StdErr, 'max_volume:\s*(-?\d+(\.\d+)?)')
    if ($m.Success) { return (ConvertTo-InvDouble $m.Groups[1].Value) }
    return $null
}

function Get-CvAudioEncodeArgs {
    <#
        Construye (PURO: sin ejecutar) el comando ffmpeg del ENCODE final de una pista de audio a su
        temporal, a partir de piezas ya resueltas por Invoke-AudioRun (la medicion de 'peak', el WAV
        clasico de sincronia y el 'aacgain' posterior son I/O y se quedan fuera). $ChainParts = cadena de
        filtros ya montada (sincronia+downmix+volumen, via Get-CvAudioFilterChain); si esta vacia, mapeo
        directo con $MapPre. $FromWav = la fuente es el WAV ya recortado (no se re-aplica -t de pruebas).
        Golden-testeable.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Codec, [Parameter(Mandatory)][int]$Channels,
        [Parameter(Mandatory)]$Ar, [string]$Bitrate = '', [Parameter(Mandatory)][string[]]$SourceInput,
        [string[]]$MapPre = @(), [Parameter(Mandatory)][string]$ALabel, $ChainParts = @(),
        [bool]$FromWav = $false, [Parameter(Mandatory)][string]$OutFile
    )
    $ffArgs = @('-hide_banner','-y','-threads',"$($Context.Threads)") + $SourceInput
    if (@($ChainParts).Count -gt 0) {
        $ffArgs += @('-filter_complex', ("[{0}]{1}[a]" -f $ALabel, (@($ChainParts) -join ',')), '-map','[a]')
    } else {
        $ffArgs += $MapPre
    }
    # Codec de salida. '-aac_coder twoloop' es exclusivo del AAC nativo (coder de mayor calidad).
    # FLAC es sin perdida (el bitrate no aplica). El resto usa el samplerate dado y el bitrate.
    $ffArgs += @('-c:a',$Codec)
    if ($Codec -eq 'aac') { $ffArgs += @('-aac_coder', $(if ("$($Context.AacCoder)") { "$($Context.AacCoder)" } else { 'twoloop' })) }
    $ffArgs += @('-ac',"$Channels",'-ar',"$Ar")
    if ($Bitrate -and $Codec -ne 'flac') { $ffArgs += @('-b:a',"$Bitrate") }
    # Modo pruebas: acotar la salida (si la fuente es el WAV clasico, ya viene recortado).
    if ($Context.TestLimit -gt 0 -and -not $FromWav) { $ffArgs += @('-t',"$($Context.TestLimit)") }
    $ffArgs += $OutFile
    return ,$ffArgs
}

function Invoke-AudioRun {
    <#
        Extrae/recodifica UNA pista de audio a un temporal (AAC -> .m4a; resto -> .mka), con sincronia y
        normalizacion de volumen. -Pos = posicion 0-based de la pista en la salida (para la multipista:
        cada pista va a <name>_aN.*); pos 0 = predeterminada. Devuelve la RUTA del temporal generado, o
        $null si falla.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$File, [double]$Sync = 0, [int]$Index = 0, [bool]$Is51 = $false,
        # Duracion del audio en segundos (para el % y ETA del progreso). 0 = desconocida (sin %/ETA).
        [double]$Duration = 0,
        # Canales de la pista de ORIGEN (para no hacer upmix: audioChannels es un MAXIMO). 0 = desconocido.
        [int]$SourceChannels = 0,
        # Posicion 0-based de la pista en la salida (multipista): define el temporal <name>_aN.*.
        [int]$Pos = 0
    )
    $name   = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $atmp   = Get-CvAudioTempPath -Context $Context -Name $name -Pos $Pos
    # Codec de salida al recodificar (perfil; 'aac' por defecto y para compatibilidad con jobs antiguos).
    # AAC va en .m4a (compatible con aacgain); el resto en .mka (Matroska) que admite cualquier codec.
    $codec  = "$($Prof.AudioCodec)".ToLower(); if (-not $codec) { $codec = 'aac' }
    $outM4a = if ($codec -eq 'aac') { $atmp.M4a } else { $atmp.Mka }
    # Limpiar CUALQUIER temporal de audio previo de ESTA pos (m4a y mka) para no dejar el que no toca.
    $oldTemps = @(
        $atmp.M4a
        $atmp.Mka
    )
    foreach ($old in $oldTemps) {
        if (Test-Path -LiteralPath $old) { Remove-Item -Force -LiteralPath $old -ErrorAction SilentlyContinue }
    }

    $hz = if ($Prof.AudioHz) { $Prof.AudioHz } else { $Context.DefaultAudioHz }
    # Plan por pista (canales sin upmix + decision de downmix voz reforzada + pan), fuente unica
    # Resolve-CvAudioTrackPlan, compartido con la ejecucion en una pasada. El aviso de canales capados
    # y las lineas de downmix se emiten aqui con los campos del plan.
    $plan   = Resolve-CvAudioTrackPlan -Context $Context -Prof $Prof -SourceChannels $SourceChannels -Is51 $Is51
    if ($plan.Capped) { Write-CvInfoStep $Context 'AUDIO' ("El origen tiene {0} canales; no se hace upmix a {1} (se conservan {0})" -f $SourceChannels, $plan.Target) }
    $ch     = $plan.Channels
    $layout = Get-CvChannelLayout $ch
    # Downmix con VOZ REFORZADA (BETA): solo al bajar 5.1 -> estereo (ch=2) con downmix 'dialogue'.
    # pan por INDICES (vale para 5.1 y 5.1(side)): sube el central (c2 = dialogos) y baja los
    # surrounds (c4/c5); descarta el LFE (c3). Coeficientes clip-safe (suman 1.0), asi el pico del
    # downmix nunca supera el de origen y la normalizacion 'peak' (medida en el origen) sigue valida.
    # BETA: los coeficientes son provisionales, a la espera de validarlos/ajustarlos con mas material.
    # Doble llave mientras sea beta: el modo 'dialogue' solo refuerza la voz si test.betaDownmix ($true).
    $wantDialogue = $plan.WantDialogue
    $downmix      = $plan.Downmix
    $panDown      = $plan.DownmixPan
    # Indicar SIEMPRE el downmix 5.1 -> estereo y con que modo: voz reforzada (beta activo), o estandar
    # de ffmpeg (aformat, que atenua el central). Si se pidio 'dialogue' pero el beta esta desactivado,
    # avisar de que sigue en estandar hasta activar test.betaDownmix. Asi se ve en el worker que se hizo.
    if ($ch -eq 2 -and $Is51) {
        if ($downmix)          { Write-CvInfoStep $Context 'AUDIO' 'Downmix 5.1 -> estereo [beta] con voz reforzada (central +, surrounds -)' }
        elseif ($wantDialogue) { Write-CvInfoStep $Context 'AUDIO' 'Downmix 5.1 -> estereo (estandar; activa test.betaDownmix para la voz reforzada [beta])' }
        else                   { Write-CvInfoStep $Context 'AUDIO' 'Downmix 5.1 -> estereo (estandar de ffmpeg; downmixMode=dialogue + test.betaDownmix para reforzar la voz)' }
    }

    # Fuente + sincronia (encode.syncAdelay elige el metodo):
    #  - ADELAY (por defecto): el retardo se aplica con el filtro 'adelay' en la MISMA pasada de
    #    codificacion (encadenado con el volumen), sin WAV intermedio.
    #  - CLASICO (syncAdelay=$false): se genera un WAV (silencio + pista) y luego se codifica ese WAV.
    $sourceInput = $null   # args de -i para medir y para codificar
    $mapPre      = @()     # -map (+ -vn/-sn...) cuando NO hay filtro
    $aLabel      = ''      # etiqueta de la pista de audio en el filtro
    $syncFilter  = ''      # filtro de retardo (solo modo adelay)
    $fromWav     = $false  # $true = la fuente es el WAV ya recortado (clasico con sincronia)

    if ($Sync -gt 0 -and $Context.SyncAdelay) {
        # ADELAY: retardo en una pasada con adelay (ms), sin WAV.
        Write-CvInfoStep $Context 'AUDIO' ("Sincronia (adelay): retardo de {0}s en una pasada" -f $Sync)
        $sourceInput = @('-i',$File)
        $mapPre      = @('-map',"0:$Index",'-vn','-sn','-map_chapters','-1')
        $aLabel      = "0:$Index"
        $syncFilter  = Get-CvAdelayFilter $Sync
    }
    elseif ($Sync -gt 0) {
        # CLASICO: WAV = silencio + pista, en el layout de salida; el índice concreto (0:Index),
        # no 0:a (que seria la PRIMERA pista y podria no ser la seleccionada).
        $wav = $atmp.SyncWav
        if (Test-Path -LiteralPath $wav) { Remove-Item -Force -LiteralPath $wav -ErrorAction SilentlyContinue }
        # La pista (a2) se lleva al layout de salida con aformat; si hay downmix con voz reforzada,
        # el propio pan hace el downmix a estereo (sustituye al aformat). El silencio se genera ya en
        # el layout de salida y se concatena delante.
        $a2f = if ($downmix) { $panDown } else { "aformat=channel_layouts=$layout" }
        # OJO: el silencio 'd=' debe ir con PUNTO decimal (InvariantCulture); "$Sync" en locale ES daria
        # "0,5" y ffmpeg parte el filtro por la coma (aevalsrc=0:d=0,5 -> error). Bug real de locale.
        $syncSec = ([double]$Sync).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $fc = ("[0:{0}]{1}[a2];aevalsrc=0:d={2}:sample_rate={3}:channel_layout={4}[sil];[sil][a2]concat=n=2:v=0:a=1[out]" -f $Index, $a2f, $syncSec, $hz, $layout)
        Start-CvStep $Context 'AUDIO' ("Generando silencio de {0}s + pista..." -f $Sync)
        $wavArgs = @('-hide_banner','-y','-i',$File,'-filter_complex',$fc,'-map','[out]')
        if ($Context.TestLimit -gt 0) { $wavArgs += @('-t',"$($Context.TestLimit)") }  # modo pruebas
        $wavArgs += $wav
        Invoke-ToolShow -Exe $Context.FFmpeg -Arguments $wavArgs -Context $Context | Out-Null
        $syncOk = (Test-Path -LiteralPath $wav)
        Stop-CvStep $Context 'AUDIO' $syncOk -FailMsg '[ERR] - No se pudo generar el audio sincronizado'
        if (-not $syncOk) { return $null }
        $sourceInput = @('-i',$wav)
        $mapPre      = @('-map','0:a')
        $aLabel      = '0:a'
        $fromWav     = $true
    }
    else {
        $sourceInput = @('-i',$File)
        $mapPre      = @('-map',"0:$Index",'-vn','-sn','-map_chapters','-1')
        $aLabel      = "0:$Index"
    }

    # Metodo de volumen (invalido->default; aacgain->peak si el codec no es AAC): Resolve-CvVolumeMethod.
    $vm     = Resolve-CvVolumeMethod -Method $Context.VolumeMethod -Codec $codec
    $method = $vm.Method
    if ($vm.AacgainDowngraded) { Write-CvInfoStep $Context 'AUDIO' ("Volumen: aacgain no aplica a {0}; se usa '{1}'" -f $codec, $vm.Method) }

    # Filtro principal de VOLUMEN (se encadenara con $syncFilter en una sola cadena de filtros).
    $mainFilter = ''
    if ($method -eq 'peak') {
        # PEAK: medir el pico (volumedetect) y subirlo hasta el objetivo volume.peakTarget
        # (0 dBFS por defecto; -1 deja margen contra el clipping inter-sample del AAC).
        # Solo se AMPLIFICA (gain > 0): si el pico ya supera el objetivo no se atenua.
        $target = [double]$Context.PeakTarget
        # En modo pruebas medimos solo el tramo que se codifica (-t). Si la fuente es el WAV ya
        # viene recortado, asi que el -t solo se añade cuando la fuente es el archivo original.
        $measureArgs = $sourceInput + $mapPre
        if ($Context.TestLimit -gt 0 -and -not $fromWav) { $measureArgs += @('-t',"$($Context.TestLimit)") }
        # Medir el pico recorre TODO el audio (volumedetect): puede tardar. Paso con ✓ para que
        # no parezca colgado entre "Resolucion" y "Aplicando ganancia".
        Start-CvStep $Context 'AUDIO' 'Analizando volumen...'
        $peak = Get-MaxVolume -Context $Context -InputArgs $measureArgs
        $peakTxt = if ($null -ne $peak) { '(pico {0} dB)' -f $peak } else { '(pico desconocido)' }
        Stop-CvStep $Context 'AUDIO' $true -Extra $peakTxt -OkMsg ("[OK] - Volumen analizado {0}" -f $peakTxt)
        $gain = 0.0
        if ($null -ne $peak -and $peak -lt $target) { $gain = [math]::Round($target - $peak, 1) }
        if ($gain -gt 0) {
            Write-CvInfoStep $Context 'AUDIO' ("Aplicando ganancia +{0} dB" -f $gain)
            $gtxt = $gain.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            $mainFilter = 'volume={0}dB:precision=fixed' -f $gtxt
        } elseif ($Context.Debug) { Write-CvLog 'AUDIO' '[VOL] - [PEAK] - Sin ajuste de volumen' }
    }
    elseif ($method -eq 'loudnorm') {
        # LOUDNORM: normalizacion de sonoridad EBU R128 (una pasada). I/TP/LRA desde config (fuente unica
        # Get-CvLoudnormFilter, compartida con la ejecucion en una pasada).
        Write-CvInfoStep $Context 'AUDIO' ("Normalizando sonoridad (I={0}, TP={1}, LRA={2})" -f $Context.LoudnormI, $Context.LoudnormTP, $Context.LoudnormLRA)
        $mainFilter = Get-CvLoudnormFilter -I $Context.LoudnormI -TP $Context.LoudnormTP -LRA $Context.LoudnormLRA
    }
    else {
        # AACGAIN: se codifica sin ajuste y despues se aplica la ganancia sin perdida.
        if ($Context.Debug) { Write-CvLog 'AUDIO' '[VOL] - [AACGAIN] - La ganancia se aplicara al m4a despues de codificar' }
    }

    # Cadena de filtros = sincronia (adelay, beta) + downmix voz + volumen; si no hay ninguno, mapeo
    # directo. El downmix pan va DESPUES de la sincronia y ANTES del volumen (orden en la fuente unica
    # Get-CvAudioFilterChain). Si la fuente es el WAV clasico, el downmix ya se hizo al generarlo.
    # Cadena de filtros (sincronia -> downmix -> volumen; el downmix del WAV clasico ya se hizo al generarlo)
    # y comando de encode final (Get-CvAudioEncodeArgs, puro). Opus fuerza 48 kHz (44,1 falla).
    $panPart    = if ($downmix -and -not $fromWav) { $panDown } else { '' }
    $chainParts = Get-CvAudioFilterChain -SyncFilter $syncFilter -DownmixPan $panPart -VolumeFilter $mainFilter
    $arOut      = if ($codec -eq 'libopus') { 48000 } else { $hz }
    $ffArgs     = Get-CvAudioEncodeArgs -Context $Context -Codec $codec -Channels $ch -Ar $arOut -Bitrate "$($Prof.AudioBitrate)" -SourceInput $sourceInput -MapPre $mapPre -ALabel $aLabel -ChainParts $chainParts -FromWav $fromWav -OutFile $outM4a

    # Progreso inline (% + ETA) si esta activo y sabemos la duracion; si no, ventana aparte + ✓.
    # Total aprox. = duracion (+ el silencio de sincronia, que alarga la salida), acotado a TestLimit.
    $progTotal = [double]$Duration
    if ($Sync -gt 0) { $progTotal += [double]$Sync }
    if ($Context.TestLimit -gt 0) { $progTotal = [math]::Min($progTotal, [double]$Context.TestLimit) }
    $global:CvLastToolError = $null   # el modo progreso lo rellena; se vuelca al log si ffmpeg falla
    if ($Context.Progress -and -not $Context.Debug -and $progTotal -gt 0) {
        $code = Invoke-ToolProgress -Exe $Context.FFmpeg -Arguments $ffArgs -Context $Context -Label 'Recodificando audio...' -TotalSeconds $progTotal
    } else {
        Start-CvStep $Context 'AUDIO' 'Recodificando audio...'
        $code = Invoke-ToolShow -Exe $Context.FFmpeg -Arguments $ffArgs -Context $Context
    }
    if ($code -ne 0) {
        Stop-CvStep $Context 'AUDIO' $false -FailMsg ("[ERR] - ffmpeg devolvio codigo {0}" -f $code)
        Show-CvToolError -Context $Context -Category 'AUDIO' -Name $name -Tool 'ffmpeg-audio'
        if (Test-Path -LiteralPath $outM4a)       { Remove-Item -Force -LiteralPath $outM4a -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $atmp.SyncWav) { Remove-Item -Force -LiteralPath $atmp.SyncWav -ErrorAction SilentlyContinue }
        return $null
    }
    Stop-CvStep $Context 'AUDIO' $true

    # AACGAIN: aplicar la ganancia ReplayGain sobre el m4a ya codificado (sin recodificar).
    if ($method -eq 'aacgain' -and (Test-Path -LiteralPath $outM4a)) {
        if (Test-Path $Context.AacGain) {
            Start-CvStep $Context 'AUDIO' 'Aplicando ganancia sin perdida (aacgain)...'
            [void](Invoke-ToolShow -Exe $Context.AacGain -Arguments @('/r','/c','/q', $outM4a) -Context $Context)
            Stop-CvStep $Context 'AUDIO' $true
        } else {
            Write-CvLog 'AUDIO' '[VOL] - [AACGAIN] - [AVISO] - No se encuentra aacgain.exe, se omite el ajuste'
        }
    }

    # limpieza del wav temporal
    if (Test-Path -LiteralPath $atmp.SyncWav) { Remove-Item -Force -LiteralPath $atmp.SyncWav -ErrorAction SilentlyContinue }

    if (Test-Path -LiteralPath $outM4a) { return $outM4a }
    return $null
}

Export-ModuleMember -Function *
