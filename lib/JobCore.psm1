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
            video { skip, index, crop, resize, anim, hdr, keepOriginal, width, height, sar },
            audio { skip, tracks[ {index, is51, sync, lang, default} ] },
            subtitles[ ... ]

        Las versiones de herramientas y el HDR no se piden: salen del contexto y del propio archivo
        (Test-CvHdr sobre la pista de video elegida), igual que hacia la consola. Sin -Info no hay
        archivo que mirar, y entonces manda -Hdr: es lo que permite reescribir un job (editar en
        bloque) sin perder lo que ya se habia decidido.

        width/height/sar = el tamano ALMACENADO del original (y su SAR), de esa misma pista de video.
        El worker no los usa: estan para que la cola diga la calidad (1080p, 4K) sin tener que
        preguntarle a ffprobe por cada archivo. Sin -Info, los de -SrcWidth/-SrcHeight/-SrcSar (los
        del job que se reescribe); 0 si no se saben.
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
        # Tamano del original ya sabido (de un job anterior). Solo se usa si no hay -Info que mirar.
        [int]$SrcWidth = 0,
        [int]$SrcHeight = 0,
        [string]$SrcSar = '',
        $AudioTracks = @(),
        $Subtitles = @(),
        # Lineas (cues) de TODAS las pistas de subtitulo del archivo, no solo de las elegidas: quien
        # prepara ya las ha contado para decidir, y guardarlas evita que el resumen tenga que volver
        # a demultiplexar el fichero para ensenarlas. Clave = indice de la pista.
        $SubtitleCues = $null,
        # Versiones de las herramientas ya CONGELADAS (las del job que se reescribe). Vacio = las de
        # ahora: es lo que pasa al preparar. Editar un job (o muchos en bloque) no las cambia.
        [string]$FFmpegVersion = '',
        [string]$AacGainVersion = ''
    )
    $hdr = [bool]$Hdr
    if ($null -ne $Info) { $hdr = [bool](Test-CvHdr -Info $Info -Index $VideoIndex) }
    $sw = $SrcWidth
    $sh = $SrcHeight
    $ss = "$SrcSar"
    if ($null -ne $Info) {
        $vs = $null
        if ($VideoIndex -ge 0) { $vs = @($Info.streams | Where-Object { [int]$_.index -eq $VideoIndex })[0] }
        if ($null -eq $vs) { $vs = Get-VideoStream -Info $Info }
        if ($null -ne $vs) {
            $sw = [int]$vs.width
            $sh = [int]$vs.height
            $ss = "$($vs.sample_aspect_ratio)"
        }
    }
    [ordered]@{
        file           = $File
        profile        = $Prof
        ffmpegVersion  = $(if ("$FFmpegVersion" -ne '') { "$FFmpegVersion" } else { $Context.FFmpegVersion })
        aacgainVersion = $(if ("$AacGainVersion" -ne '') { "$AacGainVersion" } else { $Context.AacGainVersion })
        video          = @{
            skip   = $VideoSkip
            index  = $VideoIndex
            crop   = $Crop
            resize = $Resize
            anim   = $Anim
            hdr    = $hdr
            keepOriginal = $KeepOriginal
            width  = $sw
            height = $sh
            sar    = $ss
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
        Text   = (Get-CvText -Key 'job.prof.auto')
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
        if ($anam) { $txt += (Get-CvText -Key 'job.op.anam' -Values @($dw)) }
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
        $br    = if ($s.bit_rate) { (Get-CvText -Key 'job.op.kbps' -Values @([int]([double]$s.bit_rate / 1000))) } else { '' }
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
            'rescue' { (Get-CvText -Key 'job.op.rescatar') }
            'srt'    { (Get-CvText -Key 'job.op.asrt') }
            'discard'{ (Get-CvText -Key 'job.op.ilegible') }
            default  { '' }
        }
        $txt = ("[{0}] {1}  {2}{3}  {4}" -f $s.index, $lang, $s.codec_name, $conv, $(if ($cues -ge 0) { (Get-CvText -Key 'job.op.cues' -Values @($cues)) } else { (Get-CvText -Key 'job.op.cues.no') }))
        if ($empty) { $txt += ('  ' + (Get-CvText -Key 'job.op.vacio')) }
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

function Get-CvJobResize {
    <#
        El ESCALADO de un job: lo mismo que decide la consola (ChangeSize del perfil, con NoUpscale, o
        ancho maximo / tratamiento anamorfico via Get-CvResize), con lo configurado en encode.anamorphic.
        -Video: una opcion de Get-CvJobVideoOptions (Width/Height/Sar). -Crop: el recorte del job. El
        filtro es 'crop' y DESPUES 'scale', asi que con recorte se decide sobre el tamaño RECORTADO:
        con el original, el modo 'square' aplastaba la imagen y maxWidth podia ampliar.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)]$Video,
        [string]$Crop = ''
    )
    $t = Get-CvCroppedSize -Width ([int]$Video.Width) -Height ([int]$Video.Height) -Crop $Crop
    if ($Prof.ChangeSize) {
        if ([bool]$Prof.NoUpscale) { return "$(Get-CvChangeSizeResize -ChangeSize $Prof.ChangeSize -Width $t.Width -Height $t.Height)" }
        return "$($Prof.ChangeSize)"
    }
    $mw = if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { [int]$Prof.MaxWidth } else { 0 }
    return "$(Get-CvResize -Width $t.Width -Height $t.Height -Sar "$($Video.Sar)" -MaxWidth $mw -Anamorphic "$($Context.Anamorphic)")"
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
    # El borrador aun no tiene recorte: si luego se pone uno, se recalcula (Get-CvJobResize -Crop).
    $resize = ''
    if ($vids.Count -gt 0) { $resize = Get-CvJobResize -Context $Context -Prof $Prof -Video $vids[0] }

    # Audio: las pistas del idioma preferido si el toggle multipista esta activo y hay varias; si no,
    # la que elige Select-AudioStream. La PREDETERMINADA va primero (como congela la consola).
    $auds  = @(Get-CvJobAudioOptions -Context $Context -Info $Info)
    $picks = @()
    if ($auds.Count -gt 0) {
        $pref = @($auds | Where-Object { $_.Preferred })
        if ($Context.MultiAudio -and $pref.Count -ge 2) {
            # La PREDETERMINADA, la misma que propone la consola (Select-CvDefaultAudio: la marcada
            # como default o, si no, la de mas calidad), y delante. Antes era la primera por orden.
            $picks = $pref
            $idxPref = @($pref | ForEach-Object { [int]$_.Index })
            $sPref = @(Get-AudioStreams -Info $Info | Where-Object { $idxPref -contains [int]$_.index })
            if ($sPref.Count -gt 0) {
                $def = Select-CvDefaultAudio $sPref
                if ($null -ne $def) {
                    $picks = @(@($pref | Where-Object { [int]$_.Index -eq [int]$def.index }) + @($pref | Where-Object { [int]$_.Index -ne [int]$def.index }))
                }
            }
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
        # Las versiones congeladas: reescribir el job las conserva (Save-CvJobDraft).
        FFmpegVersion  = "$($job.ffmpegVersion)"
        AacGainVersion = "$($job.aacgainVersion)"
        VideoSkip  = [bool]$job.video.skip
        VideoIndex = $(if ($null -ne $job.video.index) { [int]$job.video.index } else { -1 })
        Hdr        = [bool]$job.video.hdr   # ya decidido: se conserva si se reescribe sin analizar
        # Tamano del original (para la columna 'Calidad'): igual, se conserva. 0 en un job de antes.
        SrcWidth   = $(if ($null -ne $job.video.width) { [int]$job.video.width } else { 0 })
        SrcHeight  = $(if ($null -ne $job.video.height) { [int]$job.video.height } else { 0 })
        SrcSar     = "$($job.video.sar)"
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
        -SrcWidth $(if ($Draft.PSObject.Properties['SrcWidth']) { [int]$Draft.SrcWidth } else { 0 }) `
        -SrcHeight $(if ($Draft.PSObject.Properties['SrcHeight']) { [int]$Draft.SrcHeight } else { 0 }) `
        -SrcSar $(if ($Draft.PSObject.Properties['SrcSar']) { "$($Draft.SrcSar)" } else { '' }) `
        -AudioSkip ([bool]$Draft.AudioSkip) -AudioTracks @($Draft.Audio) -Subtitles @($Draft.Subtitles) `
        -SubtitleCues $(if ($Draft.PSObject.Properties['SubCues']) { $Draft.SubCues } else { $null }) `
        -FFmpegVersion $(if ($Draft.PSObject.Properties['FFmpegVersion']) { "$($Draft.FFmpegVersion)" } else { '' }) `
        -AacGainVersion $(if ($Draft.PSObject.Properties['AacGainVersion']) { "$($Draft.AacGainVersion)" } else { '' })
    Write-CvJob -Context $Context -Name $Draft.Name -Job $rec
    return $rec
}

function Test-CvJobResizeText {
    <# PURO. Si un escalado esta bien escrito: 'W:H' (-1/-2 = automatico) y, si acaso, ',setsar=1'. #>
    param([string]$Text = '')
    return ("$Text".Trim() -match '^-?\d+:-?\d+(,setsar=1)?$')
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
    if ($null -eq $Draft) { return [pscustomobject]@{ Ok = $false; Errors = @((Get-CvText -Key 'job.val.vacio')); Warnings = @() } }
    if ([string]::IsNullOrWhiteSpace("$($Draft.File)")) { $err += (Get-CvText -Key 'job.val.sinfile') }
    if (-not $Draft.VideoSkip -and [int]$Draft.VideoIndex -lt 0) { $err += (Get-CvText -Key 'job.val.sinvideo') }
    $tr = @($Draft.Audio)
    if ($tr.Count -eq 0 -and -not $Draft.AudioSkip) { $warn += (Get-CvText -Key 'job.val.muda') }
    if ($tr.Count -gt 0 -and @($tr | Where-Object { $_.Default }).Count -ne 1) { $err += (Get-CvText -Key 'job.val.unadef') }
    $crop = "$($Draft.Crop)"
    if ($crop -and $crop -notmatch '^\d+:\d+:\d+:\d+$') { $err += (Get-CvText -Key 'job.val.recorte' -Values @($crop)) }
    # El escalado tambien (como en la edicion en bloque): '1280x720' se guardaba y fallaba despues,
    # en el worker, con un 'scale=' que ffmpeg no entiende. Con ',setsar=1' es el de pixel cuadrado.
    $rs = "$($Draft.Resize)"
    if ($rs -and -not (Test-CvJobResizeText -Text $rs)) { $err += (Get-CvText -Key 'job.val.escalado' -Values @($rs)) }
    foreach ($t in $tr) {
        if ("$($t.Lang)" -notmatch '^[a-z]{3}$') { $warn += (Get-CvText -Key 'job.val.idioma' -Values @($t.Lang)) }
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
    if ($Detect) { return (Get-CvText -Key 'job.cell.sinbarras') }
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
    if ($t.Count -eq 0) { return $(if ($Skip) { '' } else { (Get-CvText -Key 'job.cell.sinaudio') }) }
    $bits = @()
    $sync = @($t | Where-Object { [double]$_.Sync -ne 0 }) | Select-Object -First 1
    if ($null -ne $sync) { $bits += (Get-CvText -Key 'job.cell.sync' -Values @((Format-CvNumber ([double]$sync.Sync)))) }
    if ($t.Count -gt 1)  { $bits += (Get-CvText -Key 'job.cell.pistas' -Values @($t.Count)) }
    if (@($t | Where-Object { [bool]$_.Is51 }).Count -gt 0) { $bits += '5.1' }
    return ($bits -join '  ')
}

function Start-CvPrepareAnalysis {
    <#
        Arranca en SEGUNDO PLANO el autodescubrimiento (Get-CvJobAutoPlan) de una lista de archivos,
        uno detras de otro, en un runspace aparte del MISMO proceso.

        Es lo que deja seguir a PREPARAR PENDIENTES mientras respondes al editor de un archivo: antes el
        analisis corria en el hilo de la ventana y, al abrirse el editor (modal), se paraba TODO hasta
        que le dabas a guardar -con un lote largo, un cuello de botella: el resto esperaba a que
        volvieras-. WinForms solo tiene un hilo, asi que lo lento (ffprobe/ffmpeg) tiene que ir aparte.

        No escribe NADA: deja cada resultado en -Results y la ventana decide (guardar el job, o ponerlo
        a esperar su turno en el editor). Tampoco toca controles: el avance va por -Progress.
          Results : @{ Index; Kind = 'plan'|'noinfo'|'error'; Plan; Info; Error }
          Progress: @{ Index; Step } (Step vacio = empieza ese archivo)
          Sync    : Cancel (lo pone la ventana) / Finished (lo pone el analisis al acabar) / Fatal
        Lo que el analisis escribe con Write-Host queda en PowerShell.Streams.Information: la ventana
        lo vuelca al log de la sesion, que es donde iba cuando corria en su hilo.

        Devuelve @{ PowerShell; Runspace; Async; Sync; Results; Progress }. Pararlo:
        Stop-CvPrepareAnalysis; recogerlo al acabar: Complete-CvPrepareAnalysis.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)]$Items
    )
    $sync     = [hashtable]::Synchronized(@{ Cancel = $false; Finished = $false; Fatal = '' })
    $results  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $progress = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    # Como TEXTO y no como scriptblock de aqui: un scriptblock queda atado al runspace donde se
    # crea, y este tiene que compilarse y correr en el nuevo.
    $script = @'
param($Lib, $Lang, $Context, $Prof, $Items, $Sync, $Results, $Progress)
try {
    foreach ($m in @(Get-ChildItem -LiteralPath $Lib -Filter '*.psm1' -File)) {
        Import-Module $m.FullName -Force
    }
    [void](Set-CvLanguage -Lang $Lang)
    Set-CvMarkStyle -Ascii $Context.AsciiMarks
    for ($i = 0; $i -lt @($Items).Count; $i++) {
        if ($Sync.Cancel) { break }
        $f = @($Items)[$i]
        $Progress.Enqueue([pscustomobject]@{ Index = $i; Step = '' })
        try {
            $info = Get-MediaInfo -Context $Context -File "$($f.Path)"
            if ($null -eq $info) {
                $Results.Enqueue([pscustomobject]@{ Index = $i; Kind = 'noinfo' })
                continue
            }
            # Regla del prefijo '_': fuerza la deteccion de bordes, igual que en consola.
            $force = "$($f.Name)".StartsWith('_')
            $idx = $i
            $paso = { param($t) $Progress.Enqueue([pscustomobject]@{ Index = $idx; Step = "$t" }) }.GetNewClosure()
            $plan = Get-CvJobAutoPlan -Context $Context -Prof $Prof -Info $info -File "$($f.Path)" -ForceBorder $force -OnStep $paso
            $Results.Enqueue([pscustomobject]@{ Index = $i; Kind = 'plan'; Plan = $plan; Info = $info })
        } catch {
            $Results.Enqueue([pscustomobject]@{ Index = $i; Kind = 'error'; Error = "$($_.Exception.Message)" })
        }
    }
} catch {
    $Sync.Fatal = "$($_.Exception.Message)"
} finally {
    $Sync.Finished = $true
}
'@
    # De paso, los parados antes que ya hayan terminado.
    [void](Clear-CvPrepareOrphans)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script)
    # Los modulos, de donde esta el CODIGO (la carpeta de este mismo modulo) y no de la raiz de
    # trabajo: esa puede no tener lib\ -la de las baterias, por ejemplo- y el analisis entero caia con
    # 'Set-CvLanguage no se reconoce'.
    foreach ($a in @("$PSScriptRoot", (Get-CvLanguage), $Context, $Prof, @($Items), $sync, $results, $progress)) {
        [void]$ps.AddArgument($a)
    }
    $async = $ps.BeginInvoke()
    [pscustomobject]@{
        PowerShell = $ps
        Runspace   = $rs
        Async      = $async
        Sync       = $sync
        Results    = $results
        Progress   = $progress
    }
}

# Analisis de fondo PARADOS que aun no han terminado: se liberan cuando terminan (ver abajo).
$script:CvPrepareOrphans = New-Object System.Collections.ArrayList

function Clear-CvPrepareOrphans {
    <#
        Libera los analisis parados (Stop-CvPrepareAnalysis) que YA han terminado. Se llama al arrancar
        y al parar otro: antes nadie los liberaba, y cada 'Preparar pendientes' cancelado dejaba su
        runspace -con todos los modulos cargados, decenas de MB- hasta cerrar la cola. Devuelve cuantos.
    #>
    $n = 0
    foreach ($h in @($script:CvPrepareOrphans)) {
        $fin = $false
        try { $fin = [bool]$h.Async.IsCompleted } catch { $fin = $true }
        if (-not $fin) { continue }
        Complete-CvPrepareAnalysis -Handle $h
        [void]$script:CvPrepareOrphans.Remove($h)
        $n++
    }
    return $n
}

function Stop-CvPrepareAnalysis {
    <#
        Para el analisis de fondo (Start-CvPrepareAnalysis): lo marca para no empezar el siguiente
        archivo y le pide que corte. SIN esperar: si en ese momento hay un ffmpeg escaneando bordes, la
        espera seria la de ese escaneo, y la ventana no puede quedarse colgada mientras. El runspace
        termina por su cuenta y se libera despues (Clear-CvPrepareOrphans).
    #>
    param($Handle)
    if ($null -eq $Handle) { return }
    $Handle.Sync.Cancel = $true
    try { [void]$Handle.PowerShell.BeginStop($null, $null) } catch { }
    if (-not $script:CvPrepareOrphans.Contains($Handle)) { [void]$script:CvPrepareOrphans.Add($Handle) }
    [void](Clear-CvPrepareOrphans)
}

function Complete-CvPrepareAnalysis {
    <# Recoge un analisis de fondo YA TERMINADO y libera su runspace. #>
    param($Handle)
    if ($null -eq $Handle) { return }
    try { [void]$Handle.PowerShell.EndInvoke($Handle.Async) } catch { }
    try { $Handle.PowerShell.Dispose() } catch { }
    try { $Handle.Runspace.Dispose() } catch { }
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
        [int]$Samples = -1,
        # El escaneo RAPIDO (detectBorder 'auto'): salta mas principio y final (Resolve-CvBorderZone).
        [switch]$Quick
    )
    # -Start: el que se pida (el campo del editor); si no, el de la zona del video (-1).
    $start   = if ($Start    -ge 0) { $Start }    else { -1 }
    $dur     = if ($Duration -ge 0) { $Duration } else { [int]$Context.BorderDur }
    $samples = if ($Samples  -ge 0) { $Samples }  else { [int]$Context.BorderSamples }
    $vdur    = Get-MediaDuration $Info
    $groups  = @((Find-CropDetectSamples -Context $Context -File "$($Info.format.filename)" -Start $start -Duration $dur -VideoDuration $vdur -Index $Index -Samples $samples -Quick:$Quick).Groups)
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
        return @((Get-CvText -Key 'sum.sinpreparar'))
    }
    $job = $null
    try { $job = Read-CvJob -Context $Context -Name $Name } catch {
        return @((Get-CvText -Key 'sum.nolegible' -Values @($_.Exception.Message)))
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
        return (Get-CvText -Key 'sum.kbps' -Values @([int]([int64]$Bps / 1000)))
    }

    # Prefijo comun de TODAS las pistas: '*' = la predeterminada, [x] = se conserva, [ ] = no.
    $mark = {
        param([bool]$Keep, [bool]$Default)
        ("{0}[{1}]" -f $(if ($Default) { '*' } else { ' ' }), $(if ($Keep) { 'x' } else { ' ' }))
    }

    $L = New-Object System.Collections.Generic.List[string]
    $dur = if ($null -ne $Info) { (Get-CvText -Key 'sum.dura' -Values @((Get-DurationText $Info))) } else { '' }
    $L.Add((Get-CvText -Key 'sum.archivo' -Values @($Name, $dur)))
    $prof = $job.profile
    $lblProf = (Get-CvText -Key 'sum.sinperfil')
    if ($null -ne $prof) {
        try { $lblProf = Format-CvProfileLabel -Prof $prof } catch { $lblProf = (Get-CvText -Key 'sum.perfilmal') }
    }
    $L.Add((Get-CvText -Key 'sum.perfil' -Values @($lblProf)))

    # ---- Video ----
    # Mismo estilo que audio y subtitulos: la cabecera dice QUE se hace y debajo van las pistas del
    # archivo, marcando la elegida. Los datos de la pista (resolucion, codec, bits, fps, bitrate)
    # salen del origen: es con lo que se compara lo que se va a hacer.
    $v = $job.video
    if ($null -eq $v) {
        $L.Add((Get-CvText -Key 'sum.sinvideo'))
    } else {
        $que = if ([bool]$v.skip) { (Get-CvText -Key 'sum.v.copia') } else { (Get-CvText -Key 'sum.v.recod') }
        # El recorte y el escalado NO van en la cabecera: van debajo de la pista elegida, contados en
        # pixeles y con el tamano que queda. Un 'recorte 1920:960:0:60' no dice cuanto se va por cada
        # lado ni con que te quedas, que es justo lo que se quiere saber.
        $bits = @()
        if (-not [bool]$v.skip) {
            if ([bool]$v.anim)  { $bits += (Get-CvText -Key 'sum.v.anim') }
            if ([bool]$v.hdr)   { $bits += (Get-CvText -Key 'sum.v.hdr') }
            # Solo se dice cuando esta puesto: es la excepcion, no lo normal.
            if (Get-CvJobKeepOriginal -Job $job) { $bits += (Get-CvText -Key 'sum.v.keep') }
        }
        $allV = @()
        if ($null -ne $Info) { $allV = @(Get-VideoStreams -Info $Info) }
        $cab = if ($allV.Count -gt 0) { (Get-CvText -Key 'sum.v.pistas' -Values @($allV.Count, $que)) } else { $que }
        if ($bits.Count -gt 0) { $cab += ("  {0}" -f ($bits -join '  ')) }
        $L.Add((Get-CvText -Key 'sum.video' -Values @($cab)))
        foreach ($vs in $allV) {
            $i = [int]$vs.index
            $o = @((Get-VideoSize -VideoStream $vs), "$($vs.codec_name)")
            if ("$($vs.profile)") { $o += "$($vs.profile)" }
            $depth = Get-CvStreamBitDepth -Stream $vs
            if ($depth -gt 0) { $o += (Get-CvText -Key 'sum.bits' -Values @($depth)) }
            $fps = Get-CvFrameRate $vs
            if ($fps -gt 0) { $o += (Get-CvText -Key 'sum.fps' -Values @((Format-CvNumber ([math]::Round($fps, 3))))) }
            $vbr = & $fmtKbps (Get-CvStreamBitrate -Stream $vs)
            if ($vbr) { $o += $vbr }
            $dw = Get-CvDisplayWidth -Width ([int]$vs.width) -Sar "$($vs.sample_aspect_ratio)"
            if ([int]$vs.width -gt 0 -and $dw -ne [int]$vs.width) { $o += (Get-CvText -Key 'sum.anamorfico' -Values @($dw)) }
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
                $L.Add((Get-CvText -Key 'sum.recorte' -Values @($geo.CropWidth, $geo.CropHeight, $corte)))
            }
            if ("$($v.resize)") {
                $baseW = $(if ($geo.CropWidth  -gt 0) { $geo.CropWidth }  else { [int]$vs.width })
                $baseH = $(if ($geo.CropHeight -gt 0) { $geo.CropHeight } else { [int]$vs.height })
                $comoQueda = if ($geo.Width -ne $baseW -or $geo.Height -ne $baseH) {
                    ("-> {0}x{1}" -f $geo.Width, $geo.Height)
                } else { (Get-CvText -Key 'sum.nocambia') }
                $L.Add((Get-CvText -Key 'sum.escalado' -Values @($v.resize, $comoQueda)))
            }
            # QUEDA: el tamano final con su proporcion (que es lo que dice si las barras se han ido
            # bien) y con que se codifica.
            $q = @(("{0}x{1}" -f $geo.Width, $geo.Height))
            if ($geo.Height -gt 0) { $q[0] += (" ({0}:1)" -f (Format-CvNumber ([math]::Round($geo.Width / [double]$geo.Height, 2)))) }
            if ($null -ne $prof) {
                $enc = Get-CvEncoderShortName -Encoder "$($prof.VideoEncoder)"
                if ($enc) { $q += $enc }
                if ("$($prof.VideoProfile)" -match '10') { $q += (Get-CvText -Key 'sum.10bits') }
            }
            $ofps = 0.0
            try { $ofps = [double](Get-CvOutputFps -Context $Context -Info $Info) } catch { $ofps = 0.0 }
            if ($ofps -gt 0) { $q += (Get-CvText -Key 'sum.fps' -Values @((Format-CvNumber ([math]::Round($ofps, 3))))) }
            $L.Add((Get-CvText -Key 'sum.queda' -Values @(($q -join '  '))))
        }
    }

    # ---- Audio ----
    # Con -Info se listan TODAS las pistas del archivo marcando las que se quedan ([x]) y las que se
    # descartan ([ ]); sin el, solo se pueden ensenar las elegidas (es lo unico que guarda el job).
    $tracks = @(Get-CvJobAudioTracks $job.audio)
    $keepA  = @{}
    foreach ($t in $tracks) { $keepA[[int]$t.Index] = $t }
    $modo = if ($null -ne $job.audio -and [bool]$job.audio.skip) { (Get-CvText -Key 'sum.a.copian') } else { (Get-CvText -Key 'sum.a.recod') }
    $allA = @()
    if ($null -ne $Info) { $allA = @(Get-AudioStreams -Info $Info) }
    if ($allA.Count -gt 0) {
        $L.Add((Get-CvText -Key 'sum.audio' -Values @($allA.Count, $tracks.Count, $modo)))
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
            if ([int]::TryParse("$($a.sample_rate)".Trim(), [ref]$sr) -and $sr -gt 0) { $bits += (Get-CvText -Key 'sum.khz' -Values @((Format-CvNumber ([math]::Round($sr / 1000.0, 1))))) }
            $lay = "$($a.channel_layout)"
            if ($lay) { $bits += $lay }
            $ttl  = "$(Get-Tag $a 'title')"
            if ($ttl) { $bits += ("'{0}'" -f $ttl) }
            if ($null -ne $t) {
                if ("$($t.Lang)" -ne $lang) { $bits += (Get-CvText -Key 'sum.etiqueta' -Values @($t.Lang)) }
                if ([double]$t.Sync -ne 0)  { $bits += (Get-CvText -Key 'sum.sync' -Values @((Format-CvNumber $t.Sync))) }
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
            if ($abit -match '^(\d+)\s*[kK]$') { $qa += (Get-CvText -Key 'sum.kbps' -Values @($Matches[1])) } elseif ($abit) { $qa += $abit }
            $ahz = 0
            if (-not [int]::TryParse("$($prof.AudioHz)".Trim(), [ref]$ahz) -or $ahz -le 0) { $ahz = [int]$Context.DefaultAudioHz }
            if ($ac -eq 'libopus') { $ahz = 48000 }   # opus solo admite 48 kHz (lo fuerza el render)
            if ($ahz -gt 0) { $qa += (Get-CvText -Key 'sum.khz' -Values @((Format-CvNumber ([math]::Round($ahz / 1000.0, 1))))) }
            if ([int]$plan.Channels -lt $ch) { $qa += (Get-CvText -Key 'sum.downmix' -Values @($ch)) }
            if ([bool]$plan.Downmix) { $qa += (Get-CvText -Key 'sum.vozreforzada') }
            $L.Add((Get-CvText -Key 'sum.queda' -Values @(($qa -join '  '))))
        }
    } elseif ($tracks.Count -eq 0) {
        $L.Add((Get-CvText -Key 'sum.audio.muda'))
    } else {
        $L.Add((Get-CvText -Key 'sum.audio.elegidas' -Values @($tracks.Count, $modo)))
        foreach ($t in $tracks) {
            $bits = @(("{0,-4}" -f $t.Lang))
            if ([bool]$t.Is51)         { $bits += '5.1' }
            if ([double]$t.Sync -ne 0) { $bits += (Get-CvText -Key 'sum.sync' -Values @((Format-CvNumber $t.Sync))) }
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
        $L.Add((Get-CvText -Key 'sum.subs' -Values @($allS.Count, $subs.Count)))
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
            if ($cues -ge 0) { $bits += (Get-CvText -Key 'sum.lineas' -Values @($cues)) }
            if ($cues -eq 0) { $bits += (Get-CvText -Key 'sum.vacio') }
            # Lo que se ESCRIBIRA si se conserva (lo dice el job); si no, como viene en el origen.
            if ($null -ne $s) {
                $bits += $(if ([bool]$s.Forced) { (Get-CvText -Key 'sum.forzado') } else { (Get-CvText -Key 'sum.completo') })
                if ([bool]$s.Rescue)    { $bits += (Get-CvText -Key 'sum.rescatado') }
                elseif ([bool]$s.ToSrt) { $bits += (Get-CvText -Key 'sum.asrt') }
                if ("$($s.Lang)" -ne $lang) { $bits += (Get-CvText -Key 'sum.etiqueta' -Values @($s.Lang)) }
            } else {
                if (Test-SubForced $sub)  { $bits += (Get-CvText -Key 'sum.forzadoorig') }
                if (Test-SubDefault $sub) { $bits += (Get-CvText -Key 'sum.defectoorig') }
            }
            $ttl = "$(Get-Tag $sub 'title')"
            if ($ttl) { $bits += ("'{0}'" -f $ttl) }
            $L.Add(("   {0} [{1}] {2}" -f (& $mark ($null -ne $s) ($null -ne $s -and [bool]$s.Default)), $i, ($bits -join '  ')))
        }
    } elseif ($subs.Count -eq 0) {
        $L.Add((Get-CvText -Key 'sum.subs.ninguno'))
    } else {
        $L.Add((Get-CvText -Key 'sum.subs.elegidos' -Values @($subs.Count)))
        foreach ($s in $subs) {
            $bits = @(("{0,-4}" -f $s.Lang), "$($s.Codec)", $(if ([bool]$s.Forced) { (Get-CvText -Key 'sum.forzado') } else { (Get-CvText -Key 'sum.completo') }))
            $L.Add(("   {0} [{1}] {2}" -f (& $mark $true ([bool]$s.Default)), $s.Index, ($bits -join '  ')))
        }
    }

    return @($L)
}

function Set-CvJobDraftAudioSync {
    <#
        Mide la SINCRONIA de las pistas de audio elegidas y deja el retardo puesto en el borrador. Es
        lo MISMO que mira la consola al preparar (Invoke-AudioAsk), con las mismas funciones:
          - el audio EMPIEZA tarde (Get-AudioInitDelay): con syncAdelay (de fabrica) el offset ya va en
            los timestamps y se conserva solo -no se toca, solo se cuenta-; en el modo WAV clasico se
            perderia, y se compensa con ese silencio (lo que hace el ENTER de la consola);
          - el audio ACABA antes que el video con los inicios alineados = va ADELANTADO, y se sugiere
            retrasarlo esa diferencia (Get-CvAudioAheadVerdict, la misma decision que la consola: umbral
            encode.audio.syncThreshold, tope encode.audio.syncMaxAhead y, si hay otra pista que llega al
            final, la comprobacion CRUZADA contra ella, que mide el desfase en vez de suponerlo).

        La consola PREGUNTA ese retardo y obliga a escucharlo; aqui se deja PUESTO y Get-CvJobAutoPlan
        manda el archivo a revisar (Reasons), donde el editor lo deja oir antes de guardar.

        -Force: vuelve a medir TODAS las pistas, pisando lo que tuvieran (el boton 'Detectar sincronia'
        del editor, para las pistas que marques tu). Sin el, una pista con un retardo ya puesto no se
        toca.

        Es LENTO (lee la cola del fichero con ffprobe, una vez por pista + una por el video), asi que
        va con -OnStep para poder decir por donde va. Devuelve @(notas) -vacio si no hay nada que
        contar- y nunca lanza: una deteccion que falla no puede tumbar la preparacion.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)]$Info,
        [scriptblock]$OnStep = $null,
        # Mensaje con el que -OnStep pide PARAR (el editor al cerrarse): ese no se traga.
        [string]$AbortMessage = '',
        [switch]$Force
    )
    $notas = @()
    if ([bool]$Draft.AudioSkip) { return $notas }                      # en copy no se toca el audio
    $tracks = @($Draft.Audio)
    if ($tracks.Count -eq 0) { return $notas }
    $umbral = [double]$Context.AudioSyncThreshold
    try {
        if ($OnStep) { & $OnStep (Get-CvText -Key 'plan.sync') }
        $dur  = Get-MediaDuration $Info
        $file = "$($Draft.File)"
        $vEnd = 0.0
        $idxs = @(Get-AudioStreams -Info $Info | ForEach-Object { [int]$_.index })
        $fines = @{}
        if ($umbral -gt 0) {
            # La pista de video del borrador, no 'v:0' (que puede ser una caratula): Get-CvSyncVideoSpec.
            # El borrador puede ser un objeto o una TABLA (el boton del editor): PSObject.Properties
            # no ve las claves de una tabla, y se media contra la primera pista de video.
            $vIdx = -1
            $vSel = if ($Draft -is [System.Collections.IDictionary]) { $Draft['VideoIndex'] } elseif ($Draft.PSObject.Properties['VideoIndex']) { $Draft.VideoIndex } else { $null }
            if ($null -ne $vSel -and "$vSel" -ne '') { $vIdx = [int]$vSel }
            $vEnd = Get-CvStreamEndPts -Context $Context -File $file -Stream (Get-CvSyncVideoSpec -Info $Info -VideoIndex $vIdx) -Duration $dur -What (Get-CvText -Key 'au.video.pista')
        }
        foreach ($t in $tracks) {
            if (-not $Force -and [double]$t.Sync -ne 0) { continue }   # ya trae un valor puesto a mano: no se pisa
            $idx  = [int]$t.Index
            $sync = 0.0
            $ini  = [double](Get-AudioInitDelay -Context $Context -File $file -Index $idx)
            if ($ini -gt 0) {
                if ($Context.SyncAdelay) {
                    # Informativo: con adelay el offset se conserva solo. Sin pedirlo, solo si se nota.
                    if ($Force -or ($umbral -gt 0 -and $ini -ge $umbral)) {
                        $notas += (Get-CvText -Key 'plan.sync.tarde' -Values @($idx, (Format-CvNumber $ini)))
                    }
                } else {
                    $sync = $ini
                    $notas += (Get-CvText -Key 'plan.sync.wav' -Values @($idx, (Format-CvNumber $ini)))
                }
            }
            elseif ($vEnd -gt 0) {
                $aEnd = Get-CvStreamEndPts -Context $Context -File $file -Stream ("{0}" -f $idx) -Duration $dur -What (Get-CvText -Key 'au.pista.audio' -Values @($idx))
                $fines[$idx] = $aEnd
                $chk  = Get-CvAudioAheadVerdict -Context $Context -File $file -AudioIndexes $idxs -Index $idx -VideoEnd $vEnd -AudioEnd $aEnd -Duration $dur -EndCache $fines
                $vc   = $chk.Cross
                if ($null -ne $vc -and "$($vc.Verdict)" -eq 'aligned') {
                    $notas += (Get-CvText -Key 'plan.sync.cruce.ok' -Values @($idx, (Format-CvNumber $chk.Diff), $chk.Ref, (Format-CvNumber $vc.Lag), $vc.Reliable, $vc.Total))
                } elseif ($null -ne $vc -and "$($vc.Verdict)" -eq 'late') {
                    $notas += (Get-CvText -Key 'plan.sync.cruce.tarde' -Values @($idx, (Format-CvNumber $vc.Lag), $chk.Ref))
                } elseif ($null -ne $vc -and "$($vc.Verdict)" -eq 'ahead') {
                    $sync = [double]$chk.Delay
                    $notas += (Get-CvText -Key 'plan.sync.cruce.ade' -Values @($idx, (Format-CvNumber $sync), $chk.Ref, $vc.Reliable, $vc.Total))
                } elseif ($chk.TooLong) {
                    $notas += (Get-CvText -Key 'plan.sync.largo' -Values @($idx, (Format-CvNumber $chk.Diff), (Format-CvNumber $Context.AudioSyncMaxAhead)))
                } elseif ([double]$chk.Delay -gt 0) {
                    $sync = [double]$chk.Delay
                    $notas += (Get-CvText -Key 'plan.sync.nota' -Values @($idx, (Format-CvNumber $sync)))
                }
            }
            $t.Sync = [double]$sync
        }
    } catch {
        # El 'para' de quien llama (el editor al cerrarse, que lo lanza desde -OnStep) no es un fallo
        # de la medida: se deja pasar, o el analisis seguiria con la ventana ya cerrada.
        if ("$AbortMessage" -ne '' -and "$($_.Exception.Message)" -eq "$AbortMessage") { throw }
        $notas += (Get-CvText -Key 'plan.sync.no' -Values @($_.Exception.Message))
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
            Text = (Get-CvText -Key 'bulk.prof.text')
            Help = (Get-CvText -Key 'bulk.prof.help')
        }
        [pscustomobject]@{
            Key  = 'videoCopy'
            Kind = 'bool'
            Text = (Get-CvText -Key 'bulk.video.text')
            On   = (Get-CvText -Key 'job.copiar')
            Off  = (Get-CvText -Key 'job.recodificar')
            Help = (Get-CvText -Key 'bulk.video.help')
        }
        [pscustomobject]@{
            Key  = 'audioCopy'
            Kind = 'bool'
            Text = (Get-CvText -Key 'bulk.audio.text')
            On   = (Get-CvText -Key 'job.copiar')
            Off  = (Get-CvText -Key 'job.recodificar')
            Help = (Get-CvText -Key 'bulk.audio.help')
        }
        [pscustomobject]@{
            Key  = 'keepOriginal'
            Kind = 'bool'
            Text = (Get-CvText -Key 'bulk.keep.text')
            On   = (Get-CvText -Key 'bulk.keep.on')
            Off  = (Get-CvText -Key 'bulk.keep.off')
            Help = (Get-CvText -Key 'bulk.keep.help')
        }
        [pscustomobject]@{
            Key  = 'anim'
            Kind = 'bool'
            Text = (Get-CvText -Key 'bulk.anim.text')
            On   = (Get-CvText -Key 'comun.si')
            Off  = (Get-CvText -Key 'comun.no')
            Help = (Get-CvText -Key 'bulk.anim.help')
        }
        [pscustomobject]@{
            Key  = 'resize'
            Kind = 'text'
            Text = (Get-CvText -Key 'bulk.resize.text')
            Hint = (Get-CvText -Key 'bulk.resize.hint')
            Help = (Get-CvText -Key 'bulk.resize.help')
        }
        [pscustomobject]@{
            Key  = 'crop'
            Kind = 'text'
            Text = (Get-CvText -Key 'bulk.crop.text')
            Hint = (Get-CvText -Key 'bulk.crop.hint')
            Help = (Get-CvText -Key 'bulk.crop.help')
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
    if ($c.Count -eq 0) { $err += (Get-CvText -Key 'bulk.val.nada') }
    if ($c.ContainsKey('crop')) {
        $crop = "$($c['crop'])"
        if ($crop -and $crop -notmatch '^\d+:\d+:\d+:\d+$') { $err += (Get-CvText -Key 'job.val.recorte' -Values @($crop)) }
    }
    if ($c.ContainsKey('resize')) {
        $rs = "$($c['resize'])"
        if ($rs -and -not (Test-CvJobResizeText -Text $rs)) { $err += (Get-CvText -Key 'job.val.escalado' -Values @($rs)) }
    }
    if ($c.ContainsKey('prof') -and $null -eq $c['prof']) { $err += (Get-CvText -Key 'bulk.val.perfil') }
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

        Con -Context, el ESCALADO se rehace como al preparar (Get-CvJobResize, con el tamano del
        original guardado en el job) si cambia el perfil, o si cambia el recorte y el escalado era el
        automatico; salvo que el cambio traiga su propio 'resize'. Sin el, pasar 40 jobs a un perfil
        de 720p los seguia codificando al tamano de antes.
    #>
    param($Draft, $Changes, $Context = $null)
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
    if ($c.ContainsKey('crop'))      { $out['Crop']      = "$($c['crop'])" }
    if ($c.ContainsKey('resize')) {
        $out['Resize'] = "$($c['resize'])"
    } elseif ($null -ne $Context -and [int]$out['SrcWidth'] -gt 0 -and [int]$out['SrcHeight'] -gt 0) {
        $vid = [pscustomobject]@{
            Width  = [int]$out['SrcWidth']
            Height = [int]$out['SrcHeight']
            Sar    = "$($out['SrcSar'])"
        }
        $cambiaProf = ($c.ContainsKey('prof') -and $null -ne $c['prof'])
        $cambiaCrop = ($c.ContainsKey('crop') -and "$($c['crop'])" -ne "$($Draft.Crop)")
        $eraAuto = $false
        if ($cambiaCrop -and $null -ne $Draft.Prof) {
            $eraAuto = ("$($Draft.Resize)" -eq (Get-CvJobResize -Context $Context -Prof $Draft.Prof -Video $vid -Crop "$($Draft.Crop)"))
        }
        if ($cambiaProf -or $eraAuto) {
            $out['Resize'] = Get-CvJobResize -Context $Context -Prof $out['Prof'] -Video $vid -Crop "$($out['Crop'])"
        }
    }
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
    if ($c.ContainsKey('prof') -and $null -ne $c['prof']) { $p += (Get-CvText -Key 'bulk.sum.perfil' -Values @((Format-CvProfileLabel -Prof $c['prof']))) }
    if ($c.ContainsKey('videoCopy')) { $p += (Get-CvText -Key 'bulk.sum.video' -Values @($(if ([bool]$c['videoCopy']) { Get-CvText -Key 'bulk.sum.copiar' } else { Get-CvText -Key 'bulk.sum.recod' }))) }
    if ($c.ContainsKey('audioCopy')) { $p += (Get-CvText -Key 'bulk.sum.audio' -Values @($(if ([bool]$c['audioCopy']) { Get-CvText -Key 'bulk.sum.copiar' } else { Get-CvText -Key 'bulk.sum.recod' }))) }
    if ($c.ContainsKey('anim'))      { $p += (Get-CvText -Key 'bulk.sum.anim'  -Values @($(if ([bool]$c['anim']) { Get-CvText -Key 'bulk.sum.si' } else { Get-CvText -Key 'bulk.sum.no' }))) }
    if ($c.ContainsKey('keepOriginal')) { $p += (Get-CvText -Key 'bulk.sum.keep' -Values @($(if ([bool]$c['keepOriginal']) { Get-CvText -Key 'bulk.sum.keepsi' } else { Get-CvText -Key 'bulk.sum.keepno' }))) }
    if ($c.ContainsKey('resize'))    { $p += (Get-CvText -Key 'bulk.sum.resize' -Values @($(if ("$($c['resize'])") { "$($c['resize'])" } else { Get-CvText -Key 'bulk.sum.sinesc' }))) }
    if ($c.ContainsKey('crop'))      { $p += (Get-CvText -Key 'bulk.sum.crop'   -Values @($(if ("$($c['crop'])") { "$($c['crop'])" } else { Get-CvText -Key 'bulk.sum.sincrop' }))) }
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
    # Uno que esta codificando un worker (o ya hecho) no se toca: la ventana es modal y puede llevar
    # un rato abierta. Reescribirlo perdia el cambio (el worker ya leyo el job y al acabar lo borra) o
    # volvia a crear el job de un archivo terminado, que la cola enseñaba 'a medias'.
    $ocupado = {
        param([string]$N)
        $l = Join-Path $Context.Proceso ("{0}.lock" -f $N)
        if ((Test-Path -LiteralPath $l) -and -not (Test-CvLockStale $l)) { return $true }
        return (Test-Path -LiteralPath (Get-OutputPath $Context $N))
    }
    foreach ($n in @($Names)) {
        try {
            if (& $ocupado $n) { throw (Get-CvText -Key 'bulk.ocupado') }
            $d = Read-CvJobDraft -Context $Context -Name $n
            $d = Set-CvJobBulkChanges -Draft $d -Changes $cambios -Context $Context
            if (& $ocupado $n) { throw (Get-CvText -Key 'bulk.ocupado') }
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

        Devuelve @{ Draft; Manual; Reasons; Notes; CropCandidates; CropAsk; CropPct }. CropAsk = la
        consola se pararia aqui a confirmar un recorte (y lo ensenaria antes): el editor hace lo mismo.
        CropPct = el % de los puntos que ven ese recorte (0 si no viene del escaneo completo). 'Notes' son cosas que se han
        medido y conviene contar (lo que dice Set-CvJobDraftAudioSync). Un retardo de audio
        detectado, ademas, va a Reasons: la consola lo pregunta y obliga a oirlo antes de aceptarlo.
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
    & $step (Get-CvText -Key 'plan.pistas')
    $draft   = New-CvJobDraft -Context $Context -Prof $Prof -Info $Info -File $f
    $reasons = @()

    # ---- Video: varias pistas o anamorfico = la consola pregunta ----
    $vids = @(Get-CvJobVideoOptions -Context $Context -Info $Info)
    if ($vids.Count -gt 1) {
        $reasons += (Get-CvText -Key 'plan.varios.video' -Values @($vids.Count))
    }
    if ($vids.Count -gt 0 -and $vids[0].Anamorphic -and -not $draft.VideoSkip) {
        $reasons += (Get-CvText -Key 'plan.anamorfico')
    }

    # ---- Audio: sin pista del idioma preferido, o varias (elegir cual/cuales) ----
    $auds = @(Get-CvJobAudioOptions -Context $Context -Info $Info)
    $pref = @($auds | Where-Object { $_.Preferred })
    if ($auds.Count -eq 0) {
        $reasons += (Get-CvText -Key 'plan.sinaudio')
    } elseif ($pref.Count -eq 0) {
        $reasons += (Get-CvText -Key 'plan.audio.idioma' -Values @((($Context.AudioLangs -join '/'))))
    } elseif ($pref.Count -gt 1) {
        $reasons += (Get-CvText -Key 'plan.audio.varias' -Values @($pref.Count))
    }

    # ---- Subtitulos: hay, pero ninguno del idioma preferido ----
    $subs = @(Get-CvJobSubtitleOptions -Context $Context -Info $Info)
    $usable = @($subs | Where-Object { $_.Usable })
    if ($usable.Count -gt 0 -and @($usable | Where-Object { $_.Preferred }).Count -eq 0) {
        $reasons += (Get-CvText -Key 'plan.subs.idioma' -Values @(($Context.SubLangs | Select-Object -First 1)))
    }

    # ---- Sincronia del audio (lo lento II): lo mismo que detecta la consola al preparar ----
    $notes = @(Set-CvJobDraftAudioSync -Context $Context -Draft $draft -Info $Info -OnStep $OnStep)
    # Un retardo detectado se deja PUESTO, pero la consola nunca lo aplica sin hacertelo oir: el
    # archivo va a revisar, y en el editor se escucha con 'Escuchar con retardo' antes de guardarlo.
    foreach ($t in @($draft.Audio)) {
        if ([double]$t.Sync -gt 0) {
            $reasons += (Get-CvText -Key 'plan.sync.revisa' -Values @([int]$t.Index, (Format-CvNumber ([double]$t.Sync))))
        }
    }

    # ---- Bordes (lo lento): solo si se recodifica y el perfil lo pide ----
    $cands = @()
    # Si la consola, en este punto, se pararia a CONFIRMAR un recorte (y lo ensenaria antes). Va como
    # dato y no se deduce de Reasons: esos son textos, y en otro idioma ya no se reconocerian.
    $cropAsk = $false
    $cropPct = 0          # % de los puntos que ven el recorte propuesto (escaneo completo)
    $dbv  = "$($Prof.DetectBorder)".ToLower()
    $on   = ($dbv -eq 'true') -or $ForceBorder
    $auto = ($dbv -eq 'auto') -and -not $ForceBorder
    if (-not $draft.VideoSkip -and $vids.Count -gt 0 -and ($on -or $auto)) {
        $v = $vids[0]
        if ($auto) {
            & $step (Get-CvText -Key 'plan.prescan')
            $c = Get-CvJobCropCandidates -Context $Context -Info $Info -Index ([int]$draft.VideoIndex) `
                -Duration ([int]$Context.BorderAutoDuration) -Samples ([int]$Context.BorderAutoSamples) -Quick
            $cands = @($c.Groups)
            # MISMA decision que la consola (Resolve-CvCropAutoDecision): aqui solo se traduce a
            # 'se guarda solo' o 'esto lo tiene que ver una persona' (Reasons).
            $dec = Resolve-CvCropAutoDecision -Groups $cands -Width ([int]$v.Width) -Height ([int]$v.Height) `
                -MinCropPct ([double]$Context.BorderMinCropPct) -MaxCropPct ([int]$Context.BorderAutoMaxCropPct)
            if ("$($dec.Decision)" -eq 'crop') {
                $draft.Crop = "$($dec.Crop)"
            } elseif ("$($dec.Decision)" -eq 'manual') {
                # El motivo YA lo explica Resolve-CvCropAutoDecision ('...: confirmalo antes de
                # aplicarlo'), asi que se usa tal cual: pegarle otra frase detras lo dejaba en
                # "confirmalo antes de aplicarlo: confirma el recorte", y ademas en castellano
                # pasara lo que pasara, porque era un literal en el codigo.
                $reasons += "$($dec.Reason)"
                $cropAsk = $true
                # Y se PROPONE el mas votado, como en el editor suelto ($autoCrop): sin el, el editor
                # se abria con "confirma el recorte" y el campo vacio.
                $draft.Crop = "$($dec.Crop)"
            } else {
                $draft.Crop = ''
            }
        } else {
            & $step (Get-CvText -Key 'plan.bordes')
            $c = Get-CvJobCropCandidates -Context $Context -Info $Info -Index ([int]$draft.VideoIndex)
            $cands = @($c.Groups)
            if ($cands.Count -gt 0) {
                $draft.Crop = "$($c.Top)"
                # Con detectBorder=true la consola SIEMPRE confirma el recorte con preview: aqui se
                # propone y se marca como intervencion, para no recortar por nuestra cuenta.
                $reasons += (Get-CvText -Key 'plan.recorte' -Values @($c.Top, $c.TopPct))
                $cropAsk = $true
                $cropPct = [int]$c.TopPct
            }
        }
        # El escalado se aplica DESPUES del recorte: con recorte, se decide con su tamaño.
        if ("$($draft.Crop)" -ne '') {
            $draft.Resize = Get-CvJobResize -Context $Context -Prof $Prof -Video $v -Crop "$($draft.Crop)"
        }
    }

    [pscustomobject]@{
        Draft          = $draft
        Manual         = (@($reasons).Count -gt 0)
        Reasons        = @($reasons)
        Notes          = @($notes)
        CropCandidates = @($cands)
        CropAsk        = [bool]$cropAsk
        CropPct        = [int]$cropPct
    }
}

Export-ModuleMember -Function *
