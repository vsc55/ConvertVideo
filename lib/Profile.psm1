<#
    Profile.psm1 - Perfiles de codificacion predefinidos y menu de seleccion.
    Espejo de select_profile.cmd. Devuelve un objeto de configuracion que se
    congela dentro de cada .job.
#>

function New-CvProfile {
    <# Estructura base de un perfil, con valores por defecto. #>
    param(
        [string]$VideoEncoder = '',   # copy | hevc_nvenc | libx265 | h264_nvenc | libx264
        [string]$VideoProfile = '',   # main10 | main | ''(=ninguno)
        [string]$VideoLevel   = '',   # 5 | 4.1 | ''
        [object]$Qmin = $null,
        [object]$Qmax = $null,
        [object]$Crf  = $null,
        [object]$DetectBorder = $false,   # $false (nunca) | $true (siempre, interactivo) | 'auto' (pre-escaneo decide)
        [string]$ChangeSize = '',      # '' = no | '1920:-2' etc. (escala; altura -2 = auto y PAR)
        [object]$NoUpscale = $false,   # $true = changeSize SOLO reduce (no amplia videos mas pequeños que el destino)
        [object]$MaxWidth = $null,     # $null = no | 1920 etc. (reduce a ese ancho SOLO si es mayor; nunca amplia)
        [string]$Multipass = '',       # '' = usar el global (encode.multipass) | off | qres | fullres (NVENC)
        # Salida de audio por defecto: FUENTE UNICA en config (encode.audio.*), no hardcodeada. El
        # default del param solo se evalua cuando el llamador NO lo pasa (perfiles de serie de Get-CvProfiles).
        [string]$AudioEncoder = "$((Get-CvConfigDefaults).encode.audio.encoder)",  # aac_coder (recodificar) | copy
        [string]$AudioCodec   = "$((Get-CvConfigDefaults).encode.audio.codec)",    # aac | ac3 | eac3 | libmp3lame | flac | libopus
        [string]$AudioBitrate = "$((Get-CvConfigDefaults).encode.audio.bitrate)",
        [int]$AudioHz         = [int](Get-CvConfigDefaults).encode.audio.hz,
        # Salida de audio POR PERFIL (override del global; $null = usar el global encode.*):
        [object]$AudioChannels = $null,   # MAXIMO de canales (no hace upmix). $null = encode.audioChannels | 2 | 6 | 8
        [object]$DownmixMode   = $null,   # $null = encode.downmixMode | 'default' | 'dialogue' (voz reforzada, BETA)
        [object]$DownmixCoeffs = $null    # $null = encode.downmixCoeffs | @{ Center; Front; Surround }
    )
    [pscustomobject]@{
        VideoEncoder = $VideoEncoder; VideoProfile = $VideoProfile; VideoLevel = $VideoLevel
        Qmin = $Qmin; Qmax = $Qmax; Crf = $Crf; DetectBorder = $DetectBorder; ChangeSize = $ChangeSize; NoUpscale = $NoUpscale; MaxWidth = $MaxWidth
        Multipass = $Multipass
        AudioEncoder = $AudioEncoder; AudioCodec = $AudioCodec; AudioBitrate = $AudioBitrate; AudioHz = $AudioHz
        AudioChannels = $AudioChannels; DownmixMode = $DownmixMode; DownmixCoeffs = $DownmixCoeffs
    }
}

function Get-CvAudioChannels {
    <# Catalogo de canales de salida para los menus (@{Value;Text}). #>
    @(
        @{
            Value = '2'
            Text  = (Get-CvText -Key 'cat.ch.2')
        }
        @{
            Value = '6'
            Text  = (Get-CvText -Key 'cat.ch.6')
        }
        @{
            Value = '8'
            Text  = (Get-CvText -Key 'cat.ch.8')
        }
    )
}

function Get-CvDownmixModes {
    <# Catalogo de modos de downmix 5.1->estereo para los menus (@{Value;Text}). #>
    @(
        @{
            Value = 'default'
            Text  = (Get-CvText -Key 'cat.dmx.default')
        }
        @{
            Value = 'dialogue'
            Text  = (Get-CvText -Key 'cat.dmx.dialogue')
        }
    )
}

function Get-CvAudioEncoders {
    <# Catalogo de la salida de audio (campo audioEncoder / encode.audio.encoder): recodificar o copiar. #>
    @(
        @{ Value = 'aac_coder'; Text = (Get-CvText -Key 'cat.aenc.recod') }
        @{ Value = 'copy';      Text = (Get-CvText -Key 'cat.aenc.copy') }
    )
}

function Get-CvDetectBorderModes {
    <#
        Catalogo de la deteccion de bordes de un perfil (detectBorder): No / Si (interactivo) / Auto.
        Value CONSERVA el tipo real que espera el perfil: $false / $true (bool) y 'auto' (string). Lo usan
        el builder custom (New-CustomProfile) y el editor de setup.
    #>
    @(
        @{ Value = $false; Text = (Get-CvText -Key 'cat.border.no') }
        @{ Value = $true;  Text = (Get-CvText -Key 'cat.border.si') }
        @{ Value = 'auto'; Text = (Get-CvText -Key 'cat.border.auto') }
    )
}

function Get-CvVideoProfileOptions {
    <#
        UNION de los perfiles (-profile:v) de todas las familias de codec (fuente unica Get-CvCodecOptions),
        para el editor de config, que edita la clave sin saber el codec. Dedup por Value, conserva orden.
    #>
    $seen = @{}; $out = @()
    foreach ($enc in @('libx265', 'libx264')) {
        foreach ($p in (Get-CvCodecOptions -Encoder $enc).Profiles) {
            if (-not $seen.ContainsKey("$($p.Value)")) { $seen["$($p.Value)"] = $true; $out += [pscustomobject]@{ Value = $p.Value; Text = $p.Text } }
        }
    }
    return , $out
}

function Get-CvVideoLevelOptions {
    <# UNION de los levels (-level:v) de todas las familias de codec (fuente unica Get-CvCodecOptions). #>
    $seen = @{}; $out = @()
    foreach ($enc in @('libx265', 'libx264')) {
        foreach ($l in (Get-CvCodecOptions -Encoder $enc).Levels) {
            if (-not $seen.ContainsKey("$($l.Value)")) { $seen["$($l.Value)"] = $true; $out += [pscustomobject]@{ Value = $l.Value; Text = $l.Text } }
        }
    }
    return , $out
}

function ConvertTo-CvDownmixCoeffs {
    <#
        Convierte un objeto de coeficientes de config.json (camelCase center/front/surround) en
        @{ Center; Front; Surround }. Devuelve $null si el objeto es $null (=> usar el global). Las
        subclaves ausentes caen al default de Get-CvDefaultDownmixCoeffs (fuente unica de los numeros).
        El cast [double] de PS es invariante de locale (los numeros del JSON ya vienen como double).
    #>
    param($Obj)
    if ($null -eq $Obj) { return $null }
    $d = Get-CvDefaultDownmixCoeffs
    @{
        Center   = $(if ($null -ne (Get-CvProfileProp $Obj 'center'   $null)) { [double](Get-CvProfileProp $Obj 'center'   $d.Center) }   else { $d.Center })
        Front    = $(if ($null -ne (Get-CvProfileProp $Obj 'front'    $null)) { [double](Get-CvProfileProp $Obj 'front'    $d.Front) }    else { $d.Front })
        Surround = $(if ($null -ne (Get-CvProfileProp $Obj 'surround' $null)) { [double](Get-CvProfileProp $Obj 'surround' $d.Surround) } else { $d.Surround })
    }
}

function Get-CvProfiles {
    <#
        Perfiles de serie por GRUPOS. Cada grupo (objeto con .Profiles) se muestra junto en el menu
        y se separa del siguiente con una linea en blanco; la numeracion (1..N) es CONTINUA a
        traves de los grupos. Anadir/quitar/reordenar aqui basta: el numero y el texto del menu se
        generan solos (Select-Profile + Format-CvProfileLabel), sin listas paralelas.
    #>
    @(
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'copy')
            (New-CvProfile -VideoEncoder 'auto' -Qmin 1 -Qmax 23 -DetectBorder 'auto' -ChangeSize '1920:-2' -NoUpscale $true)
        )}
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -DetectBorder 'auto')
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -DetectBorder $true)
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23)
        )}
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -MaxWidth 1920 -DetectBorder 'auto')
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -MaxWidth 1920 -DetectBorder $true)
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -MaxWidth 1920)
        )}
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 -ChangeSize '1920:-2' -NoUpscale $true)
        )}
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -DetectBorder 'auto')
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -DetectBorder $true)
            (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5')
        )}
        [pscustomobject]@{ Profiles = @(
            (New-CvProfile -VideoEncoder 'h264_nvenc' -VideoLevel '5' -Qmin 1 -Qmax 23)
        )}
    )
}

function Get-CvVideoEncoders {
    <#
        Catalogo de encoders de video para el menu del perfil custom (ENCODER DE VIDEO). Lista
        ordenada de @{ Value; Text }: el numero de menu (1..N) lo genera New-CustomProfile, asi que
        anadir/quitar/reordenar aqui basta. Value = valor de -VideoEncoder; Text = descripcion.
    #>
    @(
        @{
            Value = 'copy'
            Text  = (Get-CvText -Key 'cat.venc.copy')
        }
        @{
            Value = 'libx264'
            Text  = (Get-CvText -Key 'cat.venc.libx264')
        }
        @{
            Value = 'h264_nvenc'
            Text  = (Get-CvText -Key 'cat.venc.h264nv')
        }
        @{
            Value = 'libx265'
            Text  = (Get-CvText -Key 'cat.venc.libx265')
        }
        @{
            Value = 'hevc_nvenc'
            Text  = (Get-CvText -Key 'cat.venc.hevcnv')
        }
        @{
            Value = 'libsvtav1'
            Text  = (Get-CvText -Key 'cat.venc.svtav1')
        }
        @{
            Value = 'av1_nvenc'
            Text  = (Get-CvText -Key 'cat.venc.av1nv')
        }
    )
}

function Get-CvEncoderShortName {
    <#
        PURO. Nombre corto y legible de un encoder de video para ENSENARLO ('hevc_nvenc' -> 'h265 (GPU)').
        Sale del MISMO catalogo del menu (Get-CvVideoEncoders), cuyo texto empieza por '[h265 - GPU]':
        asi no hay una segunda lista que mantener. Si el encoder no esta en el catalogo se devuelve su
        nombre tal cual (p. ej. uno escrito a mano en config.json).
    #>
    param([string]$Encoder)
    $e = "$Encoder".Trim().ToLower()
    if ($e -eq '')     { return '' }
    if ($e -eq 'copy') { return (Get-CvText -Key 'enc.copia') }
    foreach ($o in (Get-CvVideoEncoders)) {
        if ("$($o.Value)".ToLower() -ne $e) { continue }
        if ("$($o.Text)" -match '^\[([^\]]+)\]') {
            $parts = @(($Matches[1] -split '-') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if ($parts.Count -ge 2) { return ("{0} ({1})" -f $parts[0], $parts[1]) }
            if ($parts.Count -eq 1) { return $parts[0] }
        }
        break
    }
    return $e
}

function Get-CvCpuEncoders {
    <# Fuente unica de los encoders de video por CPU (usan CRF, no QP/multipass de NVENC). #>
    @(
        'libx264'
        'libx265'
        'libsvtav1'
    )
}

function Get-CvAv1Encoders {
    <# Fuente unica de la FAMILIA AV1 (CPU + GPU): comparten opciones de codec (profundidad de bits,
       sin levels). libsvtav1 (CPU) validado; av1_nvenc (GPU) etiquetado [SIN PROBAR] (sin hardware RTX 40+). #>
    @(
        'libsvtav1'
        'av1_nvenc'
    )
}

function Get-CvMultipass2Pass {
    <# Fuente unica de los modos de multipass NVENC que SI son 2-pass (excluye 'off'). #>
    @(
        'qres'
        'fullres'
    )
}

function Get-CvAutoEncoderPriority {
    <#
        Orden de preferencia del perfil AUTO: MEJOR codec primero (av1 > h265 > h264) y, dentro de
        cada codec, GPU (NVENC, mas rapido) antes que CPU. Cada entrada: Value (encoder), Codec y Gpu.
        Resolve-CvAutoEncoder recorre esta lista aplicando los filtros (autoGpuOnly / autoMaxCodec) y
        la sonda de soporte real, y devuelve el primero que encaje.
    #>
    @(
        @{ Value = 'av1_nvenc';  Codec = 'av1';  Gpu = $true }
        @{ Value = 'libsvtav1';  Codec = 'av1';  Gpu = $false }
        @{ Value = 'hevc_nvenc'; Codec = 'h265'; Gpu = $true }
        @{ Value = 'libx265';    Codec = 'h265'; Gpu = $false }
        @{ Value = 'h264_nvenc'; Codec = 'h264'; Gpu = $true }
        @{ Value = 'libx264';    Codec = 'h264'; Gpu = $false }
    )
}

function Get-CvCodecRank {
    <# Rango de "nivel" de codec para el tope autoMaxCodec (mayor = mejor compresion). #>
    param([string]$Codec)
    switch ("$Codec".ToLower()) {
        'av1'  { 3 }
        'h265' { 2 }
        'h264' { 1 }
        default { 0 }
    }
}

function Resolve-CvAutoEncoder {
    <#
        Elige el mejor encoder soportado por este equipo segun Get-CvAutoEncoderPriority, aplicando:
          -GpuOnly:  si $true, solo considera entradas por GPU (descarta CPU).
          -MaxCodec: tope de codec ('' = sin tope | h264 | h265 | av1); descarta los de codec superior.
        Se comprueba el soporte real con Test-CvEncoderSupported (CPU siempre; GPU segun la sonda).
        Si nada encaja (p. ej. GpuOnly sin GPU compatible), cae a 'libx265' (CPU H.265, red de seguridad).
    #>
    param($Context, [bool]$GpuOnly = $false, [string]$MaxCodec = '')
    $cap = if ($MaxCodec) { Get-CvCodecRank $MaxCodec } else { 99 }
    foreach ($e in (Get-CvAutoEncoderPriority)) {
        if ($GpuOnly -and -not $e.Gpu) { continue }
        if ((Get-CvCodecRank $e.Codec) -gt $cap) { continue }
        if (Test-CvEncoderSupported -Context $Context -Encoder $e.Value) { return $e.Value }
    }
    'libx265'
}

function Get-CvAutoRate {
    <#
        Control de tasa "auto" para un encoder concreto: profundidad segun el codec (main10 en h265/av1,
        high 8-bit en h264 —no tiene main10—) y QP en NVENC / CRF en CPU (AV1 0-63 vs H.264/265 0-51).
        Los VALORES (CRF/Qmin/Qmax/level) NO se hardcodean aqui: salen de la config (encode.auto.crf /
        crfAv1 / qmin / qmax / level) via el Context; si no se pasa Context, se leen de
        Get-CvConfigDefaults (misma fuente de verdad). FUENTE UNICA de la parametrizacion auto: la usan
        New-CvAutoProfile (opcion "A") y Resolve-CvProfileAuto (videoEncoder: "auto"). Solo la
        profundidad (main10/high) es logica del codec. Devuelve {VideoProfile; VideoLevel; Qmin; Qmax; Crf}.
    #>
    param([Parameter(Mandatory)][string]$Encoder, $Context = $null)
    # Valores del Context si los trae; si no (p. ej. tests con -Context $null), de los defaults de config.
    if ($null -ne $Context -and $null -ne $Context.AutoQmax) {
        $crf26x = [int]$Context.AutoCrf; $crfAv1 = [int]$Context.AutoCrfAv1
        $qmin   = [int]$Context.AutoQmin; $qmax = [int]$Context.AutoQmax; $level = "$($Context.AutoLevel)"
    } else {
        $a = (Get-CvConfigDefaults).encode.video.auto
        $crf26x = [int]$a.crf; $crfAv1 = [int]$a.crfAv1
        $qmin   = [int]$a.qmin; $qmax = [int]$a.qmax; $level = "$($a.level)"
    }
    $isCpu  = $Encoder -in (Get-CvCpuEncoders)
    $isAv1  = $Encoder -in (Get-CvAv1Encoders)
    $isH264 = $Encoder -in @('libx264', 'h264_nvenc')
    $vp = if ($isH264) { 'high' } else { 'main10' }
    # Nivel: lo llevan todos los codecs H.26x (CPU y GPU); AV1 no usa level (queda vacio).
    $vl = if ($isAv1) { '' } else { $level }
    if ($isCpu) {
        [pscustomobject]@{ VideoProfile = $vp; VideoLevel = $vl; Qmin = $null; Qmax = $null; Crf = $(if ($isAv1) { $crfAv1 } else { $crf26x }) }
    } else {
        [pscustomobject]@{ VideoProfile = $vp; VideoLevel = $vl; Qmin = $qmin; Qmax = $qmax; Crf = $null }
    }
}

function New-CvAutoProfile {
    <#
        Perfil AUTO: resuelve el mejor encoder del equipo (Resolve-CvAutoEncoder con los filtros
        encode.auto.gpuOnly / encode.auto.maxCodec del Context) y arma el perfil con el control de tasa
        adecuado (Get-CvAutoRate). Asi el usuario elige "Auto" y no tiene que saber que soporta su equipo.
    #>
    param($Context)
    $gpuOnly = [bool]($Context -and $Context.AutoGpuOnly)
    $maxCod  = if ($Context) { "$($Context.AutoMaxCodec)" } else { '' }
    $enc     = Resolve-CvAutoEncoder -Context $Context -GpuOnly $gpuOnly -MaxCodec $maxCod
    $r       = Get-CvAutoRate -Encoder $enc -Context $Context
    New-CvProfile -VideoEncoder $enc -VideoProfile $r.VideoProfile -VideoLevel $r.VideoLevel -Qmin $r.Qmin -Qmax $r.Qmax -Crf $r.Crf
}

function Resolve-CvProfileAuto {
    <#
        Resuelve un perfil cuyo VideoEncoder sea el literal 'auto' (p. ej. de un perfil de config.json)
        al mejor encoder soportado por este equipo, CONSERVANDO el resto del perfil (audio, resize/crop,
        maxWidth, detectBorder, multipass...). Solo reescribe los campos ligados al codec de video
        (VideoEncoder + control de tasa via Get-CvAutoRate), porque el CRF/QP del origen no puede saber
        que encoder saldra. Si el encoder no es 'auto', devuelve el perfil TAL CUAL (no-op). Se llama en
        PREPARAR (con Context, para la sonda de GPU) antes de congelar el perfil en el .job.json, igual
        que la opcion "A" del menu.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof)
    if ("$($Prof.VideoEncoder)".ToLower() -ne 'auto') { return $Prof }
    $gpuOnly = [bool]($Context -and $Context.AutoGpuOnly)
    $maxCod  = if ($Context) { "$($Context.AutoMaxCodec)" } else { '' }
    $enc     = Resolve-CvAutoEncoder -Context $Context -GpuOnly $gpuOnly -MaxCodec $maxCod
    $r       = Get-CvAutoRate -Encoder $enc -Context $Context
    $new = $Prof.PSObject.Copy()   # copia superficial: conserva audio/resize/crop/etc.
    $new.VideoEncoder = $enc
    $new.VideoProfile = $r.VideoProfile
    $new.VideoLevel   = $r.VideoLevel
    $new.Qmin = $r.Qmin
    $new.Qmax = $r.Qmax
    $new.Crf  = $r.Crf
    return $new
}

function Get-CvVideoSizes {
    <#
        Catalogo de tamanos de referencia para el menu de resize del perfil custom. Lista de
        @{ Value; Text } (formato comun): Value = tamano 'W:H' para -ChangeSize; Text = descripcion.
        Solo informativo: el usuario teclea el tamano; anadir/quitar filas aqui basta.
    #>
    @(
        @{
            Value = '640:360'
            Text  = (Get-CvText -Key 'cat.size.360')
        }
        @{
            Value = '1024:576'
            Text  = (Get-CvText -Key 'cat.size.576')
        }
        @{
            Value = '1280:720'
            Text  = (Get-CvText -Key 'cat.size.720')
        }
        @{
            Value = '1920:1080'
            Text  = (Get-CvText -Key 'cat.size.1080')
        }
        @{
            Value = '1920:-2'
            Text  = (Get-CvText -Key 'cat.size.1080ar')
        }
        @{
            Value = '3840:2160'
            Text  = (Get-CvText -Key 'cat.size.4k')
        }
    )
}

function Get-CvCodecOptions {
    <#
        Perfiles (-profile:v) y levels (-level:v) validos segun la familia del codec, con una
        descripcion por opcion para el menu. H.265 (libx265/hevc_nvenc) y H.264 (libx264/h264_nvenc)
        admiten valores distintos.

        OJO fuente: la doc de ffmpeg NO describe estos valores (-profile remite a "x264 --fullhelp"
        y -level a "Annex A"). Las descripciones salen del ESTANDAR del codec (H.264/HEVC); las de
        level son APROXIMADAS (marcadas con '~': tope tipico de resolucion/fps del nivel).
        Devuelve @{ Profiles; Levels }, cada una lista de @{ Value; Text } (formato comun).
    #>
    param([string]$Encoder)
    $h265Family = @(
        'libx265'
        'hevc_nvenc'
    )
    $av1Family = Get-CvAv1Encoders
    if ($Encoder -in $h265Family) {
        [pscustomobject]@{
            Profiles = @(
                @{
                    Value = 'main'
                    Text  = (Get-CvText -Key 'cat.bits.8')
                }
                @{
                    Value = 'main10'
                    Text  = (Get-CvText -Key 'cat.bits.10')
                }
            )
            Levels = @(
                @{
                    Value = '4.0'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p30')
                }
                @{
                    Value = '4.1'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p60')
                }
                @{
                    Value = '5.0'
                    Text  = (Get-CvText -Key 'cat.lvl.4k30')
                }
                @{
                    Value = '5.1'
                    Text  = (Get-CvText -Key 'cat.lvl.4k60')
                }
                @{
                    Value = '5.2'
                    Text  = (Get-CvText -Key 'cat.lvl.4k120')
                }
                @{
                    Value = '6.0'
                    Text  = (Get-CvText -Key 'cat.lvl.8k30')
                }
                @{
                    Value = '6.1'
                    Text  = (Get-CvText -Key 'cat.lvl.8k60')
                }
                @{
                    Value = '6.2'
                    Text  = (Get-CvText -Key 'cat.lvl.8k120')
                }
            )
        }
    } elseif ($Encoder -in $av1Family) {
        # AV1: aqui 'Profiles' solo elige la PROFUNDIDAD de bits (main = 8, main10 = 10; no se pasa
        # como -profile:v). No hay 'Levels' relevantes (el codificador no los usa), asi que van vacios.
        [pscustomobject]@{
            Profiles = @(
                @{
                    Value = 'main'
                    Text  = (Get-CvText -Key 'cat.bits.8')
                }
                @{
                    Value = 'main10'
                    Text  = (Get-CvText -Key 'cat.bits.10')
                }
            )
            Levels = @()
        }
    } else {
        [pscustomobject]@{
            Profiles = @(
                @{
                    Value = 'baseline'
                    Text  = (Get-CvText -Key 'cat.prof.baseline')
                }
                @{
                    Value = 'main'
                    Text  = (Get-CvText -Key 'cat.prof.main')
                }
                @{
                    Value = 'high'
                    Text  = (Get-CvText -Key 'cat.prof.high')
                }
                @{
                    Value = 'high10'
                    Text  = (Get-CvText -Key 'cat.prof.high10')
                }
            )
            Levels = @(
                @{
                    Value = '3.0'
                    Text  = (Get-CvText -Key 'cat.lvl.480p')
                }
                @{
                    Value = '3.1'
                    Text  = (Get-CvText -Key 'cat.lvl.720p30')
                }
                @{
                    Value = '4.0'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p30')
                }
                @{
                    Value = '4.1'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p30bd')
                }
                @{
                    Value = '4.2'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p60')
                }
                @{
                    Value = '5.0'
                    Text  = (Get-CvText -Key 'cat.lvl.1080p72')
                }
                @{
                    Value = '5.1'
                    Text  = (Get-CvText -Key 'cat.lvl.4k30')
                }
            )
        }
    }
}

function Get-CvAudioBitrates {
    <#
        Catalogo de bitrates del menu del perfil custom, APROPIADO AL CODEC (-Codec). Lista
        @{ Value; Text } (+ 'Position' opcional): sin Position -> preset numerado en orden;
        'end' -> siempre la ultima ('custom', bitrate a mano). Para AC-3/E-AC-3 se ofrecen
        bitrates de sonido envolvente (hasta 640k, el maximo de AC-3); para el resto (AAC/MP3/Opus),
        el rango estereo/lossy habitual. FLAC no llama aqui (es sin perdida). Descripciones =
        orientativas (no de la doc de ffmpeg). El menu se muestra DESPUES de elegir el codec.
    #>
    param([string]$Codec = 'aac')
    $ac3Family = @(
        'ac3'
        'eac3'
    )
    if ("$Codec".ToLower() -in $ac3Family) {
        @(
            @{
                Value = '192k'
                Text  = (Get-CvText -Key 'cat.abr.ac3.384')
            }
            @{
                Value = '256k'
                Text  = (Get-CvText -Key 'cat.abr.ac3.448')
            }
            @{
                Value = '384k'
                Text  = (Get-CvText -Key 'cat.abr.ac3.512')
            }
            @{
                Value = '448k'
                Text  = (Get-CvText -Key 'cat.abr.ac3.576')
            }
            @{
                Value = '640k'
                Text  = (Get-CvText -Key 'cat.abr.ac3.640')
            }
            @{
                Value    = 'custom'
                Text     = (Get-CvText -Key 'cat.abr.mano.768')
                Position = 'end'
            }
        )
    } else {
        @(
            @{
                Value = '96k'
                Text  = (Get-CvText -Key 'cat.abr.aac.96')
            }
            @{
                Value = '128k'
                Text  = (Get-CvText -Key 'cat.abr.aac.128')
            }
            @{
                Value = '160k'
                Text  = (Get-CvText -Key 'cat.abr.aac.160')
            }
            @{
                Value = '192k'
                Text  = (Get-CvText -Key 'cat.abr.aac.192')
            }
            @{
                Value = '256k'
                Text  = (Get-CvText -Key 'cat.abr.aac.256')
            }
            @{
                Value = '320k'
                Text  = (Get-CvText -Key 'cat.abr.aac.320')
            }
            @{
                Value    = 'custom'
                Text     = (Get-CvText -Key 'cat.abr.mano.224')
                Position = 'end'
            }
        )
    }
}

function Get-CvAudioCodecs {
    <#
        Catalogo de la SALIDA de audio del perfil custom: 'copy' (no recodificar) + codecs a los que
        recodificar. Lista @{ Value; Short; Text }: Value = 'copy' o el codec de ffmpeg (-c:a).
        Al recodificar, el intermedio va en '.m4a' para AAC (compatible con la normalizacion aacgain)
        y en '.mka' (Matroska) para el resto, que luego se remultiplexa igual al MKV final. 'aac' es
        el codec por defecto. Notas: FLAC es sin perdida (se salta el bitrate); Opus fuerza 48 kHz.
        Short = nombre corto para la etiqueta compacta del perfil (Format-CvProfileLabel); asi el
        nombre "bonito" (p. ej. libmp3lame -> MP3) se define UNA sola vez, aqui.
    #>
    @(
        @{
            Value = 'copy'
            Short = 'COPY'
            Text  = (Get-CvText -Key 'cat.acod.copy')
        }
        @{
            Value = 'aac'
            Short = 'AAC'
            Text  = (Get-CvText -Key 'cat.acod.aac')
        }
        @{
            Value = 'ac3'
            Short = 'AC3'
            Text  = (Get-CvText -Key 'cat.acod.ac3')
        }
        @{
            Value = 'eac3'
            Short = 'EAC3'
            Text  = (Get-CvText -Key 'cat.acod.eac3')
        }
        @{
            Value = 'libmp3lame'
            Short = 'MP3'
            Text  = (Get-CvText -Key 'cat.acod.mp3')
        }
        @{
            Value = 'flac'
            Short = 'FLAC'
            Text  = (Get-CvText -Key 'cat.acod.flac')
        }
        @{
            Value = 'libopus'
            Short = 'OPUS'
            Text  = (Get-CvText -Key 'cat.acod.opus')
        }
    )
}

function Get-CvNvencMultipass {
    <#
        Catalogo del 2-pass de NVENC (-multipass) para el menu del perfil custom. Lista de
        @{ Value; Text } (formato comun) con off/qres/fullres. Descripciones tomadas de ffmpeg
        (-h encoder=hevc_nvenc): la parte de resolucion es literal; el resto es la consecuencia
        practica (mas pasadas = mas calidad y mas tiempo). 'off' se usa como opcion 0 en el menu.
    #>
    @(
        @{
            Value    = 'off'
            Text     = (Get-CvText -Key 'cat.mp.off')
            Position = 'first'
        }
        @{
            Value = 'qres'
            Text  = (Get-CvText -Key 'cat.mp.qres')
        }
        @{
            Value = 'fullres'
            Text  = (Get-CvText -Key 'cat.mp.fullres')
        }
    )
}

function Get-CvProfileProp($obj, [string]$key, $default) {
    <# Valor de una propiedad del objeto de perfil de config, o $default si falta / es null. #>
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$key]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}

function ConvertTo-CvProfile {
    <# Convierte un objeto de perfil de config.json (camelCase) en un perfil (New-CvProfile). #>
    param([Parameter(Mandatory)]$Obj)
    # Fallbacks de la salida de audio: FUENTE UNICA en config (encode.audio.*), no hardcodeados.
    $eaud = (Get-CvConfigDefaults).encode.audio
    New-CvProfile `
        -VideoEncoder "$(Get-CvProfileProp $Obj 'videoEncoder' '')" `
        -VideoProfile "$(Get-CvProfileProp $Obj 'videoProfile' '')" `
        -VideoLevel   "$(Get-CvProfileProp $Obj 'videoLevel' '')" `
        -Qmin (Get-CvProfileProp $Obj 'qmin' $null) `
        -Qmax (Get-CvProfileProp $Obj 'qmax' $null) `
        -Crf  (Get-CvProfileProp $Obj 'crf'  $null) `
        -DetectBorder $(if ("$(Get-CvProfileProp $Obj 'detectBorder' $false)".ToLower() -eq 'auto') { 'auto' } else { [bool](Get-CvProfileProp $Obj 'detectBorder' $false) }) `
        -ChangeSize   "$(Get-CvProfileProp $Obj 'changeSize' '')" `
        -NoUpscale    ([bool](Get-CvProfileProp $Obj 'noUpscale' $false)) `
        -MaxWidth     (Get-CvProfileProp $Obj 'maxWidth' $null) `
        -Multipass    "$(Get-CvProfileProp $Obj 'multipass' '')" `
        -AudioEncoder "$(Get-CvProfileProp $Obj 'audioEncoder' $eaud.encoder)" `
        -AudioCodec   "$(Get-CvProfileProp $Obj 'audioCodec' $eaud.codec)" `
        -AudioBitrate "$(Get-CvProfileProp $Obj 'audioBitrate' $eaud.bitrate)" `
        -AudioHz ([int](Get-CvProfileProp $Obj 'audioHz' $eaud.hz)) `
        -AudioChannels (Get-CvProfileProp $Obj 'audioChannels' $null) `
        -DownmixMode   (Get-CvProfileProp $Obj 'downmixMode' $null) `
        -DownmixCoeffs (ConvertTo-CvDownmixCoeffs (Get-CvProfileProp $Obj 'downmixCoeffs' $null))
}

# ===========================================================================
#  Perfiles PROPIOS (config.json -> 'profiles'): guardarlos, renombrarlos y borrarlos
#
#  Hasta ahora un perfil hecho a mano (el Custom de consola / 'Ajustar...' de la ventana) moria con
#  el job: para reutilizarlo habia que escribirlo A MANO en config.json. Esto es lo que falta para
#  cerrar el circulo, y vive AQUI -con el resto de lo que sabe de perfiles- en vez de en cada UI:
#  la consola y las dos ventanas llaman a las mismas funciones.
#
#  Las de LISTA son puras (se prueban sin tocar disco); las de fichero son una capa fina encima.
# ===========================================================================

function ConvertTo-CvProfileConfig {
    <#
        PURO. Inverso de ConvertTo-CvProfile: el objeto camelCase que se guarda en config.json.

        Solo se escribe lo que TIENE valor. Un campo ausente significa "usa el global de encode.*",
        que es exactamente como lo lee ConvertTo-CvProfile: asi un perfil guardado sigue al config
        si manana se cambia el bitrate o el downmix globales, en vez de quedarse congelado.
    #>
    param(
        [Parameter(Mandatory)]$Prof,
        [string]$Label = ''
    )
    $o = [ordered]@{}
    if ("$Label".Trim() -ne '') { $o['label'] = "$Label".Trim() }
    # El encoder SIEMPRE se escribe (incluido 'copy'): es lo que define el perfil.
    $o['videoEncoder'] = "$($Prof.VideoEncoder)"
    if ("$($Prof.VideoProfile)".Trim() -ne '') { $o['videoProfile'] = "$($Prof.VideoProfile)".Trim() }
    if ("$($Prof.VideoLevel)".Trim()   -ne '') { $o['videoLevel']   = "$($Prof.VideoLevel)".Trim() }
    if ($null -ne $Prof.Qmin) { $o['qmin'] = [int]$Prof.Qmin }
    if ($null -ne $Prof.Qmax) { $o['qmax'] = [int]$Prof.Qmax }
    if ($null -ne $Prof.Crf)  { $o['crf']  = [int]$Prof.Crf }
    # detectBorder: 'auto' o $true se guardan; $false es el default, no hace falta escribirlo.
    if ("$($Prof.DetectBorder)".ToLower() -eq 'auto') { $o['detectBorder'] = 'auto' }
    elseif ([bool]$Prof.DetectBorder)                 { $o['detectBorder'] = $true }
    if ("$($Prof.ChangeSize)".Trim() -ne '') { $o['changeSize'] = "$($Prof.ChangeSize)".Trim() }
    if ([bool]$Prof.NoUpscale)               { $o['noUpscale']  = $true }
    if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { $o['maxWidth'] = [int]$Prof.MaxWidth }
    if ("$($Prof.Multipass)".Trim()    -ne '') { $o['multipass']    = "$($Prof.Multipass)".Trim() }
    if ("$($Prof.AudioEncoder)".Trim() -ne '') { $o['audioEncoder'] = "$($Prof.AudioEncoder)".Trim() }
    if ("$($Prof.AudioCodec)".Trim()   -ne '') { $o['audioCodec']   = "$($Prof.AudioCodec)".Trim() }
    if ("$($Prof.AudioBitrate)".Trim() -ne '') { $o['audioBitrate'] = "$($Prof.AudioBitrate)".Trim() }
    if ($null -ne $Prof.AudioHz -and [int]$Prof.AudioHz -gt 0) { $o['audioHz'] = [int]$Prof.AudioHz }
    if ($null -ne $Prof.AudioChannels -and [int]$Prof.AudioChannels -ge 1) { $o['audioChannels'] = [int]$Prof.AudioChannels }
    if ("$($Prof.DownmixMode)".Trim() -ne '') { $o['downmixMode'] = "$($Prof.DownmixMode)".Trim() }
    if ($null -ne $Prof.DownmixCoeffs) {
        $o['downmixCoeffs'] = [pscustomobject][ordered]@{
            center   = [double]$Prof.DownmixCoeffs.Center
            front    = [double]$Prof.DownmixCoeffs.Front
            surround = [double]$Prof.DownmixCoeffs.Surround
        }
    }
    return [pscustomobject]$o
}

function Get-CvProfileLabel {
    <# PURO. Nombre de una entrada de 'profiles' (su 'label'), o '' si no lo lleva. #>
    param($Entry)
    return "$(Get-CvProfileProp $Entry 'label' '')".Trim()
}

function Test-CvProfileName {
    <#
        PURO. Comprueba el nombre con el que se quiere guardar un perfil. Devuelve @{ Ok; Error }.
        -Existing son las entradas que ya hay (para el duplicado) y -Allow el nombre que se esta
        editando (renombrarse a si mismo no es un duplicado).
    #>
    param(
        [string]$Name,
        $Existing = @(),
        [string]$Allow = ''
    )
    $n = "$Name".Trim()
    if ($n -eq '')            { return @{ Ok = $false; Error = 'El perfil necesita un nombre.' } }
    if ($n.Length -gt 60)     { return @{ Ok = $false; Error = 'El nombre es demasiado largo (maximo 60 caracteres).' } }
    foreach ($e in @($Existing)) {
        $lbl = Get-CvProfileLabel $e
        if ($lbl -eq '') { continue }
        if ($lbl -eq "$Allow".Trim()) { continue }
        # Sin distinguir mayusculas: dos perfiles que solo se diferencien en eso no se distinguen
        # en el menu, y el que manda es el primero.
        if ($lbl -ieq $n) { return @{ Ok = $false; Error = ("Ya hay un perfil que se llama '{0}'." -f $lbl) } }
    }
    return @{ Ok = $true; Error = '' }
}

function Set-CvProfileInList {
    <#
        PURO. Devuelve la lista de perfiles con -Entry dentro: sustituye al que tenga ese mismo
        nombre (o el de -Replace, para renombrar) y, si no hay ninguno, lo anade al final.
    #>
    param(
        $List = @(),
        [Parameter(Mandatory)]$Entry,
        [string]$Replace = ''
    )
    $target = $(if ("$Replace".Trim() -ne '') { "$Replace".Trim() } else { Get-CvProfileLabel $Entry })
    $out  = @()
    $done = $false
    foreach ($e in @($List)) {
        if (-not $done -and $target -ne '' -and (Get-CvProfileLabel $e) -ieq $target) {
            $out += $Entry
            $done = $true
        } else {
            $out += $e
        }
    }
    if (-not $done) { $out += $Entry }
    return @($out)
}

function Remove-CvProfileFromList {
    <# PURO. La lista sin el perfil que se llama -Label (si no esta, la misma lista). #>
    param(
        $List = @(),
        [Parameter(Mandatory)][string]$Label
    )
    $t = "$Label".Trim()
    return @(@($List) | Where-Object { (Get-CvProfileLabel $_) -ine $t })
}

function Get-CvProfileList {
    <#
        PURO. La seccion 'profiles' de un config (crudo o el de defaults) como array LIMPIO. Sin
        esto, una seccion ausente da @($null) -un elemento fantasma que se cuenta como perfil y
        acabaria escrito como 'null' en el fichero-.
    #>
    param($Config)
    if ($null -eq $Config) { return @() }
    # A mano y no con Get-CvNodeVal: ese devuelve el valor con una coma unaria delante (para que
    # PowerShell no desenvuelva las listas), y aqui eso deja la lista DENTRO de otra lista: el
    # primer 'perfil' seria el array entero y nada cuadraria despues.
    $v = $null
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains('profiles')) { $v = $Config['profiles'] }
    } elseif ($Config.PSObject.Properties['profiles']) {
        $v = $Config.profiles
    }
    if ($null -eq $v) { return @() }
    return @(@($v) | Where-Object { $null -ne $_ })
}

function Get-CvConfigProfiles {
    <#
        Los perfiles propios que hay AHORA en el fichero de config (no los del contexto, que son los
        que habia al abrirlo). Vacio si el fichero no existe o no tiene la seccion.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $cfg = Read-CvConfigFile -Path $Path
    } catch { return @() }
    return @(Get-CvProfileList $cfg)
}

function Get-CvConfigProfileRows {
    <#
        Los perfiles propios listos para ENSENARLOS: @{ Label; Text; Prof; Entry } por cada uno, con
        la misma etiqueta que el menu de perfiles (Format-CvProfileLabel). Lo usan el submenu de
        consola y la ventana de perfiles: ninguna de las dos re-lee ni re-formatea por su cuenta.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $out = @()
    foreach ($e in @(Get-CvConfigProfiles -Path $Path)) {
        $prof = ConvertTo-CvProfile -Obj $e
        $out += [pscustomobject]@{
            Label = (Get-CvProfileLabel $e)
            Text  = (Format-CvProfileLabel -Prof $prof)
            Prof  = $prof
            Entry = $e
            Kind  = 'propio'
        }
    }
    return @($out)
}

function Get-CvBuiltinProfileRows {
    <#
        PURO. Los perfiles DE SERIE listos para ensenarlos: @{ Num; Label; Text; Prof; Kind }. El
        numero es el MISMO con el que salen en el menu de perfiles (1..N, continuo entre grupos),
        que es como se conocen; el texto, la misma etiqueta que ahi (Format-CvProfileLabel).

        No se pueden editar ni borrar -viven en el codigo, no en el config-, pero DUPLICAR uno es la
        forma comoda de partir de algo que ya funciona para hacerse uno propio.
    #>
    $out = @()
    $n = 0
    foreach ($g in @(Get-CvProfiles)) {
        foreach ($pr in @($g.Profiles)) {
            $n++
            $out += [pscustomobject]@{
                Num   = $n
                Label = ("Perfil {0}" -f $n)
                Text  = (Format-CvProfileLabel -Prof $pr)
                Prof  = $pr
                Entry = $null
                Kind  = 'serie'
            }
        }
    }
    return @($out)
}

function Get-CvDefaultProfileKey {
    <#
        PURO. La CLAVE de menu del perfil PREDETERMINADO: '3' (uno de serie), '14' (uno propio) o 'A'
        (Auto). -Default es lo que diga la config: el NOMBRE de un perfil propio, 'Perfil N' de los
        de serie, o 'Auto'. Lo que no se reconozca -un perfil propio que se ha borrado, por ejemplo-
        cae en Auto, que es lo que habia antes de que existiera esta opcion.

        La numeracion es la MISMA que el menu de consola y la lista de la ventana: los de serie 1..N
        (continuo entre grupos) y los propios detras, en el orden del config.
    #>
    param(
        [string]$Default = '',
        [object[]]$Extra = @()
    )
    $d = "$Default".Trim()
    if ($d -eq '' -or $d -match '^(?i)auto$') { return 'A' }
    $n = 0
    foreach ($g in @(Get-CvProfiles)) {
        foreach ($pr in @($g.Profiles)) { $n++ }
    }
    # Por NOMBRE, que es como se identifican los propios (igual que al guardarlos o borrarlos).
    for ($i = 0; $i -lt @($Extra).Count; $i++) {
        $obj = @($Extra)[$i]
        if ($null -eq $obj) { continue }
        $lbl = "$(Get-CvProfileProp $obj 'label' '')".Trim()
        if ($lbl -ne '' -and $lbl -eq $d) { return "$($n + $i + 1)" }
    }
    if ($d -match '^(?i)perfil\s+(\d+)$') {
        $num = [int]$matches[1]
        if ($num -ge 1 -and $num -le $n) { return "$num" }
    }
    return 'A'
}

function Get-CvConfigDefaultProfile {
    <#
        El perfil predeterminado que hay AHORA en el fichero (no el del contexto, que es el que habia
        al abrir): asi cambiarlo desde la ventana vale sin reiniciar. 'Auto' si no hay nada puesto.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'Auto' }
    try {
        $cfg = Read-CvConfigFile -Path $Path
    } catch { return 'Auto' }
    $v = ''
    if ($cfg -is [System.Collections.IDictionary]) {
        if ($cfg.Contains('defaultProfile')) { $v = "$($cfg['defaultProfile'])" }
    } elseif ($cfg.PSObject.Properties['defaultProfile']) {
        $v = "$($cfg.defaultProfile)"
    }
    if ("$v".Trim() -eq '') { return 'Auto' }
    return "$v".Trim()
}

function Save-CvConfigDefaultProfile {
    <#
        Deja escrito cual es el perfil predeterminado (-Label: el nombre de uno propio, 'Perfil N' de
        los de serie, o 'Auto'). Escribe SOLO esa clave sobre el config crudo. Devuelve @{ Ok; Error }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label
    )
    $v = "$Label".Trim()
    if ($v -eq '') { $v = 'Auto' }
    return (Set-CvConfigValue -Path $Path -Key 'defaultProfile' -Value $v)
}

function Get-CvProfileManagerRows {
    <#
        Todo lo que se ensena al gestionar perfiles: primero los PROPIOS (los editables) y detras los
        de SERIE (solo lectura). Fuente unica de las dos caras: la ventana de setup y el submenu de
        consola listan lo mismo y en el mismo orden.
    #>
    param([Parameter(Mandatory)][string]$Path)
    return @(@(Get-CvConfigProfileRows -Path $Path) + @(Get-CvBuiltinProfileRows))
}

function Save-CvConfigProfile {
    <#
        Guarda un perfil en config.json -> 'profiles' con el nombre -Label. Si ya hay uno con ese
        nombre se SUSTITUYE (o se renombra el de -Replace), asi que sirve igual para crear y para
        editar. Devuelve @{ Ok; Error; Label; Count }.

        Se escribe sobre el fichero CRUDO (Read-CvConfigFile / Save-CvConfigFile): lo que no sea la
        seccion 'profiles' se queda tal cual estaba, incluida la sangria y el orden.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$Label,
        [string]$Replace = ''
    )
    try {
        # El config crudo es un PSCustomObject (viene de ConvertFrom-Json) pero los defaults son un
        # hashtable: se entra por los helpers del propio Config, que saben con cual estan hablando.
        $cfg = $(if (Test-Path -LiteralPath $Path) { Read-CvConfigFile -Path $Path } else { Get-CvConfigDefaults })
        $cur = @(Get-CvProfileList $cfg)
        $chk = Test-CvProfileName -Name $Label -Existing $cur -Allow $(if ("$Replace" -ne '') { $Replace } else { $Label })
        if (-not $chk.Ok) { return @{ Ok = $false; Error = "$($chk.Error)"; Label = "$Label"; Count = $cur.Count } }
        $entry = ConvertTo-CvProfileConfig -Prof $Prof -Label $Label
        $new   = @(Set-CvProfileInList -List $cur -Entry $entry -Replace $Replace)
        Set-CvChildLeaf -Node $cfg -Key 'profiles' -Value $new
        Save-CvConfigFile -Path $Path -Config $cfg
        return @{ Ok = $true; Error = ''; Label = "$Label".Trim(); Count = $new.Count }
    } catch {
        return @{ Ok = $false; Error = "$($_.Exception.Message)"; Label = "$Label"; Count = 0 }
    }
}

function Remove-CvConfigProfile {
    <# Borra de config.json el perfil propio que se llama -Label. Devuelve @{ Ok; Error; Count }. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return @{ Ok = $false; Error = 'No existe el fichero de configuracion.'; Count = 0 } }
        $cfg = Read-CvConfigFile -Path $Path
        $cur = @(Get-CvProfileList $cfg)
        $new = @(Remove-CvProfileFromList -List $cur -Label $Label)
        if ($new.Count -eq $cur.Count) { return @{ Ok = $false; Error = ("No hay ningun perfil que se llame '{0}'." -f $Label); Count = $cur.Count } }
        Set-CvChildLeaf -Node $cfg -Key 'profiles' -Value $new
        Save-CvConfigFile -Path $Path -Config $cfg
        return @{ Ok = $true; Error = ''; Count = $new.Count }
    } catch {
        return @{ Ok = $false; Error = "$($_.Exception.Message)"; Count = 0 }
    }
}

function Save-CvProfileInteractive {
    <#
        CONSOLA: pide el nombre y guarda el perfil en config.json ('profiles'). Insiste mientras el
        nombre no valga (vacio o repetido) y se sale con 'C'/ESC sin guardar nada.
        -Current = nombre actual cuando se esta EDITANDO uno (ENTER lo conserva y no cuenta como
        duplicado consigo mismo). Devuelve el nombre guardado, o '' si no se guardo.
    #>
    param(
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$Path,
        [string]$Current = ''
    )
    while ($true) {
        $hint = $(if ("$Current" -ne '') { " [ENTER = {0}]" -f $Current } else { '' })
        $name = ''
        try {
            $name = (Read-CvLine -Prompt (Get-CvText -Key 'pr.nombre.q' -Values @($hint)) -AllowCancel).Trim()
        } catch {
            if ("$($_.Exception.Message)" -eq 'CV_CANCEL') { return '' }
            throw
        }
        if ($name -match '^[Cc]$') { return '' }
        if ($name -eq '' -and "$Current" -ne '') { $name = "$Current" }
        $chk = Test-CvProfileName -Name $name -Existing (Get-CvConfigProfiles -Path $Path) -Allow $Current
        if (-not $chk.Ok) {
            Write-Host ("   {0}" -f $chk.Error) -ForegroundColor Yellow
            continue
        }
        $r = Save-CvConfigProfile -Path $Path -Prof $Prof -Label $name -Replace $Current
        if (-not $r.Ok) {
            Write-Host (Get-CvText -Key 'pr.noguarda' -Values @($r.Error)) -ForegroundColor Red
            return ''
        }
        Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.guardado' -Values @((Split-Path -Leaf $Path), $r.Label))
        return "$($r.Label)"
    }
}

function Format-CvProfileLabel {
    <#
        Etiqueta compacta de un perfil para el menu (estilo 'A: 192K, V: h265[NV]/M10/L5/Q(1-23)').
        FUENTE UNICA: la usan tanto los perfiles de serie (Select-Profile) como los propios de
        config.json, para no duplicar la lista del menu y que siempre refleje los valores reales.
    #>
    param([Parameter(Mandatory)]$Prof)
    $encMap = @{
        'hevc_nvenc' = 'h265[NV]'
        'h264_nvenc' = 'h264[NV]'
        'libx265'    = 'h265'
        'libx264'    = 'h264'
        'av1_nvenc'  = 'av1[NV]'
        'libsvtav1'  = 'av1'
    }
    $profMap = @{
        'main10' = 'M10'
        'main'   = 'M'
    }
    if ($Prof.VideoEncoder -eq 'copy' -or -not $Prof.VideoEncoder) {
        $v = 'COPY'
    } else {
        $enc = $encMap["$($Prof.VideoEncoder)"]; if (-not $enc) { $enc = "$($Prof.VideoEncoder)".ToUpper() }
        $parts = @($enc)
        if ($Prof.VideoProfile) {
            $pm = $profMap["$($Prof.VideoProfile)"]; if (-not $pm) { $pm = "$($Prof.VideoProfile)" }
            $parts += $pm
        }
        if ($Prof.VideoLevel) { $parts += ('L{0}' -f $Prof.VideoLevel) }
        # Control de tasa: CRF (CPU) / Q(min-max) (NVENC) / Q(AUTO) (NVENC sin qmin ni qmax).
        $isCpu = ($Prof.VideoEncoder -in (Get-CvCpuEncoders))
        if ($null -ne $Prof.Crf) { $parts += ('CRF{0}' -f $Prof.Crf) }
        elseif (($null -ne $Prof.Qmin) -or ($null -ne $Prof.Qmax)) { $parts += ('Q({0}-{1})' -f $Prof.Qmin, $Prof.Qmax) }
        elseif (-not $isCpu) { $parts += 'Q(AUTO)' }
        if ("$($Prof.Multipass)" -in (Get-CvMultipass2Pass)) { $parts += ('2PASS:{0}' -f $Prof.Multipass) }
        if ("$($Prof.DetectBorder)".ToLower() -eq 'auto') { $parts += (Get-CvText -Key 'lbl.autoborde') }
        elseif ([bool]$Prof.DetectBorder)                 { $parts += (Get-CvText -Key 'lbl.detectborde') }
        if ($Prof.ChangeSize)   { $parts += ('RESIZE{0} {1}' -f $(if ([bool]$Prof.NoUpscale) { '<=' } else { '' }), $Prof.ChangeSize) }
        if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { $parts += ('RESIZE<={0}w' -f [int]$Prof.MaxWidth) }
        $v = ($parts -join '/')
    }
    if ($Prof.AudioEncoder -eq 'copy') {
        $a = 'COPY'
    } else {
        # Codec solo si no es el AAC por defecto (AAC 192K queda como '192K'; AC3/EAC3/... se muestran).
        # El nombre corto sale del catalogo Get-CvAudioCodecs (columna Short), fuente unica.
        $codec = "$($Prof.AudioCodec)"; if (-not $codec) { $codec = 'aac' }
        $ac = ''
        if ($codec -ne 'aac') {
            $e = @(Get-CvAudioCodecs | Where-Object { $_.Value -eq $codec })[0]
            $short = if ($e -and $e.Short) { "$($e.Short)" } else { "$codec".ToUpper() }
            $ac = "$short "
        }
        $a = '{0}{1}' -f $ac, "$($Prof.AudioBitrate)".ToUpper()
    }
    # Overrides de salida de audio del perfil: canales (si != estereo) y downmix con voz reforzada.
    if ($null -ne $Prof.AudioChannels -and [int]$Prof.AudioChannels -ge 1 -and [int]$Prof.AudioChannels -ne 2) { $a += (' {0}CH' -f [int]$Prof.AudioChannels) }
    if ("$($Prof.DownmixMode)".ToLower() -eq 'dialogue') { $a += ' DLG' }
    ('A: {0}, V: {1}' -f $a, $v)
}

function New-CustomProfile {
    <#
        Construye un perfil de forma interactiva. En CUALQUIER pregunta, escribir 'C' o
        pulsar ESC cancela y vuelve al menu de perfiles. Al final permite [R]ehacer.
        Devuelve el perfil, o $null si se cancela.

        -Seed: partir de un perfil EXISTENTE (editar o duplicar uno propio) en vez de las semillas
        de config ('customProfile'); cada pregunta llega con su valor ya puesto.
        -NoSaveOffer: no preguntar si se guarda en el config. Lo usa quien ya va a guardarlo por su
        cuenta (el menu de perfiles propios de setup), para no preguntar dos veces lo mismo.
    #>
    param(
        $Context = $null,
        $Seed = $null,
        [switch]$NoSaveOffer
    )
    # Valores por defecto: del contexto (config 'customProfile'); si no hay contexto, de los defaults
    # de config (Get-CvConfigDefaults, fuente unica) en vez de literales hardcodeados aqui.
    $dflt = Get-CvConfigDefaults; $cp = $dflt.customProfile
    $defEnc  = if ($Context -and "$($Context.CustomVideoEncoder)" -ne '') { "$($Context.CustomVideoEncoder)" } else { "$($cp.videoEncoder)" }
    $defProf = if ($Context -and "$($Context.CustomVideoProfile)" -ne '') { "$($Context.CustomVideoProfile)" } else { "$($cp.videoProfile)" }
    $defLvl  = if ($Context -and "$($Context.CustomVideoLevel)"   -ne '') { "$($Context.CustomVideoLevel)"   } else { "$($cp.videoLevel)" }
    # Si hay contexto se usa su valor TAL CUAL (puede ser $null = "auto"); sin contexto, el default de config.
    $defQmin = if ($Context) { $Context.CustomQmin } else { [int]$cp.qmin }
    $defQmax = if ($Context) { $Context.CustomQmax } else { [int]$cp.qmax }
    $defCrf  = if ($Context) { $Context.CustomCrf }  else { [int]$cp.crf }
    $defMp    = if ($Context -and "$($Context.CustomMultipass)" -ne '') { "$($Context.CustomMultipass)" } else { "$($cp.multipass)" }
    $defAb    = if ($Context -and "$($Context.CustomAudioBitrate)" -ne '') { "$($Context.CustomAudioBitrate)" } else { "$($cp.audioBitrate)" }
    $defCodec = if ($Context -and "$($Context.CustomAudioCodec)" -ne '') { "$($Context.CustomAudioCodec)" } else { "$($cp.audioCodec)" }
    # Semillas restantes (paridad con profiles[]): bordes, reescalado, audioEncoder/Hz/canales y downmix.
    $defDetect = if ($Context) { $Context.CustomDetectBorder } else { $(if ("$($cp.detectBorder)".ToLower() -eq 'auto') { 'auto' } else { [bool]$cp.detectBorder }) }
    $defChange = if ($Context) { "$($Context.CustomChangeSize)" } else { "$($cp.changeSize)" }
    $defNoUp   = if ($Context) { [bool]$Context.CustomNoUpscale } else { [bool]$cp.noUpscale }
    $defMaxW   = if ($Context) { [int]$Context.CustomMaxWidth } else { [int]$cp.maxWidth }
    $defAEnc   = if ($Context -and "$($Context.CustomAudioEncoder)" -ne '') { "$($Context.CustomAudioEncoder)" } else { "$($cp.audioEncoder)" }
    $defHz     = if ($Context -and [int]$Context.CustomAudioHz -ge 1) { [int]$Context.CustomAudioHz } else { [int]$cp.audioHz }
    $defCh     = if ($Context -and [int]$Context.CustomAudioChannels -ge 1) { [int]$Context.CustomAudioChannels } else { [int]$cp.audioChannels }
    $defDm     = if ($Context -and "$($Context.CustomDownmixMode)" -ne '') { "$($Context.CustomDownmixMode)" } else { "$($cp.downmixMode)" }
    $defCoeffs = if ($Context -and $Context.CustomDownmixCoeffs) { $Context.CustomDownmixCoeffs } else { @{ Center = [double]$cp.downmixCoeffs.center; Front = [double]$cp.downmixCoeffs.front; Surround = [double]$cp.downmixCoeffs.surround } }

    # EDITAR / DUPLICAR uno que ya existe: las semillas salen del perfil, no del config, para que
    # cada pregunta llegue con lo que ese perfil tiene y solo haya que tocar lo que se quiere cambiar.
    if ($null -ne $Seed) {
        $defEnc    = "$($Seed.VideoEncoder)"
        $defProf   = "$($Seed.VideoProfile)"
        $defLvl    = "$($Seed.VideoLevel)"
        $defQmin   = $Seed.Qmin
        $defQmax   = $Seed.Qmax
        $defCrf    = $Seed.Crf
        $defMp     = "$($Seed.Multipass)"
        $defAb     = "$($Seed.AudioBitrate)"
        $defCodec  = "$($Seed.AudioCodec)"
        $defDetect = $Seed.DetectBorder
        $defChange = "$($Seed.ChangeSize)"
        $defNoUp   = [bool]$Seed.NoUpscale
        $defMaxW   = $(if ($null -ne $Seed.MaxWidth) { [int]$Seed.MaxWidth } else { 0 })
        $defAEnc   = "$($Seed.AudioEncoder)"
        $defHz     = $(if ([int]$Seed.AudioHz -ge 1) { [int]$Seed.AudioHz } else { $defHz })
        $defCh     = $(if ($null -ne $Seed.AudioChannels -and [int]$Seed.AudioChannels -ge 1) { [int]$Seed.AudioChannels } else { $defCh })
        $defDm     = $(if ("$($Seed.DownmixMode)" -ne '') { "$($Seed.DownmixMode)" } else { $defDm })
        if ($null -ne $Seed.DownmixCoeffs) { $defCoeffs = $Seed.DownmixCoeffs }
    }

    while ($true) {
        try {
            # Encoder: menu generico (Select-FromList) sin opcion "0" (-NoNone). El default es el
            # encoder configurado; si no esta en la lista (config erronea), cae a hevc_nvenc y, si
            # ni eso, a la 1a opcion.
            $encList = @(Get-CvVideoEncoders)
            # Marcar '[NO SOPORTADO]' (Show-Menu lo pinta en amarillo) los encoders por GPU que ESTA
            # GPU no admite (sondeo cacheado): asi se ve en el propio menu, antes de seleccionar.
            $encList = @($encList | ForEach-Object {
                $t = "$($_.Text)"
                if (-not (Test-CvEncoderSupported -Context $Context -Encoder "$($_.Value)")) { $t = ("{0} {1}" -f $t, (Get-CvText -Key 'con.nosoportado')) }
                @{
                    Value = "$($_.Value)"
                    Text  = $t
                }
            })
            # 'auto' (solo builder/config, no es un encoder real de ffmpeg): mejor encoder del equipo,
            # se resuelve al PREPARAR (Resolve-CvProfileAuto). Se ofrece SIEMPRE (no depende de la GPU).
            $encList = @(@{ Value = 'auto'; Text = (Get-CvText -Key 'cp.autoenc') }) + $encList
            $encVals = @($encList | ForEach-Object { "$($_.Value)" })
            $encDefIdx = 1 + [array]::IndexOf($encVals, "$defEnc")
            if ($encDefIdx -le 0) { $encDefIdx = 1 + [array]::IndexOf($encVals, 'hevc_nvenc') }
            if ($encDefIdx -le 0) { $encDefIdx = 1 }
            $enc = Select-FromList -Title (Get-CvText -Key 'cp.encoder') -Options $encList -NoNone -DefaultIndex $encDefIdx 
                -CancelLabel (Get-CvText -Key 'cp.cancelar') -AllowCancel

            # Encoder por GPU no soportado por ESTA GPU (p. ej. av1_nvenc en GPUs anteriores a RTX 40):
            # se avisa y se vuelve al menu del encoder en vez de dejar que ffmpeg falle al codificar.
            if (-not (Test-CvEncoderSupported -Context $Context -Encoder "$enc")) {
                Write-CvOptionUnsupported -Option "$enc" -Reason (Get-CvText -Key 'cp.gpu.no') -Hint (Get-CvText -Key 'cp.gpu.otro')
                continue
            }

            $p = New-CvProfile -VideoEncoder $enc

            if ($enc -ne 'copy') {
                # Deteccion de bordes: No / Si (interactivo) / Auto (pre-escaneo decide). Semilla: $defDetect.
                $dbDef = if ("$defDetect" -eq 'auto') { 'auto' } elseif ([bool]$defDetect) { '1' } else { '0' }
                $dbSel = Select-FromList -Title (Get-CvText -Key 'cp.bordes') -Options @(
                    @{ Value = '0';    Text = 'No' }
                    @{ Value = '1';    Text = 'Si (interactivo, con preview)' }
                    @{ Value = 'auto'; Text = (Get-CvText -Key 'cat.border.auto') }
                ) -NoNone -DefaultValue $dbDef -AllowCancel
                $p.DetectBorder = switch ("$dbSel") { '1' { $true } 'auto' { 'auto' } default { $false } }

                # Reescalado: No / Maximo ancho (reduce solo si es mayor) / Escalar siempre. Semilla: maxWidth/changeSize.
                $rzDef = if ($defMaxW -gt 0) { 'max' } elseif ("$defChange" -ne '') { 'scale' } else { 'no' }
                $rzSel = Select-FromList -Title (Get-CvText -Key 'cp.resize') -Options @(
                    @{ Value = 'no';    Text = 'No cambiar el tamano' }
                    @{ Value = 'max';   Text = (Get-CvText -Key 'cp.resize.max') }
                    @{ Value = 'scale'; Text = (Get-CvText -Key 'cp.resize.fijo') }
                ) -NoNone -DefaultValue $rzDef -AllowCancel
                if ($rzSel -eq 'max') {
                    $mwDef = if ($defMaxW -gt 0) { "$defMaxW" } else { '1920' }
                    $mw = (Read-CvLine -Prompt (Get-CvText -Key 'cp.ancho.q' -Values @($mwDef)) -AllowCancel).Trim()
                    if ($mw -match '^[Cc]$') { throw 'CV_CANCEL' }
                    if ($mw -eq '') { $mw = $mwDef }
                    if ($mw -match '^\d+$') { $p.MaxWidth = [int]$mw }
                }
                elseif ($rzSel -eq 'scale') {
                    $sizeLines = @(Get-CvVideoSizes | ForEach-Object { '{0,-24}- {1}' -f $_.Text, $_.Value })
                    Show-Menu -Title (Get-CvText -Key 'cp.tamanos') -Lines ($sizeLines + @(
                        '',
                        (Get-CvText -Key 'cp.altura'),
                        '',
                        (Get-CvText -Key 'con.cancelar')
                    ))
                    $szDef = if ("$defChange" -ne '') { "$defChange" } else { '1920:-2' }
                    $sz = (Read-CvLine -Prompt (Get-CvText -Key 'cp.tamano.q' -Values @($szDef)) -AllowCancel).Trim()
                    if ($sz -match '^[Cc]$') { throw 'CV_CANCEL' }
                    if ($sz -eq '') { $sz = $szDef }
                    if ($sz -ne '') {
                        # Si solo dan el ancho, se completa con ':-2' (no ':-1'): -2 mantiene el aspecto
                        # y ademas fuerza altura PAR, requisito de 4:2:0 (con -1 podria salir impar y
                        # fallar la codificacion en CPU: libx264/libx265).
                        if ($sz -notmatch ':') { $sz = "$sz`:-2" }
                        $p.ChangeSize = $sz
                        # Solo reducir: si el video es MAS pequeño que el destino, no ampliarlo (dejarlo tal cual).
                        $nuSel = Select-FromList -Title (Get-CvText -Key 'cp.soloreducir') -Options @(
                            @{ Value = '1'; Text = 'Si (solo reduce; un 720p no sube a 1080p)' }
                            @{ Value = '0'; Text = 'No (escala siempre al destino, tambien amplia)' }
                        ) -NoNone -DefaultValue $(if ($defNoUp) { '1' } else { '0' }) -AllowCancel
                        $p.NoUpscale = ("$nuSel" -eq '1')
                    }
                }

                # Perfil/level/control de tasa: SOLO con encoder concreto. Con 'auto' se saltan (los fija
                # Resolve-CvProfileAuto al preparar segun el encoder que resuelva para este equipo).
                if ($enc -ne 'auto') {
                    # Perfil y level validos segun el codec (catalogo @{Value;Text} en Get-CvCodecOptions).
                    $co       = Get-CvCodecOptions -Encoder $enc
                    $profOpts = @($co.Profiles)
                    $lvlOpts  = @($co.Levels)
                    # Indice 1-based del valor por defecto. Perfil y level son OBLIGATORIOS (-NoNone): si
                    # el default de config no aplica al codec, caen a la 1a opcion (nunca a "ninguno").
                    $profDefIdx = 1 + [array]::IndexOf(@($profOpts | ForEach-Object { "$($_.Value)" }), "$defProf")
                    if ($profDefIdx -le 0) { $profDefIdx = 1 }
                    $lvlDefIdx  = 1 + [array]::IndexOf(@($lvlOpts  | ForEach-Object { "$($_.Value)" }), "$defLvl")
                    if ($lvlDefIdx -le 0) { $lvlDefIdx = 1 }
                    $p.VideoProfile = Select-FromList -Title (Get-CvText -Key 'cp.perfilcodec') -Options $profOpts -NoNone -DefaultIndex $profDefIdx -AllowCancel
                    # AV1 no usa level: si el codec no ofrece niveles, se salta el menu.
                    if ($lvlOpts.Count -gt 0) { $p.VideoLevel = Select-FromList -Title (Get-CvText -Key 'cp.level') -Options $lvlOpts -NoNone -DefaultIndex $lvlDefIdx -AllowCancel }
                    else { $p.VideoLevel = '' }

                    # Control de tasa: CRF (CPU: libx264/libx265/libsvtav1) o qmin/qmax (NVENC). Defaults de config.
                    if ($enc -in (Get-CvCpuEncoders)) {
                        $p.Crf = Read-QOrNull (Get-CvText -Key 'cp.crf.q') $defCrf -Max 51 -AllowCancel
                    } else {
                        $p.Qmin = Read-QOrNull (Get-CvText -Key 'cp.qmin.q') $defQmin -Max 51 -AllowCancel
                        $p.Qmax = Read-QOrNull (Get-CvText -Key 'cp.qmax.q') $defQmax -Max 51 -AllowCancel
                        # 2-pass NVENC (multipass): catalogo @{Value;Text;Position} ('off'=opcion 0). Default por valor.
                        $p.Multipass = Select-FromList -Title (Get-CvText -Key 'cp.multipass') 
                            -Options (Get-CvNvencMultipass) -DefaultValue "$defMp" -AllowCancel
                    }
                }
            }

            # AUDIO: 1) SALIDA = copy (no recodificar) o codec (Get-CvAudioCodecs); al recodificar,
            # 2) bitrate (Get-CvAudioBitrates -Codec; FLAC/copy lo saltan), 3) frecuencia, 4) canales y
            # 5) downmix. Todo con semilla de customProfile (audioEncoder/Bitrate/Codec/Hz/Channels/Downmix*).
            $defOut = if ("$defAEnc" -eq 'copy') { 'copy' } else { "$defCodec" }
            $out = Select-FromList -Title (Get-CvText -Key 'cp.audio') -Options (Get-CvAudioCodecs) -NoNone -DefaultValue "$defOut" -AllowCancel
            if ($out -eq 'copy') {
                $p.AudioEncoder = 'copy'; $p.AudioCodec = 'aac'; $p.AudioBitrate = ''
            } else {
                $p.AudioEncoder = 'aac_coder'; $p.AudioCodec = $out
                if ($out -eq 'flac') {
                    $p.AudioBitrate = ''    # sin perdida: el bitrate no aplica
                } else {
                    while ($true) {
                        $ab = Select-FromList -Title (Get-CvText -Key 'cp.bitrate') -Options (Get-CvAudioBitrates -Codec $out) -NoNone -DefaultValue "$defAb" -AllowCancel
                        if ($ab -eq 'custom') {
                            $cb = (Read-CvLine -Prompt (Get-CvText -Key 'cp.bitrate.q') -AllowCancel).Trim()
                            if ($cb -match '^[Cc]$') { throw 'CV_CANCEL' }
                            if ($cb -ne '') { $p.AudioBitrate = $cb; break }
                            continue   # vacio -> volver a mostrar el menu
                        }
                        $p.AudioBitrate = $ab; break
                    }
                }
                # Frecuencia de salida (Hz). Semilla: customProfile.audioHz. (Opus se fuerza a 48000 al codificar.)
                $hzIn = (Read-CvLine -Prompt (Get-CvText -Key 'cp.hz.q' -Values @($defHz)) -AllowCancel).Trim()
                if ($hzIn -match '^[Cc]$') { throw 'CV_CANCEL' }
                $p.AudioHz = if ($hzIn -match '^\d+$') { [int]$hzIn } else { [int]$defHz }
                # Canales de salida (MAXIMO, no upmix). Semilla: customProfile.audioChannels.
                $chSel = Select-FromList -Title (Get-CvText -Key 'cp.canales') -Options (Get-CvAudioChannels) -NoNone -DefaultValue "$defCh" -AllowCancel
                $p.AudioChannels = [int]$chSel
                # Downmix SOLO si la salida es estereo (2): solo entonces se baja 5.1 -> estereo. Semilla: customProfile.downmixMode.
                if ([int]$chSel -eq 2) {
                    $p.DownmixMode = Select-FromList -Title (Get-CvText -Key 'cp.downmix') -Options (Get-CvDownmixModes) -NoNone -DefaultValue "$defDm" -AllowCancel
                    # Coeficientes del downmix 'dialogue' (voz reforzada). Semilla: customProfile.downmixCoeffs;
                    # se pueden personalizar (si no, se conserva la semilla).
                    if ("$($p.DownmixMode)" -eq 'dialogue') {
                        $p.DownmixCoeffs = @{ Center = $defCoeffs.Center; Front = $defCoeffs.Front; Surround = $defCoeffs.Surround }
                        if (Read-YesNo (Get-CvText -Key 'cp.coefs.q' -Values @($defCoeffs.Center, $defCoeffs.Front, $defCoeffs.Surround)) $false -AllowCancel) {
                            $toNum = { param($s, $d) if ("$s" -match '^\d+([.,]\d+)?$') { [double]("$s" -replace ',', '.') } else { [double]$d } }
                            $cC = (Read-CvLine -Prompt (Get-CvText -Key 'cp.coef.c' -Values @($defCoeffs.Center)) -AllowCancel).Trim()
                            if ($cC -match '^[Cc]$') { throw 'CV_CANCEL' }
                            $cF = (Read-CvLine -Prompt (Get-CvText -Key 'cp.coef.f' -Values @($defCoeffs.Front)) -AllowCancel).Trim()
                            if ($cF -match '^[Cc]$') { throw 'CV_CANCEL' }
                            $cS = (Read-CvLine -Prompt (Get-CvText -Key 'cp.coef.s' -Values @($defCoeffs.Surround)) -AllowCancel).Trim()
                            if ($cS -match '^[Cc]$') { throw 'CV_CANCEL' }
                            $p.DownmixCoeffs = @{
                                Center   = (& $toNum $cC $defCoeffs.Center)
                                Front    = (& $toNum $cF $defCoeffs.Front)
                                Surround = (& $toNum $cS $defCoeffs.Surround)
                            }
                        }
                    }
                }
            }

            # Resumen y confirmacion.
            Write-ProfileInfo -Prof $p
            $conf = (Read-CvLine -Prompt (Get-CvText -Key 'cp.fin') -AllowCancel).Trim()
            if ($conf -match '^[Rr]$') { continue }
            # Guardarlo para REUTILIZARLO: hasta ahora un perfil hecho aqui moria con el job y habia
            # que reescribirlo a mano en config.json. Se ofrece con el default en NO, asi que quien
            # siempre ha pulsado ENTER no nota el cambio.
            if (-not $NoSaveOffer -and $Context -and "$($Context.ConfigPath)" -ne '') {
                try {
                    if (Read-YesNo (Get-CvText -Key 'cp.guardar.q') $false) {
                        [void](Save-CvProfileInteractive -Prof $p -Path "$($Context.ConfigPath)")
                    }
                } catch {
                    if ("$($_.Exception.Message)" -ne 'CV_CANCEL') { throw }   # ESC aqui = no guardar
                }
            }
            return $p
        }
        catch {
            if ("$($_.Exception.Message)" -eq 'CV_CANCEL') { return $null }
            throw
        }
    }
}

function Select-Profile {
    <#
        Muestra el menu y devuelve el perfil elegido, o $null si el usuario elige salir (X).
        -Extra: perfiles PROPIOS de config.json (seccion 'profiles'); se ANADEN despues de los de
        serie (numeracion continua, 12, 13, ...) sin sustituirlos.
    #>
    param([object[]]$Extra = @(), $Context = $null)
    # Perfiles de serie por GRUPOS; se numeran automaticamente 1..N (continuo entre grupos) y el
    # texto del menu se GENERA de sus valores (Format-CvProfileLabel). Entre grupos, linea en blanco.
    # Se recogen primero las opciones numeradas (numero + etiqueta) y las rupturas de grupo (linea
    # en blanco); el numero se formatea DESPUES, alineado a la derecha al ancho del mayor indice
    # mostrado (Get-CvMenuNumWidth), para que TODAS las etiquetas queden en columna con indices de 1
    # y 2+ cifras (' 1.' … '11.'). Las opciones '0' (Custom) y 'X' (Salir) se alinean igual.
    $groups   = @(Get-CvProfiles)
    $profiles = [ordered]@{}
    $baseItems = @()   # cada uno: @{ Break = $true } (separador) o @{ Num; Label }
    $n = 0
    for ($g = 0; $g -lt $groups.Count; $g++) {
        if ($g -gt 0) { $baseItems += @{ Break = $true } }       # separador entre grupos
        foreach ($pr in @($groups[$g].Profiles)) {
            $n++
            $profiles["$n"] = $pr
            $baseItems += @{ Num = $n; Label = (Format-CvProfileLabel -Prof $pr) }
        }
    }
    # Perfiles propios de config.json: CONTINUAN la numeracion (N+1, N+2, ...); etiqueta = 'label' o resumen.
    $extraItems = @()
    $base = $n
    for ($i = 0; $i -lt @($Extra).Count; $i++) {
        $obj = @($Extra)[$i]
        if ($null -eq $obj) { continue }
        $num = $base + $i + 1
        $p   = ConvertTo-CvProfile -Obj $obj
        $profiles["$num"] = $p
        $lbl = "$(Get-CvProfileProp $obj 'label' '')"
        if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = Format-CvProfileLabel -Prof $p }
        $extraItems += @{ Num = $num; Label = $lbl }
    }
    # Ancho comun: el mayor indice que se mostrara (incluye los perfiles de config.json).
    $maxNum = 0
    foreach ($k in $profiles.Keys) { if ([int]$k -gt $maxNum) { $maxNum = [int]$k } }
    $numW   = Get-CvMenuNumWidth $maxNum
    $numFmt = { param($num, $label) '{0}. {1}' -f (("$num").PadLeft($numW)), $label }

    # Perfil PREDETERMINADO (config 'defaultProfile'): sale con un '*' delante y es lo que se usa al
    # pulsar ENTER sin escribir nada, que es el gesto de quien no va a cambiar de perfil.
    $defKey = Get-CvDefaultProfileKey -Default $(if ($null -ne $Context) { "$($Context.DefaultProfile)" } else { '' }) -Extra $Extra
    $marca  = { param($num) $(if ("$num" -eq "$defKey") { '* ' } else { '  ' }) }
    $baseLines = @()
    foreach ($it in $baseItems) { $baseLines += $(if ($it.Break) { '' } else { (& $marca $it.Num) + (& $numFmt $it.Num $it.Label) }) }
    $extraLines = @()
    foreach ($it in $extraItems) { $extraLines += ((& $marca $it.Num) + (& $numFmt $it.Num $it.Label)) }

    $menuLines = @($baseLines)
    if ($extraLines.Count) { $menuLines += @('', (Get-CvText -Key 'cp.deconfig')) + $extraLines }
    # OJO con los parentesis: dentro de un @(...) la COMA ata mas que el '+', asi que
    # `'', '  ' + $texto` no es una linea con sangria, son DOS elementos ('' y '  ') mas el texto
    # suelto. Cada concatenacion va entera entre parentesis.
    $menuLines += @(
        '',
        ('  ' + (Get-CvText -Key 'cp.op.custom' -Values @(('0'.PadLeft($numW))))),
        ((& $marca 'A') + (Get-CvText -Key 'cp.op.auto' -Values @(('A'.PadLeft($numW))))),
        '',
        ('  ' + (Get-CvText -Key 'cp.op.salir' -Values @(('X'.PadLeft($numW))))),
        '',
        (Get-CvText -Key 'cp.marcado')
    )

    $show = $true
    while ($true) {
        if ($show) {
            Show-Menu -Title (Get-CvText -Key 'cp.usarperfil') -Lines $menuLines
            $show = $false
        }
        $sel = (Read-Host (Get-CvText -Key 'cp.opcion.q')).Trim()
        if ($sel -eq '') { $sel = "$defKey" }                      # ENTER = el predeterminado
        if ($sel -match '^[Xx]$') { return $null }                 # salir
        if ($sel -eq '0') {
            $custom = New-CustomProfile -Context $Context
            if ($null -ne $custom) { return $custom }
            Clear-Host                                             # custom cancelado -> limpiar y re-mostrar
            $show = $true
            continue
        }
        if ($sel -match '^[Aa]$') {
            # Auto: resuelve el mejor encoder soportado por este equipo (GPU o CPU) y lo anuncia.
            $auto = New-CvAutoProfile -Context $Context
            $via  = if ("$($auto.VideoEncoder)" -in (Get-CvCpuEncoders)) { 'CPU' } else { 'GPU' }
            Write-CvLog 'GLOBAL' ("[INFO] - Perfil Auto: se usara '{0}' ({1})." -f $auto.VideoEncoder, $via)
            return $auto
        }
        if ($profiles.Contains($sel)) {
            $chosen = $profiles[$sel]
            # Perfil (de serie o de config.json) con encoder por GPU que ESTA GPU no soporta: se
            # avisa y se vuelve al menu, en vez de dejar que ffmpeg falle luego al codificar.
            if (-not (Test-CvEncoderSupported -Context $Context -Encoder "$($chosen.VideoEncoder)")) {
                Write-CvOptionUnsupported -Option "$($chosen.VideoEncoder)" -Reason (Get-CvText -Key 'cp.gpu.usa') -Hint 'Elige otro perfil (para AV1, uno con libsvtav1 por CPU).'
                continue
            }
            return $chosen
        }
        Write-Host (Get-CvText -Key 'con.opcion.mala3') -ForegroundColor Yellow
    }
}

function Write-ProfileInfo {
    param([Parameter(Mandatory)]$Prof)
    Write-Host ''
    Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.encoder' -Values @($Prof.VideoEncoder.ToUpper()))
    if ($Prof.VideoEncoder -ne 'copy') {
        if ($Prof.VideoProfile) { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.profile' -Values @($Prof.VideoProfile)) }
        if ($Prof.VideoLevel)   { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.level' -Values @($Prof.VideoLevel)) }
        if ($null -ne $Prof.Qmin) { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.qmin' -Values @($Prof.Qmin)) }
        if ($null -ne $Prof.Qmax) { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.qmax' -Values @($Prof.Qmax)) }
        if ($null -ne $Prof.Crf)  { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.crf' -Values @($Prof.Crf)) }
        $dbTxt = if ("$($Prof.DetectBorder)".ToLower() -eq 'auto') { 'auto' } elseif ([bool]$Prof.DetectBorder) { 'si' } else { 'no' }
        Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.borde' -Values @($dbTxt))
        if ($Prof.ChangeSize) { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.resize' -Values @($Prof.ChangeSize)) }
        if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.resize2' -Values @([int]$Prof.MaxWidth)) }
    }
    if ($Prof.AudioEncoder -eq 'copy') {
        Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.acopy')
    } else {
        $codec = "$($Prof.AudioCodec)"; if (-not $codec) { $codec = 'aac' }
        Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.acodec' -Values @($codec, $Prof.AudioBitrate))
        # Overrides de salida del perfil (si no, se usa el global encode.*).
        if ($null -ne $Prof.AudioChannels -and [int]$Prof.AudioChannels -ge 1) {
            Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.ach' -Values @([int]$Prof.AudioChannels))
        }
        if ($Prof.DownmixMode) {
            Write-CvLog 'GLOBAL' (Get-CvText -Key 'pr.inf.admx' -Values @("$($Prof.DownmixMode)".ToLower()))
        }
    }
    Write-Host ''
}

Export-ModuleMember -Function *
