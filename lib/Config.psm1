<#
    Config.psm1 - Valores por defecto de config.json, carga y fusion.
    Get-CvConfigDefaults es la FUENTE UNICA de los defaults; Get-CvConfig los fusiona
    (fusion profunda) con el config.json del usuario. Sin dependencias de otros modulos.
#>

function Merge-CvConfig {
    <#
        Fusiona (en sitio) $Override (objeto de JSON) sobre $Default (ordered hashtable),
        recorriendo secciones anidadas. Los escalares y arrays se reemplazan; las
        subsecciones (objetos) se fusionan recursivamente para no perder claves ausentes.
    #>
    param($Default, $Override)
    if ($null -eq $Override) { return }
    # Sobreescribir/fusionar las claves existentes.
    foreach ($key in @($Default.Keys)) {
        if ($Override.PSObject.Properties[$key] -and $null -ne $Override.$key) {
            $dv = $Default[$key]
            $ov = $Override.$key
            if ($dv -is [System.Collections.IDictionary] -and $ov -is [System.Management.Automation.PSCustomObject]) {
                Merge-CvConfig -Default $dv -Override $ov
            } else {
                $Default[$key] = $ov
            }
        }
    }
    # Anadir claves nuevas que solo estan en el override (ej: versiones de ffmpeg extra).
    foreach ($prop in $Override.PSObject.Properties) {
        if (-not $Default.Contains($prop.Name) -and $null -ne $prop.Value) {
            $Default[$prop.Name] = $prop.Value
        }
    }
}

function Get-CvVolumeMethods {
    <#
        FUENTE UNICA de los metodos de normalizacion de volumen validos (el 1o es el DEFAULT/fallback).
        Forma @{ Value; Text } como el resto de catalogos: el Text lo muestra el editor de setup.
        'peak' se mantiene por compatibilidad (LEGACY): iguala el PICO, no el volumen percibido, asi
        que entre archivos distintos el volumen sigue sonando desigual; 'loudnorm' (EBU R128) es el
        recomendado y el default desde v4.5.5.
    #>
    @(
        @{
            Value = 'loudnorm'
            Text  = 'Sonoridad EBU R128 (I/TP/LRA): mismo volumen percibido entre archivos (recomendado)'
        }
        @{
            Value = 'peak'
            Text  = 'LEGACY: amplifica hasta el pico objetivo (peakTarget); rapido, pero no iguala el volumen percibido'
        }
        @{
            Value = 'aacgain'
            Text  = 'ReplayGain sobre el .m4a ya codificado (sin recodificar); solo AAC y solo por etapas'
        }
    )
}

function Get-CvVolumeMethodValues {
    <# Solo los VALORES de Get-CvVolumeMethods (para validar y para los textos de ayuda). #>
    @(Get-CvVolumeMethods | ForEach-Object { $_.Value })
}

function Get-CvTonemapCurves {
    <#
        FUENTE UNICA de las curvas de tone-mapping de libplacebo mas comunes (la 1a = por defecto).
        La ofrece el editor de setup como menu para encode.video.tonemapCurve; NO es una lista cerrada:
        libplacebo admite mas (y varian por version), asi que el editor deja escribir otra ('custom').
    #>
    @(
        'bt.2390'
        'bt.2446a'
        'spline'
        'reinhard'
        'mobius'
        'hable'
        'gamma'
        'linear'
        'clip'
    )
}

# --- Catálogos de dominio de config (fuente única de los valores válidos de cada opción "enum").
# Los consumen la validación del contexto (Resolve-CvOneOf en New-CvContext) y el editor de setup
# (Get-CvEditorOptions), para no repetir literales. Forma común @{ Value; Text } como los demás catálogos.
function Get-CvOutputContainers {
    <# Contenedores de salida válidos (encode.outputExtension). #>
    @(
        @{ Value = 'mkv'; Text = 'Matroska (recomendado)' }
        @{ Value = 'mp4'; Text = 'MP4 (+faststart)' }
        @{ Value = 'mov'; Text = 'QuickTime (+faststart)' }
    )
}

function Get-CvTonemapHdrModes {
    <# Modos de tone-mapping HDR->SDR (encode.video.tonemapHdr). El 1o es el default de fábrica. #>
    @(
        @{ Value = 'auto'; Text = 'HDR->SDR solo si el origen es HDR' }
        @{ Value = 'off';  Text = 'no aplicar tone-mapping' }
    )
}

function Get-CvAnamorphicModes {
    <# Tratamiento del vídeo anamórfico SAR!=1 (encode.video.anamorphic). El 1o = default de fábrica. #>
    @(
        @{ Value = 'square';       Text = 'cuadrar por ancho (píxeles cuadrados)' }
        @{ Value = 'squareheight'; Text = 'cuadrar por alto' }
        @{ Value = 'keep';         Text = 'conservar el SAR/DAR' }
    )
}

function Get-CvQualityCheckModes {
    <# Métricas de control de calidad de la salida vs origen (encode.video.qualityCheck). #>
    @(
        @{ Value = 'off';  Text = 'no medir' }
        @{ Value = 'ssim'; Text = 'SSIM (estructural, rápido)' }
        @{ Value = 'vmaf'; Text = 'VMAF (perceptual, requiere libvmaf; lento)' }
    )
}

function Get-CvMaxCodecOptions {
    <# Tope de códec del perfil Auto (encode.video.auto.maxCodec); '' = sin tope. #>
    @(
        @{ Value = '';     Text = 'sin tope' }
        @{ Value = 'h264'; Text = 'no subir de H.264' }
        @{ Value = 'h265'; Text = 'no subir de H.265' }
        @{ Value = 'av1';  Text = 'permitir hasta AV1' }
    )
}

function Get-CvSubtitleEditorModes {
    <# Como abrir el texto de un subtitulo con 'V N' (preview.subtitleEditor). El 1o = default de fábrica. #>
    @(
        @{ Value = 'start';    Text = 'programa asociado de Windows (fallback a Notepad)' }
        @{ Value = 'win';      Text = 'ventana propia (WinForms + RichTextBox)' }
        @{ Value = 'external'; Text = 'el .exe definido en subtitleEditorExe' }
    )
}

function Get-CvGuiThemes {
    <# Aspecto de las ventanas (gui.theme). El 1o = default de fabrica. #>
    @(
        @{ Value = 'system'; Text = 'el de Windows (si lo pones oscuro, las ventanas tambien)' }
        @{ Value = 'light';  Text = 'claro siempre' }
        @{ Value = 'dark';   Text = 'oscuro siempre' }
    )
}

function Get-CvPlayerModes {
    <# Con que se reproduce un video entero desde la cola (preview.player). El 1o = default. #>
    @(
        @{ Value = 'start';    Text = 'reproductor asociado de Windows (si no hay, ffplay)' }
        @{ Value = 'ffplay';   Text = 'el ffplay de tools (siempre esta, no depende del equipo)' }
        @{ Value = 'external'; Text = 'el reproductor de playerExe (VLC, MPC-HC...)' }
    )
}

function Get-CvNvencTiers {
    <# Tier de hevc_nvenc (encode.video.tuning.tier). #>
    @(
        @{ Value = 'main'; Text = 'main' }
        @{ Value = 'high'; Text = 'high' }
    )
}

function Resolve-CvOneOf {
    <#
        Valida una opcion enum: devuelve $Value en minusculas si esta en $Valid (comparacion sin
        distinguir mayusculas); si no, $Default. Se usa para las opciones de config con conjunto
        cerrado de valores (p. ej. multipass, tonemapHdr, downmixMode), cayendo al default si el
        valor de config.json no es valido.
    #>
    param([string]$Value, [string[]]$Valid, [string]$Default)
    $v = "$Value".ToLower()
    foreach ($x in $Valid) { if ($v -eq "$x".ToLower()) { return $v } }
    return $Default
}

function Get-CvDefaultDownmixCoeffs {
    <#
        FUENTE UNICA de los coeficientes por defecto del downmix 'dialogue' (voz reforzada). La usan
        el default de config (encode.downmixCoeffs) y los fallbacks de Context/Profile cuando la
        config/perfil omite alguna subclave, para no repetir los numeros en varios sitios.
        center = canal central (dialogos), front = frontales, surround = surrounds (el LFE se descarta).
    #>
    [ordered]@{
        Center   = 0.5
        Front    = 0.35
        Surround = 0.15
    }
}

function Get-CvConfigDefaults {
    <# Valores por defecto de config.json (fuente unica: los usa Get-CvConfig y el reset). #>
    $langs = @(
        'spa'
        'es'
        'esp'
        'es-es'
        'es_es'
        'castellano'
        'spanish'
    )
    $dmc   = Get-CvDefaultDownmixCoeffs   # coeficientes por defecto del downmix dialogue (fuente unica)
    # NOTA: customProfile es la SEMILLA del builder custom; los campos con equivalente en encode.* NO
    # se re-declaran aqui: se DERIVAN mas abajo (fuente unica), justo antes de devolver el objeto:
    # videoEncoder/videoProfile/videoLevel de encode.video; qmin/qmax/crf de encode.video.auto; multipass
    # de encode.video; encoder/codec/bitrate/hz/channels/downmixMode/downmixCoeffs de encode.audio. El
    # resto (bordes/resize) es propio del builder y no tiene gemelo en encode.*.
    $cfg = [ordered]@{
        downloads = [ordered]@{
            ffmpeg = [ordered]@{
                selected     = '8.1.2'
                type         = 'zip'
                url          = 'https://github.com/GyanD/codexffmpeg/releases/download/{version}/ffmpeg-{version}-full_build.zip'
                binPath      = 'ffmpeg-{version}-full_build/bin'
                files        = @(
                    'ffmpeg.exe'
                    'ffprobe.exe'
                    'ffplay.exe'
                )
                platform     = 'x86_64'
                versionExe   = 'ffmpeg.exe'
                versionArgs  = @('-version')
                versionRegex = 'ffmpeg version (\d+\.\d+(?:\.\d+)?)'
                versions = [ordered]@{
                    '8.1.2' = 'b8cdefab5f50590a076c27c2b56b0294a0e6154faded28ba1ba05ebc4f801f57'
                    '7.1.1' = 'd760e1b3574402ed18b4865851f87d87e73965a982e6453212df8621fed1c508'
                    '5.1.2' = '1f4056c147694228fddaeb925083338e35d952e4b65e3bd3c5a0a2c13c7800d6'
                }
            }
            aacgain = [ordered]@{
                selected     = '2.0.0'
                type         = 'file'
                url          = 'https://github.com/dgilman/aacgain/releases/download/{version}/aacgain-{version}-windows-amd64.exe'
                files        = @('aacgain.exe')
                platform     = 'x86_64'
                versionExe   = 'aacgain.exe'
                versionArgs  = @('/v')
                versionRegex = '[Vv]ersion (\d+\.\d+(?:\.\d+)?)'
                versions     = [ordered]@{
                    '2.0.0' = 'd960cedbd274881badd3dd914475ca23bb31c27b3a5cab881ff0d1515a37371a'
                }
            }
            # 7zr: extractor 7z minimo (un solo .exe). Es el 'bootstrap' que necesita mkvtoolnix
            # (que se distribuye como .7z/LZMA y no lo abre Expand-Archive ni el tar de Windows).
            sevenzip = [ordered]@{
                selected     = '26.02'
                type         = 'file'
                url          = 'https://github.com/ip7z/7zip/releases/download/{version}/7zr.exe'
                files        = @('7zr.exe')
                platform     = 'x86_64'
                versionExe   = '7zr.exe'
                versionArgs  = @()
                versionRegex = '7-Zip.*?(\d+\.\d+)'
                versions     = [ordered]@{
                    '26.02' = '56b8cc9f4971cef253644fafe54063ed7fdca551d4dee0f8c6baa81b855acd72'
                }
            }
            # mkvtoolnix: 'mkvpropedit.exe' limpia las etiquetas DURATION del MKV final; 'mkvextract.exe'
            # rescata subtitulos embebidos que ffmpeg NO puede leer (p.ej. S_TEXT/WEBVTT, que el demuxer
            # de Matroska de ffmpeg marca como codec 'none') extrayendolos a un fichero que luego ffmpeg
            # convierte a .srt. Se distribuye como .7z (se extrae con 7zr). Los exe son autosuficientes.
            mkvtoolnix = [ordered]@{
                selected     = '100.0'
                type         = '7z'
                url          = 'https://mkvtoolnix.download/windows/releases/{version}/mkvtoolnix-64-bit-{version}.7z'
                binPath      = 'mkvtoolnix'
                files        = @('mkvpropedit.exe', 'mkvextract.exe')
                dependsOn    = @('sevenzip')   # 7zr para extraer el .7z (LZMA)
                platform     = 'x86_64'
                versionExe   = 'mkvpropedit.exe'
                versionArgs  = @('--version')
                versionRegex = 'mkvpropedit v(\d+\.\d+)'
                versions     = [ordered]@{
                    '100.0' = '061de38bd10e7e28697b897e0b890b78d6f2ec8d668a9c198600ed45c19672ab'
                }
            }
        }
        languages = [ordered]@{
            audio    = $langs
            subtitle = $langs
        }
        # encode: outputExtension = contenedor de salida; extensions = extensiones de ENTRADA que se
        # procesan de Original\ (sin punto); threads = -threads de ffmpeg (0 = auto, usa TODOS los nucleos;
        # N para limitar, util con encoders CPU + varios workers; con NVENC casi no influye). El resto se
        # agrupa en dos subsecciones: encode.VIDEO (fps, forceFps, multipass, tonemapHdr, anamorphic,
        # qualityCheck + auto{} + tuning{}) y encode.AUDIO (hz, channels, downmixMode, downmixCoeffs,
        # syncAdelay, multiAudio, keepTitle, syncThreshold, aacCoder). audio.channels = canales del audio
        # recodificado, tratado como MAXIMO (no hace upmix: si el origen tiene menos canales se conservan
        # los suyos; 2 = estereo, 6 = 5.1, 8 = 7.1). tuning = ajustes finos del encoder de video (preset por
        # familia, rc-lookahead NVENC, refs x26x, tier hevc); aacCoder = coder del AAC nativo (twoloop).
        # forceFps: si $true (por defecto) se fuerza la salida a 'fps' (-r), reajustando (dup/drop)
        #   los videos con otro fps de origen; si $false, se CONSERVA el fps de cada archivo (sin -r).
        # multipass: 2-pass de NVENC (solo hevc_nvenc/h264_nvenc). 'off' (por defecto) | 'qres'
        #   (1a pasada a 1/4 de resolucion) | 'fullres' (a resolucion completa). Mas calidad a costa
        #   de mas tiempo de GPU. No afecta a los encoders de CPU (libx264/libx265).
        # tonemapHdr: convierte el HDR (BT.2020/PQ o HLG) a SDR BT.709 al recodificar, para que no se
        #   vea "lavado" al reproducir en SDR. 'auto' (por defecto) = solo actua si el origen es HDR;
        #   'off' = nunca (deja el video como esta). Usa el filtro libplacebo en la GPU (Vulkan).
        # tonemapping: curva de tone-mapping de libplacebo (parametro 'tonemapping='). 'bt.2390' (por
        #   defecto, recomendada), 'bt.2446a', 'spline', 'reinhard', 'mobius', 'hable', 'gamma', 'linear',
        #   'clip'... Solo aplica cuando tonemapHdr actua.
        # downmixMode: SOLO al bajar 5.1 -> estereo (audio.channels=2). 'default' (por defecto) = downmix
        #   estandar de ffmpeg. 'dialogue' (BETA) = downmix con VOZ REFORZADA (filtro pan que sube el
        #   canal central —dialogos— y baja los surrounds), para que los dialogos no queden bajos frente
        #   al ambiente/efectos. No aplica si la salida no es estereo o el origen no es 5.1. BETA: los
        #   coeficientes del pan son provisionales, pendientes de validar/afinar con mas material.
        # downmixCoeffs: pesos del downmix 'dialogue' (voz reforzada). center = canal central (dialogos),
        #   front = frontales L/R, surround = surrounds; el LFE siempre se descarta. Cada salida =
        #   center*central + front*frontal + surround*surround. Para que sea clip-safe (el pico no supere
        #   al del origen) deben sumar <= 1.0; por encima puede recortar. El filtro pan se construye de
        #   estos valores, asi que se pueden afinar sin tocar codigo. Solo se usan con downmixMode=dialogue.
        # multiAudio: si $true (por defecto), cuando hay 2+ pistas del idioma preferido se ofrece
        #   conservar VARIAS (no solo la mejor) y elegir cual queda como predeterminada. Con $false =
        #   monopista (elige una, como siempre). Con 0-1 pistas del idioma preferido no cambia nada.
        # keepTitle (audio): si $true, la(s) pista(s) de audio de salida CONSERVAN el titulo del origen
        #   (util para distinguir varias del mismo idioma: principal/comentarios/...). Por defecto
        #   $false = titulo en blanco (como el resto de pistas recodificadas).
        # anamorphic: como tratar el video ANAMORFICO (pixeles no cuadrados, SAR != 1, p. ej. un DVD
        #   1920x1072 con SAR 115:87 que se VE a ~2538x1072). Al detectarlo, PREPARAR PREGUNTA que hacer
        #   (preseleccionando este valor); esta clave es el DEFAULT de esa pregunta. 'square' (por defecto)
        #   = cuadra a pixeles cuadrados fijando el ANCHO de almacenamiento (1920 -> 1920x810 SAR 1:1, sin
        #   ampliar); 'squareheight' = cuadra fijando el ALTO (amplia el ancho al mostrado); 'keep' =
        #   conserva el SAR/DAR tal cual (depende de que el reproductor lo respete). En 'square'/'squareheight'
        #   se elimina el SAR (se ve igual en cualquier reproductor) conservando la proporcion; maxWidth capa.
        # syncAdelay: metodo del silencio de sincronia audio/video. $true (por defecto) = filtro 'adelay'
        #   en UNA sola pasada (encadenado con la normalizacion de volumen), sin WAV intermedio. $false =
        #   metodo clasico (genera un WAV silencio+pista y luego lo codifica). Ambos dan el mismo resultado
        #   audible; 'adelay' cuantiza a ms enteros (ver docs/ref-gotchas.md). Antes era la beta test.syncAdelay.
        # auto: ajustes del perfil 'Auto' (opcion A del menu y videoEncoder:"auto" en un perfil), que
        #   elige solo el mejor encoder soportado. FILTROS: gpuOnly ($false por defecto): si $true, Auto
        #   solo considera encoders por GPU (NVENC); si el equipo no tiene GPU compatible cae a CPU con
        #   aviso. maxCodec (''=sin tope): limita hasta que CODEC sube Auto: 'h264' | 'h265' | 'av1' (ej:
        #   con 'h265', aunque la GPU soporte AV1, Auto no pasa de H.265). Auto escala av1 > h265 > h264,
        #   GPU antes que CPU. CONTROL DE TASA (fuente unica, la usa Get-CvAutoRate): crf = CRF de
        #   libx264/libx265 (0-51, menor = mejor); crfAv1 = CRF de libsvtav1/AV1 (0-63, escala distinta a
        #   H.26x); en NVENC se usan qmin/qmax (control por QP) y level = -level:v de H.264/H.265 (AV1 no
        #   usa level). La profundidad (main10 en h265/av1, high 8-bit en h264) la fija el codec, no config.
        # syncThreshold (audio): detecta un posible AUDIO ADELANTADO comparando cuánto ACABA el audio
        #   antes que el vídeo (con inicios alineados). Si la diferencia supera este umbral en segundos,
        #   PREPARAR avisa y PREGUNTA cuánto retardo aplicar (por defecto el valor detectado; se puede
        #   previsualizar original vs corregido). 0 = desactiva la detección. Timeout de la pregunta:
        #   behavior.promptTimeout.audioSync (15 s). OJO: un audio con cola legítimamente más corta
        #   puede dar un falso positivo; por eso PREGUNTA (y ofrece preview) en vez de aplicarlo a ciegas.
        # qualityCheck: control de calidad de la SALIDA frente al origen tras codificar. 'off' (por
        #   defecto) = no medir; 'ssim' o 'vmaf' = medir esa metrica. Es una pasada extra de ffmpeg que
        #   decodifica AMBOS videos enteros -> LENTO en pelis largas (ssim ~5-9x realtime; vmaf muchisimo
        #   mas, ~0,06x = puede tardar horas), por eso viene desactivado por defecto. El resultado se
        #   registra ([QC]). No se mide en 'copy'. vmaf requiere que el ffmpeg tenga libvmaf; si no, avisa.
        encode    = [ordered]@{
            outputExtension = 'mkv'
            extensions      = @(
                'avi'
                'flv'
                'mp4'
                'mov'
                'mkv'
            )
            threads         = 0
            # --- VIDEO ---
            video = [ordered]@{
                # Codec de video por defecto (fuente unica; la hereda customProfile como semilla del builder).
                # OJO: los perfiles de serie y de profiles[] declaran su PROPIO encoder/profile/level, asi que
                # estos globales NO los sustituyen; solo siembran el constructor CUSTOM (opcion 0). El nivel
                # usa el formato '5.0' (mismo que encode.video.auto.level); ffmpeg trata '5'=='5.0' igual.
                videoEncoder = 'hevc_nvenc'
                videoProfile = 'main10'
                videoLevel   = '5.0'
                fps          = '23.976'
                forceFps     = $true
                multipass    = 'off'
                tonemapHdr   = 'auto'
                tonemapCurve = 'bt.2390'
                anamorphic   = 'square'
                qualityCheck = 'off'
                # Si el video RECODIFICADO sale mas grande que el original, recodificar no ha
                # compensado: se tira lo codificado y se multiplexa con la pista de video ORIGINAL
                # (el audio, los subtitulos y los capitulos ya estan hechos, no se repite nada). Solo
                # se hace cuando la imagen NO se toca: sin recorte, sin escalado, sin tone-mapping
                # HDR y sin forzar fps -si se cambia la imagen, el original ya no vale de sustituto-.
                keepOriginalIfBigger = $false
                # A partir de que proporcion se da por no compensado. 1.00 = solo si el recodificado
                # es MAS grande que el original; 0.95 = si no ahorra ni un 5%.
                keepOriginalRatio    = 1.00
                # Perfil Auto: filtros (gpuOnly/maxCodec) + control de tasa (crf/crfAv1/qmin/qmax/level).
                auto = [ordered]@{
                    gpuOnly  = $false
                    maxCodec = ''
                    crf      = 21
                    crfAv1   = 30
                    qmin     = 1
                    qmax     = 23
                    level    = '5.0'
                }
                # Tuning del encoder de video (fuente unica, la usa Get-VideoArgs): preset por familia
                # (NVENC h264/h265 y libx264/libx265 = 'slow'; SVT-AV1 0-13; AV1 NVENC p1-p7), lookahead
                # de control de tasa (NVENC), refs (x264/x265) y tier (hevc_nvenc).
                tuning = [ordered]@{
                    presetNvenc    = 'slow'
                    presetX26x     = 'slow'
                    presetSvtav1   = '6'
                    presetAv1Nvenc = 'p6'
                    rcLookahead    = 32
                    refs           = 4
                    tier           = 'high'
                }
                # border: deteccion de bordes negros con cropdetect.
                #  - start: segundo del primer punto de escaneo. duration: segundos que escanea CADA punto.
                #  - samples: en cuantos puntos repartidos del video se escanea (1 = solo al inicio, clasico).
                #  - autoAcceptPct: si el recorte mas votado alcanza este % de los puntos que detectaron
                #    borde, se acepta AUTOMATICAMENTE (se descartan los atipicos); por debajo, se pregunta.
                #  - autoAcceptMinMargin: ADEMAS del %, el mas votado debe superar al 2o por al menos estos
                #    votos. Evita auto-aceptar con evidencia debil cuando hay pocas muestras (2/3 = 67% pero
                #    solo 1 de margen -> pregunta; 6/9 = 67% con 3+ de margen -> auto). 0 = sin margen.
                #  - autoSamples/autoDuration: puntos y segundos del PRE-ESCANEO del modo 'auto' del perfil
                #    (DetectBorder='auto'), mas ligero. OJO: el escaneo aplica un minimo de 5 s por punto,
                #    asi que autoDuration < 5 se trata como 5. minCropPct: reduccion minima (%) para
                #    considerar barras de verdad. El modo 'auto' reusa autoAcceptPct/autoAcceptMinMargin.
                border = [ordered]@{
                    start               = 120
                    duration            = 120
                    samples             = 6
                    autoAcceptPct       = 60
                    autoAcceptMinMargin = 2
                    autoSamples         = 3
                    #  - autoMaxCropPct: tope de lo que el modo 'auto' recorta SOLO. Los puntos se
                    #    combinan por UNION (lo que esta negro en todos), asi que el resultado es
                    #    conservador; pero si aun asi sale un recorte enorme -mas de este % de ancho o
                    #    de alto- casi seguro es que ningun punto vio un plano a pantalla completa, asi
                    #    que se propone y se pide confirmacion en vez de aplicarlo a ciegas. Referencia:
                    #    un 2.39:1 dentro de 16:9 se lleva ~22% del alto; un 4:3, ~25% del ancho.
                    autoMaxCropPct      = 40
                    autoDuration        = 15
                    minCropPct          = 2
                }
            }
            # --- AUDIO ---
            audio = [ordered]@{
                hz            = 44100
                channels      = 2
                # Salida de audio por defecto (fuente unica; la hereda customProfile): encoder = recodificar
                # (aac_coder) o 'copy'; codec = codec de recodificacion; bitrate ('copy' = copiar la pista).
                encoder       = 'aac_coder'
                codec         = 'aac'
                bitrate       = '192k'
                downmixMode   = 'default'
                downmixCoeffs = [ordered]@{
                    center   = $dmc.Center
                    front    = $dmc.Front
                    surround = $dmc.Surround
                }
                syncAdelay    = $true
                multiAudio    = $true
                keepTitle     = $false
                syncThreshold = 2.0
                aacCoder      = 'twoloop'   # coder del encoder AAC nativo (twoloop = mayor calidad)
                # volume: normalizacion de volumen (metodos y textos en Get-CvVolumeMethods).
                #   method = 'loudnorm' (por defecto desde v4.5.5): sonoridad EBU R128, iguala el
                #     volumen PERCIBIDO entre archivos. 'peak' es LEGACY (solo iguala el pico) y
                #     'aacgain' solo aplica a AAC por etapas.
                #   peakTarget = pico objetivo dBFS del metodo 'peak' (0 = maximo sin recorte; -1 deja
                #     headroom contra el clipping inter-sample del AAC).
                volume = [ordered]@{
                    method     = 'loudnorm'
                    peakTarget = 0
                    loudnorm   = [ordered]@{
                        I   = -16
                        TP  = -1.5
                        LRA = 11
                    }
                }
            }
            # subtitles.toSrt: lista de tipos de subtitulo (por codec) a CONVERTIR A SRT. Los de la lista
            # se transcodifican a SubRip; el WEBVTT embebido que ffmpeg NO puede leer (el demuxer de
            # Matroska lo marca como codec 'none') se RESCATA con mkvextract a un temporal y se convierte
            # en la misma ejecucion. Los que NO estan en la lista se copian tal cual. Lista vacia = no
            # convertir nada (un subtitulo ilegible se descarta con aviso). Anade p.ej. 'ass','mov_text'.
            # subtitles.defaultLang: idioma por defecto de la pregunta de idioma del fallback (cuando no
            # hay subtitulo del idioma preferido). Vacio ('') = comportamiento clasico: ENTER mantiene el
            # idioma del subtitulo elegido. Con un codigo (p. ej. 'spa') = ese es el default: ENTER/timeout
            # reetiqueta a ese idioma sin tener que teclearlo cada vez (util cuando siempre vienen mal
            # etiquetados igual). Se puede teclear otro codigo en el momento para sobreescribirlo.
            # subtitles.dropEmpty: descarta al PREPARAR las pistas de subtitulo VACIAS (sin un solo cue;
            # se detecta por los tags de mkvmerge, sin demultiplexar: ver Test-CvSubtitleEmpty). Ademas
            # de no meter en el MKV final una pista que no muestra nada, evita que la barra de progreso
            # se congele: ffmpeg calcula el 'out_time' del '-progress' como el MINIMO de todas las pistas
            # de salida, asi que una pista vacia lo deja en 'N/A' durante toda la codificacion. false =
            # conservarlas (comportamiento anterior).
            subtitles = [ordered]@{
                toSrt       = @('webvtt')
                defaultLang = ''
                dropEmpty   = $true
                # Codecs de subtitulo que son TEXTO: se pueden leer, pasar a .srt y contar sus lineas.
                #   Lo que no este aqui se trata como de IMAGEN (mapas de bits: PGS, VobSub, DVB), que
                #   no tienen texto que ensenar y solo se pueden sacar tal cual y abrir con quien los
                #   entienda (que ademas hace OCR). Si aparece un codec de texto nuevo, se anade aqui
                #   y funciona en todo el programa (visor, resumen, editor de jobs) sin tocar codigo.
                #   OJO: es una LISTA, y en config.json una lista SUSTITUYE a esta (no se suma); para
                #   anadir uno hay que escribirlas todas. El mapa de abajo, en cambio, se fusiona.
                textCodecs  = @(
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
                # A que FICHERO se saca cada codec de IMAGEN al extraerlo para abrirlo fuera. El
                #   formato es 'codec de ffmpeg' -> 'extension' (con o sin punto, da igual). Lo que
                #   se ponga aqui se SUMA a lo de serie: config.json solo tiene que traer los codecs
                #   nuevos, no repetir estos. Un codec que no este en la lista no se puede extraer.
                imageExtensions = [ordered]@{
                    hdmv_pgs_subtitle = '.sup'
                    pgssub            = '.sup'
                    dvd_subtitle      = '.idx'
                    dvdsub            = '.idx'
                }
            }
        }
        # customProfile: valores por DEFECTO del constructor de perfil CUSTOM interactivo (opcion 0
        #   del menu USAR PERFIL). En cada menu, ENTER acepta el valor por defecto (o eliges otro).
        #   Acepta los MISMOS campos que un perfil del array 'profiles' (paridad), como semilla de cada
        #   pregunta del builder. videoEncoder: libx264|h264_nvenc|libx265|hevc_nvenc|libsvtav1|av1_nvenc|
        #   copy|auto (auto = mejor encoder del equipo, se resuelve al preparar como la opcion 'A').
        #   videoProfile: main|main10|... / videoLevel: 4.0|4.1|5.0|... (segun codec; se ignoran si no aplican).
        #   qmin/qmax: tasa por defecto en NVENC. crf: tasa por defecto en CPU. Rango 0-51; -1 = AUTO.
        #   detectBorder: false|true|'auto' (deteccion de bordes por archivo). changeSize: '' | '1920:-2'
        #     (reescalado fijo). noUpscale: true = changeSize SOLO reduce (no amplia videos mas pequeños que
        #     el destino; p.ej. un 720p no sube a 1080p). maxWidth: 0 (no) | 1920 (reduce a ese ancho solo
        #     si es mayor; no amplia).
        #   audioEncoder: aac_coder (recodificar) | copy. audioCodec: aac|ac3|eac3|libmp3lame|flac|libopus.
        #   audioBitrate: bitrate de audio ('copy' = copiar la pista sin recodificar). audioHz: frecuencia.
        #   audioChannels: 2|6|8 (MAXIMO, no upmix). downmixMode: default|dialogue. downmixCoeffs: pesos
        #   del downmix dialogue (center/front/surround), como en encode.audio.downmixCoeffs.
        customProfile = [ordered]@{
            videoEncoder  = $null   # <- se deriva de encode.video.videoEncoder
            videoProfile  = $null   # <- se deriva de encode.video.videoProfile
            videoLevel    = $null   # <- se deriva de encode.video.videoLevel
            qmin          = $null   # <- se deriva de encode.video.auto.qmin
            qmax          = $null   # <- se deriva de encode.video.auto.qmax
            crf           = $null   # <- se deriva de encode.video.auto.crf
            detectBorder  = $false
            changeSize    = ''
            noUpscale     = $false
            maxWidth      = 0
            multipass     = $null   # <- se deriva de encode.video.multipass (abajo)
            audioEncoder  = $null   # <- se deriva de encode.audio.encoder
            audioCodec    = $null   # <- se deriva de encode.audio.codec
            audioBitrate  = $null   # <- se deriva de encode.audio.bitrate
            audioHz       = $null   # <- se deriva de encode.audio.hz
            audioChannels = $null   # <- se deriva de encode.audio.channels
            downmixMode   = $null   # <- se deriva de encode.audio.downmixMode
            downmixCoeffs = $null   # <- se deriva de encode.audio.downmixCoeffs
        }
        # preview: previsualizacion con ffplay en PREPARAR (pista audio/video, comparacion de bordes).
        #   start = segundo donde empieza (0 = desde el principio). seconds = duracion de la muestra
        #   (0 = SIN limite: reproduce hasta el final o hasta que el usuario cierre con q/ESC). El
        #   comando 'P N <seg>' de los menus fuerza el inicio en ese segundo puntual.
        #   syncSeconds = tope de duracion (seg) de cada preview de la comparacion A/B de sincronia de
        #   audio; 0 = SIN limite (por defecto: reproduce la fuente directa hasta el final o hasta q/ESC).
        #   Se puede acotar (> 0) si se prefiere una muestra corta.
        #   subtitleEditor = como abrir el .srt al usar 'V N' (ver texto del subtitulo) en el menu. Tres
        #   modos: 'start' (por defecto) = el programa asociado de Windows (fallback a Notepad); 'win' =
        #   una ventana propia de PowerShell (WinForms + RichTextBox, modal); 'external' = el programa
        #   definido en subtitleEditorExe (p. ej. Subtitle Edit o VS Code). subtitleEditorExe = ruta al
        #   .exe que usa el modo 'external' (ignorado en los otros modos). Compatibilidad: '' equivale a
        #   'start' y 'ventana' a 'win'. El comando 'V N' admite override puntual: 'V N <modo> [exe]'.
        #   player/playerExe = con que se REPRODUCE un video entero desde la cola (el original o el ya
        #   convertido, con el boton derecho): 'start' (por defecto) = el reproductor asociado de
        #   Windows -el que ya tiene configurado cada uno-, con vuelta a ffplay si no hay ninguno;
        #   'ffplay' = el de tools (siempre esta); 'external' = el .exe de playerExe. Esto NO son las
        #   previews de PREPARAR, que son siempre ffplay con sus filtros.
        preview   = [ordered]@{
            start             = 0
            seconds           = 0
            syncSeconds       = 0
            subtitleEditor    = 'start'
            subtitleEditorExe = ''
            player            = 'start'
            playerExe         = ''
        }
        # Postproceso del MKV final:
        #  - stripTags: limpiar con mkvpropedit las etiquetas DURATION por pista que anade el
        #    muxer de ffmpeg (mkvpropedit vacio = usar la version descargada en tools\).
        #  - attachments: conservar adjuntos del original, permitiendo/excluyendo por categoria
        #    (keep = interruptor maestro; fonts = fuentes p. ej. para subtitulos ASS; covers =
        #    caratulas/imagenes; other = el resto).
        postprocess = [ordered]@{
            stripTags   = $true
            mkvpropedit = ''
            attachments = [ordered]@{
                keep   = $false
                fonts  = $true
                covers = $false
                other  = $false
            }
        }
        # promptTimeout: auto-aceptar el valor por defecto en las preguntas simples de PREPARAR si no
        #   se teclea nada durante N segundos (contador de inactividad; cualquier tecla lo reinicia).
        #   'default' = timeout GENERICO en segundos (0 = desactivado). El resto son overrides por tipo
        #   de pregunta: -1 = usar el generico; >=0 = valor propio (0 = desactivado solo para esa).
        #   'sync' (silencio de sincronia), 'border' (deteccion de bordes), 'animation' (video de
        #   animacion), y los menus de seleccion 'video'/'audio'/'subtitle' (al expirar toman la opcion
        #   por defecto: la pista preseleccionada, o 'ninguno' en subtitulos). Los menus vienen a -1
        #   (heredan del generico, que por defecto es 0 = off) para no auto-elegir pista sin querer;
        #   sube 'default' o cada menu para dejar PREPARAR desatendido. Para una pregunta/menu nuevo
        #   basta anadir su clave aqui (sin tocar codigo salvo pasar su nombre a Get-CvPromptTimeout).
        # progress: en los pasos largos (recodificar video/audio) muestra una linea VIVA con % y ETA
        #   ( - Procesando Video...  42%  ETA 03:12  1.8x) leyendo el '-progress' de ffmpeg, en vez de
        #   lanzarlo en una ventana aparte y esperar al ✓. $true (por defecto) = progreso inline; $false
        #   = comportamiento clasico (ventana aparte / ✓ al final). En modo debug no aplica (se ve el
        #   log de ffmpeg). Convive con separateWindow: si progress esta activo, esos pasos van inline.
        # promptTimeoutStopOnType: $true (por defecto) = al empezar a teclear en una pregunta con auto,
        #   el auto se DESACTIVA y solo ENTER envia (no se auto-envia lo tecleado a medias). $false =
        #   clasico: al expirar el auto envia lo que haya tecleado (o el default si no hay nada).
        behavior  = [ordered]@{
            cleanTemps      = $true
            separateWindow  = $true
            lockCloseButton = $true
            log             = $true
            workers         = 2
            retries         = 2
            progress        = $true
            promptTimeout   = [ordered]@{
                default    = 0
                sync       = 5
                border     = 10
                animation  = 10
                anamorphic = 10
                audioSync  = 15
                video      = -1
                audio      = -1
                subtitle   = -1
                subtitleLang = 15
            }
            promptTimeoutStopOnType = $true
        }
        # Depuracion: enabled = mensajes/log detallados (comandos de ffmpeg, pasos internos) en vez de
        #   la vista compacta; ademas las codificaciones van a la ventana principal (no inline ni en
        #   ventana aparte), para ver todo el log. Tambien se activa con el marcador 'debug_on'.
        #   pausePerCommand ($true por defecto): en modo debug, ANTES de cada ejecucion de ffmpeg se
        #   imprime el comando y se pide ENTER para continuar; con $false se ejecuta sin pausar (util
        #   para ver el log detallado sin ir confirmando comando a comando).
        debug     = [ordered]@{
            enabled         = $false
            pausePerCommand = $true
        }
        # Modo pruebas: si 'enabled', cada archivo se codifica solo hasta 'minutes' minutos (el resto
        #   se descarta). Sirve para validar perfiles/ajustes rapido. Tambien se activa con 'test_on'.
        #   betaDownmix (BETA): activador del downmix 'dialogue' (voz reforzada). Mientras esa mezcla
        #   sea beta hay doble llave: encode.downmixMode='dialogue' fija el modo, pero SOLO refuerza la
        #   voz si betaDownmix=$true. Con $false (por defecto), aunque downmixMode sea 'dialogue' se usa
        #   el downmix estandar de ffmpeg. Al promocionar la mezcla se retira este flag.
        #   betaOnePass (BETA): funde audio+video+multiplexado en UNA sola ejecucion de ffmpeg
        #   (menos temporales y arranques). Solo aplica si video y audio se codifican (no copy),
        #   sincronia 'adelay', volumen 'loudnorm' y sin tone-mapping HDR; en el resto se usa el
        #   pipeline por etapas. Con $false (por defecto) SIEMPRE se usa el pipeline por etapas.
        test      = [ordered]@{
            enabled        = $false
            minutes        = 5
            betaDownmix    = $false
            betaOnePass    = $false
        }
        console   = [ordered]@{
            background       = 'DarkBlue'
            foreground       = 'Yellow'
            font             = 'Cascadia Code'
            fontSize         = 18
            windowWidth      = 150
            windowHeight     = 40
            sepWidth         = 64
            progressBarWidth = 20
            # Marcas de estado en ASCII ([OK]/[ERROR]) en vez de simbolos ✓/✗ (util si la fuente no
            # tiene esos glifos). Es apariencia de consola, por eso vive aqui (no en behavior).
            asciiMarks       = $false
        }
        # IDIOMA de la interfaz. OJO, no confundir con 'languages', que son los idiomas de las
        # PISTAS (que audio o que subtitulo se elige): esto es en que idioma te habla el programa.
        # 'auto' = el de Windows si hay traduccion; si no, castellano. Los textos estan en lang\.
        ui        = [ordered]@{
            language = 'auto'
        }
        # Apariencia de las VENTANAS (lo que 'console' es para el modo consola).
        #   rememberLayout: al cerrar la ventana de la COLA se apunta como quedo -tamano, maximizada, reparto
        #   del divisor y anchos de columna- en '<config>.gui.json' (junto al config en uso) y la
        #   siguiente vez se abre igual. Con $false no se escribe nada y siempre se abre con los
        #   tamanos de aqui. El fichero es de estado, no de configuracion: se puede borrar sin mas.
        gui       = [ordered]@{
            theme             = 'system'
            rememberLayout    = $true
            # Los workers son procesos APARTE: cerrar la ventana no los mata, siguen codificando sin
            # nada a la vista (van con la consola oculta). Con esto activado, al cerrar con workers
            # vivos se pregunta que hacer: dejarlos, parada ordenada o cortarlos. Es el equivalente
            # en ventana de behavior.lockCloseButton (que desactiva la X de la consola).
            confirmCloseWithWorkers = $true
            queueWidth        = 1320
            queueHeight       = 760
            # Tamano de partida de la ventana de SETUP (cuando no hay nada recordado, o con
            # rememberLayout en false).
            setupWidth        = 1040
            # 800 y no 720: el menu de setup ya no cabia en 720 (medido: necesita 780) y salia con
            # barra de scroll, con la ultima seccion cortada. Aun asi, la ventana se AJUSTA sola al
            # abrir si el menu no cabe, asi que anadir opciones no vuelve a romperlo.
            setupHeight       = 800
            # Reparto del alto de la cola: % para la lista; el resto, para el resumen y el log.
            queueSplitPercent = 52
            # Un archivo YA CONVERTIDO no tiene job (el worker lo borra al terminar), asi que la
            # columna 'Bordes' se quedaba en blanco. Se puede DEDUCIR comparando la proporcion del
            # original con la de la salida: si no cuadran, se quitaron barras. Cuesta dos ffprobe por
            # archivo (~300 ms medidos; casi todo es ARRANCAR ffprobe, que ocupa 231 MB: leer el
            # tamano de un archivo de 1 GB cuesta lo mismo que el de uno de 3 MB), asi que se
            # analizan como mucho N por refresco -el resultado
            # se cachea, asi que la lista se va rellenando sola en unos segundos- y SOLO con la cola
            # parada: mientras hay workers, el refresco tiene que seguir siendo barato. 0 = no deducir.
            queueDoneProbe     = 2
            # Cada cuanto se REPINTA la cola mientras hay workers: solo se lee el estado que ellos
            # publican (Proceso\*.worker.json), no las carpetas de archivos.
            queueRefreshMs     = 1000
            # Y cada cuanto se RELEEN LAS CARPETAS sin nada en marcha. 0 = nunca: la lista se
            # actualiza cuando la pides (boton Actualizar), cuando la propia ventana hace algo
            # (preparar, iniciar, limpiar), cuando un worker cambia de archivo o termina, y al
            # volver a la ventana. Leer tres carpetas cada pocos segundos para nada solo estorba,
            # y mas si Original\ esta en red.
            queueIdleRefreshMs = 0
            # Releer al volver a la ventana: recoge lo que hayas dejado en Original\ mientras
            # estabas en otra cosa, sin tener que acordarte de pulsar Actualizar.
            queueRefreshOnActivate = $true
            # Que la lista SIGA al archivo que se esta codificando: si se sale de la zona visible,
            # se mueve sola para dejarlo a la vista. Si te has ido tu a mirar otra parte de la
            # lista, no se mueve (vuelve a engancharse cuando vuelves a tenerlo a la vista).
            queueFollowWorker  = $true
            # Cuanto se espera a que un worker recien abierto publique su estado. En ese hueco no
            # hay workers vivos pero SI hay algo que esperar: el temporizador sigue mirando (y el
            # boton Iniciar sigue apagado) hasta que aparezca o se acabe el plazo.
            queueStartGraceSec = 20
            # Cuanto se queda QUIETA la lista despues de que la toques (marcar filas, teclas). Se
            # persigue al archivo en curso, pero no mientras estas eligiendo: moverla bajo el raton
            # a mitad de un Ctrl/Mayus+clic acaba seleccionando lo que no querias.
            queueFollowHoldSec = 3
            # Margen de proporcion para decidir que hubo recorte (0.01 = 1%). Por debajo caen los
            # redondeos a tamano PAR del escalado (un pixel en 1080 es un 0,09%); por encima, los
            # recortes de verdad (quitar 140px de barras cambia la proporcion un 15%).
            queueDoneTolerance = 0.01
        }
        # Carpetas de trabajo: vacio = junto al programa; admite ruta absoluta o relativa.
        paths     = [ordered]@{
            original   = ''
            proceso    = ''
            convertido = ''
            logs       = ''
        }
        # Perfiles de codificacion PROPIOS: se ANADEN a los de serie en el menu USAR PERFIL
        # (no los sustituyen). Cada objeto admite: label, videoEncoder, videoProfile, videoLevel,
        # qmin, qmax, crf, detectBorder, changeSize, audioEncoder, audioCodec, audioBitrate, audioHz.
        # Ejemplo: { "label":"Anime 1080p", "videoEncoder":"libx265", "crf":18, "changeSize":"1920:-2" }
        profiles  = @()
        # Perfil que sale MARCADO al preparar (ventana y consola). Vale el NOMBRE de uno propio de
        # 'profiles', 'Perfil N' de los de serie (el mismo numero del menu) o 'Auto'. Se cambia desde
        # setup > Perfiles, sin tocar el fichero a mano.
        defaultProfile = 'Auto'
    }
    # customProfile HEREDA de encode.* (fuente unica) los campos con equivalente global, en vez de
    # repetir el literal: cambiar el default global cambia tambien la semilla del builder custom.
    # videoEncoder/videoProfile/videoLevel salen de encode.video; el nivel usa '5.0' (mismo formato que
    # encode.video.auto.level; ffmpeg trata '5'=='5.0'). El control de tasa (qmin/qmax/crf) se toma del
    # perfil Auto (encode.video.auto). downmixCoeffs se COPIA (nuevo [ordered]) para no compartir
    # referencia con encode.audio.
    $cfg.customProfile.videoEncoder  = $cfg.encode.video.videoEncoder
    $cfg.customProfile.videoProfile  = $cfg.encode.video.videoProfile
    $cfg.customProfile.videoLevel    = $cfg.encode.video.videoLevel
    $cfg.customProfile.qmin          = $cfg.encode.video.auto.qmin
    $cfg.customProfile.qmax          = $cfg.encode.video.auto.qmax
    $cfg.customProfile.crf           = $cfg.encode.video.auto.crf
    $cfg.customProfile.multipass     = $cfg.encode.video.multipass
    $cfg.customProfile.audioEncoder  = $cfg.encode.audio.encoder
    $cfg.customProfile.audioCodec    = $cfg.encode.audio.codec
    $cfg.customProfile.audioBitrate  = $cfg.encode.audio.bitrate
    $cfg.customProfile.audioHz       = $cfg.encode.audio.hz
    $cfg.customProfile.audioChannels = $cfg.encode.audio.channels
    $cfg.customProfile.downmixMode   = $cfg.encode.audio.downmixMode
    $cfg.customProfile.downmixCoeffs = [ordered]@{
        center   = $cfg.encode.audio.downmixCoeffs.center
        front    = $cfg.encode.audio.downmixCoeffs.front
        surround = $cfg.encode.audio.downmixCoeffs.surround
    }
    return $cfg
}

function ConvertTo-CvSubtitleExtMap {
    <#
        PURO. Normaliza el mapa 'codec -> extension' de encode.subtitles.imageExtensions a una tabla
        con las claves en minusculas y las extensiones con su punto ('PGSSUB' + 'sup' -> 'pgssub' +
        '.sup'): asi la config admite lo que escriba cada uno y el resto del codigo compara sin mas.
        Acepta tanto la tabla de los defaults como el objeto que sale de leer el JSON.
    #>
    param($Source)
    $map = @{}
    if ($null -eq $Source) { return $map }
    $pairs = @()
    if ($Source -is [System.Collections.IDictionary]) {
        foreach ($k in @($Source.Keys)) { $pairs += @{ Name = "$k"; Value = $Source[$k] } }
    } else {
        foreach ($p in @($Source.PSObject.Properties)) { $pairs += @{ Name = "$($p.Name)"; Value = $p.Value } }
    }
    foreach ($p in $pairs) {
        $codec = "$($p.Name)".Trim().ToLower()
        $ext   = "$($p.Value)".Trim().ToLower()
        if ($codec -eq '' -or $ext -eq '') { continue }
        if (-not $ext.StartsWith('.')) { $ext = '.' + $ext }
        $map[$codec] = $ext
    }
    return $map
}

function Get-CvConfigHelp {
    <#
        Catalogo de AYUDA de las opciones de config.json: { 'ruta/clave' -> descripcion corta }.
        La ruta usa '/' igual que el navegador del editor (setup.ps1 Edit-Node): claves de raiz
        'seccion'; anidadas 'seccion/clave'; profundas 'seccion/sub/clave'. Lo consume setup.ps1
        para mostrar, junto a cada opcion, que hace. Fuente unica de los textos (los comentarios
        de Get-CvConfigDefaults son la version larga).
    #>
    @{
        'downloads' = '[av] Catalogo de herramientas descargables (ffmpeg, aacgain, 7zr, mkvpropedit); se gestiona desde el menu Herramientas'

        'languages'          = "Idiomas preferidos (etiquetas que cuentan como 'espanol')"
        'languages/audio'    = 'Etiquetas de idioma preferidas al elegir la pista de audio'
        'languages/subtitle' = 'Etiquetas de idioma preferidas al elegir/conservar subtitulos'

        'encode'                = 'Ajustes de codificacion (contenedor + subsecciones video/audio)'
        'encode/outputExtension'= 'Contenedor de salida (mkv recomendado; mp4/mov admiten +faststart)'
        'encode/extensions'     = 'Extensiones de entrada que se procesan de Original\ (sin punto)'
        'encode/threads'        = '-threads de ffmpeg: 0 = todos los nucleos; N para limitar'
        'encode/video'          = 'Ajustes de VIDEO (fps, HDR, anamorfico, perfil Auto, tuning...)'
        'encode/video/videoEncoder'= 'Codec de video por defecto (semilla del builder custom): libx264|h264_nvenc|libx265|hevc_nvenc|libsvtav1|av1_nvenc|copy|auto'
        'encode/video/videoProfile'= 'Perfil del codec por defecto (main|main10|...); se ignora si no aplica'
        'encode/video/videoLevel'  = 'Nivel del codec por defecto (4.0|4.1|5.0|...); se ignora si no aplica'
        'encode/video/fps'      = "Fps de salida cuando forceFps=true (ej 23.976)"
        'encode/video/forceFps' = "true = fuerza la salida a 'fps' (-r); false = conserva el fps de origen"
        'encode/video/multipass'= '2-pass NVENC: off | qres (1/4 res) | fullres. Mas calidad, mas GPU'
        'encode/video/tonemapHdr' = 'HDR->SDR BT.709 al recodificar: auto (solo si origen HDR) | off'
        'encode/video/tonemapCurve'= 'Curva de tone-mapping libplacebo: bt.2390 (rec.) | bt.2446a | spline | reinhard | mobius | hable | ...'
        'encode/video/anamorphic' = 'Video anamorfico (SAR!=1): keep | square (cuadra por ancho) | squareheight (por alto)'
        'encode/video/keepOriginalIfBigger' = 'Si el video recodificado sale mas grande que el original (y no se toca la imagen), usar la pista ORIGINAL en vez de la recodificada'
        'encode/video/keepOriginalRatio' = 'Desde que proporcion se da por no compensado (1.00 = solo si es mas grande; 0.95 = si no ahorra ni un 5%)'
        'encode/video/qualityCheck' = 'Medir calidad de la salida vs origen tras codificar: off | ssim | vmaf (pasada extra, mas lento)'
        'encode/video/auto'         = 'Ajustes del perfil Auto (filtros de encoder + control de tasa)'
        'encode/video/auto/gpuOnly' = 'Perfil Auto: si true, solo considera encoders por GPU (NVENC); false = permite CPU'
        'encode/video/auto/maxCodec'= 'Perfil Auto: tope de codec ("" sin tope | h264 | h265 | av1); Auto no sube de ahi'
        'encode/video/auto/crf'     = 'Perfil Auto: CRF de libx264/libx265 (0-51, menor = mejor calidad)'
        'encode/video/auto/crfAv1'  = 'Perfil Auto: CRF de libsvtav1/AV1 (0-63, escala distinta a H.26x)'
        'encode/video/auto/qmin'    = 'Perfil Auto: Qmin de los encoders NVENC (control por QP)'
        'encode/video/auto/qmax'    = 'Perfil Auto: Qmax de los encoders NVENC (control por QP)'
        'encode/video/auto/level'   = 'Perfil Auto: -level:v de H.264/H.265 NVENC (AV1 no usa level)'
        'encode/video/tuning'                = '[av] Tuning del encoder de video (preset por familia, lookahead, refs, tier)'
        'encode/video/tuning/presetNvenc'    = 'Preset de hevc_nvenc/h264_nvenc (p. ej. slow, o p1-p7)'
        'encode/video/tuning/presetX26x'     = 'Preset de libx264/libx265 (ultrafast..placebo; def slow)'
        'encode/video/tuning/presetSvtav1'   = 'Preset de libsvtav1 (0-13; menor = mas lento/mejor)'
        'encode/video/tuning/presetAv1Nvenc' = 'Preset de av1_nvenc (p1-p7)'
        'encode/video/tuning/rcLookahead'    = 'rc-lookahead de los encoders NVENC (frames)'
        'encode/video/tuning/refs'           = 'Frames de referencia de libx264/libx265 (-refs)'
        'encode/video/tuning/tier'           = 'Tier de hevc_nvenc (main | high)'
        'encode/audio'          = 'Ajustes de AUDIO (canales, downmix, sincronia, multipista...)'
        'encode/audio/hz'       = 'Frecuencia del audio recodificado (Hz); opus fuerza 48000'
        'encode/audio/channels' = 'Canales de salida (MAXIMO, no hace upmix): 2 = estereo, 6 = 5.1, 8 = 7.1'
        'encode/audio/encoder'  = 'Salida de audio por defecto: aac_coder (recodificar) | copy'
        'encode/audio/codec'    = 'Codec de recodificacion por defecto: aac|ac3|eac3|libmp3lame|flac|libopus'
        'encode/audio/bitrate'  = "Bitrate de audio por defecto ('copy' = copiar la pista sin recodificar)"
        'encode/audio/downmixMode'    = 'Al bajar 5.1->estereo: default | dialogue (refuerza la voz)'
        'encode/audio/downmixCoeffs'        = '[av] Pesos del downmix dialogue (voz reforzada); solo con downmixMode=dialogue'
        'encode/audio/downmixCoeffs/center' = 'Peso del canal central (dialogos) en el downmix dialogue'
        'encode/audio/downmixCoeffs/front'  = 'Peso de los frontales L/R en el downmix dialogue'
        'encode/audio/downmixCoeffs/surround' = 'Peso de los surrounds en el downmix dialogue (el LFE se descarta)'
        'encode/audio/syncAdelay'     = 'Sincronia: true (por defecto) = adelay en 1 pasada (sin WAV); false = clasico (WAV silencio+pista)'
        'encode/audio/multiAudio'     = 'Con 2+ pistas del idioma preferido, conservar varias y elegir la predeterminada (false = monopista, solo la mejor)'
        'encode/audio/keepTitle'      = 'Conservar el titulo del audio de origen en la salida (false = titulo en blanco)'
        'encode/audio/syncThreshold'  = 'Detectar audio adelantado si acaba N s antes que el video (0 = off); PREPARAR pregunta el retardo'
        'encode/audio/aacCoder'       = 'Coder del encoder AAC nativo (twoloop = mayor calidad)'
        'encode/subtitles/toSrt'      = 'Tipos de subtitulo (por codec) a convertir a SRT (p.ej. webvtt); el WEBVTT ilegible se rescata con mkvextract. Vacio = no convertir'
        'encode/subtitles/defaultLang' = 'Idioma por defecto de la pregunta de idioma del fallback de subtitulos (ENTER lo usa). Vacio = mantener el del subtitulo elegido'
        'encode/subtitles/textCodecs'  = 'Codecs de subtitulo que son TEXTO (el resto se trata como imagen)'
        'encode/subtitles/imageExtensions' = 'A que fichero se saca cada codec de IMAGEN al extraerlo (codec -> extension); se suma a los de serie'
        'encode/subtitles/dropEmpty'  = 'Descartar las pistas de subtitulo VACIAS (sin cues); evitan una pista muerta en la salida y que se congele la barra de progreso'

        'customProfile'             = '[av] Valores por defecto del constructor de perfil CUSTOM (opcion 0 de USAR PERFIL); mismos campos que un profiles[]'
        'customProfile/videoEncoder'= 'Codec de video: libx264|h264_nvenc|libx265|hevc_nvenc|libsvtav1|av1_nvenc|copy|auto'
        'customProfile/videoProfile'= 'Perfil del codec (main|main10|...); se ignora si no aplica'
        'customProfile/videoLevel'  = 'Nivel del codec (4.0|4.1|5.0|...); se ignora si no aplica'
        'customProfile/qmin'        = 'Q minimo del control de tasa en NVENC (0-51)'
        'customProfile/qmax'        = 'Q maximo del control de tasa en NVENC (0-51)'
        'customProfile/crf'         = 'CRF por defecto en encoders de CPU (0-51); -1 = auto'
        'customProfile/detectBorder'= 'Deteccion de bordes por defecto: false | true | auto'
        'customProfile/changeSize'  = 'Reescalado fijo por defecto ("" = no; ej "1920:-2")'
        'customProfile/noUpscale'   = 'changeSize SOLO reduce: no amplia videos mas pequeños que el destino (true/false)'
        'customProfile/maxWidth'    = 'Ancho maximo por defecto (0 = no; ej 1920 reduce solo si es mayor)'
        'customProfile/multipass'   = '2-pass NVENC del perfil custom: off | qres | fullres'
        'customProfile/audioEncoder'= 'Audio por defecto: aac_coder (recodificar) | copy'
        'customProfile/audioCodec'  = 'Codec de audio: aac|ac3|eac3|libmp3lame|flac|libopus'
        'customProfile/audioBitrate'= "Bitrate de audio ('copy' = copiar sin recodificar)"
        'customProfile/audioHz'     = 'Frecuencia de audio por defecto (Hz); opus fuerza 48000'
        'customProfile/audioChannels'= 'Canales de salida por defecto (MAXIMO, no upmix): 2 | 6 | 8'
        'customProfile/downmixMode' = 'Downmix 5.1->estereo por defecto: default | dialogue'
        'customProfile/downmixCoeffs'= 'Pesos del downmix dialogue por defecto (center/front/surround)'
        'customProfile/downmixCoeffs/center'  = 'Peso del canal central (dialogos) en el downmix dialogue'
        'customProfile/downmixCoeffs/front'   = 'Peso de los frontales L/R en el downmix dialogue'
        'customProfile/downmixCoeffs/surround'= 'Peso de los surrounds en el downmix dialogue (el LFE se descarta)'

        'encode/video/border'                    = '[av] Deteccion de bordes negros con cropdetect'
        'encode/video/border/start'              = 'Segundo del primer punto de escaneo'
        'encode/video/border/duration'           = 'Segundos que escanea CADA punto'
        'encode/video/border/samples'            = 'En cuantos puntos repartidos se escanea (1 = solo al inicio)'
        'encode/video/border/autoAcceptPct'      = '% de puntos que deben coincidir para auto-aceptar el recorte'
        'encode/video/border/autoAcceptMinMargin'= 'Votos de ventaja sobre el 2o para auto-aceptar (0 = sin margen)'
        'encode/video/border/autoSamples'        = "Puntos del pre-escaneo del modo 'auto' del perfil"
        'encode/video/border/autoMaxCropPct'     = "Tope de recorte que el modo 'auto' aplica solo (% de ancho/alto); mas que eso, se confirma"
        'encode/video/border/autoDuration'       = "Segundos por punto del pre-escaneo 'auto' (minimo real 5 s)"
        'encode/video/border/minCropPct'         = 'Reduccion minima (%) para considerar barras (menos = no recorta)'


        'preview'         = 'Previsualizacion con ffplay en PREPARAR'
        'preview/start'   = 'Segundo en que empieza la muestra (0 = desde el principio)'
        'preview/seconds' = 'Duracion de la muestra en seg (0 = sin limite, todo el video)'
        'preview/syncSeconds' = 'Tope (seg) del preview A/B de sincronia de audio (0 = sin limite, hasta el final o q/ESC)'
        'preview/player'         = "Reproducir un video desde la cola: 'start' = asociado de Windows | 'ffplay' = el de tools | 'external' = el .exe de playerExe"
        'preview/playerExe'      = 'Reproductor para player=external (ruta al .exe: VLC, MPC-HC...)'
        'preview/subtitleEditor' = "Ver texto de subtitulo ('V N'): 'start' = asociado de Windows | 'win' = ventana propia (WinForms) | 'external' = el .exe de subtitleEditorExe"
        'preview/subtitleEditorExe' = "Ruta al .exe para el modo 'external' de subtitleEditor (p. ej. Subtitle Edit, VS Code); ignorado en 'start'/'win'"

        'encode/audio/volume'             = 'Normalizacion de volumen del audio'
        'encode/audio/volume/method'      = ('Metodo: {0} (peak = legacy)' -f ((Get-CvVolumeMethodValues) -join ' | '))
        'encode/audio/volume/peakTarget'  = "Pico objetivo dBFS de 'peak' (LEGACY; 0 = maximo; -1 deja headroom)"
        'encode/audio/volume/loudnorm'    = '[av] Parametros EBU R128 del metodo loudnorm'
        'encode/audio/volume/loudnorm/I'  = 'Loudness integrada objetivo (LUFS), ej -16'
        'encode/audio/volume/loudnorm/TP' = 'True Peak maximo (dBTP), ej -1.5'
        'encode/audio/volume/loudnorm/LRA'= 'Rango de loudness objetivo (LU), ej 11'

        'postprocess'                    = 'Postproceso del MKV final'
        'postprocess/stripTags'          = 'Limpiar con mkvpropedit las etiquetas DURATION que anade ffmpeg'
        'postprocess/mkvpropedit'        = 'Ruta a mkvpropedit (vacio = usar la de tools\)'
        'postprocess/attachments'        = 'Conservar adjuntos del original (fuentes, caratulas...)'
        'postprocess/attachments/keep'   = 'Interruptor maestro: conservar adjuntos del original'
        'postprocess/attachments/fonts'  = 'Conservar fuentes (p. ej. para subtitulos ASS)'
        'postprocess/attachments/covers' = 'Conservar caratulas/imagenes'
        'postprocess/attachments/other'  = 'Conservar el resto de adjuntos'

        'behavior'                          = 'Comportamiento general del conversor'
        'behavior/cleanTemps'               = 'Borrar los temporales de Proceso\ al terminar cada archivo'
        'behavior/separateWindow'           = 'Lanzar cada codificacion en su propia ventana'
        'behavior/lockCloseButton'          = 'Desactivar el boton X mientras hay conversiones en marcha'
        'behavior/log'                      = 'Guardar log (transcript) de la sesion en logs\'
        'behavior/workers'                  = 'Codificaciones en paralelo al terminar PREPARAR (esta + N-1)'
        'behavior/retries'                  = 'Reintentos por archivo cuando la codificacion falla'
        'console/asciiMarks'                = 'Marcas en ASCII puro ([OK]/[ERROR]) en vez de simbolos'
        'behavior/progress'                 = 'Linea viva con % y ETA al recodificar (inline); false = ventana aparte + solo ✓'
        'behavior/promptTimeout'            = 'Auto-aceptar el valor por defecto en preguntas de PREPARAR tras N s de inactividad'
        'behavior/promptTimeout/default'    = 'Timeout generico en segundos (0 = desactivado)'
        'behavior/promptTimeout/sync'       = 'Timeout de la pregunta de sincronia (-1 = usar el generico)'
        'behavior/promptTimeout/border'     = 'Timeout de la pregunta de bordes (-1 = usar el generico)'
        'behavior/promptTimeout/animation'  = 'Timeout de la pregunta de animacion (-1 = usar el generico)'
        'behavior/promptTimeout/anamorphic' = 'Timeout de la pregunta de video anamorfico (-1 = generico; toma el modo configurado)'
        'behavior/promptTimeout/audioSync' = 'Timeout de la pregunta de audio adelantado (-1 = generico; al expirar aplica el retardo detectado)'
        'behavior/promptTimeout/video'      = 'Timeout del menu de seleccion de pista de video (-1 = generico; toma la preseleccionada)'
        'behavior/promptTimeout/audio'      = 'Timeout del menu de seleccion de pista de audio (-1 = generico; toma la preseleccionada)'
        'behavior/promptTimeout/subtitle'   = 'Timeout del menu de subtitulos fallback (-1 = generico; al expirar no conserva ninguno)'
        'behavior/promptTimeout/subtitleLang' = 'Timeout de la pregunta de idioma de los subtitulos elegidos (al expirar mantiene el idioma detectado; 0 = sin timeout)'
        'behavior/promptTimeoutStopOnType'  = 'Al teclear algo se desactiva el auto (solo ENTER envia); false = clasico (al expirar envia lo tecleado)'

        'debug'                 = '[av] Depuracion (log detallado; tambien se activa con el marcador debug_on)'
        'debug/enabled'         = 'Modo debug: log detallado (comandos ffmpeg, pasos internos) y codificacion en la ventana principal'
        'debug/pausePerCommand' = 'En debug, pedir ENTER antes de cada comando de ffmpeg; false = ejecutar sin pausar'

        'test'            = '[av] Modo pruebas (codificacion parcial para validar ajustes)'
        'test/enabled'    = "Activar modo pruebas: cada archivo solo se codifica hasta 'minutes' min"
        'test/minutes'    = 'Minutos que se codifican por archivo en modo pruebas (>=1)'
        'test/betaDownmix'= 'BETA: activa el downmix dialogue (voz reforzada); sin el, dialogue = downmix estandar'
        'test/betaOnePass'= 'BETA: audio+video+mux en una sola ejecucion de ffmpeg (solo encode+adelay+loudnorm, sin HDR)'

        'console'             = 'Apariencia de la ventana de consola'
        'console/background'  = 'Color de fondo de la consola'
        'console/foreground'  = 'Color de texto de la consola'
        'console/font'        = 'Fuente de la consola (ej Cascadia Code / Consolas)'
        'console/fontSize'    = 'Tamano de la fuente'
        'console/windowWidth' = 'Ancho de la ventana en columnas (0 = no cambiar)'
        'console/windowHeight'= 'Alto de la ventana en lineas (0 = no cambiar)'
        'console/sepWidth'    = 'Ancho (caracteres) de los separadores de seccion === / --- de la UI'
        'console/progressBarWidth' = 'Ancho (caracteres) de la barra visual de progreso del worker; 0 = sin barra'

        'gui'                   = 'Apariencia de las ventanas (Convert-gui / setup-gui)'
        'ui'                    = 'Interfaz: en que idioma te habla el programa'
        'ui/language'           = "Idioma de la interfaz: 'auto' (el de Windows) / 'es' / 'en'; NO es el idioma de las pistas (eso es 'languages')"

        'gui/theme'             = "Aspecto de las ventanas: 'system' (sigue a Windows) / 'light' / 'dark'"
        'gui/rememberLayout'    = 'Recordar como queda la ventana de la cola al cerrarla (en <config>.gui.json, donde tambien se cachea lo deducido de los bordes)'
        'gui/confirmCloseWithWorkers' = 'Al cerrar la cola con workers codificando, preguntar que hacer (siguen vivos si no)'
        'gui/queueWidth'        = 'Ancho (px) de la ventana de la cola la primera vez'
        'gui/queueHeight'       = 'Alto (px) de la ventana de la cola la primera vez'
        'gui/queueRefreshMs'     = 'Cada cuantos ms se repinta el progreso mientras hay workers (no relee las carpetas)'
        'gui/queueIdleRefreshMs' = 'Cada cuantos ms se releen las carpetas sin nada en marcha (0 = solo cuando lo pidas)'
        'gui/queueRefreshOnActivate' = 'Releer las carpetas al volver a la ventana de la cola'
        'gui/queueFollowWorker'  = 'La lista se mueve sola para no perder de vista el archivo que se esta codificando (salvo si te has ido tu a otra parte)'
        'gui/queueStartGraceSec' = 'Segundos que se espera a que un worker recien abierto publique su estado (la cola sigue mirando en ese hueco)'
        'gui/queueFollowHoldSec' = 'Segundos que la lista se queda quieta despues de que la toques (no se mueve mientras eliges filas)'
        'gui/queueDoneProbe'     = 'Cuantos archivos YA CONVERTIDOS se analizan por refresco -solo con la cola parada- para deducir si llevaron recorte (0 = ninguno)'
        'gui/queueDoneTolerance' = 'Margen de proporcion (0.01 = 1%) para decidir que a un convertido se le quitaron barras'
        'gui/setupWidth'        = 'Ancho de partida de la ventana de setup (px)'
        'gui/setupHeight'       = 'Alto de partida de la ventana de setup (px)'
        'gui/queueSplitPercent' = 'Porcentaje del alto para la lista de la cola (el resto, resumen y log)'

        'paths'            = '[av] Carpetas de trabajo (vacio = junto al programa)'
        'paths/original'   = 'Carpeta de entrada (videos a convertir)'
        'paths/proceso'    = 'Carpeta de temporales durante la conversion'
        'paths/convertido' = 'Carpeta de salida (videos ya convertidos)'
        'paths/logs'       = 'Carpeta de logs de sesion'

        'profiles' = '[av] Perfiles propios (se anaden a los de serie); se crean desde setup > Perfiles propios o al ajustar un perfil'
        'defaultProfile' = "Perfil marcado al preparar: nombre de uno propio, 'Perfil N' de los de serie, o Auto"
    }
}

function Get-CvHelpFor {
    <#
        Ayuda de una opcion por su ruta ('seccion/clave'); '' si no hay entrada. Quita el marcador de
        opcion AVANZADA ('[av] ', ver Get-CvConfigAdvancedMark) si lo lleva: es metadato para el
        editor, no parte del texto que se enseña.
    #>
    param([string]$Path)
    $h = Get-CvConfigHelp
    if (-not $h.ContainsKey($Path)) { return '' }
    $t = "$($h[$Path])"
    $m = Get-CvConfigAdvancedMark
    if ($t.StartsWith($m)) { $t = $t.Substring($m.Length) }
    return $t
}

function Get-CvConfigDefaultValue {
    <#
        Valor POR DEFECTO (de Get-CvConfigDefaults) de una opcion, por su ruta con '/' ('seccion/clave',
        'seccion/sub/clave'). Devuelve $null si la ruta no existe. Lo usa el editor de setup para marcar
        el default real (no el valor actual). Los defaults son todo [ordered]@{}, asi que se navega por
        clave nivel a nivel.
    #>
    param([string]$Path)
    $node = Get-CvConfigDefaults
    foreach ($seg in ($Path -split '/')) {
        if ($node -isnot [System.Collections.IDictionary] -or -not $node.Contains($seg)) { return $null }
        $node = $node[$seg]
    }
    # Coma unaria: sin ella PowerShell DESENVUELVE un array de un solo elemento y el default de, por
    # ejemplo, downloads/ffmpeg/versionArgs (['-version']) salia como la cadena '-version'. Eso hacia
    # que toda lista de 1 elemento pareciera distinta del default (Test-CvCfgIsDefault compara la
    # serializacion JSON). Para un escalar el comportamiento no cambia (la tuberia lo desenvuelve).
    return ,$node
}

function ConvertTo-CvPromptTimeouts {
    <#
        Normaliza behavior.promptTimeout a un [ordered]@{ tipo = segundos(int) } con 'default'
        garantizado. Acepta un objeto (ordered/PSCustomObject) o el formato antiguo escalar (que se
        interpreta como el generico 'default'). Los tipos ausentes o -1 heredan de 'default' en
        tiempo de resolucion (Get-CvPromptTimeout), aqui solo se convierte a enteros.
    #>
    param($Node)
    $map = [ordered]@{ default = 0 }
    if ($null -eq $Node) { return $map }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { $map["$k"] = [int]$Node[$k] }
    }
    elseif ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) { $map["$($p.Name)"] = [int]$p.Value }
    }
    else {
        # formato antiguo: un solo numero = timeout generico
        $n = 0; if ([int]::TryParse("$Node", [ref]$n)) { $map['default'] = $n }
    }
    if (-not $map.Contains('default')) { $map['default'] = 0 }
    return $map
}

function Resolve-CvConfigPathArg {
    <#
        Resuelve el argumento -Config de Convert.ps1/setup.ps1 a una ruta completa:
        vacio = <Root>\config.json; relativo = respecto al directorio actual; absoluto = tal cual.
    #>
    param([Parameter(Mandatory)][string]$Root, [string]$Config = '')
    if ([string]::IsNullOrWhiteSpace($Config)) { return (Join-Path $Root 'config.json') }
    if ([System.IO.Path]::IsPathRooted($Config)) { return $Config }
    return (Join-Path (Get-Location).Path $Config)
}

function Get-CvConfig {
    <#
        Carga config.json (si existe) sobre los valores por defecto, por secciones.
        Cualquier clave ausente en el json usa el valor por defecto (fusion profunda).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        # Ruta explicita al config (parametro -Config de Convert/setup). Vacio = Root\config.json.
        [string]$Path = ''
    )
    $cfg = Get-CvConfigDefaults
    $path = if ([string]::IsNullOrWhiteSpace($Path)) { Join-Path $Root 'config.json' } else { $Path }
    if (Test-Path $path) {
        try {
            $json = Get-Content -Raw -Path $path | ConvertFrom-Json
            Merge-CvConfig -Default $cfg -Override $json
        } catch {
            Write-Host ("AVISO: config.json no valido, se usan valores por defecto ({0})" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    return $cfg
}

# ---------- ACCESO GENERICO A NODOS (PSCustomObject de ConvertFrom-Json e IDictionary) ----------

function Get-CvNodeKind($v) {
    if ($null -eq $v)                                        { return 'null' }
    if ($v -is [bool])                                       { return 'bool' }
    if ($v -is [string])                                     { return 'string' }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [single] -or $v -is [decimal]) { return 'number' }
    if ($v -is [System.Collections.IDictionary])             { return 'object' }
    if ($v -is [System.Management.Automation.PSCustomObject]){ return 'object' }
    if ($v -is [System.Collections.IEnumerable])             { return 'array' }
    return 'string'
}
function Get-CvNodeKeys($node) {
    if ($node -is [System.Collections.IDictionary]) { return @($node.Keys) }
    # Nota: en un PSCustomObject sin propiedades, .Name devuelve $null y @($null) daria una
    # clave fantasma; filtramos nulos/vacios para que un objeto vacio de 0 claves.
    if ($node) { return @($node.PSObject.Properties.Name | Where-Object { -not [string]::IsNullOrEmpty($_) }) }
    return @()
}
function Get-CvNodeVal($node, $key) {
    # La coma unaria evita que PowerShell desenvuelva un array de 1 elemento al retornar.
    if ($node -is [System.Collections.IDictionary]) { return , $node[$key] }
    return , $node.$key
}
function Set-CvNodeVal($node, $key, $value) {
    if ($node -is [System.Collections.IDictionary]) { $node[$key] = $value }
    else { $node.$key = $value }
}

# ---------- SERIALIZADOR JSON PROPIO (4 espacios, arrays de escalares en linea) ----------

function ConvertTo-CvJsonString([string]$s) {
    $e = $s.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n').Replace("`t",'\t')
    return '"' + $e + '"'
}
function Format-CvNumber($n) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($n -is [double] -or $n -is [single] -or $n -is [decimal]) { return ([double]$n).ToString($inv) }
    return ([long]$n).ToString($inv)
}
function ConvertTo-CvJson {
    param($Node, [int]$Indent = 0)
    $pad  = '    ' * $Indent
    $pad1 = '    ' * ($Indent + 1)
    switch (Get-CvNodeKind $Node) {
        'object' {
            $keys = @(Get-CvNodeKeys $Node)
            if ($keys.Count -eq 0) { return '{}' }
            $parts = @()
            foreach ($k in $keys) {
                $parts += ('{0}{1}: {2}' -f $pad1, (ConvertTo-CvJsonString "$k"), (ConvertTo-CvJson (Get-CvNodeVal $Node $k) ($Indent + 1)))
            }
            return "{`n" + ($parts -join ",`n") + "`n$pad}"
        }
        'array' {
            $items = @($Node)
            if ($items.Count -eq 0) { return '[]' }
            $allScalar = $true
            $nodeKinds = @(
                'object'
                'array'
            )
            foreach ($it in $items) { if ((Get-CvNodeKind $it) -in $nodeKinds) { $allScalar = $false; break } }
            if ($allScalar) {
                $vals = foreach ($it in $items) { ConvertTo-CvJson $it 0 }
                return '[' + ($vals -join ', ') + ']'
            }
            $parts = foreach ($it in $items) { $pad1 + (ConvertTo-CvJson $it ($Indent + 1)) }
            return "[`n" + ($parts -join ",`n") + "`n$pad]"
        }
        'bool'   { if ($Node) { return 'true' } else { return 'false' } }
        'number' { return (Format-CvNumber $Node) }
        'null'   { return 'null' }
        default  { return (ConvertTo-CvJsonString "$Node") }
    }
}

# ---------- APLICAR SOLO LOS CAMBIOS (para que el editor no reescriba todo config.json) ----------

function Get-CvChildNode {
    <# Devuelve el subnodo objeto $Node[$Key]; si no existe (o no es objeto) lo crea vacio. #>
    param($Node, [string]$Key)
    if ($Node -is [System.Collections.IDictionary]) {
        if (-not $Node.Contains($Key) -or (Get-CvNodeKind $Node[$Key]) -ne 'object') { $Node[$Key] = [ordered]@{} }
        return $Node[$Key]
    }
    if (-not $Node.PSObject.Properties[$Key]) { $Node | Add-Member -NotePropertyName $Key -NotePropertyValue ([pscustomobject]@{}) -Force }
    elseif ((Get-CvNodeKind $Node.$Key) -ne 'object') { $Node.$Key = [pscustomobject]@{} }
    return $Node.$Key
}

function Set-CvChildLeaf {
    <# Fija $Node[$Key] = $Value, creando la propiedad si falta (PSCustomObject o IDictionary). #>
    param($Node, [string]$Key, $Value)
    if ($Node -is [System.Collections.IDictionary]) { $Node[$Key] = $Value; return }
    if ($Node.PSObject.Properties[$Key]) { $Node.$Key = $Value }
    else { $Node | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
}

function Remove-CvChild {
    <# Elimina la clave $Key de $Node (PSCustomObject o IDictionary). #>
    param($Node, [string]$Key)
    if ($Node -is [System.Collections.IDictionary]) { if ($Node.Contains($Key)) { $Node.Remove($Key) }; return }
    if ($Node.PSObject.Properties[$Key]) { $Node.PSObject.Properties.Remove($Key) }
}

function Get-CvConfigAdvancedMark {
    <#
        Marcador que declara una opcion como AVANZADA. Va al PRINCIPIO de su texto en el catalogo de
        ayuda (Get-CvConfigHelp), que ya es el registro por-opcion: asi el nivel se define JUNTO a la
        opcion y no hace falta una lista paralela de rutas que se desincronice al renombrar algo.
        Get-CvHelpFor lo quita (nadie lo ve) y Test-CvConfigAdvanced lo lee.
    #>
    '[av] '
}

function Test-CvConfigAdvanced {
    <#
        $true si esa ruta del config esta marcada como AVANZADA en el catalogo de ayuda. Comparacion
        EXACTA de la ruta: quien oculta el subarbol entero es el llamador (el editor), que al topar
        con una rama avanzada no baja por ella.
    #>
    param([string]$Path)
    $h = Get-CvConfigHelp
    if (-not $h.ContainsKey("$Path")) { return $false }
    return ("$($h["$Path"])").StartsWith((Get-CvConfigAdvancedMark))
}

function Get-CvConfigAdvancedPaths {
    <# Rutas marcadas como avanzadas, DERIVADAS del catalogo de ayuda (no es una segunda lista: se
       calcula). Util para documentar y para los tests. #>
    @(Get-CvConfigHelp).Keys | Where-Object { Test-CvConfigAdvanced -Path $_ } | Sort-Object
}

function Test-CvCfgIsDefault {
    <#
        PURO. $true si el valor de una clave es EL DE FABRICA. Compara por serializacion JSON, la
        MISMA regla con la que Update-CvConfigEdits decide si una clave se guarda en el fichero o se
        borra de el: asi lo que el editor resalta como "editado" es exactamente lo que acabara
        escrito en config.json, sin criterios paralelos que se desincronicen.
        Un valor presente cuyo default es $null (clave que no existe de fabrica) cuenta como NO default.
    #>
    param($Value, $Default)
    return ((ConvertTo-CvJson $Value 0) -eq (ConvertTo-CvJson $Default 0))
}

function Update-CvConfigEdits {
    <#
        Aplica en $Target (config.json crudo) SOLO las hojas que cambiaron entre $Before y $Edited:
          - si el nuevo valor es IGUAL al default -> se ELIMINA de $Target (se usara el default).
          - si DIFIERE del default                -> se fija en $Target.
        Las hojas no editadas no se tocan (un config completo conserva lo no editado). Las
        secciones que quedan vacias tras eliminar se podan. Compara por serializacion JSON.
    #>
    param($Edited, $Before, $Default, $Target)
    $bkeys = @(Get-CvNodeKeys $Before)
    $dkeys = @(Get-CvNodeKeys $Default)
    foreach ($key in @(Get-CvNodeKeys $Edited)) {
        $ev = Get-CvNodeVal $Edited $key
        $bv = if ($bkeys -contains $key) { Get-CvNodeVal $Before $key } else { $null }
        # sin cambios respecto al inicio de la edicion -> no tocar
        if (($bkeys -contains $key) -and ((ConvertTo-CvJson $ev 0) -eq (ConvertTo-CvJson $bv 0))) { continue }

        $dv = if ($dkeys -contains $key) { Get-CvNodeVal $Default $key } else { $null }

        if ((Get-CvNodeKind $ev) -eq 'object' -and (Get-CvNodeKind $bv) -eq 'object') {
            # seccion con cambios dentro: recursar y podar si queda vacia
            $tchild = Get-CvChildNode -Node $Target -Key $key
            Update-CvConfigEdits -Edited $ev -Before $bv -Default $dv -Target $tchild
            if (@(Get-CvNodeKeys $tchild).Count -eq 0) { Remove-CvChild -Node $Target -Key $key }
        }
        elseif (($dkeys -contains $key) -and ((ConvertTo-CvJson $ev 0) -eq (ConvertTo-CvJson $dv 0))) {
            Remove-CvChild -Node $Target -Key $key      # volvio al default -> quitar del json
        }
        else {
            Set-CvChildLeaf -Node $Target -Key $key -Value $ev   # distinto del default -> guardar
        }
    }
}

# ---------- LECTURA / ESCRITURA DE config.json ----------

function Repair-CvConfigArrays($cfg) {
    <#
        PS 5.1 ConvertFrom-Json desenvuelve los arrays de 1 elemento a escalar (["es"] -> "es").
        Forzamos a array los campos que del esquema deben serlo (se editan como lista / [...] ).
    #>
    if ($cfg.languages) {
        if ($null -ne $cfg.languages.audio)    { $cfg.languages.audio    = @($cfg.languages.audio) }
        if ($null -ne $cfg.languages.subtitle) { $cfg.languages.subtitle = @($cfg.languages.subtitle) }
    }
    if ($cfg.downloads) {
        foreach ($p in $cfg.downloads.PSObject.Properties) {
            $app = $p.Value
            if ($null -ne $app.files)       { $app.files       = @($app.files) }
            if ($null -ne $app.versionArgs) { $app.versionArgs = @($app.versionArgs) }
            if ($null -ne $app.dependsOn)   { $app.dependsOn   = @($app.dependsOn) }
        }
    }
    if ($cfg.PSObject.Properties['profiles'] -and $null -ne $cfg.profiles) { $cfg.profiles = @($cfg.profiles) }
    if ($cfg.encode -and $null -ne $cfg.encode.extensions) { $cfg.encode.extensions = @($cfg.encode.extensions) }
    if ($cfg.encode -and $cfg.encode.subtitles -and $null -ne $cfg.encode.subtitles.toSrt) { $cfg.encode.subtitles.toSrt = @($cfg.encode.subtitles.toSrt) }
}
function Read-CvConfigFile {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Read-CvJsonFile -Path $Path
    Repair-CvConfigArrays $cfg
    return $cfg
}
function Save-CvConfigFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    # El JSON lo monta el formateador propio (ConvertTo-CvJson, que respeta el orden y la sangria
    # del fichero de configuracion); aqui solo se escribe. NO atomico: config.json no lo lee nadie
    # mientras se guarda, y un .tmp suelto en la raiz del programa se veria raro.
    $json = (ConvertTo-CvJson -Node $Config -Indent 0) -replace "`n", "`r`n"
    [void](Save-CvTextFile -Path $Path -Text ($json + "`r`n"))
}

function Set-CvConfigValue {
    <#
        Guarda UN valor suelto en el fichero de configuracion, sin tocar nada mas: -Key es la ruta
        con barras ('gui/theme'). Se escribe sobre el config CRUDO, asi que un config minimo sigue
        minimo y lo que no se toca se queda con su formato.

        Es lo que necesita una ventana para recordar una preferencia que se cambia desde ella (el
        tema, por ejemplo) sin montar el editor entero. Devuelve @{ Ok; Error }.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        # AllowEmptyString: una clave vacia se contesta con @{ Ok = $false }, no con una excepcion
        # (esta funcion INFORMA de los fallos, que es lo que espera quien la llama desde una ventana).
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        $Value
    )
    try {
        $cfg = $(if (Test-Path -LiteralPath $Path) { Read-CvConfigFile -Path $Path } else { Get-CvConfigDefaults })
        $partes = @("$Key" -split '/' | Where-Object { "$_" -ne '' })
        if ($partes.Count -eq 0) { return @{ Ok = $false; Error = 'clave vacia' } }
        # Get-CvChildNode CREA la seccion si falta, que es lo que hace falta aqui: un config minimo
        # puede no tener 'gui' todavia y aun asi se le puede guardar 'gui/theme'.
        $nodo = $cfg
        for ($i = 0; $i -lt ($partes.Count - 1); $i++) { $nodo = Get-CvChildNode -Node $nodo -Key $partes[$i] }
        Set-CvChildLeaf -Node $nodo -Key $partes[-1] -Value $Value
        Save-CvConfigFile -Path $Path -Config $cfg
        return @{ Ok = $true; Error = '' }
    } catch {
        return @{ Ok = $false; Error = "$($_.Exception.Message)" }
    }
}

function Reset-CvConfig {
    <#
        Restablece config.json a los valores por defecto, CONSERVANDO el catalogo de
        herramientas (seccion 'downloads' del config actual). Hace copia en <Path>.bak.
        Devuelve $true.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force } catch {}
        try {
            $cur = Read-CvConfigFile -Path $Path
        } catch { $cur = $null }
    }
    $def = Get-CvConfigDefaults
    if ($cur -and $cur.downloads) { $def['downloads'] = $cur.downloads }   # preservar herramientas
    Save-CvConfigFile -Path $Path -Config $def
    return $true
}

Export-ModuleMember -Function *
