<#
    MediaInfo.psm1 - Informacion de streams via ffprobe con salida JSON.
    Sustituye a los antiguos AudioGetID.vbs / VideoSizeReal_*.vbs / parseos con findstr.
#>

function Get-Tag {
    <# Lee un tag de un stream de forma segura (ffprobe puede no traer .tags). #>
    param($Stream, [string]$Name)
    if ($null -eq $Stream) { return $null }
    if ($Stream.PSObject.Properties['tags'] -and $Stream.tags -and $Stream.tags.PSObject.Properties[$Name]) {
        return $Stream.tags.$Name
    }
    return $null
}

function Get-MediaInfo {
    <# Devuelve el objeto JSON de ffprobe (streams + format) o $null si falla. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File)
    $r = Invoke-ToolCapture -Exe $Context.FFprobe -Arguments @(
        '-v','quiet','-print_format','json','-show_streams','-show_format', $File
    ) -Context $Context
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) { return $null }
    try { return ($r.StdOut | ConvertFrom-Json) } catch { return $null }
}

function Get-VideoStreams {
    <#
        Pistas de video REALES: excluye caratulas/portadas incrustadas (disposition.attached_pic
        y codecs de imagen: mjpeg/png/bmp/gif/webp), que ffprobe lista como codec_type=video.
    #>
    param([Parameter(Mandatory)]$Info)
    $imageCodecs = @(
        'mjpeg'
        'png'
        'bmp'
        'gif'
        'webp'
    )
    @($Info.streams | Where-Object {
        $_.codec_type -eq 'video' -and
        $_.codec_name -notin $imageCodecs -and
        -not ($_.disposition -and $_.disposition.attached_pic -eq 1)
    })
}

function Get-VideoStream {
    <# Primera pista de video real (excluye caratulas). #>
    param([Parameter(Mandatory)]$Info)
    @(Get-VideoStreams -Info $Info) | Select-Object -First 1
}

function Test-CvHdr {
    <#
        $true si la pista de video de $Info es HDR: su 'color_transfer' es PQ (smpte2084) o HLG
        (arib-std-b67). Esos son los casos que, mostrados como SDR, se ven "lavados". Si se pasa
        -Index, comprueba ESA pista (por indice absoluto); si no, la primera de video real.
    #>
    param([Parameter(Mandatory)]$Info, [int]$Index = -1)
    $hdrTransfers = @(
        'smpte2084'
        'arib-std-b67'
    )
    $s = if ($Index -ge 0) { @($Info.streams | Where-Object { [int]$_.index -eq $Index })[0] } else { Get-VideoStream -Info $Info }
    if (-not $s) { return $false }
    return ("$($s.color_transfer)".ToLower() -in $hdrTransfers)
}

function Get-VideoStreamPos {
    <#
        Posicion 0-based de una pista (por su indice absoluto) entre TODAS las de codec_type=video
        (incluye caratulas), para el stream specifier 'v:N' de ffplay (-vst).
    #>
    param([Parameter(Mandatory)]$Info, [int]$Index)
    $all = @($Info.streams | Where-Object { $_.codec_type -eq 'video' })
    for ($i = 0; $i -lt $all.Count; $i++) { if ([int]$all[$i].index -eq $Index) { return $i } }
    return 0
}

function Get-CvAudioBitrate {
    <#
        Bitrate de una pista de audio en bps (o $null si no se puede saber). Se lee de
        'stream.bit_rate' (lo traen habitualmente AC-3/E-AC-3/DTS) o, si falta, del tag de
        estadisticas de mkvmerge 'BPS' (frecuente en MKV). Sirve para comparar calidad de pistas.
    #>
    param([Parameter(Mandatory)]$Stream)
    $n = [int64]0
    if ($Stream.PSObject.Properties['bit_rate'] -and $Stream.bit_rate -and [int64]::TryParse("$($Stream.bit_rate)".Trim(), [ref]$n) -and $n -gt 0) { return $n }
    $bps = Get-Tag $Stream 'BPS'
    if ($bps -and [int64]::TryParse("$bps".Trim(), [ref]$n) -and $n -gt 0) { return $n }
    return $null
}

function Get-CvAudioCodecRank {
    <# Rango de "calidad de master" del codec de audio (mayor = mejor); desempata pistas equivalentes. #>
    param([string]$Codec)
    switch -Wildcard ("$Codec".ToLower()) {
        'truehd' { 100 }
        'mlp'    { 100 }
        'flac'   { 95 }
        'pcm*'   { 95 }
        'dts'    { 70 }
        'eac3'   { 60 }
        'ac3'    { 50 }
        'opus'   { 42 }
        'aac'    { 40 }
        'vorbis' { 38 }
        'mp3'    { 30 }
        default  { 10 }
    }
}

function Select-CvBestAudio {
    <#
        De un conjunto de pistas de audio, la de MEJOR calidad como fuente: primero mas canales
        (5.1 > estereo), luego mejor codec (Get-CvAudioCodecRank: E-AC-3 > AC-3, etc.) y por
        ultimo mayor bitrate. Devuelve el stream elegido.
    #>
    param([Parameter(Mandatory)]$Streams)
    @($Streams) | Sort-Object `
        @{
            Expression = { [int]$_.channels }
            Descending = $true
        }, `
        @{
            Expression = { Get-CvAudioCodecRank $_.codec_name }
            Descending = $true
        }, `
        @{
            Expression = { $b = Get-CvAudioBitrate $_; if ($null -ne $b) { $b } else { [int64]-1 } }
            Descending = $true
        } |
        Select-Object -First 1
}

function Select-CvDefaultAudio {
    <#
        De un conjunto de pistas de audio, la que se PRESELECCIONA como predeterminada: la marcada
        con disposition.default; si ninguna lo esta, la de mejor calidad (Select-CvBestAudio). La usa
        el menu multipista para sugerir la default (* ) por defecto. Devuelve el stream (o $null).
    #>
    param([Parameter(Mandatory)]$Streams)
    $s = @($Streams)
    if ($s.Count -eq 0) { return $null }
    $def = @($s | Where-Object { $_.disposition -and $_.disposition.default -eq 1 })
    if ($def.Count -gt 0) { return $def[0] }
    return (Select-CvBestAudio $s)
}

function Select-AudioStream {
    <#
        Selecciona la pista de audio: (idioma preferido) > (default) > 5.1 > primera pista.
        Con VARIAS del idioma preferido, elige la de mejor calidad (Select-CvBestAudio: canales,
        luego codec, luego bitrate). Devuelve un objeto con Index, Language, Channels, Is51.
    #>
    param([Parameter(Mandatory)]$Info, [string[]]$PrefLangs = @('spa'))
    $aud = @($Info.streams | Where-Object { $_.codec_type -eq 'audio' })
    if ($aud.Count -eq 0) { return $null }

    $pick = $null
    $spa = @($aud | Where-Object { Test-CvLanguage (Get-Tag $_ 'language') $PrefLangs })
    if ($spa.Count -gt 0) { $pick = Select-CvBestAudio $spa }
    if ($null -eq $pick) {
        $def = @($aud | Where-Object { $_.disposition -and $_.disposition.default -eq 1 })
        if ($def.Count -gt 0) { $pick = $def[0] }
    }
    if ($null -eq $pick) {
        $s51 = @($aud | Where-Object { $_.channels -ge 6 })
        if ($s51.Count -gt 0) { $pick = $s51[0] }
    }
    if ($null -eq $pick) { $pick = $aud[0] }

    return (ConvertTo-AudioSel $pick)
}

function ConvertTo-AudioSel {
    <# Construye el objeto de seleccion {Index,Language,Channels,Is51} a partir de un stream. #>
    param([Parameter(Mandatory)]$Stream)
    [pscustomobject]@{
        Index    = [int]$Stream.index
        Language = (Get-Tag $Stream 'language')
        Channels = [int]$Stream.channels
        Is51     = ([int]$Stream.channels -ge 6)
    }
}

function Get-AudioStreams {
    <# Devuelve todas las pistas de audio del contenedor. #>
    param([Parameter(Mandatory)]$Info)
    @($Info.streams | Where-Object { $_.codec_type -eq 'audio' })
}

function Resolve-CvAudioTitle {
    <#
        Titulo de SALIDA de una pista de audio segun encode.audioKeepTitle: si -Keep es $false ->
        cadena vacia (titulo en blanco); si $true -> el titulo del ORIGEN (la pista con ese indice
        absoluto en $Info), o '' si no lo tiene / no existe. Lo usa Invoke-Multiplex por cada pista.
    #>
    param([bool]$Keep, [Parameter(Mandatory)]$Info, [int]$Index)
    if (-not $Keep) { return '' }
    $s = @($Info.streams | Where-Object { [int]$_.index -eq $Index })[0]
    if ($s) { "$(Get-Tag $s 'title')" } else { '' }
}

function Get-VideoSize {
    <# "AnchoxAlto" del stream de video. #>
    param([Parameter(Mandatory)]$VideoStream)
    "{0}x{1}" -f [int]$VideoStream.width, [int]$VideoStream.height
}

function Get-CvDisplayWidth {
    <#
        Ancho MOSTRADO (display) del video = ancho almacenado x SAR (sample aspect ratio).
        En video anamorfico (pixeles no cuadrados, p.ej. SAR 115:87) el ancho que se ve NO es el
        almacenado: un 1920x1072 con SAR 115:87 se muestra a ~2538px de ancho. Si el SAR es 1:1,
        vacio o desconocido, el ancho mostrado es igual al almacenado.
    #>
    param([int]$Width, [string]$Sar)
    if ($Width -le 0) { return 0 }
    if ($Sar -match '^(\d+):(\d+)$') {
        $n = [int]$Matches[1]; $d = [int]$Matches[2]
        if ($n -gt 0 -and $d -gt 0) { return [int][math]::Round(($Width * $n) / $d) }
    }
    return $Width
}

function Get-CvMaxWidthResize {
    <#
        Decide el reescalado por ANCHO MAXIMO comparando el ancho MOSTRADO (no el almacenado): si el
        ancho de display (Width x SAR) supera MaxWidth, devuelve "tw:-2" (ancho de almacenamiento par,
        altura auto par). El objetivo es que el ancho MOSTRADO caiga a MaxWidth conservando el aspecto
        (DAR) del origen: como scale mantiene el DAR, basta con escalar el almacenamiento a tw = MaxWidth/SAR.
        Nunca amplia por encima del origen. Devuelve '' si no hay que reescalar (o datos invalidos).
        Con SAR 1:1 (pixeles cuadrados) equivale al clasico "MaxWidth:-2".
    #>
    param([int]$Width, [string]$Sar, [int]$MaxWidth)
    if ($Width -le 0 -or $MaxWidth -le 0) { return '' }
    $dw = Get-CvDisplayWidth -Width $Width -Sar $Sar
    if ($dw -le $MaxWidth) { return '' }
    $n = 1; $d = 1
    if ($Sar -match '^(\d+):(\d+)$' -and [int]$Matches[1] -gt 0 -and [int]$Matches[2] -gt 0) {
        $n = [int]$Matches[1]; $d = [int]$Matches[2]
    }
    $tw = [int][math]::Round(($MaxWidth * $d) / $n)   # ancho de almacenamiento cuyo display = MaxWidth
    if ($tw % 2 -ne 0) { $tw-- }                      # par (yuv420 exige dimensiones pares)
    if ($tw -lt 2) { $tw = 2 }
    if ($tw -gt $Width) { $tw = $Width }              # no ampliar el almacenamiento por encima del origen
    "{0}:-2" -f $tw
}

function Get-CvResize {
    <#
        Decide el filtro de reescalado (valor para `scale=`) combinando el ancho maximo (MaxWidth) con
        el tratamiento del video ANAMORFICO (SAR != 1). Devuelve '' si no hay que reescalar.
          - Anamorphic 'keep' (o SAR 1:1): comportamiento clasico (Get-CvMaxWidthResize) -> conserva el
            caracter anamorfico y solo capa por ancho MOSTRADO.
          - 'square'       : cuadra a pixeles cuadrados fijando el ANCHO de almacenamiento (Width; no
            amplia). Sale "W:H,setsar=1" con la proporcion (DAR) del origen conservada.
          - 'squareheight' : cuadra fijando el ALTO (Height); el ancho pasa a ser el MOSTRADO (amplia).
          En 'square'/'squareheight', MaxWidth sigue capando el ancho de salida (y baja el alto a la vez).
        No se usa aqui para ChangeSize (valor literal, tiene prioridad y se resuelve fuera).
    #>
    param([int]$Width, [int]$Height, [string]$Sar, [int]$MaxWidth = 0, [string]$Anamorphic = 'keep')
    if ($Width -le 0 -or $Height -le 0) { return '' }
    $sn = 1; $sd = 1
    if ($Sar -match '^(\d+):(\d+)$' -and [int]$Matches[1] -gt 0 -and [int]$Matches[2] -gt 0) { $sn = [int]$Matches[1]; $sd = [int]$Matches[2] }
    $isAnam = ($sn -ne $sd)
    $mode   = "$Anamorphic".ToLower()

    if ($isAnam -and ($mode -eq 'square' -or $mode -eq 'squareheight')) {
        $dispW  = [int][math]::Round(($Width * $sn) / $sd)   # ancho mostrado del origen
        $darNum = $Width * $sn; $darDen = $Height * $sd      # DAR = darNum/darDen (aspecto mostrado)
        $outW   = if ($mode -eq 'square') { $Width } else { $dispW }
        if ($MaxWidth -gt 0 -and $outW -gt $MaxWidth) { $outW = $MaxWidth }  # capa por MaxWidth
        if ($outW -gt $dispW) { $outW = $dispW }             # nunca ampliar mas que el mostrado original
        if ($outW % 2 -ne 0) { $outW-- }
        if ($outW -lt 2) { $outW = 2 }
        $outH = [int][math]::Round(($outW * $darDen) / $darNum)   # H = W / DAR (conserva proporcion)
        if ($outH % 2 -ne 0) { $outH-- }
        if ($outH -lt 2) { $outH = 2 }
        return "{0}:{1},setsar=1" -f $outW, $outH
    }
    Get-CvMaxWidthResize -Width $Width -Sar $Sar -MaxWidth $MaxWidth
}

function Get-CvChangeSizeResize {
    <#
        Resuelve el reescalado FIJO (changeSize, valor literal 'W:H' donde -1/-2 = auto que conserva el
        aspecto). SOLO REDUCE: si el destino AMPLIARIA el origen (p. ej. changeSize '1920:-2' sobre un
        1280x720), devuelve '' para dejar el video a su tamaño ORIGINAL en vez de estirarlo. Devuelve el
        propio ChangeSize cuando reduce (o iguala) el tamaño. Comparacion por dimension ALMACENADA (es lo
        que toca el filtro scale). '' si no hay changeSize; se aplica tal cual si el formato es inesperado
        o no hay datos del origen (comportamiento previo: no romper casos raros).
    #>
    param([string]$ChangeSize, [int]$Width, [int]$Height)
    $cs = "$ChangeSize".Trim()
    if ($cs -eq '') { return '' }
    if ($Width -le 0 -or $Height -le 0) { return $cs }   # sin datos de origen: aplicar tal cual
    $parts = $cs -split ':'
    if ($parts.Count -lt 2) { return $cs }               # formato inesperado ('W' suelto, etc.): no tocar
    $tw = 0; $th = 0
    [void][int]::TryParse($parts[0].Trim(), [ref]$tw)
    [void][int]::TryParse($parts[1].Trim(), [ref]$th)
    # tw/th <= 0 => token 'auto' (-1/-2) o no numerico: no impone tamaño en esa dimension. Con -2 el
    # otro eje sigue el aspecto, asi que basta comprobar la dimension NUMERICA contra el origen.
    $up = (($tw -gt 0) -and ($tw -gt $Width)) -or (($th -gt 0) -and ($th -gt $Height))
    if ($up) { return '' }
    return $cs
}

function Get-CvAnamorphicWarning {
    <#
        Si la pista es ANAMORFICA (SAR != 1: el tamaño ALMACENADO que reporta el contenedor NO es el que
        se VE), devuelve un texto de aviso para PREPARAR con almacenado vs mostrado y que hara el modo
        Anamorphic configurado. Devuelve '' si los pixeles son cuadrados (nada que avisar). Se comprueba
        SIEMPRE, aunque no haya maxWidth ni reescalado, para que el usuario sepa que el tamaño real difiere.
    #>
    param([int]$Width, [int]$Height, [string]$Sar, [string]$Anamorphic = 'keep')
    if ($Width -le 0 -or $Height -le 0) { return '' }
    $dw = Get-CvDisplayWidth -Width $Width -Sar $Sar
    if ($dw -eq $Width) { return '' }
    $acc = switch ("$Anamorphic".ToLower()) {
        'square'       { "se cuadrara a pixeles cuadrados por ancho (encode.anamorphic='square')" }
        'squareheight' { "se cuadrara a pixeles cuadrados por alto (encode.anamorphic='squareheight')" }
        default        { "se conservara el SAR tal cual (encode.anamorphic='keep'; depende de que el reproductor lo respete)" }
    }
    "Pista anamorfica: almacena {0}x{1} pero SAR {2} -> se VE a {3}x{1}. {4}." -f $Width, $Height, $Sar, $dw, $acc
}

function Get-MediaDuration {
    <# Duracion del contenedor en segundos (double), o 0 si ffprobe no la trae. #>
    param([Parameter(Mandatory)]$Info)
    if ($Info.PSObject.Properties['format'] -and $Info.format.PSObject.Properties['duration']) {
        $d = ConvertTo-InvDouble $Info.format.duration
        if ($null -ne $d) { return [double]$d }
    }
    return 0.0
}

function Get-SubtitleStreamPos {
    <#
        Posicion 0-based de una pista (por su indice absoluto) entre TODAS las de subtitulo,
        para el stream specifier 's:N' de ffplay (-sst).
    #>
    param([Parameter(Mandatory)]$Info, [int]$Index)
    $all = @($Info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
    for ($i = 0; $i -lt $all.Count; $i++) { if ([int]$all[$i].index -eq $Index) { return $i } }
    return 0
}

function Get-CvSubtitleCueCount {
    <#
        Nº de cues (entradas) de una pista de subtitulo por su indice absoluto. Devuelve -1 si no
        se puede determinar. Sirve para distinguir forzado (pocas) de completo (muchas) por tamaño.

        RAPIDO primero: el tag de estadisticas de mkvmerge 'NUMBER_OF_FRAMES' (= nº de cues) es
        instantaneo (ya viene en el stream cargado por Get-MediaInfo, o en un ffprobe de METADATOS).
        Solo si falta ese tag se recurre a '-count_packets', que DEMULTIPLEXA el fichero entero
        (varios segundos en MKVs de varios GB, por cada pista). Muchos MKVs (los muxeados con
        mkvmerge/MKVToolNix) traen el tag, asi que PREPARAR no tiene por que demultiplexar.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File, [int]$Index, $Stream = $null)
    $n = 0

    # 1) Tag NUMBER_OF_FRAMES. Si se pasa el stream (ya viene de Get-MediaInfo CON todos sus tags),
    #    se lee de memoria: si no lo trae, un ffprobe extra tampoco lo encontraria -> directo al
    #    fallback. Sin stream, un ffprobe de METADATOS (rapido, sin demux) para leer el tag.
    $nf = ''
    if ($Stream) {
        $nf = "$(Get-Tag $Stream 'NUMBER_OF_FRAMES')"
    } else {
        $t = Invoke-ToolCapture -Exe $Context.FFprobe -Arguments @(
            '-v','error','-select_streams',"$Index",
            '-show_entries','stream_tags=NUMBER_OF_FRAMES','-of','default=nw=1:nk=1', $File
        ) -Context $Context
        $nf = "$($t.StdOut)".Trim()
    }
    if ([int]::TryParse("$nf".Trim(), [ref]$n)) { return $n }

    # 2) Sin tag: contar paquetes demultiplexando (lento en ficheros grandes).
    $r = Invoke-ToolCapture -Exe $Context.FFprobe -Arguments @(
        '-v','error','-select_streams',"$Index",'-count_packets',
        '-show_entries','stream=nb_read_packets','-of','default=nw=1:nk=1', $File
    ) -Context $Context
    if ([int]::TryParse("$($r.StdOut)".Trim(), [ref]$n)) { return $n }
    return -1
}

function Get-CvChapterCount {
    <# Nº de capitulos del contenedor (ffprobe -show_chapters), 0 si no hay. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File)
    $r = Invoke-ToolCapture -Exe $Context.FFprobe -Arguments @('-v','error','-show_chapters','-of','csv=p=0', $File) -Context $Context
    return @("$($r.StdOut)" -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count
}

function Get-DurationText {
    <# Duracion formateada H:MM:SS a partir de format.duration (segundos). #>
    param([Parameter(Mandatory)]$Info)
    $sec = Get-MediaDuration $Info
    if ($sec -le 0) { return '?' }
    $ts = [TimeSpan]::FromSeconds([math]::Floor($sec))
    # OJO: [int] REDONDEA en PowerShell (0.9 h -> 1); hay que TRUNCAR las horas totales
    # (ej. 53:56 = 0.899 h) con [math]::Floor, si no un video de <1h saldria como "1:MM:SS".
    return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Write-SourceSummary {
    <#
        Resumen del ARCHIVO DE ORIGEN antes de procesarlo (usado en modo pruebas): toda la info
        de las pistas del contenedor -> video (resolucion/codec/fps), TODAS las de audio
        (codec/canales/idioma/titulo), TODAS las de subtitulo (idioma/tipo/forzado/default/nº de
        cues) y capitulos. Sirve para revisar de un vistazo que trae el fichero.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$Info
    )
    $name = [System.IO.Path]::GetFileName($File)

    $lines = @(
        ("Archivo : {0}" -f $name),
        ("Duracion: {0}" -f (Get-DurationText $Info)),
        ''
    )

    # --- Video (pistas reales, excluye caratulas) ---
    $lines += 'Video:'
    $vids = @(Get-VideoStreams -Info $Info)
    if ($vids.Count -eq 0) { $lines += '  (ninguna)' }
    foreach ($v in $vids) {
        $fps = ''
        $rate = if ($v.PSObject.Properties['avg_frame_rate'] -and $v.avg_frame_rate -notmatch '^0') { $v.avg_frame_rate } else { $v.r_frame_rate }
        if ("$rate" -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) { $fps = "  {0:0.##} fps" -f ([double]$Matches[1] / [int]$Matches[2]) }
        $lines += ("  [{0}] {1}  {2}x{3}{4}" -f [int]$v.index, $v.codec_name, [int]$v.width, [int]$v.height, $fps)
    }

    # --- Audio (todas) ---
    $lines += 'Audio:'
    $auds = @(Get-AudioStreams -Info $Info)
    if ($auds.Count -eq 0) { $lines += '  (ninguna)' }
    foreach ($a in $auds) {
        $lang  = "$(Get-Tag $a 'language')"; if ($lang -eq '') { $lang = 'und' }
        $title = "$(Get-Tag $a 'title')"
        $ttl   = if ($title -ne '') { ('  "{0}"' -f $title) } else { '' }
        $lines += ("  [{0}] {1}  {2}ch  {3}{4}" -f [int]$a.index, $a.codec_name, [int]$a.channels, $lang, $ttl)
    }

    # --- Subtitulos (todos): idioma, tipo (codec), forzado, default, nº de cues (tamaño) ---
    $lines += 'Subtitulos:'
    $subs = @($Info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
    if ($subs.Count -eq 0) { $lines += '  (ninguno)' }
    foreach ($s in $subs) {
        $lang  = "$(Get-Tag $s 'language')"; if ($lang -eq '') { $lang = 'und' }
        $title = "$(Get-Tag $s 'title')"
        $flags = @()
        if ($s.disposition -and $s.disposition.forced  -eq 1) { $flags += 'forzado' }
        if ($s.disposition -and $s.disposition.default -eq 1) { $flags += 'default' }
        $fstr  = if ($flags.Count -gt 0) { '  ' + ($flags -join ' ') } else { '' }
        $cues  = Get-CvSubtitleCueCount -Context $Context -File $File -Index ([int]$s.index) -Stream $s
        $csz   = if ($cues -ge 0) { "  cues={0}" -f $cues } else { '' }
        $ttl   = if ($title -ne '') { ('  "{0}"' -f $title) } else { '' }
        $lines += ("  [{0}] {1}  {2}{3}{4}{5}" -f [int]$s.index, $s.codec_name, $lang, $fstr, $csz, $ttl)
    }

    # --- Capitulos ---
    $lines += ("Capitulos: {0}" -f (Get-CvChapterCount -Context $Context -File $File))

    $dash = Get-CvDashLine
    Write-Host ''
    Write-Host $dash
    Write-Host 'RESUMEN DEL ORIGEN'
    Write-Host $dash
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host $dash
    Write-Host ''
}

function Write-ConversionSummary {
    <# Muestra un resumen enmarcado al terminar la conversion de un archivo. #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)][string]$Output,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        $Prof = $null,
        [int]$AudioIndex = -1   # indice absoluto de la pista de audio de ORIGEN elegida (para el resumen)
    )
    $name = [System.IO.Path]::GetFileName($File)

    $origBytes = (Get-Item -LiteralPath $File).Length
    $outBytes  = 0
    if (Test-Path -LiteralPath $Output) { $outBytes = (Get-Item -LiteralPath $Output).Length }
    $origMB = [math]::Round($origBytes / 1MB, 1)
    $outMB  = [math]::Round($outBytes  / 1MB, 1)
    $ahorro = if ($origBytes -gt 0) { [math]::Round(100 * (1 - ($outBytes / $origBytes)), 1) } else { 0 }

    $vs      = Get-VideoStream -Info $Info
    $origRes = if ($vs) { Get-VideoSize -VideoStream $vs } else { '?' }
    $origVc  = if ($vs) { $vs.codec_name } else { '?' }

    # Audio de ORIGEN: la pista elegida (por indice absoluto) o, si no se dio, la primera de audio.
    $srcA = if ($AudioIndex -ge 0) { @($Info.streams | Where-Object { [int]$_.index -eq $AudioIndex })[0] } else { @($Info.streams | Where-Object { $_.codec_type -eq 'audio' })[0] }
    $origAc  = if ($srcA) { $srcA.codec_name } else { '?' }
    $origAch = if ($srcA) { "$($srcA.channels)ch" } else { '?' }
    $origAbrBps = if ($srcA) { Get-CvAudioBitrate -Stream $srcA } else { $null }
    $origAbr = if ($origAbrBps) { " {0}k" -f [math]::Round(([double]$origAbrBps) / 1000) } else { '' }

    $oInfo = Get-MediaInfo -Context $Context -File $Output
    $ov = $null; $oa = $null; $oaAll = @()
    if ($oInfo) {
        $ov = Get-VideoStream -Info $oInfo
        $oaAll = @($oInfo.streams | Where-Object { $_.codec_type -eq 'audio' })
        $oa = $oaAll[0]
    }
    $outRes = if ($ov) { Get-VideoSize -VideoStream $ov } else { '?' }
    $outVc  = if ($ov) { $ov.codec_name } else { '?' }
    $outAc  = if ($oa) { $oa.codec_name } else { '?' }
    $outAch = if ($oa) { "$($oa.channels)ch" } else { '?' }
    # Bitrate del audio: preferimos el medido por ffprobe; si no lo trae (habitual con AAC en
    # MKV), usamos el CONFIGURADO en el perfil (el objetivo de la recodificacion), marcado.
    $outAbr = ''
    if ($oa -and $oa.PSObject.Properties['bit_rate'] -and $oa.bit_rate) {
        $outAbr = " {0}k" -f [math]::Round(([double]$oa.bit_rate) / 1000)
    } elseif ($Prof -and "$($Prof.AudioEncoder)" -ne 'copy' -and $Prof.AudioBitrate) {
        $outAbr = " {0} (config)" -f $Prof.AudioBitrate
    }

    # Subtitulos de la salida: nº + idioma (+ 'forzado' si lo es). OJO: asignacion DIRECTA con
    # @(...), no via 'if () { @() }' (el if desenvuelve el array de 1 elemento a escalar).
    $osubs = @()
    if ($oInfo) { $osubs = @($oInfo.streams | Where-Object { $_.codec_type -eq 'subtitle' }) }
    $subTxt = if ($osubs.Count -gt 0) {
        "{0} ({1})" -f $osubs.Count, ((@($osubs | ForEach-Object {
            $l = "$(Get-Tag $_ 'language')"; if ($l -eq '') { $l = 'und' }
            if ($_.disposition -and $_.disposition.forced -eq 1) { "$l forzado" } else { $l }
        })) -join ', ')
    } else { 'ninguno' }
    # Capitulos de la salida.
    $nChap = Get-CvChapterCount -Context $Context -File $Output

    # Duracion: la del fichero GENERADO (de lo que trata este resumen), no la del original. En
    # modo pruebas ambas difieren (la salida es un recorte), asi que se indica tambien el origen.
    $outDur = if ($oInfo) { Get-DurationText $oInfo } else { Get-DurationText $Info }
    $durTxt = if ($Context.TestLimit -gt 0) { "{0} (origen {1})" -f $outDur, (Get-DurationText $Info) } else { $outDur }

    # Audio de la salida: con UNA pista, origen -> destino (como siempre); con VARIAS (multipista),
    # una linea por pista (idioma, codec, canales, bitrate, titulo y * = predeterminada).
    $audioSection = @()
    if ($oaAll.Count -le 1) {
        $audioSection = @(("Audio   : {0}" -f $(if ("$($Prof.AudioEncoder)" -eq 'copy') {
            "{0} {1}{2}" -f $outAc, $outAch, $outAbr
        } else {
            "{0} {1}{2}  ->  {3} {4}{5}" -f $origAc, $origAch, $origAbr, $outAc, $outAch, $outAbr
        })))
    } else {
        $audioSection = @("Audio   : {0} pistas" -f $oaAll.Count)
        foreach ($s in $oaAll) {
            $l = "$(Get-Tag $s 'language')"; if ($l -eq '') { $l = 'und' }
            $br = Get-CvAudioBitrate -Stream $s; $brTxt = if ($br) { ' {0}k' -f [math]::Round(([double]$br) / 1000) } else { '' }
            $t = "$(Get-Tag $s 'title')"; $tt = if ($t) { " '$t'" } else { '' }
            $def = if ($s.disposition -and $s.disposition.default -eq 1) { '  * (predeterminada)' } else { '' }
            $audioSection += ("          - [{0}] {1} {2}ch{3}{4}{5}" -f $l, $s.codec_name, $s.channels, $brTxt, $tt, $def)
        }
    }

    # Nota: se usa '+=' para incorporar $audioSection (un array de 1..N lineas); dentro de un literal
    # @(...) una variable-array NO se aplana (quedaria anidada y se imprimiria en una sola linea).
    $lines = @(
        ("Archivo : {0}" -f $name),
        ("Duracion: {0}     Tiempo de proceso: {1:hh\:mm\:ss}" -f $durTxt, $Elapsed),
        '',
        ("Tamano  : {0} MB  ->  {1} MB   (ahorro {2}%)" -f $origMB, $outMB, $ahorro),
        # Video: codec origen -> destino; la resolucion se muestra a ambos lados SOLO si cambia
        # (resize); si es la misma, se pone una sola vez para no repetir '1920x1080 -> 1920x1080'.
        ("Video   : {0}" -f $(if ($origRes -eq $outRes) {
            "{0} -> {1}  {2}" -f $origVc, $outVc, $outRes
        } else {
            "{0} {1}  ->  {2} {3}" -f $origVc, $origRes, $outVc, $outRes
        }))
    )
    $lines += $audioSection
    $lines += ("Subs    : {0}" -f $subTxt)
    $lines += ("Caps    : {0}" -f $nChap)
    # En modo pruebas la salida es un RECORTE (la 'Duracion' de arriba ya lo refleja: salida +
    # origen): se avisa explicitamente para que no se confunda con una conversion completa.
    if ($Context.TestLimit -gt 0) {
        $lines += ('', ("*** MODO PRUEBAS: salida recortada a los primeros {0} min ***" -f [int]($Context.TestLimit / 60)))
    }
    # Sin encuadrar: los cuadros recortan las lineas largas (p.ej. el nombre del archivo).
    $dash = Get-CvDashLine
    $eq   = Get-CvSepLine
    Write-Host ''
    Write-Host $dash
    Write-Host 'RESUMEN DE LA CONVERSION'
    Write-Host $dash
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host $eq
    Write-Host ''
}

Export-ModuleMember -Function *
