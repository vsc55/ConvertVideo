<#
    Context.psm1 - Contexto de ejecucion (rutas, herramientas y opciones desde config.json)
    y helpers de contexto (idiomas, parseo de numeros invariante).
#>

function Get-CvVersion {
    <# Version del proyecto (fuente unica; la usan Convert.ps1 y setup.ps1). #>
    '4.5.2'
}

function Get-CvAppName {
    <# Nombre del proyecto/aplicacion (fuente unica: titulos de ventana, cabecera). #>
    'ConvertVideo'
}

function Start-CvSession {
    <#
        Arranque COMUN de Convert.ps1 y setup.ps1 (evita duplicar la secuencia y desincronizar el
        orden): resuelve el -Config (avisa si la ruta indicada no existe), crea el contexto, fija las
        marcas ASCII, arranca el transcript y aplica apariencia (titulo = "<AppName> <Version><Suffix>")
        y cabecera. Devuelve @{ Context; ConfigPath; LogFile }. El bootstrap (encoding + Import-Module)
        se queda en cada script por ser previo a que existan estas funciones.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Config = '',        # argumento -Config (vacio = Root\config.json)
        [string]$TitleSuffix = '',   # p. ej. ' - Setup' para el titulo de ventana
        [string]$Subtitle = '',      # subtitulo de la cabecera (p. ej. 'Setup')
        [string]$LogPrefix = 'app'   # prefijo del fichero de transcript en logs\
    )
    $cfgPath = Resolve-CvConfigPathArg -Root $Root -Config $Config
    if (-not [string]::IsNullOrWhiteSpace($Config) -and -not (Test-Path -LiteralPath $cfgPath)) {
        Write-Host ("AVISO: no existe el config indicado ({0}); se usan los valores por defecto." -f $cfgPath) -ForegroundColor Yellow
    }
    $ctx = New-CvContext -Root $Root -ConfigPath $cfgPath
    Set-CvMarkStyle -Ascii $ctx.AsciiMarks     # [OK]/[ERROR] en vez de simbolos si console.asciiMarks
    Set-CvSepWidth -Width $ctx.SepWidth         # ancho de los separadores de seccion (config console.sepWidth)
    Set-CvProgressBarWidth -Width $ctx.ProgressBarWidth   # ancho de la barra de progreso (config console.progressBarWidth)
    Set-CvPromptStopOnType -Value $ctx.PromptStopOnType   # auto-timeout: desactivar al teclear (behavior.promptTimeoutStopOnType)
    $log = Start-CvLog -Context $ctx -Prefix $LogPrefix   # transcript a logs\ (antes de pintar, para capturarlo)
    Set-CvAppearance -Context $ctx -Title ("{0} {1}{2}" -f $ctx.AppName, $ctx.Version, $TitleSuffix)
    Show-CvHeader -Context $ctx -Subtitle $Subtitle
    [pscustomobject]@{
        Context    = $ctx
        ConfigPath = $cfgPath
        LogFile    = $log
    }
}

function Get-CvWorkDirs {
    <# Unica fuente de verdad de las carpetas de trabajo del proyecto (crear/comprobar). #>
    param([Parameter(Mandatory)]$Context)
    @($Context.Original, $Context.Proceso, $Context.Convertido, $Context.Tools, $Context.Logs)
}

function Resolve-CvPath {
    <#
        Resuelve una carpeta de trabajo desde config.json (seccion 'paths'):
        - vacio       -> por defecto en la carpeta del programa ($Root\<DefaultName>).
        - ruta absoluta (C:\..., D:\..., \\servidor\...) -> se usa tal cual.
        - ruta relativa -> relativa a $Root.
    #>
    param([string]$Root, [string]$Configured, [string]$DefaultName)
    if ([string]::IsNullOrWhiteSpace($Configured)) { return (Join-Path $Root $DefaultName) }
    if ([System.IO.Path]::IsPathRooted($Configured)) { return $Configured }
    return (Join-Path $Root $Configured)
}


function New-CvContext {
    <# Crea el objeto de contexto con rutas, herramientas y opciones (de config.json). #>
    param(
        [Parameter(Mandatory)][string]$Root,
        # Ruta explicita al config (parametro -Config de Convert/setup). Vacio = Root\config.json.
        [string]$ConfigPath = ''
    )

    $cfgFile = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $Root 'config.json' } else { $ConfigPath }
    $cfg = Get-CvConfig -Root $Root -Path $cfgFile
    # Defaults (fuente unica): se usan como fallback cuando un valor de $cfg es INVALIDO (no cuando
    # falta, que ya lo cubre la fusion de Get-CvConfig). Asi los numeros/opciones por defecto viven
    # SOLO en Get-CvConfigDefaults y no se re-hardcodean aqui.
    $def = Get-CvConfigDefaults
    $plat  = Get-CvPlatform
    $ffSel = "$($cfg.downloads.ffmpeg.selected)"
    $agSel = "$($cfg.downloads.aacgain.selected)"

    $ctx = [pscustomobject]@{
        Root           = $Root
        # Fichero de config en uso (Root\config.json por defecto, o el pasado con -Config).
        ConfigPath     = $cfgFile
        Version        = Get-CvVersion
        AppName        = Get-CvAppName
        # Carpetas de trabajo (configurables en config.json 'paths'; vacio = junto al programa).
        Original       = Resolve-CvPath $Root "$($cfg.paths.original)"   'Original'
        Proceso        = Resolve-CvPath $Root "$($cfg.paths.proceso)"    'Proceso'
        Convertido     = Resolve-CvPath $Root "$($cfg.paths.convertido)" 'Convertido'
        Logs           = Resolve-CvPath $Root "$($cfg.paths.logs)"       'logs'
        Tools          = Join-Path $Root 'tools'
        # Rutas de herramientas: las rellena New-CvToolContext mas abajo (fuente unica de
        # los nombres de exe), apuntando a la version 'selected'.
        FFmpeg         = $null
        FFprobe        = $null
        FFplay         = $null
        AacGain        = $null
        FFmpegVersion  = $ffSel
        AacGainVersion = $agSel
        Platform       = $plat
        Downloads      = $cfg.downloads
        VolumeMethod   = "$($cfg.encode.audio.volume.method)"
        # Pico objetivo (dBFS) del metodo 'peak'; se limita a <= 0 (positivo recortaria).
        PeakTarget     = [Math]::Min(0.0, [double]$cfg.encode.audio.volume.peakTarget)
        LoudnormI      = $cfg.encode.audio.volume.loudnorm.I
        LoudnormTP     = $cfg.encode.audio.volume.loudnorm.TP
        LoudnormLRA    = $cfg.encode.audio.volume.loudnorm.LRA
        OutExt         = "$($cfg.encode.outputExtension)"
        Threads        = [int]$cfg.encode.threads
        Fps            = "$($cfg.encode.video.fps)"
        # Forzar el fps de salida (-r). $true = como hasta ahora; $false = conserva el fps de origen.
        ForceFps       = [bool]$cfg.encode.video.forceFps
        # 2-pass de NVENC (-multipass): 'off'|'qres'|'fullres'. Solo lo usan los encoders NVENC.
        Multipass      = (Resolve-CvOneOf "$($cfg.encode.video.multipass)" @('off','qres','fullres') "$($def.encode.video.multipass)")
        # Tone-mapping HDR->SDR (BT.709): 'auto' = solo si el origen es HDR; 'off' = nunca.
        TonemapHdr     = (Resolve-CvOneOf "$($cfg.encode.video.tonemapHdr)" @(Get-CvTonemapHdrModes | ForEach-Object { $_.Value }) "$($def.encode.video.tonemapHdr)")
        # Curva de tone-mapping de libplacebo (config encode.video.tonemapCurve); si viene vacia, el
        # default de config. La consume Get-CvVideoFilterChain al construir el filtro libplacebo.
        TonemapCurve    = $(if ("$($cfg.encode.video.tonemapCurve)" -ne '') { "$($cfg.encode.video.tonemapCurve)" } else { "$($def.encode.video.tonemapCurve)" })
        # Video anamorfico (SAR!=1): 'keep' = conserva SAR; 'square'/'squareheight' = cuadra a pixeles
        # cuadrados (fijando ancho/alto). Lo consume Get-CvResize al decidir el reescalado.
        Anamorphic     = (Resolve-CvOneOf "$($cfg.encode.video.anamorphic)" @(Get-CvAnamorphicModes | ForEach-Object { $_.Value }) "$($def.encode.video.anamorphic)")
        # Tuning del encoder de video (fuente unica encode.video.tuning; lo consume Get-VideoArgs):
        # preset por familia, rc-lookahead (NVENC), refs (x264/x265) y tier (hevc_nvenc).
        PresetNvenc    = "$($cfg.encode.video.tuning.presetNvenc)"
        PresetX26x     = "$($cfg.encode.video.tuning.presetX26x)"
        PresetSvtav1   = "$($cfg.encode.video.tuning.presetSvtav1)"
        PresetAv1Nvenc = "$($cfg.encode.video.tuning.presetAv1Nvenc)"
        RcLookahead    = [int]$cfg.encode.video.tuning.rcLookahead
        Refs           = [int]$cfg.encode.video.tuning.refs
        Tier           = "$($cfg.encode.video.tuning.tier)"
        # Downmix 5.1->estereo: 'dialogue' = voz reforzada (pan); 'default' = downmix estandar.
        DownmixMode    = (Resolve-CvOneOf "$($cfg.encode.audio.downmixMode)" @('default','dialogue') "$($def.encode.audio.downmixMode)")
        # Pesos del downmix 'dialogue' (center/front/surround); el pan se construye de estos valores.
        # Del JSON llegan como numero; el cast [double] de PowerShell es invariante de locale. Con la
        # clave ausente (null) se usa el default de Get-CvDefaultDownmixCoeffs (fuente unica de los
        # numeros, sin repetirlos aqui). El LFE siempre se descarta.
        DownmixCoeffs  = $(
            $d = Get-CvDefaultDownmixCoeffs
            @{
                Center   = $(if ($null -ne $cfg.encode.audio.downmixCoeffs.center)   { [double]$cfg.encode.audio.downmixCoeffs.center }   else { $d.Center })
                Front    = $(if ($null -ne $cfg.encode.audio.downmixCoeffs.front)    { [double]$cfg.encode.audio.downmixCoeffs.front }    else { $d.Front })
                Surround = $(if ($null -ne $cfg.encode.audio.downmixCoeffs.surround) { [double]$cfg.encode.audio.downmixCoeffs.surround } else { $d.Surround })
            }
        )
        # Coder del encoder AAC nativo (twoloop = mayor calidad). Fuente unica encode.audio.aacCoder.
        AacCoder       = "$($cfg.encode.audio.aacCoder)"
        DefaultAudioHz = [int]$cfg.encode.audio.hz
        BorderStart    = [int]$cfg.encode.video.border.start
        BorderDur      = [int]$cfg.encode.video.border.duration
        # Nº de puntos del video donde se escanean bordes (1 = solo al inicio, clasico).
        BorderSamples  = [int]$cfg.encode.video.border.samples
        # % de votos que debe alcanzar el recorte mas votado para aceptarse sin preguntar (0-100).
        BorderAutoAcceptPct = [Math]::Min(100, [Math]::Max(0, [int]$cfg.encode.video.border.autoAcceptPct))
        # Margen minimo de votos del mas votado sobre el 2o para auto-aceptar (ademas del %).
        BorderAutoAcceptMargin = [Math]::Max(0, [int]$cfg.encode.video.border.autoAcceptMinMargin)
        # Modo DetectBorder='auto': puntos/seg del pre-escaneo y reduccion minima (%) para tomar el
        # recorte como barras reales (por debajo = ruido de borde -> no recorta).
        BorderAutoSamples = [Math]::Max(1, [int]$cfg.encode.video.border.autoSamples)
        BorderAutoDuration = [Math]::Max(1, [int]$cfg.encode.video.border.autoDuration)
        BorderMinCropPct  = [Math]::Max(0.0, [double]$cfg.encode.video.border.minCropPct)   # 0.0 (no 0) para forzar el overload double y no truncar un valor fraccionario
        # Previsualizacion ffplay: inicio (0 = principio) y duracion de la muestra (0 = sin limite).
        PreviewStart   = [Math]::Max(0, [int]$cfg.preview.start)
        PreviewSeconds = [Math]::Max(0, [int]$cfg.preview.seconds)
        # Tope (seg) de cada preview de la comparacion A/B de sincronia (Show-CvSyncPreview); 0 = SIN
        # limite (reproduce la fuente directa hasta el final o hasta q/ESC), como preview.seconds.
        PreviewSyncSeconds = [Math]::Max(0, [int]$cfg.preview.syncSeconds)
        AudioLangs     = @($cfg.languages.audio)
        SubLangs       = @($cfg.languages.subtitle)
        # debug: desde config.json (seccion 'debug') o creando el marcador 'debug_on' (cualquiera lo
        # activa). DebugPausePerCommand: en debug, pedir ENTER antes de cada comando de ffmpeg (lo usa
        # Exec); solo aplica si Debug esta activo.
        Debug          = ([bool]$cfg.debug.enabled -or (Test-Path (Join-Path $Root 'debug_on')))
        DebugPausePerCommand = [bool]$cfg.debug.pausePerCommand
        # cleanTemps/separateWindow salen de config.json; los marcadores 'keep_temp' y
        # 'same_window' los desactivan sobre la marcha sin editar el json.
        CleanTemps     = ([bool]$cfg.behavior.cleanTemps     -and -not (Test-Path (Join-Path $Root 'keep_temp')))
        SeparateWindow = ([bool]$cfg.behavior.separateWindow -and -not (Test-Path (Join-Path $Root 'same_window')))
        LockClose      = [bool]$cfg.behavior.lockCloseButton
        # Workers en paralelo por defecto al terminar PREPARAR (esta ventana + N-1 nuevas).
        Workers        = [int]$cfg.behavior.workers
        # Reintentos por archivo cuando la codificacion falla (antes de abandonarlo).
        Retries        = [int]$cfg.behavior.retries
        # Marcas/avisos en ASCII puro ([OK]/[ERROR]) en vez de simbolos/badge (consolas sin glifos).
        AsciiMarks     = [bool]$cfg.console.asciiMarks
        # Progreso inline (% + ETA) en los pasos largos de recodificacion en vez de ventana aparte.
        Progress       = [bool]$cfg.behavior.progress
        # Timeout de inactividad (seg) en las preguntas simples de PREPARAR: mapa {tipo -> segundos}
        # normalizado desde behavior.promptTimeout. 'default' es el generico; los tipos con -1 heredan
        # de 'default'. Lo resuelve Get-CvPromptTimeout $Context <tipo>. Tolera el formato antiguo
        # (escalar) tratandolo como el generico. 0 = desactivado.
        PromptTimeouts = (ConvertTo-CvPromptTimeouts $cfg.behavior.promptTimeout)
        # Al teclear en una pregunta con auto: $true desactiva el auto (solo ENTER); $false = clasico.
        PromptStopOnType = [bool]$cfg.behavior.promptTimeoutStopOnType
        # Modo pruebas: limite de codificacion por archivo en SEGUNDOS (0 = off = archivo completo).
        # Se activa por config (test.enabled) o con el marcador 'test_on'; los minutos salen de
        # test.minutes (>=1). Lo consumen Invoke-VideoRun/Invoke-AudioRun/Invoke-Multiplex (-t).
        TestLimit      = $(if (([bool]$cfg.test.enabled) -or (Test-Path (Join-Path $Root 'test_on'))) {
                              [int]([Math]::Max(1, [int]$cfg.test.minutes) * 60)
                          } else { 0 })
        # Sincronia con el filtro 'adelay' en una pasada (combinada con el volumen), sin WAV intermedio.
        # $true (por defecto) = adelay; $false = metodo clasico (WAV). Config encode.syncAdelay. Lo
        # consume Invoke-AudioRun.
        SyncAdelay     = [bool]$cfg.encode.audio.syncAdelay
        # BETA: activador del downmix 'dialogue' (voz reforzada). Doble llave: DownmixMode='dialogue'
        # fija el modo, pero solo refuerza la voz si BetaDownmix. Config test.betaDownmix; lo usa
        # Invoke-AudioRun junto con DownmixMode.
        BetaDownmix    = [bool]$cfg.test.betaDownmix
        # BETA: ejecucion en UNA sola pasada de ffmpeg (audio+video+mux fundidos). Config test.betaOnePass;
        # lo consumen Test-CvOnePassEligible/Invoke-CvOnePass (lib/OnePass.psm1) desde el worker. Off por
        # defecto: solo aplica en encode+encode con sincronia adelay, volumen loudnorm y sin HDR.
        BetaOnePass    = [bool]$cfg.test.betaOnePass
        # Multipista de audio (conservar varias pistas del idioma preferido + elegir la default).
        # Toggle encode.multiAudio ($true por defecto). Lo consumen Invoke-AudioAsk (seleccion) y el
        # worker/Multiplex (varias pistas). Con $false = monopista (elige una).
        MultiAudio     = [bool]$cfg.encode.audio.multiAudio
        # Filtros del perfil Auto (opcion A de USAR PERFIL). AutoGpuOnly: Auto solo considera encoders
        # GPU. AutoMaxCodec: tope de codec ('' sin tope | h264 | h265 | av1). Los consume New-CvAutoProfile.
        AutoGpuOnly    = [bool]$cfg.encode.video.auto.gpuOnly
        AutoMaxCodec   = (Resolve-CvOneOf "$($cfg.encode.video.auto.maxCodec)" @(Get-CvMaxCodecOptions | ForEach-Object { $_.Value }) '')
        # Control de tasa del perfil Auto (fuente unica en config.json encode.auto; lo consume
        # Get-CvAutoRate): CRF para CPU (H.26x / AV1), Qmin/Qmax + level para NVENC.
        AutoCrf        = [int]$cfg.encode.video.auto.crf
        AutoCrfAv1     = [int]$cfg.encode.video.auto.crfAv1
        AutoQmin       = [int]$cfg.encode.video.auto.qmin
        AutoQmax       = [int]$cfg.encode.video.auto.qmax
        AutoLevel      = "$($cfg.encode.video.auto.level)"
        # Control de calidad de la salida vs origen tras codificar: off | ssim | vmaf. Lo consume el
        # worker (Measure-CvQuality) tras un encode con exito (no en 'copy').
        QualityCheck   = (Resolve-CvOneOf "$($cfg.encode.video.qualityCheck)" @(Get-CvQualityCheckModes | ForEach-Object { $_.Value }) 'off')
        # Umbral (seg) para detectar audio adelantado (acaba antes que el video); 0 = off. Lo usa
        # Invoke-AudioAsk para avisar/preguntar el retardo. Ver encode.audioSyncThreshold.
        AudioSyncThreshold = [double]([Math]::Max(0.0, [double]$cfg.encode.audio.syncThreshold))
        # Conservar el titulo del audio de origen en la salida (false = titulo en blanco). Lo aplica
        # Invoke-Multiplex leyendo el titulo del origen por el indice de cada pista.
        AudioKeepTitle = [bool]$cfg.encode.audio.keepTitle
        # Tipos de subtitulo (por codec) a convertir a SRT (encode.subtitles.toSrt); en minusculas para
        # comparar sin distinguir mayusculas. El WEBVTT ilegible de un MKV se rescata con mkvextract.
        SubtitlesToSrt = @($(if ($cfg.encode.subtitles -and $null -ne $cfg.encode.subtitles.toSrt) { @($cfg.encode.subtitles.toSrt) | ForEach-Object { "$_".ToLower() } } else { @() }))
        # log: transcript de la ejecucion a logs\; el marcador 'no_log' lo desactiva.
        Log            = ([bool]$cfg.behavior.log -and -not (Test-Path (Join-Path $Root 'no_log')))
        # Postproceso: limpiar las etiquetas DURATION del MKV con mkvpropedit.
        # MkvPropEdit lo rellena New-CvToolContext: override de config o la version descargada.
        StripTags           = [bool]$cfg.postprocess.stripTags
        MkvPropEditOverride = "$($cfg.postprocess.mkvpropedit)"
        MkvPropEdit         = ''
        # mkvextract (misma version de mkvtoolnix): rescata subtitulos que ffmpeg no puede leer.
        MkvExtract          = ''
        # Conservacion de adjuntos (por defecto ninguno). Permitir/excluir por categoria.
        Attachments         = [pscustomobject]@{
            Keep   = [bool]$cfg.postprocess.attachments.keep
            Fonts  = [bool]$cfg.postprocess.attachments.fonts
            Covers = [bool]$cfg.postprocess.attachments.covers
            Other  = [bool]$cfg.postprocess.attachments.other
        }
        ConsoleBackground = "$($cfg.console.background)"
        ConsoleForeground = "$($cfg.console.foreground)"
        ConsoleFont       = "$($cfg.console.font)"
        ConsoleFontSize   = [int]$cfg.console.fontSize
        WindowWidth       = [int]$cfg.console.windowWidth
        WindowHeight      = [int]$cfg.console.windowHeight
        # Ancho de los separadores de seccion (=== / ---) de la UI; lo aplica Set-CvSepWidth al arrancar.
        SepWidth          = [Math]::Max(1, [int]$cfg.console.sepWidth)
        # Ancho de la barra visual de progreso del worker (0 = sin barra); lo aplica Set-CvProgressBarWidth.
        ProgressBarWidth  = [Math]::Max(0, [int]$cfg.console.progressBarWidth)
        # Extensiones de ENTRADA (config encode.extensions): se normalizan a patron glob '*.ext'
        # (tolera que el usuario las escriba con o sin '*.'/'.').
        Extensions     = @(@($cfg.encode.extensions) | Where-Object { "$_" -ne '' } | ForEach-Object { '*.' + ("$_".TrimStart('*').TrimStart('.')) })
        # Canales del audio recodificado (encode.audioChannels; 2 = estereo por defecto).
        AudioChannels  = $(if ([int]$cfg.encode.audio.channels -ge 1) { [int]$cfg.encode.audio.channels } else { [int]$def.encode.audio.channels })
        # Perfiles de codificacion propios (config 'profiles'); se anaden a los de serie.
        Profiles       = @($cfg.profiles)
        # Valores por defecto del constructor de perfil CUSTOM interactivo (config 'customProfile').
        CustomVideoEncoder = "$($cfg.customProfile.videoEncoder)"
        CustomVideoProfile = "$($cfg.customProfile.videoProfile)"
        CustomVideoLevel   = "$($cfg.customProfile.videoLevel)"
        # Defaults del control de tasa: NEGATIVO (p. ej. -1) => $null = "auto" (sin -qmin/-qmax ni
        # -crf; decide el encoder); el resto se acota a 0-51 (escala QP de H.264/HEVC y CRF x264/x265).
        CustomQmin         = $(if ([int]$cfg.customProfile.qmin -lt 0) { $null } else { [Math]::Min(51, [int]$cfg.customProfile.qmin) })
        CustomQmax         = $(if ([int]$cfg.customProfile.qmax -lt 0) { $null } else { [Math]::Min(51, [int]$cfg.customProfile.qmax) })
        CustomCrf          = $(if ([int]$cfg.customProfile.crf  -lt 0) { $null } else { [Math]::Min(51, [int]$cfg.customProfile.crf) })
        CustomMultipass    = (Resolve-CvOneOf "$($cfg.customProfile.multipass)" @('off','qres','fullres') "$($def.customProfile.multipass)")
        CustomAudioBitrate = "$($cfg.customProfile.audioBitrate)"
        CustomAudioCodec   = "$($cfg.customProfile.audioCodec)"
        # Semillas restantes del builder custom (paridad con profiles[]): deteccion de bordes (false|
        # true|'auto'), reescalado (changeSize/maxWidth), audio (encoder/hz/canales) y downmix (modo +
        # coeficientes). Los consume New-CustomProfile como default de cada pregunta.
        CustomDetectBorder = $(if ("$($cfg.customProfile.detectBorder)".ToLower() -eq 'auto') { 'auto' } else { [bool]$cfg.customProfile.detectBorder })
        CustomChangeSize   = "$($cfg.customProfile.changeSize)"
        CustomMaxWidth     = [int]$cfg.customProfile.maxWidth
        CustomAudioEncoder = "$($cfg.customProfile.audioEncoder)"
        CustomAudioHz      = [int]$cfg.customProfile.audioHz
        CustomAudioChannels = [int]$cfg.customProfile.audioChannels
        CustomDownmixMode  = (Resolve-CvOneOf "$($cfg.customProfile.downmixMode)" @('default','dialogue') "$($def.customProfile.downmixMode)")
        CustomDownmixCoeffs = $(
            $dd = Get-CvDefaultDownmixCoeffs
            @{
                Center   = $(if ($null -ne $cfg.customProfile.downmixCoeffs.center)   { [double]$cfg.customProfile.downmixCoeffs.center }   else { $dd.Center })
                Front    = $(if ($null -ne $cfg.customProfile.downmixCoeffs.front)    { [double]$cfg.customProfile.downmixCoeffs.front }    else { $dd.Front })
                Surround = $(if ($null -ne $cfg.customProfile.downmixCoeffs.surround) { [double]$cfg.customProfile.downmixCoeffs.surround } else { $dd.Surround })
            }
        )
    }

    # Rutas de las herramientas para la version 'selected' (fuente unica en New-CvToolContext).
    $ctx = New-CvToolContext -Context $ctx -FFmpegVersion $ffSel -AacGainVersion $agSel

    # Crear las carpetas de trabajo que falten (lista en Get-CvWorkDirs).
    foreach ($d in (Get-CvWorkDirs -Context $ctx)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    return $ctx
}


function Get-CvLangCanon {
    <#
        Canonicaliza un codigo de idioma a una forma unica, para que las distintas variantes
        (ISO 639-1 de 2 letras, ISO 639-2 de 3 letras y nombres) del MISMO idioma se comparen
        como iguales: 'es', 'spa', 'esp', 'es-ES', 'castellano', 'spanish' -> 'es'.
        Asi basta con tener UN codigo en la lista de preferidos para reconocer cualquier variante.
    #>
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return '' }
    $c = ($Code.Trim().ToLower() -split '[-_]')[0]   # parte principal (antes de '-' o '_')
    switch -Regex ($c) {
        '^(es|spa|esp|spanish|castellano|espanol)$'  { return 'es' }
        '^(en|eng|english)$'                         { return 'en' }
        '^(fr|fre|fra|french|frances)$'              { return 'fr' }
        '^(de|ger|deu|german|aleman)$'               { return 'de' }
        '^(it|ita|italian|italiano)$'                { return 'it' }
        '^(pt|por|portuguese|portugues)$'            { return 'pt' }
        '^(ja|jpn|japanese|japones)$'                { return 'ja' }
        '^(zh|chi|zho|chinese|chino)$'               { return 'zh' }
        '^(ko|kor|korean|coreano)$'                  { return 'ko' }
        '^(ru|rus|russian|ruso)$'                    { return 'ru' }
        '^(ca|cat|catalan)$'                         { return 'ca' }
        '^(gl|glg|galician|gallego)$'                { return 'gl' }
        '^(eu|baq|eus|basque|euskera|vasco)$'        { return 'eu' }
        default { return $c }
    }
}

function Get-CvSafeStart {
    <#
        Ajusta un segundo de inicio (scan de bordes, o el inicio explicito de una preview 'P N seg')
        a la duracion real del video: si el inicio configurado (p. ej. border.start = 120) cae fuera
        porque el video es mas corto, lo lleva a ~10% de la duracion para seguir dentro del contenido
        (dejando hueco para una ventana de $Window segundos). Duracion desconocida (<=0) = sin cambios.
    #>
    param([int]$Start, [double]$Duration, [int]$Window = 5)
    if ($Duration -le 0) { return $Start }
    if (($Start + $Window) -lt $Duration) { return $Start }
    return [int]([Math]::Max(0.0, [Math]::Floor($Duration * 0.1)))
}

function Test-CvLanguage {
    <#
        Compara un codigo de idioma con una lista de preferidos. Canonicaliza ambos lados
        (Get-CvLangCanon), de modo que 'es_es', 'es-ES', 'es' y 'spa' se consideran el mismo
        idioma AUNQUE la lista solo tenga uno de ellos. Tambien mantiene la comparacion por
        codigo completo y por parte principal (antes de '-' o '_') como respaldo.
    #>
    param([string]$Lang, [string[]]$Prefs)
    if ([string]::IsNullOrWhiteSpace($Lang) -or $null -eq $Prefs) { return $false }
    $l = $Lang.Trim().ToLower()
    $primary = ($l -split '[-_]')[0]
    $lc = Get-CvLangCanon $l
    foreach ($p in $Prefs) {
        if ($null -eq $p) { continue }
        $pp = $p.Trim().ToLower()
        $pprimary = ($pp -split '[-_]')[0]
        if ($l -eq $pp -or $primary -eq $pp -or $primary -eq $pprimary) { return $true }
        if ($lc -ne '' -and $lc -eq (Get-CvLangCanon $pp)) { return $true }
    }
    return $false
}


function ConvertTo-InvDouble {
    <# Parseo de decimales independiente del locale (ffmpeg usa siempre punto). #>
    param([string]$Text)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $out = 0.0
    if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, $inv, [ref]$out)) { return $out }
    return $null
}

function Get-CvFiles {
    <#
        Lista los ficheros de $Dir que casen con uno o varios -Filters (p. ej. '*.mkv','*.srt'); con
        -Recurse baja a subcarpetas. Devuelve FileInfo UNICOS ordenados por ruta; @() si el dir no existe.
        Fuente unica del "listar ficheros por extension/patron" (clasificacion de Original, limpieza de
        Proceso, selector de subtitulos).
          -Exact: endurece el match. El `-Filter` del proveedor hereda el comodin 8.3 de Windows
        ('*.mp4' tambien casa '.mp4v', '*.avi' casa '.avix'); con -Exact se re-comprueba cada resultado
        con `-like` (comparacion real de PowerShell, sin la trampa 8.3), asi el llamador no re-filtra.
    #>
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Filters = @('*'), [switch]$Recurse, [switch]$Exact)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $out = @()
    foreach ($f in $Filters) {
        $found = @(Get-ChildItem -LiteralPath $Dir -Filter $f -File -Recurse:$Recurse -ErrorAction SilentlyContinue)
        if ($Exact) { $found = @($found | Where-Object { $_.Name -like $f }) }
        $out += $found
    }
    @($out | Sort-Object -Property FullName -Unique)
}

function Get-CvTimeParts {
    <#
        Descompone unos segundos (double) en @{ H; M; S; MS } (milisegundos redondeados; negativo -> 0).
        Base comun de los formateadores de tiempo (Format-CvEta, ConvertTo-CvSrtStamp), cada uno con su
        propio formato de salida.
    #>
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ms = [long][math]::Round($Seconds * 1000)
    $h = [math]::Floor($ms / 3600000); $ms -= $h * 3600000
    $m = [math]::Floor($ms / 60000);   $ms -= $m * 60000
    $s = [math]::Floor($ms / 1000);    $ms -= $s * 1000
    @{
        H  = [int]$h
        M  = [int]$m
        S  = [int]$s
        MS = [int]$ms
    }
}


Export-ModuleMember -Function *
