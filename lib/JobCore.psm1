<#
    JobCore.psm1 - DATOS para preparar un job (sin interfaz).

    Tercera pieza del mismo patron que SetupCore/WorkerCore: aqui vive "que se puede elegir para este
    archivo y que se elegiria solo", en OBJETOS. No pregunta ni pinta nada.

    Por que existe: la fase PREPARAR de la consola (Invoke-VideoAsk / Invoke-AudioAsk /
    Select-Subtitles) mezcla en el mismo bucle DETECTAR, PREGUNTAR y LOGUEAR, asi que no se puede
    reutilizar desde una ventana. Lo que SI se reutiliza -y es lo importante- son las funciones que
    DECIDEN: Select-AudioStream, Split-CvSubtitlesByRole, Find-CropDetectSamples, Get-CvResize,
    Resolve-CvSubtitleAction... Aqui se apoyan esas mismas para armar un BORRADOR con lo que se
    elegiria automaticamente, y la UI solo retoca lo que quiera. Las decisiones siguen teniendo una
    sola fuente; lo que cambia es quien pregunta.

    Ademas ConvertTo-CvJobRecord es la FUENTE UNICA de la forma del .job.json: la usan tanto la
    consola (Convert.ps1 al terminar sus preguntas) como la ventana, para que no haya dos sitios
    escribiendo la misma estructura y se desincronicen.
#>

function ConvertTo-CvJobRecord {
    <#
        FUENTE UNICA de la estructura del .job.json (lo que congela PREPARAR y lee el worker):

            file, profile, ffmpegVersion, aacgainVersion,
            video { skip, index, crop, resize, anim, hdr, keepOriginal },
            audio { skip, tracks[ {index, is51, sync, lang, default} ] },
            subtitles[ ... ]

        Las versiones de herramientas y el HDR no se piden: salen del contexto y del propio archivo
        (Test-CvHdr sobre la pista de video elegida), igual que hacia la consola. Sin -Info no hay
        archivo que mirar, y entonces manda -Hdr: es lo que permite reescribir un job (editar en
        bloque) sin perder lo que ya se habia decidido.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$Prof,
        $Info = $null,
        [bool]$VideoSkip = $false,
        [int]$VideoIndex = -1,
        [string]$Crop = '',
        [string]$Resize = '',
        [bool]$Anim = $false,
        [bool]$AudioSkip = $false,
        # HDR ya sabido (de un job anterior). Solo se usa si no hay -Info que mirar.
        [bool]$Hdr = $false,
        # Si recodificar sale mas caro en tamano que el original, quedarse con la pista original. Se
        # decide POR ARCHIVO y se congela aqui; de serie viene lo que diga encode.video.
        [bool]$KeepOriginal = $false,
        $AudioTracks = @(),
        $Subtitles = @(),
        # Lineas (cues) de TODAS las pistas de subtitulo del archivo, no solo de las elegidas: quien
        # prepara ya las ha contado para decidir, y guardarlas evita que el resumen tenga que volver
        # a demultiplexar el fichero para ensenarlas. Clave = indice de la pista.
        $SubtitleCues = $null
    )
    $hdr = [bool]$Hdr
    if ($null -ne $Info) { $hdr = [bool](Test-CvHdr -Info $Info -Index $VideoIndex) }
    [ordered]@{
        file           = $File
        profile        = $Prof
        ffmpegVersion  = $Context.FFmpegVersion
        aacgainVersion = $Context.AacGainVersion
        video          = @{
            skip   = $VideoSkip
            index  = $VideoIndex
            crop   = $Crop
            resize = $Resize
            anim   = $Anim
            hdr    = $hdr
            keepOriginal = $KeepOriginal
        }
        audio          = @{
            skip   = $AudioSkip
            tracks = @(@($AudioTracks) | ForEach-Object {
                @{
                    index   = [int]$_.Index
                    is51    = [bool]$_.Is51
                    sync    = [double]$_.Sync
                    lang    = "$($_.Lang)"
                    default = [bool]$_.Default
                }
            })
        }
        subtitles      = @($Subtitles)
        subtitleCues   = $(if ($null -ne $SubtitleCues) { $SubtitleCues } else { @{} })
    }
}

function Get-CvJobKeepOriginal {
    <#
        PURO. Si ESTE job dice que, cuando recodificar engorde el video, se use la pista original.
        Los jobs preparados ANTES de existir la opcion no traen el campo: entonces manda -Default (lo
        que diga encode.video.keepOriginalIfBigger), para que un job viejo se comporte como la
        configuracion de ahora y no como un 'no' que nadie eligio.
    #>
    param($Job, [bool]$Default = $false)
    if ($null -eq $Job -or $null -eq $Job.video) { return $Default }
    $v = $Job.video
    $tiene = $false
    if ($v -is [System.Collections.IDictionary]) { $tiene = $v.Contains('keepOriginal') }
    elseif ($null -ne $v.PSObject.Properties['keepOriginal']) { $tiene = $true }
    if (-not $tiene) { return $Default }
    $val = $v.keepOriginal
    if ($null -eq $val) { return $Default }
    return [bool]$val
}

function Get-CvJobProfileOptions {
    <#
        Perfiles que se pueden elegir, en una lista PLANA lista para un desplegable: los de serie por
        grupos (Get-CvProfiles), los propios de config.json (seccion 'profiles') y 'Auto'. El texto
        sale de Format-CvProfileLabel, el mismo del menu de consola, asi que las dos caras ensenan la
        misma etiqueta. 'Auto' se deja SIN resolver (lo resuelve el llamador con Resolve-CvProfileAuto
        cuando hace falta la sonda de GPU).

        Devuelve @{ Key; Text; Group; Prof; IsAuto }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        # Perfiles PROPIOS a incluir. Por defecto los del contexto (los que habia al abrir la
        # aplicacion); quien acaba de guardar uno pasa los del FICHERO, para que salga en la lista
        # sin tener que reiniciar.
        $Profiles = $null
    )
    $out = @()
    $n = 0
    foreach ($g in @(Get-CvProfiles)) {
        foreach ($pr in @($g.Profiles)) {
            $n++
            $out += [pscustomobject]@{
                Key    = "$n"
                Text   = (Format-CvProfileLabel -Prof $pr)
                # 'Label' = el NOMBRE con el que esta guardado en config.json; vacio en los de serie
                # y en Auto, que no viven en ningun fichero (y por eso no se pueden borrar).
                Label  = ''
                Group  = 'serie'
                Prof   = $pr
                IsAuto = $false
            }
        }
    }
    foreach ($obj in @($(if ($null -ne $Profiles) { $Profiles } else { $Context.Profiles }))) {
        if ($null -eq $obj) { continue }
        $n++
        $p   = ConvertTo-CvProfile -Obj $obj
        $lbl = "$(Get-CvProfileProp $obj 'label' '')"
        if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = Format-CvProfileLabel -Prof $p }
        $out += [pscustomobject]@{
            Key    = "$n"
            Text   = $lbl
            Label  = "$(Get-CvProfileProp $obj 'label' '')".Trim()
            Group  = 'config.json'
            Prof   = $p
            IsAuto = $false
        }
    }
    # 'Auto' = el mejor encoder de ESTE equipo; se resuelve al guardar (necesita la sonda de GPU).
    $out += [pscustomobject]@{
        Key    = 'A'
        Text   = 'Auto (mejor encoder de este equipo: GPU si puede, si no CPU)'
        Label  = ''
        Group  = 'auto'
        Prof   = (New-CvProfile -VideoEncoder 'auto' -AudioEncoder 'aac_coder' -AudioBitrate '128k')
        IsAuto = $true
    }
    return @($out)
}

function Get-CvJobVideoOptions {
    <#
        Pistas de video del archivo con lo que hace falta para elegir: tamano ALMACENADO y MOSTRADO
        (que no son el mismo en anamorfico, SAR != 1), codec y si es HDR. 'Auto' marca la que elegiria
        la consola (la primera pista de video real).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info)
    $vids = @(Get-VideoStreams -Info $Info)
    $out  = @()
    for ($i = 0; $i -lt $vids.Count; $i++) {
        $s   = $vids[$i]
        $w   = [int]$s.width
        $h   = [int]$s.height
        $sar = "$($s.sample_aspect_ratio)"
        $dw  = Get-CvDisplayWidth -Width $w -Sar $sar
        $anam = ($w -gt 0 -and $dw -ne $w)
        $txt = ("[{0}] {1}x{2} {3}" -f $s.index, $w, $h, $s.codec_name)
        if ($anam) { $txt += ("  (anamorfico: se ve a {0}px)" -f $dw) }
        if (Test-CvHdr -Info $Info -Index ([int]$s.index)) { $txt += '  HDR' }
        $out += [pscustomobject]@{
            Index        = [int]$s.index
            Pos          = $i
            Width        = $w
            Height       = $h
            Sar          = $sar
            DisplayWidth = $dw
            Anamorphic   = $anam
            Codec        = "$($s.codec_name)"
            Text         = $txt
            Auto         = ($i -eq 0)
        }
    }
    return @($out)
}

function Get-CvJobAudioOptions {
    <#
        Pistas de audio con idioma, canales, codec y bitrate, marcando cuales estan en el idioma
        PREFERIDO (languages.audio) y cual elegiria la consola sola (Select-AudioStream: la mejor por
        idioma > default > 5.1 > primera). La UI solo tiene que pintar esto y dejar marcar.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info)
    $aud = @(Get-AudioStreams -Info $Info)
    if ($aud.Count -eq 0) { return @() }
    $auto = Select-AudioStream -Info $Info -PrefLangs $Context.AudioLangs
    $autoIdx = if ($auto) { [int]$auto.Index } else { -1 }
    $out = @()
    $pos = -1
    foreach ($s in $aud) {
        $pos++     # posicion 0-based ENTRE LAS DE AUDIO: es lo que pide ffplay para oirla ('-ast a:N')
        $lang = "$(Get-Tag $s 'language')"
        if (-not $lang) { $lang = 'und' }
        $ch    = [int]$s.channels
        $title = "$(Get-Tag $s 'title')"
        $br    = if ($s.bit_rate) { ("{0} kbps" -f [int]([double]$s.bit_rate / 1000)) } else { '' }
        $txt   = ("[{0}] {1}  {2}ch  {3}" -f $s.index, $lang, $ch, $s.codec_name)
        if ($br)    { $txt += ("  {0}" -f $br) }
        if ($title) { $txt += ("  '{0}'" -f $title) }
        $out += [pscustomobject]@{
            Index     = [int]$s.index
            Pos       = $pos
            Lang      = $lang
            Channels  = $ch
            Is51      = ($ch -ge 6)
            Codec     = "$($s.codec_name)"
            Bitrate   = $br
            Title     = $title
            Preferred = [bool](Test-CvLanguage $lang $Context.AudioLangs)
            Auto      = ([int]$s.index -eq $autoIdx)
            Text      = $txt
        }
    }
    return @($out)
}

function Get-CvJobSubtitleOptions {
    <#
        Subtitulos con lo que decide si vale la pena conservarlos: idioma, codec (y que se hara con
        el: copiar / pasar a srt / rescatar), numero de cues, si esta VACIO y si viene marcado como
        forzado o predeterminado. 'Auto' marca los que conservaria la consola sin preguntar (los del
        idioma preferido, clasificados con Split-CvSubtitlesByRole) y 'Forced' el papel que les toca.

        Los de codec ilegible (accion 'discard') se devuelven marcados, NO se esconden: que no se
        puedan usar es justo lo que hay que ver en la ventana.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info)
    $subs = @(Get-SubtitleStreams -Info $Info)
    if ($subs.Count -eq 0) { return @() }
    $file = "$($Info.format.filename)"

    # Los que la consola conservaria sola: los del idioma preferido, repartidos en forzados/completos.
    # Las pistas VACIAS (0 cues) quedan FUERA si encode.subtitles.dropEmpty, igual que en Select-Subtitles:
    # no aportan nada a la salida y ademas CONGELAN la barra de progreso de ffmpeg (out_time se calcula
    # como el minimo de todas las pistas de salida, asi que una que nunca avanza la deja clavada en 0%).
    # Se siguen ENSENANDO -marcadas como VACIO- para que se vea que estan; solo no vienen marcadas.
    $usable = @($subs | Where-Object { (Resolve-CvSubtitleAction -Context $Context -Info $Info -Stream $_) -ne 'discard' })
    if ($Context.SubtitlesDropEmpty) { $usable = @($usable | Where-Object { -not (Test-CvSubtitleEmpty -Stream $_) }) }
    $pref   = @($usable | Where-Object { Test-CvLanguage (Get-Tag $_ 'language') $Context.SubLangs })
    $autoForced = @{}
    $autoKeep   = @{}
    if ($pref.Count -gt 0) {
        $roles = Split-CvSubtitlesByRole -Context $Context -Info $Info -Subs $pref
        foreach ($s in @($roles.Forced))   { $autoKeep[[int]$s.index] = $true; $autoForced[[int]$s.index] = $true }
        foreach ($s in @($roles.Complete)) { $autoKeep[[int]$s.index] = $true }
    }

    $out = @()
    $spos = -1
    foreach ($s in $subs) {
        $spos++    # posicion 0-based ENTRE LAS DE SUBTITULO: es lo que pide ffplay ('-sst s:N')
        $act   = Resolve-CvSubtitleAction -Context $Context -Info $Info -Stream $s
        $lang  = "$(Get-Tag $s 'language')"
        if (-not $lang) { $lang = 'und' }
        $cues  = Get-CvSubtitleCueCount -Context $Context -File $file -Index ([int]$s.index) -Stream $s
        $empty = [bool](Test-CvSubtitleEmpty -Stream $s)
        $title = "$(Get-Tag $s 'title')"
        $conv  = switch ($act) {
            'rescue' { ' -> rescatar a srt' }
            'srt'    { ' -> srt' }
            'discard'{ ' (ilegible: no se puede usar)' }
            default  { '' }
        }
        $txt = ("[{0}] {1}  {2}{3}  {4}" -f $s.index, $lang, $s.codec_name, $conv, $(if ($cues -ge 0) { "$cues cues" } else { '? cues' }))
        if ($empty) { $txt += '  VACIO' }
        if ($title) { $txt += ("  '{0}'" -f $title) }
        $out += [pscustomobject]@{
            Index     = [int]$s.index
            Pos       = $spos
            Lang      = $lang
            Codec     = "$($s.codec_name)"
            Action    = $act
            Usable    = ($act -ne 'discard')
            IsText    = [bool](Test-CvSubtitleTextCodec -Codec "$($s.codec_name)" -Context $Context)
            Cues      = $cues
            Empty     = $empty
            Title     = $title
            Forced    = [bool](Test-SubForced $s)
            Default   = [bool](Test-SubDefault $s)
            Preferred = [bool](Test-CvLanguage $lang $Context.SubLangs)
            Auto      = [bool]$autoKeep[[int]$s.index]
            AutoForced= [bool]$autoForced[[int]$s.index]
            Text      = $txt
            Stream    = $s
        }
    }
    return @($out)
}

function New-CvJobDraft {
    <#
        BORRADOR del job con lo que se elegiria SOLO, sin preguntar ni escanear nada (la deteccion de
        bordes es lenta y va aparte, a peticion: Get-CvJobCropCandidates). Es el punto de partida del
        editor en ventana: se ensena y se retoca.

        Copia (skip) de video/audio: sale del propio perfil, igual que en la consola.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)]$Info,
        [string]$File = ''
    )
    $f = if ($File) { $File } else { "$($Info.format.filename)" }
    $vids = @(Get-CvJobVideoOptions -Context $Context -Info $Info)
    $vIdx = if ($vids.Count -gt 0) { [int]$vids[0].Index } else { -1 }

    # Resize: lo mismo que decide la consola (ChangeSize del perfil, con NoUpscale, o ancho maximo /
    # tratamiento anamorfico via Get-CvResize). Aqui NO hay pregunta anamorfica: se usa lo configurado.
    $resize = ''
    if ($vids.Count -gt 0) {
        $v = $vids[0]
        if ($Prof.ChangeSize) {
            if ([bool]$Prof.NoUpscale) { $resize = "$(Get-CvChangeSizeResize -ChangeSize $Prof.ChangeSize -Width $v.Width -Height $v.Height)" }
            else { $resize = "$($Prof.ChangeSize)" }
        } else {
            $mw = if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { [int]$Prof.MaxWidth } else { 0 }
            $resize = "$(Get-CvResize -Width $v.Width -Height $v.Height -Sar $v.Sar -MaxWidth $mw -Anamorphic "$($Context.Anamorphic)")"
        }
    }

    # Audio: las pistas del idioma preferido si el toggle multipista esta activo y hay varias; si no,
    # la que elige Select-AudioStream. La PREDETERMINADA va primero (como congela la consola).
    $auds  = @(Get-CvJobAudioOptions -Context $Context -Info $Info)
    $picks = @()
    if ($auds.Count -gt 0) {
        $pref = @($auds | Where-Object { $_.Preferred })
        if ($Context.MultiAudio -and $pref.Count -ge 2) {
            $picks = $pref
        } else {
            # OJO: '$picks = if (...) { @($x) }' NO vale. Una expresion 'if' que devuelve un array de
            # UN elemento lo DESENVUELVE al asignarlo, asi que $picks acababa siendo el objeto suelto,
            # sin .Count, y el bucle de abajo no daba ni una vuelta (se quedaba sin pistas de audio).
            $a = @($auds | Where-Object { $_.Auto })
            if ($a.Count -gt 0) { $picks = @($a[0]) } else { $picks = @($auds[0]) }
        }
    }
    $tracks = @()
    $picks  = @($picks)
    for ($i = 0; $i -lt $picks.Count; $i++) {
        $tracks += [pscustomobject]@{
            Index   = [int]$picks[$i].Index
            Is51    = [bool]$picks[$i].Is51
            Sync    = 0.0
            Lang    = "$($picks[$i].Lang)"
            Default = ($i -eq 0)
        }
    }

    # Subtitulos: los que conservaria la consola (idioma preferido, forzados primero).
    $subOpts = @(Get-CvJobSubtitleOptions -Context $Context -Info $Info)
    $subs = @()
    foreach ($s in @($subOpts | Where-Object { $_.Auto -and $_.AutoForced })) {
        $subs += (ConvertTo-SubSel $s.Stream -Forced $true -Default $true -Action $s.Action -Cues ([int]$s.Cues))
    }
    foreach ($s in @($subOpts | Where-Object { $_.Auto -and -not $_.AutoForced })) {
        $subs += (ConvertTo-SubSel $s.Stream -Forced $false -Default $false -Action $s.Action -Cues ([int]$s.Cues))
    }

    # Lineas de TODAS las pistas (ya contadas arriba para clasificarlas): se guardan en el job.
    $cueMap = @{}
    foreach ($s in $subOpts) { if ([int]$s.Cues -ge 0) { $cueMap["$($s.Index)"] = [int]$s.Cues } }

    [pscustomobject]@{
        Name       = [System.IO.Path]::GetFileNameWithoutExtension($f)
        File       = $f
        Prof       = $Prof
        SubCues    = $cueMap
        VideoSkip  = ($Prof.VideoEncoder -eq 'copy') -or ($vids.Count -eq 0)
        VideoIndex = $vIdx
        Hdr        = $false   # se decide al guardar, mirando el archivo (Test-CvHdr)
        KeepOriginal = [bool]$Context.KeepOriginal
        Crop       = ''
        Resize     = $resize
        Anim       = [bool]$Prof.TuneAnimation
        AudioSkip  = ($Prof.AudioEncoder -eq 'copy')
        Audio      = @($tracks)
        Subtitles  = @($subs)
    }
}

function Read-CvJobDraft {
    <#
        Borrador a partir de un job YA existente (para editarlo en vez de crearlo). Las pistas de
        audio salen de Get-CvJobAudioTracks, que ya normaliza el formato antiguo monopista.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $job = Read-CvJob -Context $Context -Name $Name
    $tracks = @()
    foreach ($t in @(Get-CvJobAudioTracks $job.audio)) {
        $tracks += [pscustomobject]@{
            Index   = [int]$t.Index
            Is51    = [bool]$t.Is51
            Sync    = [double]$t.Sync
            Lang    = "$($t.Lang)"
            Default = [bool]$t.Default
        }
    }
    $cueMap = @{}
    if ($job.PSObject.Properties['subtitleCues'] -and $null -ne $job.subtitleCues) {
        foreach ($p in @($job.subtitleCues.PSObject.Properties)) { $cueMap["$($p.Name)"] = [int]$p.Value }
    }
    [pscustomobject]@{
        Name       = $Name
        File       = "$($job.file)"
        Prof       = $job.profile
        SubCues    = $cueMap
        VideoSkip  = [bool]$job.video.skip
        VideoIndex = $(if ($null -ne $job.video.index) { [int]$job.video.index } else { -1 })
        Hdr        = [bool]$job.video.hdr   # ya decidido: se conserva si se reescribe sin analizar
        KeepOriginal = (Get-CvJobKeepOriginal -Job $job -Default ([bool]$Context.KeepOriginal))
        Crop       = "$($job.video.crop)"
        Resize     = "$($job.video.resize)"
        Anim       = [bool]$job.video.anim
        AudioSkip  = [bool]$job.audio.skip
        Audio      = @($tracks)
        Subtitles  = @($job.subtitles)
    }
}

function Save-CvJobDraft {
    <#
        Escribe el borrador como .job.json (Write-CvJob, escritura atomica). Si el perfil es 'auto' se
        resuelve AQUI al mejor encoder de este equipo (Resolve-CvProfileAuto, con la sonda de GPU),
        igual que hace la consola antes de congelarlo: el job debe quedar con un encoder concreto.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Draft,
        $Info = $null
    )
    $prof = Resolve-CvProfileAuto -Context $Context -Prof $Draft.Prof
    $rec  = ConvertTo-CvJobRecord -Context $Context -File $Draft.File -Prof $prof -Info $Info `
        -VideoSkip ([bool]$Draft.VideoSkip) -VideoIndex ([int]$Draft.VideoIndex) `
        -Crop "$($Draft.Crop)" -Resize "$($Draft.Resize)" -Anim ([bool]$Draft.Anim) `
        -Hdr $(if ($Draft.PSObject.Properties['Hdr']) { [bool]$Draft.Hdr } else { $false }) `
        -KeepOriginal $(if ($Draft.PSObject.Properties['KeepOriginal']) { [bool]$Draft.KeepOriginal } else { $false }) `
        -AudioSkip ([bool]$Draft.AudioSkip) -AudioTracks @($Draft.Audio) -Subtitles @($Draft.Subtitles) `
        -SubtitleCues $(if ($Draft.PSObject.Properties['SubCues']) { $Draft.SubCues } else { $null })
    Write-CvJob -Context $Context -Name $Draft.Name -Job $rec
    return $rec
}

function Test-CvJobDraft {
    <#
        PURO. Comprueba lo que impediria codificar y devuelve los avisos (vacio = todo correcto). La UI
        los ensena; no se bloquea nada por si acaso, salvo lo que de verdad no tiene arreglo.
        Devuelve @{ Ok; Errors; Warnings }.
    #>
    param($Draft)
    $err  = @()
    $warn = @()
    if ($null -eq $Draft) { return [pscustomobject]@{ Ok = $false; Errors = @('borrador vacio'); Warnings = @() } }
    if ([string]::IsNullOrWhiteSpace("$($Draft.File)")) { $err += 'no hay archivo de origen' }
    if (-not $Draft.VideoSkip -and [int]$Draft.VideoIndex -lt 0) { $err += 'no hay pista de video elegida' }
    $tr = @($Draft.Audio)
    if ($tr.Count -eq 0 -and -not $Draft.AudioSkip) { $warn += 'sin pistas de audio: la salida quedara muda' }
    if ($tr.Count -gt 0 -and @($tr | Where-Object { $_.Default }).Count -ne 1) { $err += 'tiene que haber exactamente UNA pista de audio predeterminada' }
    $crop = "$($Draft.Crop)"
    if ($crop -and $crop -notmatch '^\d+:\d+:\d+:\d+$') { $err += ("recorte mal escrito ('{0}'): tiene que ser W:H:X:Y" -f $crop) }
    foreach ($t in $tr) {
        if ("$($t.Lang)" -notmatch '^[a-z]{3}$') { $warn += ("idioma '{0}' no es un codigo ISO 639-2 de 3 letras" -f $t.Lang) }
    }
    [pscustomobject]@{
        Ok       = ($err.Count -eq 0)
        Errors   = @($err)
        Warnings = @($warn)
    }
}

function Format-CvJobBorderCell {
    <#
        PURO. Lo que pone la columna de BORDES del recorrido de 'Preparar pendientes': si se han
        detectado barras y con que tamano queda el video. Se ve de un vistazo en que archivos ha
        entrado el recorte y en cuales no, sin abrir el job.

          '[x] 1920x960'  hay barras: se recortan y queda ese tamano (ya con el escalado aplicado)
          '[ ] sin barras' se busco y no habia (el perfil detecta bordes)
          '1280x720'       no hay recorte pero el escalado cambia el tamano
          ''               ni se busco ni cambia nada

        Marcas en ASCII a proposito: los .psm1 se leen como Windows-1252 en PowerShell 5.1 si no
        llevan BOM, asi que un simbolo Unicode aqui acabaria en mojibake.
    #>
    param(
        [string]$Crop   = '',
        [string]$Resize = '',
        [int]$Width     = 0,
        [int]$Height    = 0,
        [bool]$Detect   = $false,
        # -Short = solo la marca, sin tamano: para la columna estrecha de la cola, donde lo unico que
        # se quiere es ver de un vistazo cuales llevan recorte.
        [switch]$Short
    )
    if ($Short) {
        if ("$Crop".Trim() -ne '') { return '[x]' }
        if ($Detect) { return '[ ]' }
        return ''
    }
    $geo = Get-CvOutputSize -Width $Width -Height $Height -Crop $Crop -Resize $Resize
    $tam = if ($geo.Width -gt 0) { "{0}x{1}" -f $geo.Width, $geo.Height } else { '' }
    if ("$Crop".Trim() -ne '') { return ("[x] {0}" -f $tam).Trim() }
    if ($Detect) { return '[ ] sin barras' }
    if ($tam -ne '' -and ($geo.Width -ne $Width -or $geo.Height -ne $Height)) { return $tam }
    return ''
}

function Format-CvJobAudioCell {
    <#
        PURO. La celda de AUDIO de la cola: que hay que mirar en este archivo DESPUES de codificar.
        Lo que se marca es lo que puede salir mal aunque la codificacion vaya bien:

          '[x] sync -0,25s'  se aplica un retardo a alguna pista: es lo que hay que comprobar oyendo
          '2 pistas'         se conservan varias (comprobar que el reproductor coge la que toca)
          '5.1'              hay una 5.1 de origen (mezcla a estereo: se pierde o se realza voz)
          ''                 nada raro

        Se combinan (p. ej. '[x] sync -0,25s  2 pistas'). El '[x]' es solo para la sincronia, que es
        lo unico que de verdad se ha DECIDIDO y conviene revisar.
    #>
    param(
        $Tracks,
        [bool]$Skip = $false
    )
    $t = @($Tracks)
    if ($t.Count -eq 0) { return $(if ($Skip) { '' } else { 'sin audio' }) }
    $bits = @()
    $sync = @($t | Where-Object { [double]$_.Sync -ne 0 }) | Select-Object -First 1
    if ($null -ne $sync) { $bits += ("[x] sync {0}s" -f (Format-CvNumber ([double]$sync.Sync))) }
    if ($t.Count -gt 1)  { $bits += ("{0} pistas" -f $t.Count) }
    if (@($t | Where-Object { [bool]$_.Is51 }).Count -gt 0) { $bits += '5.1' }
    return ($bits -join '  ')
}

function Get-CvJobCropCandidates {
    <#
        Escanea bordes negros y devuelve los recortes candidatos con sus VOTOS (Find-CropDetectSamples,
        el mismo que usa la consola), mas el que ganaria por mayoria con los umbrales de config
        (border.autoAcceptPct / autoAcceptMinMargin) y si esa mayoria es FIABLE.

        Es LENTO (N escaneos de ffmpeg), asi que no se llama al abrir: solo cuando se pide.
        Devuelve @{ Groups; Top; TopPct; Margin; Reliable; Total }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Info,
        [int]$Index = -1,
        [int]$Start = -1,
        [int]$Duration = -1,
        [int]$Samples = -1
    )
    $start   = if ($Start    -ge 0) { $Start }    else { [int]$Context.BorderStart }
    $dur     = if ($Duration -ge 0) { $Duration } else { [int]$Context.BorderDur }
    $samples = if ($Samples  -ge 0) { $Samples }  else { [int]$Context.BorderSamples }
    $vdur    = Get-MediaDuration $Info
    $groups  = @((Find-CropDetectSamples -Context $Context -File "$($Info.format.filename)" -Start $start -Duration $dur -VideoDuration $vdur -Index $Index -Samples $samples).Groups)
    $tot     = if ($groups.Count -gt 0) { ($groups | Measure-Object -Property Count -Sum).Sum } else { 0 }
    $topPct  = if ($tot -gt 0) { [int][math]::Round(100 * $groups[0].Count / $tot) } else { 0 }
    $margin  = if ($groups.Count -ge 2) { $groups[0].Count - $groups[1].Count } elseif ($groups.Count -eq 1) { $groups[0].Count } else { 0 }
    $reliable = ($groups.Count -eq 1) -or (($groups.Count -gt 1) -and ($topPct -ge $Context.BorderAutoAcceptPct) -and ($margin -ge $Context.BorderAutoAcceptMargin))
    [pscustomobject]@{
        Groups   = @($groups)
        Top      = $(if ($groups.Count -gt 0) { "$($groups[0].Crop)" } else { '' })
        TopPct   = $topPct
        Margin   = $margin
        Reliable = [bool]$reliable
        Total    = $tot
    }
}

function Get-CvJobSummaryLines {
    <#
        RESUMEN de lo que se le va a hacer a un archivo, en lineas de texto listas para pintar. Sale
        del JOB -que es justo lo que se congelo en PREPARAR y lo que el worker va a ejecutar-, asi que
        es lo que de verdad va a pasar, no una suposicion.

        Es INSTANTANEO: solo lee el .job.json. Con -Info (el de Get-MediaInfo) ensena TODAS las pistas
        del archivo -no solo las elegidas- marcando cuales se conservan y cuales se descartan, que es
        lo que de verdad se quiere comparar; y anade lo que el job no guarda: canales de cada pista de
        audio y numero de cues de cada subtitulo, estos ultimos SOLO si vienen en los tags
        (Get-CvSubtitleCueTag), nunca demultiplexando. Muchos MKV no traen ese tag y entonces no se
        puede saber el nº de lineas sin demultiplexar el fichero ENTERO por pista (varios segundos
        cada una): eso no se hace aqui por las bravas, lo pide quien llama y lo pasa ya contado en
        -CueCounts (tabla indice -> nº de lineas), que manda sobre lo guardado en el job y sobre el tag.

        Sin job devuelve una sola linea diciendolo (el archivo esta sin preparar). Y tolera un job
        INCOMPLETO -sin perfil, sin la seccion de video...-: lo dice y sigue, en vez de fallar. Un job
        puede venir de una version anterior, o haberse quedado a medio escribir; y esto lo pinta un
        manejador de la ventana, donde una excepcion no es un error: es un cuelgue de la aplicacion.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        $Info = $null,
        # OJO con el nombre: en PowerShell las variables NO distinguen mayusculas, asi que un
        # '$cues' local dentro de la funcion PISARIA un parametro llamado '$Cues' (paso: en la
        # segunda vuelta del bucle el parametro ya era un entero y reventaba al llamar ContainsKey).
        $CueCounts = $null
    )
    if (-not (Test-CvJob -Context $Context -Name $Name)) {
        return @('Sin preparar: todavia no hay job, asi que no hay nada decidido.')
    }
    $job = $null
    try { $job = Read-CvJob -Context $Context -Name $Name } catch {
        return @(("No se pudo leer el job: {0}" -f $_.Exception.Message))
    }

    # Indices -> stream, para poder anadir canales y cues cuando hay -Info.
    $byIdx = @{}
    if ($null -ne $Info) {
        foreach ($s in @($Info.streams)) { $byIdx[[int]$s.index] = $s }
    }
    # Lineas por pista: lo que guarda el job (contado al preparar) mas lo que pase el llamador.
    $cueJob = @{}
    if ($job.PSObject.Properties['subtitleCues'] -and $null -ne $job.subtitleCues) {
        foreach ($p in @($job.subtitleCues.PSObject.Properties)) { $cueJob["$($p.Name)"] = [int]$p.Value }
    }
    $fmtKbps = {
        param($Bps)
        if ($null -eq $Bps -or [int64]$Bps -le 0) { return '' }
        return ("{0} kbps" -f [int]([int64]$Bps / 1000))
    }

    # Prefijo comun de TODAS las pistas: '*' = la predeterminada, [x] = se conserva, [ ] = no.
    $mark = {
        param([bool]$Keep, [bool]$Default)
        ("{0}[{1}]" -f $(if ($Default) { '*' } else { ' ' }), $(if ($Keep) { 'x' } else { ' ' }))
    }

    $L = New-Object System.Collections.Generic.List[string]
    $dur = if ($null -ne $Info) { ("   dura {0}" -f (Get-DurationText $Info)) } else { '' }
    $L.Add(("ARCHIVO : {0}{1}" -f $Name, $dur))
    $prof = $job.profile
    $lblProf = '(el job no trae perfil)'
    if ($null -ne $prof) {
        try { $lblProf = Format-CvProfileLabel -Prof $prof } catch { $lblProf = '(perfil ilegible)' }
    }
    $L.Add(("PERFIL  : {0}" -f $lblProf))

    # ---- Video ----
    # Mismo estilo que audio y subtitulos: la cabecera dice QUE se hace y debajo van las pistas del
    # archivo, marcando la elegida. Los datos de la pista (resolucion, codec, bits, fps, bitrate)
    # salen del origen: es con lo que se compara lo que se va a hacer.
    $v = $job.video
    if ($null -eq $v) {
        $L.Add('VIDEO   : (el job no trae la seccion de video)')
    } else {
        $que = if ([bool]$v.skip) { 'se COPIA sin recodificar' } else { 'se recodifica' }
        # El recorte y el escalado NO van en la cabecera: van debajo de la pista elegida, contados en
        # pixeles y con el tamano que queda. Un 'recorte 1920:960:0:60' no dice cuanto se va por cada
        # lado ni con que te quedas, que es justo lo que se quiere saber.
        $bits = @()
        if (-not [bool]$v.skip) {
            if ([bool]$v.anim)  { $bits += 'tune animacion' }
            if ([bool]$v.hdr)   { $bits += 'HDR: se tonemapea' }
            # Solo se dice cuando esta puesto: es la excepcion, no lo normal.
            if (Get-CvJobKeepOriginal -Job $job) { $bits += 'si engorda, se queda el original' }
        }
        $allV = @()
        if ($null -ne $Info) { $allV = @(Get-VideoStreams -Info $Info) }
        $cab = if ($allV.Count -gt 0) { ("{0} pista(s) en el archivo, {1}" -f $allV.Count, $que) } else { $que }
        if ($bits.Count -gt 0) { $cab += ("  {0}" -f ($bits -join '  ')) }
        $L.Add(("VIDEO   : {0}" -f $cab))
        foreach ($vs in $allV) {
            $i = [int]$vs.index
            $o = @((Get-VideoSize -VideoStream $vs), "$($vs.codec_name)")
            if ("$($vs.profile)") { $o += "$($vs.profile)" }
            $depth = Get-CvStreamBitDepth -Stream $vs
            if ($depth -gt 0) { $o += ("{0} bits" -f $depth) }
            $fps = Get-CvFrameRate $vs
            if ($fps -gt 0) { $o += ("{0} fps" -f (Format-CvNumber ([math]::Round($fps, 3)))) }
            $vbr = & $fmtKbps (Get-CvStreamBitrate -Stream $vs)
            if ($vbr) { $o += $vbr }
            $dw = Get-CvDisplayWidth -Width ([int]$vs.width) -Sar "$($vs.sample_aspect_ratio)"
            if ([int]$vs.width -gt 0 -and $dw -ne [int]$vs.width) { $o += ("anamorfico: se ve a {0}px" -f $dw) }
            if (Test-CvHdr -Info $Info -Index $i) { $o += 'HDR' }
            $usa = ($i -eq [int]$v.index)
            $L.Add(("   {0} [{1}] {2}" -f (& $mark $usa $usa), $i, ($o -join '  ')))
            # Debajo de la pista que se codifica, la CADENA: de que se parte, que se quita, que se
            # escala y con que se queda. Cada linea solo sale si hay algo que contar.
            if (-not $usa -or [bool]$v.skip) { continue }
            $geo = Get-CvOutputSize -Width ([int]$vs.width) -Height ([int]$vs.height) -Crop "$($v.crop)" -Resize "$($v.resize)"
            if ($geo.Width -le 0) { continue }
            if ($geo.Cropped) {
                $corte = Format-CvCropCut -Left $geo.Left -Top $geo.Top -Right $geo.Right -Bottom $geo.Bottom
                $L.Add(("        recorte  {0}x{1}   {2}" -f $geo.CropWidth, $geo.CropHeight, $corte))
            }
            if ("$($v.resize)") {
                $baseW = $(if ($geo.CropWidth  -gt 0) { $geo.CropWidth }  else { [int]$vs.width })
                $baseH = $(if ($geo.CropHeight -gt 0) { $geo.CropHeight } else { [int]$vs.height })
                $comoQueda = if ($geo.Width -ne $baseW -or $geo.Height -ne $baseH) {
                    ("-> {0}x{1}" -f $geo.Width, $geo.Height)
                } else { 'no cambia el tamano' }
                $L.Add(("        escalado {0}   {1}" -f $v.resize, $comoQueda))
            }
            # QUEDA: el tamano final con su proporcion (que es lo que dice si las barras se han ido
            # bien) y con que se codifica.
            $q = @(("{0}x{1}" -f $geo.Width, $geo.Height))
            if ($geo.Height -gt 0) { $q[0] += (" ({0}:1)" -f (Format-CvNumber ([math]::Round($geo.Width / [double]$geo.Height, 2)))) }
            if ($null -ne $prof) {
                $enc = Get-CvEncoderShortName -Encoder "$($prof.VideoEncoder)"
                if ($enc) { $q += $enc }
                if ("$($prof.VideoProfile)" -match '10') { $q += '10 bits' }
            }
            $ofps = 0.0
            try { $ofps = [double](Get-CvOutputFps -Context $Context -Info $Info) } catch { $ofps = 0.0 }
            if ($ofps -gt 0) { $q += ("{0} fps" -f (Format-CvNumber ([math]::Round($ofps, 3)))) }
            $L.Add(("        QUEDA    {0}" -f ($q -join '  ')))
        }
    }

    # ---- Audio ----
    # Con -Info se listan TODAS las pistas del archivo marcando las que se quedan ([x]) y las que se
    # descartan ([ ]); sin el, solo se pueden ensenar las elegidas (es lo unico que guarda el job).
    $tracks = @(Get-CvJobAudioTracks $job.audio)
    $keepA  = @{}
    foreach ($t in $tracks) { $keepA[[int]$t.Index] = $t }
    $modo = if ($null -ne $job.audio -and [bool]$job.audio.skip) { 'se COPIAN' } else { 'se recodifican' }
    $allA = @()
    if ($null -ne $Info) { $allA = @(Get-AudioStreams -Info $Info) }
    if ($allA.Count -gt 0) {
        $L.Add(("AUDIO   : {0} pista(s) en el archivo, se conservan {1} ({2})" -f $allA.Count, $tracks.Count, $modo))
        foreach ($a in $allA) {
            $i = [int]$a.index
            $t = $keepA[$i]
            $lang = "$(Get-Tag $a 'language')"; if (-not $lang) { $lang = 'und' }
            $ch   = [int]$a.channels
            $bits = @(("{0,-4}" -f $lang), ("{0}ch" -f $ch), "$($a.codec_name)")
            # Calidad de la pista: bitrate, frecuencia y disposicion de canales.
            $abr = & $fmtKbps (Get-CvAudioBitrate -Stream $a)
            if ($abr) { $bits += $abr }
            $sr = 0
            if ([int]::TryParse("$($a.sample_rate)".Trim(), [ref]$sr) -and $sr -gt 0) { $bits += ("{0} kHz" -f (Format-CvNumber ([math]::Round($sr / 1000.0, 1)))) }
            $lay = "$($a.channel_layout)"
            if ($lay) { $bits += $lay }
            $ttl  = "$(Get-Tag $a 'title')"
            if ($ttl) { $bits += ("'{0}'" -f $ttl) }
            if ($null -ne $t) {
                if ("$($t.Lang)" -ne $lang) { $bits += ("se etiqueta como {0}" -f $t.Lang) }
                if ([double]$t.Sync -ne 0)  { $bits += ("sync {0}s" -f (Format-CvNumber $t.Sync)) }
            }
            $L.Add(("   {0} [{1}] {2}" -f (& $mark ($null -ne $t) ($null -ne $t -and [bool]$t.Default)), $i, ($bits -join '  ')))
            # Y que va a ser de ella: canales de salida (la MISMA decision que toma el codificador,
            # Resolve-CvAudioTrackPlan), codec, bitrate y frecuencia del perfil.
            if ($null -eq $t -or $null -eq $prof -or ($null -ne $job.audio -and [bool]$job.audio.skip)) { continue }
            $plan = $null
            try { $plan = Resolve-CvAudioTrackPlan -Context $Context -Prof $prof -SourceChannels $ch -Is51 ([bool]$t.Is51) } catch { $plan = $null }
            if ($null -eq $plan) { continue }
            $ac = "$($prof.AudioCodec)".ToLower(); if (-not $ac) { $ac = 'aac' }
            $qa = @($ac, ("{0}ch" -f $plan.Channels))
            $abit = "$($prof.AudioBitrate)".Trim()
            if ($abit -match '^(\d+)\s*[kK]$') { $qa += ("{0} kbps" -f $Matches[1]) } elseif ($abit) { $qa += $abit }
            $ahz = 0
            if ([int]::TryParse("$($prof.AudioHz)".Trim(), [ref]$ahz) -and $ahz -le 0) { $ahz = [int]$Context.DefaultAudioHz }
            if ($ac -eq 'libopus') { $ahz = 48000 }   # opus solo admite 48 kHz (lo fuerza el render)
            if ($ahz -gt 0) { $qa += ("{0} kHz" -f (Format-CvNumber ([math]::Round($ahz / 1000.0, 1)))) }
            if ([int]$plan.Channels -lt $ch) { $qa += ("downmix desde {0}ch" -f $ch) }
            if ([bool]$plan.Downmix) { $qa += 'voz reforzada' }
            $L.Add(("        QUEDA    {0}" -f ($qa -join '  ')))
        }
    } elseif ($tracks.Count -eq 0) {
        $L.Add('AUDIO   : ninguna pista (la salida quedara muda)')
    } else {
        $L.Add(("AUDIO   : {0} pista(s) elegida(s), {1}" -f $tracks.Count, $modo))
        foreach ($t in $tracks) {
            $bits = @(("{0,-4}" -f $t.Lang))
            if ([bool]$t.Is51)         { $bits += '5.1' }
            if ([double]$t.Sync -ne 0) { $bits += ("sync {0}s" -f (Format-CvNumber $t.Sync)) }
            $L.Add(("   {0} [{1}] {2}" -f (& $mark $true ([bool]$t.Default)), $t.Index, ($bits -join '  ')))
        }
    }

    # ---- Subtitulos ----
    $subs  = @($job.subtitles)
    $keepS = @{}
    foreach ($s in $subs) { $keepS[[int]$s.Index] = $s }
    $allS = @()
    if ($null -ne $Info) { $allS = @(Get-SubtitleStreams -Info $Info) }
    if ($allS.Count -gt 0) {
        $L.Add(("SUBS    : {0} pista(s) en el archivo, se conservan {1}" -f $allS.Count, $subs.Count))
        foreach ($sub in $allS) {
            $i = [int]$sub.index
            $s = $keepS[$i]
            $lang = "$(Get-Tag $sub 'language')"; if (-not $lang) { $lang = 'und' }
            $bits = @(("{0,-4}" -f $lang), "$($sub.codec_name)")
            # Lo ya contado manda sobre el tag; sin ninguno de los dos, no se inventa nada. El job
            # guarda las lineas de TODAS las pistas (no solo de las elegidas), asi que tambien se
            # ensenan las de las descartadas, que es lo que hace falta para comparar.
            $cues = -1
            if ($null -ne $CueCounts -and $CueCounts.ContainsKey($i)) { $cues = [int]$CueCounts[$i] }
            if ($cues -lt 0 -and $cueJob.ContainsKey("$i")) { $cues = [int]$cueJob["$i"] }
            if ($cues -lt 0 -and $null -ne $s -and $s.PSObject.Properties['Cues']) { $cues = [int]$s.Cues }
            if ($cues -lt 0) { $cues = Get-CvSubtitleCueTag -Stream $sub }
            if ($cues -ge 0) { $bits += ("{0} lineas" -f $cues) }
            if ($cues -eq 0) { $bits += 'VACIO' }
            # Lo que se ESCRIBIRA si se conserva (lo dice el job); si no, como viene en el origen.
            if ($null -ne $s) {
                $bits += $(if ([bool]$s.Forced) { 'forzado' } else { 'completo' })
                if ([bool]$s.Rescue)    { $bits += 'rescatado -> srt' }
                elseif ([bool]$s.ToSrt) { $bits += '-> srt' }
                if ("$($s.Lang)" -ne $lang) { $bits += ("se etiqueta como {0}" -f $s.Lang) }
            } else {
                if (Test-SubForced $sub)  { $bits += 'forzado en origen' }
                if (Test-SubDefault $sub) { $bits += 'predeterminado en origen' }
            }
            $ttl = "$(Get-Tag $sub 'title')"
            if ($ttl) { $bits += ("'{0}'" -f $ttl) }
            $L.Add(("   {0} [{1}] {2}" -f (& $mark ($null -ne $s) ($null -ne $s -and [bool]$s.Default)), $i, ($bits -join '  ')))
        }
    } elseif ($subs.Count -eq 0) {
        $L.Add('SUBS    : ninguno')
    } else {
        $L.Add(("SUBS    : {0} elegido(s)" -f $subs.Count))
        foreach ($s in $subs) {
            $bits = @(("{0,-4}" -f $s.Lang), "$($s.Codec)", $(if ([bool]$s.Forced) { 'forzado' } else { 'completo' }))
            $L.Add(("   {0} [{1}] {2}" -f (& $mark $true ([bool]$s.Default)), $s.Index, ($bits -join '  ')))
        }
    }

    return @($L)
}

function Set-CvJobDraftAudioSync {
    <#
        Detecta el AUDIO ADELANTADO de las pistas elegidas y deja el retardo puesto en el borrador.
        Es lo MISMO que hace la consola al preparar (Invoke-AudioAsk): se compara donde ACABA el video
        con donde acaba cada pista de audio -con los inicios alineados, un audio que termina antes va
        adelantado- y se sugiere retrasarlo esa diferencia (Resolve-CvAudioAhead, la misma funcion
        pura, con el umbral encode.audio.syncThreshold).

        La consola lo pregunta con preview A/B; aqui se APLICA -que es lo que hace su ENTER y lo que
        aplica su timeout- y se DEVUELVE la nota para que la UI lo cuente: el retardo se ve luego en el
        resumen del archivo y en la columna Audio de la cola, y se puede cambiar en el editor del job.

        Es LENTO (lee la cola del fichero con ffprobe, una vez por pista + una por el video), asi que
        va con -OnStep para poder decir por donde va. Devuelve @(notas) -vacio si no hay nada que
        contar- y nunca lanza: una deteccion que falla no puede tumbar la preparacion.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)]$Info,
        [scriptblock]$OnStep = $null
    )
    $notas = @()
    if ([double]$Context.AudioSyncThreshold -le 0) { return $notas }   # deteccion desactivada
    if ([bool]$Draft.AudioSkip) { return $notas }                      # en copy no se toca el audio
    $tracks = @($Draft.Audio)
    if ($tracks.Count -eq 0) { return $notas }
    try {
        if ($OnStep) { & $OnStep 'Comprobando la sincronia del audio...' }
        $dur = Get-MediaDuration $Info
        $file = "$($Draft.File)"
        $vEnd = Get-CvStreamEndPts -Context $Context -File $file -Stream 'v:0' -Duration $dur -What 'video'
        if ($vEnd -le 0) { return $notas }
        foreach ($t in $tracks) {
            if ([double]$t.Sync -ne 0) { continue }   # ya trae un valor puesto a mano: no se pisa
            $aEnd  = Get-CvStreamEndPts -Context $Context -File $file -Stream ("{0}" -f [int]$t.Index) -Duration $dur -What ("audio pista {0}" -f $t.Index)
            $ahead = Resolve-CvAudioAhead -VideoEnd $vEnd -AudioEnd $aEnd -Threshold ([double]$Context.AudioSyncThreshold)
            if ($ahead -gt 0) {
                $t.Sync = [double]$ahead
                $notas += ("Audio adelantado en la pista {0}: se retrasa {1}s" -f $t.Index, (Format-CvNumber $ahead))
            }
        }
    } catch {
        $notas += ("No se pudo comprobar la sincronia del audio: {0}" -f $_.Exception.Message)
    }
    return @($notas)
}

function Get-CvJobBulkFields {
    <#
        PURO. Ajustes que se pueden aplicar A VARIOS JOBS a la vez. Solo estan los que NO dependen de
        lo que tenga dentro cada archivo: la pista de audio, los subtitulos, el retardo o el recorte
        concreto son decisiones de ESE archivo y no se tocan en bloque (lo que no marcas se queda
        exactamente como esta en cada job).

        -Key es la clave que entiende Set-CvJobBulkChanges; -Kind, como se pide en la ventana
        ('profile' = elegir perfil, 'bool' = si/no, 'text' = texto libre, vacio = quitar).
    #>
    return @(
        [pscustomobject]@{
            Key  = 'prof'
            Kind = 'profile'
            Text = 'Perfil de codificacion'
            Help = 'El perfil entero y si se recodifica video y audio (lo de abajo manda).'
        }
        [pscustomobject]@{
            Key  = 'videoCopy'
            Kind = 'bool'
            Text = 'Video'
            On   = 'Copiar (sin recodificar)'
            Off  = 'Recodificar'
            Help = 'Copiar deja la pista de video tal cual, sin recodificarla.'
        }
        [pscustomobject]@{
            Key  = 'audioCopy'
            Kind = 'bool'
            Text = 'Audio'
            On   = 'Copiar (sin recodificar)'
            Off  = 'Recodificar'
            Help = 'No cambia QUE pistas se conservan, solo si se recodifican.'
        }
        [pscustomobject]@{
            Key  = 'keepOriginal'
            Kind = 'bool'
            Text = 'Si engorda al recodificar'
            On   = 'Quedarse con el video ORIGINAL'
            Off   = 'Dejar el recodificado igualmente'
            Help = 'Usar la original si recodificar la hace mas grande (sin tocar la imagen).'
        }
        [pscustomobject]@{
            Key  = 'anim'
            Kind = 'bool'
            Text = 'Animacion'
            On   = 'Si'
            Off  = 'No'
            Help = 'El ajuste del encoder para dibujos (tune animation).'
        }
        [pscustomobject]@{
            Key  = 'resize'
            Kind = 'text'
            Text = 'Escalado'
            Hint = 'vacio = sin escalar'
            Help = 'W:H igual en todos: usa -2 de alto si varian de proporcion.'
        }
        [pscustomobject]@{
            Key  = 'crop'
            Kind = 'text'
            Text = 'Recorte'
            Hint = 'W:H:X:Y, vacio = quitarlo'
            Help = 'Los bordes son de cada archivo: en bloque lo normal es dejarlo vacio.'
        }
    )
}

function Test-CvJobBulkChanges {
    <#
        PURO. Revisa lo que se va a aplicar en bloque antes de tocar ningun job. Devuelve
        @{ Ok; Errors }. Vacio (no se ha marcado nada) tampoco vale: no habria nada que hacer.
    #>
    param($Changes)
    $err = @()
    $c = @{}
    if ($null -ne $Changes) {
        foreach ($k in @($Changes.Keys)) { $c["$k"] = $Changes[$k] }
    }
    if ($c.Count -eq 0) { $err += 'no se ha marcado ningun ajuste' }
    if ($c.ContainsKey('crop')) {
        $crop = "$($c['crop'])"
        if ($crop -and $crop -notmatch '^\d+:\d+:\d+:\d+$') { $err += ("recorte mal escrito ('{0}'): tiene que ser W:H:X:Y" -f $crop) }
    }
    if ($c.ContainsKey('resize')) {
        $rs = "$($c['resize'])"
        if ($rs -and $rs -notmatch '^-?\d+:-?\d+$') { $err += ("escalado mal escrito ('{0}'): tiene que ser W:H (p. ej. 1280:-2)" -f $rs) }
    }
    if ($c.ContainsKey('prof') -and $null -eq $c['prof']) { $err += 'no se ha elegido perfil' }
    return [pscustomobject]@{
        Ok     = ($err.Count -eq 0)
        Errors = @($err)
    }
}

function Set-CvJobBulkChanges {
    <#
        PURO. Aplica a un BORRADOR de job (New-CvJobDraft / Read-CvJobDraft) SOLO las claves que
        vengan en -Changes; todo lo demas -pista de audio, idioma, retardo, subtitulos, pista de
        video- se queda como estaba. Devuelve un borrador NUEVO (no toca el que se le pasa).

        Claves: prof, videoCopy, audioCopy, anim, resize, crop (las de Get-CvJobBulkFields).

        El PERFIL arrastra si se recodifica video y audio, igual que al preparar (New-CvJobDraft):
        un perfil 'copy' con skip a $false dejaria el job incoherente -el worker mira video.skip- y
        cambiar a un perfil de verdad sin quitar el skip no recodificaria nada. Por eso el perfil se
        aplica PRIMERO y lo que hayas marcado a mano manda sobre lo que el perfil implique.
    #>
    param($Draft, $Changes)
    if ($null -eq $Draft) { return $null }
    $out = [ordered]@{}
    foreach ($p in @($Draft.PSObject.Properties)) { $out[$p.Name] = $p.Value }
    $c = @{}
    if ($null -ne $Changes) {
        foreach ($k in @($Changes.Keys)) { $c["$k"] = $Changes[$k] }
    }
    if ($c.ContainsKey('prof') -and $null -ne $c['prof']) {
        $prof = $c['prof']
        $out['Prof']      = $prof
        $out['VideoSkip'] = ("$($prof.VideoEncoder)".ToLower() -eq 'copy')
        $out['AudioSkip'] = ("$($prof.AudioEncoder)".ToLower() -eq 'copy')
        $out['Anim']      = [bool]$prof.TuneAnimation
    }
    if ($c.ContainsKey('videoCopy')) { $out['VideoSkip'] = [bool]$c['videoCopy'] }
    if ($c.ContainsKey('audioCopy')) { $out['AudioSkip'] = [bool]$c['audioCopy'] }
    if ($c.ContainsKey('anim'))      { $out['Anim']      = [bool]$c['anim'] }
    if ($c.ContainsKey('keepOriginal')) { $out['KeepOriginal'] = [bool]$c['keepOriginal'] }
    if ($c.ContainsKey('resize'))    { $out['Resize']    = "$($c['resize'])" }
    if ($c.ContainsKey('crop'))      { $out['Crop']      = "$($c['crop'])" }
    return [pscustomobject]$out
}

function Get-CvJobBulkSummary {
    <#
        PURO. En una linea, que se va a cambiar (lo que se ensena antes de aplicar y lo que se apunta
        en el log). Sin nada marcado, cadena vacia.
    #>
    param($Changes)
    $c = @{}
    if ($null -ne $Changes) {
        foreach ($k in @($Changes.Keys)) { $c["$k"] = $Changes[$k] }
    }
    $p = @()
    if ($c.ContainsKey('prof') -and $null -ne $c['prof']) { $p += ("perfil -> {0}" -f (Format-CvProfileLabel -Prof $c['prof'])) }
    if ($c.ContainsKey('videoCopy')) { $p += ("video -> {0}" -f $(if ([bool]$c['videoCopy']) { 'copiar' } else { 'recodificar' })) }
    if ($c.ContainsKey('audioCopy')) { $p += ("audio -> {0}" -f $(if ([bool]$c['audioCopy']) { 'copiar' } else { 'recodificar' })) }
    if ($c.ContainsKey('anim'))      { $p += ("animacion -> {0}" -f $(if ([bool]$c['anim']) { 'si' } else { 'no' })) }
    if ($c.ContainsKey('keepOriginal')) { $p += ("si engorda -> {0}" -f $(if ([bool]$c['keepOriginal']) { 'quedarse con el original' } else { 'dejar el recodificado' })) }
    if ($c.ContainsKey('resize'))    { $p += ("escalado -> {0}" -f $(if ("$($c['resize'])") { "$($c['resize'])" } else { 'sin escalar' })) }
    if ($c.ContainsKey('crop'))      { $p += ("recorte -> {0}" -f $(if ("$($c['crop'])") { "$($c['crop'])" } else { 'sin recorte' })) }
    return ($p -join ', ')
}

function Set-CvJobsBulk {
    <#
        Aplica -Changes a los jobs de -Names, uno a uno: se lee el job, se le cambia SOLO lo marcado
        (Set-CvJobBulkChanges) y se vuelve a escribir. No se analiza ningun archivo: lo que ya estaba
        congelado -pistas, subtitulos, lineas contadas, HDR- se conserva tal cual.

        Un job que falle no para a los demas: se cuenta y se sigue. Devuelve @{ Done; Failed; Errors }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string[]]$Names = @(),
        $Changes
    )
    $chk = Test-CvJobBulkChanges -Changes $Changes
    if (-not $chk.Ok) {
        return [pscustomobject]@{
            Done   = 0
            Failed = 0
            Errors = @($chk.Errors)
        }
    }
    # 'Auto' se resuelve UNA vez para todo el lote (la sonda de GPU es la misma para todos), no una
    # vez por archivo.
    $cambios = @{}
    foreach ($k in @($Changes.Keys)) { $cambios["$k"] = $Changes[$k] }
    if ($cambios.ContainsKey('prof') -and $null -ne $cambios['prof']) {
        $cambios['prof'] = Resolve-CvProfileAuto -Context $Context -Prof $cambios['prof']
    }
    $done = 0
    $fail = 0
    $errs = @()
    foreach ($n in @($Names)) {
        try {
            $d = Read-CvJobDraft -Context $Context -Name $n
            $d = Set-CvJobBulkChanges -Draft $d -Changes $cambios
            [void](Save-CvJobDraft -Context $Context -Draft $d)
            $done++
        } catch {
            $fail++
            $errs += ("{0}: {1}" -f $n, $_.Exception.Message)
        }
    }
    return [pscustomobject]@{
        Done   = $done
        Failed = $fail
        Errors = @($errs)
    }
}

function Get-CvJobAutoPlan {
    <#
        AUTODISCOVER de un archivo: hace lo MISMO que la fase PREPARAR de la consola cuando no hay
        que preguntar nada -detectar y decidir- y, cuando la consola SI preguntaria, lo deja anotado
        en 'Reasons' en vez de preguntar. Quien llama decide que hacer con eso (la ventana abre el
        editor solo para esos archivos; los demas se guardan solos).

        Incluye la DETECCION DE BORDES segun el perfil (detectBorder false/auto/true) con las mismas
        reglas y umbrales que la consola: en 'auto' un pre-escaneo rapido que aplica el recorte si la
        mayoria es fiable y lo deja a mano si no; en 'true' un escaneo completo cuyo resultado se
        PROPONE (la consola siempre lo confirma con preview, asi que cuenta como intervencion).
        Es la parte LENTA (varios ffmpeg), de ahi -OnStep: un scriptblock al que se le pasa un texto
        de progreso para que la UI diga por donde va en vez de parecer colgada.

        Devuelve @{ Draft; Manual; Reasons; Notes; CropCandidates }. 'Notes' son cosas que se han
        decidido solas y conviene contar (el retardo de audio detectado), pero que NO obligan a
        revisar el archivo: la consola tambien las aplica sola cuando expira su pregunta.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)]$Info,
        [string]$File = '',
        [bool]$ForceBorder = $false,
        [scriptblock]$OnStep = $null
    )
    $step = {
        param([string]$Text)
        if ($OnStep) { & $OnStep $Text }
    }

    $f = if ($File) { $File } else { "$($Info.format.filename)" }
    & $step 'Analizando pistas...'
    $draft   = New-CvJobDraft -Context $Context -Prof $Prof -Info $Info -File $f
    $reasons = @()

    # ---- Video: varias pistas o anamorfico = la consola pregunta ----
    $vids = @(Get-CvJobVideoOptions -Context $Context -Info $Info)
    if ($vids.Count -gt 1) {
        $reasons += ("Hay {0} pistas de video: elige cual usar." -f $vids.Count)
    }
    if ($vids.Count -gt 0 -and $vids[0].Anamorphic -and -not $draft.VideoSkip) {
        $reasons += 'Video anamorfico (el tamano almacenado no es el que se ve): revisa el escalado.'
    }

    # ---- Audio: sin pista del idioma preferido, o varias (elegir cual/cuales) ----
    $auds = @(Get-CvJobAudioOptions -Context $Context -Info $Info)
    $pref = @($auds | Where-Object { $_.Preferred })
    if ($auds.Count -eq 0) {
        $reasons += 'El archivo no tiene pista de audio.'
    } elseif ($pref.Count -eq 0) {
        $reasons += ("Ninguna pista de audio en el idioma preferido ({0}): elige una." -f ($Context.AudioLangs -join '/'))
    } elseif ($pref.Count -gt 1) {
        $reasons += ("{0} pistas de audio en el idioma preferido: elige cuales conservar y la predeterminada." -f $pref.Count)
    }

    # ---- Subtitulos: hay, pero ninguno del idioma preferido ----
    $subs = @(Get-CvJobSubtitleOptions -Context $Context -Info $Info)
    $usable = @($subs | Where-Object { $_.Usable })
    if ($usable.Count -gt 0 -and @($usable | Where-Object { $_.Preferred }).Count -eq 0) {
        $reasons += ("Hay subtitulos pero ninguno en el idioma preferido ({0}): elige cuales conservar." -f ($Context.SubLangs | Select-Object -First 1))
    }

    # ---- Sincronia del audio (lo lento II): lo mismo que detecta la consola al preparar ----
    $notes = @(Set-CvJobDraftAudioSync -Context $Context -Draft $draft -Info $Info -OnStep $OnStep)

    # ---- Bordes (lo lento): solo si se recodifica y el perfil lo pide ----
    $cands = @()
    $dbv  = "$($Prof.DetectBorder)".ToLower()
    $on   = ($dbv -eq 'true') -or $ForceBorder
    $auto = ($dbv -eq 'auto') -and -not $ForceBorder
    if (-not $draft.VideoSkip -and $vids.Count -gt 0 -and ($on -or $auto)) {
        $v = $vids[0]
        if ($auto) {
            & $step 'Comprobando si hay barras negras (pre-escaneo)...'
            $c = Get-CvJobCropCandidates -Context $Context -Info $Info -Index ([int]$draft.VideoIndex) `
                -Duration ([int]$Context.BorderAutoDuration) -Samples ([int]$Context.BorderAutoSamples)
            $cands = @($c.Groups)
            # MISMA decision que la consola (Resolve-CvCropAutoDecision): aqui solo se traduce a
            # 'se guarda solo' o 'esto lo tiene que ver una persona' (Reasons).
            $dec = Resolve-CvCropAutoDecision -Groups $cands -Width ([int]$v.Width) -Height ([int]$v.Height) `
                -MinCropPct ([double]$Context.BorderMinCropPct) -MaxCropPct ([int]$Context.BorderAutoMaxCropPct)
            if ("$($dec.Decision)" -eq 'crop') {
                $draft.Crop = "$($dec.Crop)"
            } elseif ("$($dec.Decision)" -eq 'manual') {
                $reasons += ("{0}: confirma el recorte." -f $dec.Reason)
            } else {
                $draft.Crop = ''
            }
        } else {
            & $step 'Detectando bordes negros...'
            $c = Get-CvJobCropCandidates -Context $Context -Info $Info -Index ([int]$draft.VideoIndex)
            $cands = @($c.Groups)
            if ($cands.Count -gt 0) {
                $draft.Crop = "$($c.Top)"
                # Con detectBorder=true la consola SIEMPRE confirma el recorte con preview: aqui se
                # propone y se marca como intervencion, para no recortar por nuestra cuenta.
                $reasons += ('Recorte propuesto {0} ({1}% de los puntos): confirmalo o cambialo.' -f $c.Top, $c.TopPct)
            }
        }
    }

    [pscustomobject]@{
        Draft          = $draft
        Manual         = (@($reasons).Count -gt 0)
        Reasons        = @($reasons)
        Notes          = @($notes)
        CropCandidates = @($cands)
    }
}

Export-ModuleMember -Function *
