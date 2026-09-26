<#
    unit-tests.ps1 - Tests UNITARIOS de las funciones puras (sin ffmpeg ni E2E).

    Complementa a run-tests.ps1 (que ejecuta el pipeline real sobre fixtures): aqui se comprueban
    en aislado los helpers deterministas (formato de tiempo, barra de progreso, separadores,
    normalizacion de timeouts/coeficientes, patrones de limpieza, fuentes unicas de defaults...),
    que no necesitan GPU ni ficheros y corren en < 1 s. Sirve de red de seguridad barata frente a
    regresiones al refactorizar.

    Uso:
      powershell -ExecutionPolicy Bypass -File test\unit-tests.ps1
    Sale con codigo 0 si todo pasa; 1 si falla algun caso (util para CI).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = Split-Path -Parent $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
$modules = @(
    'Log'
    'Io'
    'I18n'
    'Config'
    'Context'
    'Console'
    'Gui'
    'Exec'
    'Job'
    'JobCore'
    'WorkerCore'
    'Tools'
    'MediaInfo'
    'Profile'
    'Video'
    'Audio'
    'Subtitle'
    'SubtitleSRT'
    'Attachment'
    'Multiplex'
    'Render'
    'OnePass'
    'ConfigEditor'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# --- Mini-harness de asercion (sin dependencias externas) ---
$script:pass = 0
$script:fail = 0
function Assert-Eq {
    param([string]$Name, $Expected, $Actual)
    $e = if ($Expected -is [System.Array]) { ($Expected -join '|') } else { "$Expected" }
    $a = if ($Actual   -is [System.Array]) { ($Actual   -join '|') } else { "$Actual" }
    if ($e -ceq $a) {
        $script:pass++; Write-Host ("  [OK]    {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:fail++; Write-Host ("  [FALLO] {0}`n           esperado: <{1}>`n           obtenido: <{2}>" -f $Name, $e, $a) -ForegroundColor Red
    }
}
function Assert-True { param([string]$Name, $Cond) Assert-Eq $Name $true ([bool]$Cond) }

# ================================================================================================
Write-Host "`nFormat-CvEta (Exec)" -ForegroundColor Cyan
Assert-Eq 'negativo -> --:--'        '--:--'   (Format-CvEta -1)
Assert-Eq 'infinito -> --:--'        '--:--'   (Format-CvEta ([double]::PositiveInfinity))
Assert-Eq 'NaN -> --:--'             '--:--'   (Format-CvEta ([double]::NaN))
Assert-Eq '0 -> 00:00'               '00:00'   (Format-CvEta 0)
Assert-Eq '59 -> 00:59'              '00:59'   (Format-CvEta 59)
Assert-Eq '65 -> 01:05'              '01:05'   (Format-CvEta 65)
Assert-Eq '3600 -> 1:00:00'          '1:00:00' (Format-CvEta 3600)
Assert-Eq '3661 -> 1:01:01'          '1:01:01' (Format-CvEta 3661)
# Get-CvTimeParts (base comun de los formateadores de tiempo)
$tp = Get-CvTimeParts 3723.5
Assert-Eq 'TimeParts H' 1 $tp.H
Assert-Eq 'TimeParts M' 2 $tp.M
Assert-Eq 'TimeParts S' 3 $tp.S
Assert-Eq 'TimeParts MS' 500 $tp.MS
Assert-Eq 'TimeParts negativo -> 0' 0 (Get-CvTimeParts -5).S

# ================================================================================================
Write-Host "`nGet-CvProgressBar (Console)" -ForegroundColor Cyan
$full = [char]0x2588
function BarFull([string]$s) { ($s.ToCharArray() | Where-Object { $_ -eq $full } | Measure-Object).Count }
Assert-Eq 'ancho por defecto = 20'   20 (Get-CvProgressBar -Percent 50).Length
Assert-Eq '50% -> 10 llenos'         10 (BarFull (Get-CvProgressBar -Percent 50))
Assert-Eq '0% -> 0 llenos'            0 (BarFull (Get-CvProgressBar -Percent 0))
Assert-Eq '100% -> 20 llenos'        20 (BarFull (Get-CvProgressBar -Percent 100))
Assert-Eq '>100% se recorta a 20'    20 (BarFull (Get-CvProgressBar -Percent 120))
Assert-Eq 'negativo se recorta a 0'   0 (BarFull (Get-CvProgressBar -Percent -5))
Assert-Eq 'width 0 -> vacia'         ''  (Get-CvProgressBar -Percent 50 -Width 0)
Assert-Eq 'width 10, 30% -> len 10'  10 (Get-CvProgressBar -Percent 30 -Width 10).Length
Assert-Eq 'width 10, 30% -> 3 llenos' 3 (BarFull (Get-CvProgressBar -Percent 30 -Width 10))
# Los caracteres de la barra salen de su fuente unica y se construyen con [char]0xNNNN (nunca
# literales en el .psm1: UTF-8 sin BOM + PS 5.1 = ANSI -> se corrompen; ver ref-gotchas.md).
$barCh = Get-CvProgressBarChars
Assert-Eq 'barra: caracter lleno' ([string]([char]0x2588)) $barCh.Full
Assert-Eq 'barra: caracter vacio' ([string]([char]0x2591)) $barCh.Empty
Assert-True 'barra usa esos caracteres' ((Get-CvProgressBar -Percent 50 -Width 4) -eq (($barCh.Full) * 2 + ($barCh.Empty) * 2))
# La linea VIVA de progreso NO debe pasar por el host: si lo hiciera, el transcript de la sesion se
# llenaria con cada repintado (llego a ser el 82% de un log). Se comprueba que no emite Information.
$progRecs = @(Write-CvProgressLine -Text ' - Paso...' -PrevLen 0 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
Assert-Eq 'progreso no pasa por el host' 0 $progRecs.Count
Assert-Eq 'progreso devuelve la longitud' 10 (Write-CvProgressLine -Text ' - Paso...' -PrevLen 0)

# ================================================================================================
# Avance y velocidad de la linea de progreso: con el out_time de ffmpeg o, si lo da como 'N/A'
# (basta una pista de salida VACIA para que pase toda la ejecucion), estimados con frames y fps.
Write-Host "`nProgreso sin out_time (Exec)" -ForegroundColor Cyan
Assert-Eq 'Prog out_time manda'        120   (Resolve-CvProgressSeconds -HasOutTime $true  -OutSeconds 120 -Frames 9999 -Fps 25)
Assert-Eq 'Prog out_time 0 vale'         0   (Resolve-CvProgressSeconds -HasOutTime $true  -OutSeconds 0   -Frames 9999 -Fps 25)
Assert-Eq 'Prog estima frames/fps'      40   (Resolve-CvProgressSeconds -HasOutTime $false -OutSeconds 0   -Frames 1000 -Fps 25)
Assert-Eq 'Prog sin fps -> 0'            0   (Resolve-CvProgressSeconds -HasOutTime $false -OutSeconds 0   -Frames 1000 -Fps 0)
Assert-Eq 'Prog sin frames -> 0'         0   (Resolve-CvProgressSeconds -HasOutTime $false -OutSeconds 0   -Frames 0    -Fps 25)
Assert-Eq 'Vel de ffmpeg'              1.8   (Resolve-CvProgressSpeed -Speed '1.8x' -Seconds 100 -Elapsed 10)
Assert-Eq 'Vel N/A -> media'            10   (Resolve-CvProgressSpeed -Speed 'N/A'  -Seconds 100 -Elapsed 10)
Assert-Eq 'Vel vacia -> media'          10   (Resolve-CvProgressSpeed -Speed ''     -Seconds 100 -Elapsed 10)
Assert-Eq 'Vel sin nada -> 0'            0   (Resolve-CvProgressSpeed -Speed 'N/A'  -Seconds 0   -Elapsed 10)
Assert-Eq 'Vel ffmpeg 0x -> media'       5   (Resolve-CvProgressSpeed -Speed '0x'   -Seconds 50  -Elapsed 10)

# ================================================================================================
Write-Host "`nSeparadores (Console)" -ForegroundColor Cyan
Assert-Eq 'Get-CvSepLine -Width 5'   '====='   (Get-CvSepLine -Width 5)
Assert-Eq 'Get-CvDashLine -Width 3'  '---'     (Get-CvDashLine -Width 3)
Assert-Eq 'Get-CvStarLine -Width 4'  '****'    (Get-CvStarLine -Width 4)
Assert-Eq 'Get-CvLine char # w6'     '######'  (Get-CvLine -Char '#' -Width 6)
Assert-Eq 'default = config.sepWidth' (Get-CvConfigDefaults).console.sepWidth (Get-CvSepLine).Length
Assert-Eq 'MenuNumWidth 9 -> 1'    1 (Get-CvMenuNumWidth 9)
Assert-Eq 'MenuNumWidth 11 -> 2'   2 (Get-CvMenuNumWidth 11)
Assert-Eq 'MenuNumWidth 0 -> 1'    1 (Get-CvMenuNumWidth 0)
Assert-Eq 'MenuNumWidth 100 -> 3'  3 (Get-CvMenuNumWidth 100)

# ================================================================================================
Write-Host "`nConvertTo-CvPromptTimeouts (Config)" -ForegroundColor Cyan
$t0 = ConvertTo-CvPromptTimeouts $null
Assert-Eq 'null -> default=0'        0 $t0['default']
$t1 = ConvertTo-CvPromptTimeouts 7
Assert-Eq 'escalar 7 -> default=7'   7 $t1['default']
$t2 = ConvertTo-CvPromptTimeouts ([ordered]@{
    sync   = 5
    border = 10
})
Assert-True 'objeto -> anade default'  ($t2.Contains('default'))
Assert-Eq 'objeto -> sync=5'         5 $t2['sync']
Assert-Eq 'objeto -> border=10'     10 $t2['border']
$t3 = ConvertTo-CvPromptTimeouts ([ordered]@{
    default = 3
    sync    = 5
})
Assert-Eq 'objeto conserva default'  3 $t3['default']

# ================================================================================================
Write-Host "`nGet-CvPromptTimeout (Console)" -ForegroundColor Cyan
$fakeCtx = [pscustomobject]@{ PromptTimeouts = [ordered]@{
    default = 3
    sync    = 5
    border  = -1
} }
Assert-Eq 'tipo explicito (sync=5)'   5 (Get-CvPromptTimeout $fakeCtx 'sync')
Assert-Eq 'tipo -1 hereda default'    3 (Get-CvPromptTimeout $fakeCtx 'border')
Assert-Eq 'tipo ausente hereda def'   3 (Get-CvPromptTimeout $fakeCtx 'animation')
Assert-Eq 'default directo'           3 (Get-CvPromptTimeout $fakeCtx 'default')
Assert-Eq 'sin mapa -> 0'             0 (Get-CvPromptTimeout ([pscustomobject]@{ PromptTimeouts = $null }) 'sync')

# ================================================================================================
Write-Host "`nGet-CvConfigDefaultValue (Config)" -ForegroundColor Cyan
Assert-Eq 'console/sepWidth = 64'         64  (Get-CvConfigDefaultValue 'console/sepWidth')
Assert-Eq 'console/progressBarWidth = 20' 20  (Get-CvConfigDefaultValue 'console/progressBarWidth')
Assert-Eq 'gui/rememberLayout = true'   $true (Get-CvConfigDefaultValue 'gui/rememberLayout')
Assert-Eq 'gui/queueWidth = 1320'        1320 (Get-CvConfigDefaultValue 'gui/queueWidth')
Assert-Eq 'gui/queueHeight = 760'         760 (Get-CvConfigDefaultValue 'gui/queueHeight')
Assert-Eq 'gui/queueSplitPercent = 52'     52 (Get-CvConfigDefaultValue 'gui/queueSplitPercent')
Assert-Eq 'gui/confirmCloseWithWorkers = true' $true (Get-CvConfigDefaultValue 'gui/confirmCloseWithWorkers')
Assert-Eq 'console/windowWidth = 150'    150  (Get-CvConfigDefaultValue 'console/windowWidth')
Assert-Eq 'console/asciiMarks def false' $false (Get-CvConfigDefaultValue 'console/asciiMarks')
Assert-Eq 'behavior/asciiMarks ya no existe' $null (Get-CvConfigDefaultValue 'behavior/asciiMarks')
Assert-True 'help console/asciiMarks'    ((Get-CvConfigHelp).Contains('console/asciiMarks'))
Assert-True 'help gui/rememberLayout'    ((Get-CvConfigHelp).Contains('gui/rememberLayout'))
Assert-True 'help gui/queueSplitPercent' ((Get-CvConfigHelp).Contains('gui/queueSplitPercent'))
Assert-True 'help gui/confirmCloseWithWorkers' ((Get-CvConfigHelp).Contains('gui/confirmCloseWithWorkers'))
Assert-Eq 'behavior/promptTimeoutStopOnType def true' $true (Get-CvConfigDefaultValue 'behavior/promptTimeoutStopOnType')
Assert-True 'help promptTimeoutStopOnType' ((Get-CvConfigHelp).Contains('behavior/promptTimeoutStopOnType'))
Assert-Eq 'encode/video/anamorphic def square' 'square' (Get-CvConfigDefaultValue 'encode/video/anamorphic')
Assert-Eq 'promptTimeout/anamorphic def 10' 10 (Get-CvConfigDefaultValue 'behavior/promptTimeout/anamorphic')
Assert-True 'help encode/video/anamorphic' ((Get-CvConfigHelp).Contains('encode/video/anamorphic'))
Assert-Eq 'encode/audio/syncAdelay def true' $true (Get-CvConfigDefaultValue 'encode/audio/syncAdelay')
Assert-True 'help encode/audio/syncAdelay'   ((Get-CvConfigHelp).Contains('encode/audio/syncAdelay'))
Assert-Eq 'encode/video/auto/gpuOnly def false'  $false (Get-CvConfigDefaultValue 'encode/video/auto/gpuOnly')
Assert-Eq 'encode/video/auto/maxCodec def vacio' ''     (Get-CvConfigDefaultValue 'encode/video/auto/maxCodec')
Assert-True 'help encode/video/auto/gpuOnly'     ((Get-CvConfigHelp).Contains('encode/video/auto/gpuOnly'))
Assert-True 'help encode/video/auto/maxCodec'    ((Get-CvConfigHelp).Contains('encode/video/auto/maxCodec'))
Assert-Eq 'encode/video/auto/crf def 21'         21  (Get-CvConfigDefaultValue 'encode/video/auto/crf')
Assert-Eq 'encode/video/auto/crfAv1 def 30'      30  (Get-CvConfigDefaultValue 'encode/video/auto/crfAv1')
Assert-Eq 'encode/video/auto/qmin def 1'         1   (Get-CvConfigDefaultValue 'encode/video/auto/qmin')
Assert-Eq 'encode/video/auto/qmax def 23'        23  (Get-CvConfigDefaultValue 'encode/video/auto/qmax')
Assert-Eq 'encode/video/auto/level def 5.0'      '5.0' (Get-CvConfigDefaultValue 'encode/video/auto/level')
Assert-True 'help encode/video/auto/crf'         ((Get-CvConfigHelp).Contains('encode/video/auto/crf'))
Assert-True 'help encode/video/auto/level'       ((Get-CvConfigHelp).Contains('encode/video/auto/level'))
# Tuning del encoder de video (fuente unica encode.video.tuning).
Assert-Eq 'encode/video/tuning/presetNvenc def' 'slow' (Get-CvConfigDefaultValue 'encode/video/tuning/presetNvenc')
Assert-Eq 'encode/video/tuning/presetSvtav1 def' '6'   (Get-CvConfigDefaultValue 'encode/video/tuning/presetSvtav1')
Assert-Eq 'encode/video/tuning/rcLookahead def'  32    (Get-CvConfigDefaultValue 'encode/video/tuning/rcLookahead')
Assert-Eq 'encode/video/tuning/refs def'         4     (Get-CvConfigDefaultValue 'encode/video/tuning/refs')
Assert-Eq 'encode/video/tuning/tier def'         'high' (Get-CvConfigDefaultValue 'encode/video/tuning/tier')
Assert-True 'help encode/video/tuning/presetNvenc' ((Get-CvConfigHelp).Contains('encode/video/tuning/presetNvenc'))
Assert-Eq 'encode/audio/aacCoder def' 'twoloop' (Get-CvConfigDefaultValue 'encode/audio/aacCoder')
Assert-True 'help encode/audio/aacCoder' ((Get-CvConfigHelp).Contains('encode/audio/aacCoder'))
Assert-Eq 'encode/audio/encoder def' 'aac_coder' (Get-CvConfigDefaultValue 'encode/audio/encoder')
Assert-Eq 'encode/audio/codec def'   'aac'       (Get-CvConfigDefaultValue 'encode/audio/codec')
Assert-Eq 'encode/audio/bitrate def' '192k'      (Get-CvConfigDefaultValue 'encode/audio/bitrate')
Assert-Eq 'encode/video/tonemapCurve def' 'bt.2390' (Get-CvConfigDefaultValue 'encode/video/tonemapCurve')
Assert-True 'help encode/video/tonemapCurve' ((Get-CvConfigHelp).Contains('encode/video/tonemapCurve'))
Assert-Eq 'preview/syncSeconds def 0' 0 (Get-CvConfigDefaultValue 'preview/syncSeconds')
Assert-True 'help encode/audio/codec' ((Get-CvConfigHelp).Contains('encode/audio/codec'))
# customProfile hereda la salida de audio de encode.audio.* (fuente unica).
$cpDef = (Get-CvConfigDefaults).customProfile
Assert-Eq 'customProfile.audioCodec <- encode.audio.codec' 'aac' $cpDef.audioCodec
Assert-Eq 'customProfile.audioBitrate <- encode.audio.bitrate' '192k' $cpDef.audioBitrate
Assert-Eq 'customProfile.audioEncoder <- encode.audio.encoder' 'aac_coder' $cpDef.audioEncoder
Assert-Eq 'customProfile.crf <- encode.video.auto.crf' 21 $cpDef.crf
# customProfile hereda tambien el codec de video de encode.video.* (fuente unica).
Assert-Eq 'encode/video/videoEncoder def'  'hevc_nvenc' (Get-CvConfigDefaultValue 'encode/video/videoEncoder')
Assert-Eq 'encode/video/videoProfile def'  'main10'     (Get-CvConfigDefaultValue 'encode/video/videoProfile')
Assert-Eq 'encode/video/videoLevel def'    '5.0'        (Get-CvConfigDefaultValue 'encode/video/videoLevel')
Assert-Eq 'customProfile.videoEncoder <- encode.video.videoEncoder' 'hevc_nvenc' $cpDef.videoEncoder
Assert-Eq 'customProfile.videoProfile <- encode.video.videoProfile' 'main10'     $cpDef.videoProfile
Assert-Eq 'customProfile.videoLevel <- encode.video.videoLevel'     '5.0'        $cpDef.videoLevel
Assert-True 'help encode/video/videoEncoder' ((Get-CvConfigHelp).Contains('encode/video/videoEncoder'))
Assert-Eq 'encode/video/qualityCheck def off' 'off' (Get-CvConfigDefaultValue 'encode/video/qualityCheck')
Assert-True 'help encode/video/qualityCheck'  ((Get-CvConfigHelp).Contains('encode/video/qualityCheck'))
Assert-Eq 'encode/audio/syncThreshold def 2' 2.0 (Get-CvConfigDefaultValue 'encode/audio/syncThreshold')
Assert-Eq 'promptTimeout/audioSync def 15'  15  (Get-CvConfigDefaultValue 'behavior/promptTimeout/audioSync')
Assert-Eq 'promptTimeout/subtitleLang def 15' 15 (Get-CvConfigDefaultValue 'behavior/promptTimeout/subtitleLang')
Assert-True 'help promptTimeout/subtitleLang' ((Get-CvConfigHelp).Contains('behavior/promptTimeout/subtitleLang'))
Assert-Eq 'encode/subtitles/defaultLang def vacio' '' (Get-CvConfigDefaultValue 'encode/subtitles/defaultLang')
Assert-True 'help encode/subtitles/defaultLang' ((Get-CvConfigHelp).Contains('encode/subtitles/defaultLang'))
Assert-Eq 'preview/subtitleEditor def start' 'start' (Get-CvConfigDefaultValue 'preview/subtitleEditor')
Assert-True 'help preview/subtitleEditor' ((Get-CvConfigHelp).Contains('preview/subtitleEditor'))
Assert-Eq 'preview/subtitleEditorExe def vacio' '' (Get-CvConfigDefaultValue 'preview/subtitleEditorExe')
Assert-True 'help preview/subtitleEditorExe' ((Get-CvConfigHelp).Contains('preview/subtitleEditorExe'))
# Resolve-CvSubtitleOpen: normaliza modo/exe (con compat '' -> start, 'ventana' -> win, token suelto -> external).
Assert-Eq 'SubOpen vacio -> start'     'start'    (Resolve-CvSubtitleOpen -Mode '').Mode
Assert-Eq 'SubOpen start'              'start'    (Resolve-CvSubtitleOpen -Mode 'start').Mode
Assert-Eq 'SubOpen win'                'win'      (Resolve-CvSubtitleOpen -Mode 'win').Mode
Assert-Eq 'SubOpen ventana -> win'     'win'      (Resolve-CvSubtitleOpen -Mode 'ventana').Mode
Assert-Eq 'SubOpen mayus WIN -> win'   'win'      (Resolve-CvSubtitleOpen -Mode 'WIN').Mode
Assert-Eq 'SubOpen external mode'      'external' (Resolve-CvSubtitleOpen -Mode 'external' -Exe 'x.exe').Mode
Assert-Eq 'SubOpen external exe'       'x.exe'    (Resolve-CvSubtitleOpen -Mode 'external' -Exe 'x.exe').Exe
Assert-Eq 'SubOpen other -> external'  'external' (Resolve-CvSubtitleOpen -Mode 'other' -Exe 'y.exe').Mode
Assert-Eq 'SubOpen token suelto mode'  'external' (Resolve-CvSubtitleOpen -Mode 'C:\p\se.exe').Mode
Assert-Eq 'SubOpen token suelto exe'   'C:\p\se.exe' (Resolve-CvSubtitleOpen -Mode 'C:\p\se.exe').Exe
Assert-Eq 'SubOpen start ignora exe'   ''         (Resolve-CvSubtitleOpen -Mode 'start' -Exe 'z.exe').Exe
Assert-True 'help encode/audio/syncThreshold' ((Get-CvConfigHelp).Contains('encode/audio/syncThreshold'))
# customProfile: paridad de campos con un profiles[] (nuevos defaults + 'auto' en videoEncoder).
Assert-Eq 'customProfile/detectBorder def' $false      (Get-CvConfigDefaultValue 'customProfile/detectBorder')
Assert-Eq 'customProfile/changeSize def'   ''           (Get-CvConfigDefaultValue 'customProfile/changeSize')
Assert-Eq 'customProfile/noUpscale def'    $false        (Get-CvConfigDefaultValue 'customProfile/noUpscale')
Assert-True 'help customProfile/noUpscale' ((Get-CvConfigHelp).Contains('customProfile/noUpscale'))
Assert-Eq 'customProfile/maxWidth def 0'   0            (Get-CvConfigDefaultValue 'customProfile/maxWidth')
Assert-Eq 'customProfile/audioEncoder def' 'aac_coder'  (Get-CvConfigDefaultValue 'customProfile/audioEncoder')
Assert-Eq 'customProfile/audioHz def'      44100        (Get-CvConfigDefaultValue 'customProfile/audioHz')
Assert-Eq 'customProfile/audioChannels def' 2           (Get-CvConfigDefaultValue 'customProfile/audioChannels')
Assert-Eq 'customProfile/downmixMode def'  'default'    (Get-CvConfigDefaultValue 'customProfile/downmixMode')
Assert-Eq 'customProfile/downmixCoeffs/center def' 0.5  (Get-CvConfigDefaultValue 'customProfile/downmixCoeffs/center')
Assert-True 'help customProfile/detectBorder' ((Get-CvConfigHelp).Contains('customProfile/detectBorder'))
Assert-Eq 'border/autoSamples def'   3 (Get-CvConfigDefaultValue 'encode/video/border/autoSamples')
# 15 s por punto, no 5: con ventanas cortas cropdetect se queda con la caja de un plano oscuro.
Assert-Eq 'border/autoDuration def'  15 (Get-CvConfigDefaultValue 'encode/video/border/autoDuration')
Assert-Eq 'border/autoMaxCropPct def' 40 (Get-CvConfigDefaultValue 'encode/video/border/autoMaxCropPct')
Assert-True 'help border/autoMaxCropPct' ((Get-CvConfigHelp).Contains('encode/video/border/autoMaxCropPct'))
Assert-True 'help customProfile/audioHz'      ((Get-CvConfigHelp).Contains('customProfile/audioHz'))
# Paridad estricta: customProfile debe traer TODOS los campos que acepta un perfil de profiles[].
$cpKeys = @((Get-CvConfigDefaults).customProfile.Keys)
foreach ($f in @('videoEncoder','videoProfile','videoLevel','qmin','qmax','crf','detectBorder','changeSize','maxWidth','multipass','audioEncoder','audioCodec','audioBitrate','audioHz','audioChannels','downmixMode','downmixCoeffs')) {
    Assert-True ("customProfile tiene '$f'") ($cpKeys -contains $f)
}
Assert-Eq 'test.syncAdelay ya no existe'    $null (Get-CvConfigDefaultValue 'test/syncAdelay')
Assert-Eq 'debug/enabled def false'         $false (Get-CvConfigDefaultValue 'debug/enabled')
Assert-Eq 'debug/pausePerCommand def true'  $true  (Get-CvConfigDefaultValue 'debug/pausePerCommand')
Assert-True 'help debug/enabled'         ((Get-CvConfigHelp).Contains('debug/enabled'))
Assert-True 'help debug/pausePerCommand' ((Get-CvConfigHelp).Contains('debug/pausePerCommand'))
Assert-Eq 'behavior.debug ya no existe' $null (Get-CvConfigDefaultValue 'behavior/debug')
Assert-Eq 'ruta inexistente -> null'    $null (Get-CvConfigDefaultValue 'no/existe/aqui')
# Un default que es una LISTA debe llegar como lista, tambien con UN solo elemento: sin la coma
# unaria PowerShell lo desenvolvia a escalar y toda lista de 1 elemento parecia editada en el editor.
# OJO: se asigna a una variable, SIN envolver en @(). La funcion devuelve con coma unaria, asi que
# un @() al llamar crearia un array ANIDADO y el recuento saldria 1 siempre (ver ref-gotchas.md).
$dVerArgs = Get-CvConfigDefaultValue 'downloads/ffmpeg/versionArgs'
$dFiles   = Get-CvConfigDefaultValue 'downloads/ffmpeg/files'
Assert-Eq 'default lista 1 elem'  1 $dVerArgs.Count
Assert-Eq 'default lista 1 valor' '-version' $dVerArgs[0]
Assert-Eq 'default lista n elem'  3 $dFiles.Count
Assert-Eq 'default lista n 1er'   'ffmpeg.exe' $dFiles[0]
Assert-Eq 'default escalar igual' 'zip' (Get-CvConfigDefaultValue 'downloads/ffmpeg/type')

# Test-CvCfgIsDefault: la MISMA regla que decide si una clave se escribe en config.json o se borra,
# y la que usa el editor en ventana para resaltar lo editado.
Assert-True 'IsDefault escalar igual'   (Test-CvCfgIsDefault -Value 'zip' -Default 'zip')
Assert-Eq   'IsDefault escalar distinto' $false (Test-CvCfgIsDefault -Value '7z' -Default 'zip')
Assert-True 'IsDefault numero igual'    (Test-CvCfgIsDefault -Value 2 -Default 2)
Assert-True 'IsDefault bool igual'      (Test-CvCfgIsDefault -Value $true -Default $true)
Assert-Eq   'IsDefault bool distinto'   $false (Test-CvCfgIsDefault -Value $false -Default $true)
Assert-True 'IsDefault lista igual'     (Test-CvCfgIsDefault -Value @('a','b') -Default @('a','b'))
Assert-Eq   'IsDefault lista orden'     $false (Test-CvCfgIsDefault -Value @('b','a') -Default @('a','b'))
Assert-True 'IsDefault lista 1 elem'    (Test-CvCfgIsDefault -Value @('-version') -Default (Get-CvConfigDefaultValue 'downloads/ffmpeg/versionArgs'))
Assert-Eq   'IsDefault sin default'     $false (Test-CvCfgIsDefault -Value 'algo' -Default $null)
Assert-True 'IsDefault null vs null'    (Test-CvCfgIsDefault -Value $null -Default $null)

# ================================================================================================
Write-Host "`nMetodos de volumen y coeficientes (Config)" -ForegroundColor Cyan
Assert-Eq 'volume methods'  @('loudnorm','peak','aacgain') (Get-CvVolumeMethodValues)
Assert-Eq   'tonemapCurve 1a = bt.2390' 'bt.2390' (@(Get-CvTonemapCurves)[0])
Assert-True 'tonemapCurve incluye mobius' (@(Get-CvTonemapCurves) -contains 'mobius')
# loudnorm es el DEFAULT y el 1o del catalogo (= fallback); 'peak' queda marcado como LEGACY.
Assert-Eq 'fallback = 1o (loudnorm)' 'loudnorm' (Get-CvVolumeMethodValues)[0]
Assert-Eq 'volume method default' 'loudnorm' (Get-CvConfigDefaultValue 'encode/audio/volume/method')
Assert-True 'peak marcado LEGACY' ((Get-CvVolumeMethods | Where-Object { $_.Value -eq 'peak' }).Text -cmatch 'LEGACY')
Assert-True 'loudnorm sin LEGACY'  ((Get-CvVolumeMethods | Where-Object { $_.Value -eq 'loudnorm' }).Text -cnotmatch 'LEGACY')
Assert-True 'todos los metodos con texto' (@(Get-CvVolumeMethods | Where-Object { -not "$($_.Text)".Trim() }).Count -eq 0)
$dc = Get-CvDefaultDownmixCoeffs
Assert-Eq 'downmix center 0.5'  0.5  $dc.Center
Assert-Eq 'downmix front 0.35'  0.35 $dc.Front
Assert-Eq 'downmix surround .15' 0.15 $dc.Surround

# ================================================================================================
Write-Host "`nCatalogo de opciones del editor (ConfigEditor)" -ForegroundColor Cyan
# Claves de valor libre (numero/texto) -> sin menu (null).
Assert-Eq 'editor opts fps null'     $null (Get-CvEditorOptions -Key 'fps')
Assert-Eq 'editor opts crf null'     $null (Get-CvEditorOptions -Key 'crf')
Assert-Eq 'editor opts bitrate null' $null (Get-CvEditorOptions -Key 'bitrate')
# Enums cerrados: valores esperados.
Assert-Eq 'editor anamorphic vals' 'square,squareheight,keep' (((Get-CvEditorOptions -Key 'anamorphic').Items | ForEach-Object { $_.Value }) -join ',')
Assert-Eq 'editor tonemapHdr vals' 'auto,off' (((Get-CvEditorOptions -Key 'tonemapHdr').Items | ForEach-Object { $_.Value }) -join ',')
Assert-Eq 'editor qualityCheck vals' 'off,ssim,vmaf' (((Get-CvEditorOptions -Key 'qualityCheck').Items | ForEach-Object { $_.Value }) -join ',')
# method: catalogo @{Value;Text} -> el editor muestra descripcion (y el 'LEGACY' de peak) en Desc.
Assert-Eq 'editor method vals' 'loudnorm,peak,aacgain' (((Get-CvEditorOptions -Key 'method').Items | ForEach-Object { $_.Value }) -join ',')
Assert-True 'editor method desc peak LEGACY' (((Get-CvEditorOptions -Key 'method').Items | Where-Object { $_.Value -eq 'peak' }).Desc -cmatch 'LEGACY')
# maxCodec incluye el valor '' (sin tope) con label '(vacio)'.
$mc = (Get-CvEditorOptions -Key 'maxCodec').Items
Assert-Eq 'editor maxCodec 1o vacio' '' $mc[0].Value
Assert-Eq 'editor maxCodec 1o label' '(vacio)' $mc[0].Label
# channels: Value ENTERO (no string), para conservar el tipo al guardar.
$ch2 = (Get-CvEditorOptions -Key 'channels').Items[0]
Assert-Eq 'editor channels tipo int' 'Int32' $ch2.Value.GetType().Name
Assert-Eq 'editor channels 1o = 2' 2 $ch2.Value
# detectBorder: 3 opciones incl. bool + 'auto'.
$db = (Get-CvEditorOptions -Key 'detectBorder').Items
Assert-Eq 'editor detectBorder 3 opts' 3 $db.Count
Assert-Eq 'editor detectBorder false bool' 'Boolean' $db[0].Value.GetType().Name
Assert-Eq 'editor detectBorder auto'   'auto' $db[2].Value
# videoEncoder incluye 'auto'; tonemapCurve permite custom.
Assert-True 'editor videoEncoder incluye auto' (((Get-CvEditorOptions -Key 'videoEncoder').Items | ForEach-Object { "$($_.Value)" }) -contains 'auto')
Assert-Eq   'editor tonemapCurve AllowCustom' $true (Get-CvEditorOptions -Key 'tonemapCurve').AllowCustom
Assert-Eq   'editor anamorphic cerrado'       $false (Get-CvEditorOptions -Key 'anamorphic').AllowCustom
# subtitleEditor: enum cerrado start/win/external (Get-CvSubtitleEditorModes).
Assert-Eq 'editor subtitleEditor vals' 'start,win,external' (((Get-CvEditorOptions -Key 'subtitleEditor').Items | ForEach-Object { $_.Value }) -join ',')
Assert-Eq 'editor subtitleEditor cerrado' $false (Get-CvEditorOptions -Key 'subtitleEditor').AllowCustom
# codec/channels comparten catalogo con sus gemelos audioCodec/audioChannels.
Assert-Eq 'editor codec == audioCodec' (((Get-CvEditorOptions -Key 'codec').Items | ForEach-Object { $_.Value }) -join ',') (((Get-CvEditorOptions -Key 'audioCodec').Items | ForEach-Object { $_.Value }) -join ',')

# ================================================================================================
Write-Host "`nConvertTo-CvDownmixCoeffs (Profile)" -ForegroundColor Cyan
Assert-Eq 'null -> null'  $null (ConvertTo-CvDownmixCoeffs $null)
$cc = ConvertTo-CvDownmixCoeffs ([pscustomobject]@{ center = 0.6 })
Assert-Eq 'center dado 0.6'       0.6  $cc.Center
Assert-Eq 'front ausente -> def'  0.35 $cc.Front
Assert-Eq 'surround ausente -> def' 0.15 $cc.Surround
$cc2 = ConvertTo-CvDownmixCoeffs ([pscustomobject]@{
    center   = 0.4
    front    = 0.4
    surround = 0.2
})
Assert-Eq 'todos dados: center'   0.4 $cc2.Center
Assert-Eq 'todos dados: surround' 0.2 $cc2.Surround

# ================================================================================================
Write-Host "`nGet-CvProcesoPatterns (Job)" -ForegroundColor Cyan
Assert-True 'jobs incluye *.job.json'  ((Get-CvProcesoPatterns -What jobs)  -contains '*.job.json')
# 'locks' = ficheros de CONTROL de los workers (el bloqueo, el estado que publican y la bandera de
# parada): lo detallan los casos de WorkerCore mas abajo.
Assert-True 'locks incluye *.lock'     ((Get-CvProcesoPatterns -What locks) -contains '*.lock')
Assert-True 'temps incluye *.mkv'      ((Get-CvProcesoPatterns -What temps) -contains '*.mkv')
Assert-True 'temps incluye *.m4a'      ((Get-CvProcesoPatterns -What temps) -contains '*.m4a')
$all = Get-CvProcesoPatterns -What all
Assert-True 'all incluye lock'         ($all -contains '*.lock')
Assert-True 'all incluye job'          ($all -contains '*.job.json')
Assert-Eq   'all sin duplicados'       $all.Count ($all | Select-Object -Unique).Count

# ================================================================================================
Write-Host "`nFuentes unicas (Context / Profile)" -ForegroundColor Cyan
Assert-Eq 'Get-CvAppName' 'ConvertVideo' (Get-CvAppName)
Assert-Eq 'Get-CvVersion' '4.7.2'        (Get-CvVersion)
Assert-Eq 'perfiles de serie = 13' 13 ((Get-CvProfiles | ForEach-Object { $_.Profiles } | Measure-Object).Count)
# Los perfiles de serie con changeSize '1920:-2' (RESIZE fijo) deben ser solo-reduce (NoUpscale).
$rzProfs = @(Get-CvProfiles | ForEach-Object { $_.Profiles } | Where-Object { "$($_.ChangeSize)" -ne '' })
Assert-Eq 'perfiles con changeSize = 2' 2 $rzProfs.Count
Assert-True 'perfiles changeSize NoUpscale' (@($rzProfs | Where-Object { -not [bool]$_.NoUpscale }).Count -eq 0)
Assert-Eq 'Tamano: vacio si no hay'  ''       (Format-CvSize -Kb 0)
Assert-Eq 'Tamano: vacio sin bytes'  ''       (Format-CvSize -Bytes 0)
Assert-Eq 'Tamano: KB -> MB'         '800 MB' (Format-CvSize -Kb (800 * 1024))
Assert-Eq 'Tamano: bytes -> MB'      '800 MB' (Format-CvSize -Bytes (800 * 1024 * 1024))
Assert-True 'Tamano: pasa a GB'      ((Format-CvSize -Kb (3 * 1024 * 1024)) -match 'GB')
# Por debajo de 1 MB, en KB: '0 MB' no informa de nada (salia asi con un punado de logs pequenos).
Assert-Eq 'Tamano: menos de 1 MB en KB' '48 KB' (Format-CvSize -Kb 48)
Assert-Eq 'Tamano: justo 1 MB ya es MB' '1 MB'  (Format-CvSize -Kb 1024)

Assert-Eq 'encode.subtitles.dropEmpty def' $true (Get-CvConfigDefaultValue 'encode/subtitles/dropEmpty')
# Los codecs de subtitulo y sus extensiones viven en la CONFIG (se amplian sin tocar codigo).
Assert-True 'subtitles/textCodecs trae subrip' ((Get-CvConfigDefaults).encode.subtitles.textCodecs -contains 'subrip')
Assert-Eq   'subtitles/imageExtensions PGS' '.sup' "$((Get-CvConfigDefaults).encode.subtitles.imageExtensions['hdmv_pgs_subtitle'])"
Assert-True 'help encode/subtitles/textCodecs'      ((Get-CvConfigHelp).Contains('encode/subtitles/textCodecs'))
Assert-True 'help encode/subtitles/imageExtensions' ((Get-CvConfigHelp).Contains('encode/subtitles/imageExtensions'))
# El mapa se normaliza: da igual como se escriba en config.json.
$mNorm = ConvertTo-CvSubtitleExtMap -Source ([pscustomobject]@{ PGSSUB = 'sup'; ' dvb_subtitle ' = '.DVB' })
Assert-Eq   'Mapa: codec a minusculas' '.sup' "$($mNorm['pgssub'])"
Assert-Eq   'Mapa: pone el punto'      '.dvb' "$($mNorm['dvb_subtitle'])"
Assert-Eq   'Mapa: vacio sin fuente'   0      (@((ConvertTo-CvSubtitleExtMap -Source $null).Keys)).Count
# Y lo que se anada en config.json se SUMA a lo de serie (no lo sustituye).
$cfgSub = Get-CvConfigDefaults
Merge-CvConfig -Default $cfgSub -Override (ConvertFrom-Json '{ "encode": { "subtitles": { "imageExtensions": { "dvb_subtitle": ".dvb" } } } }')
$mMerged = ConvertTo-CvSubtitleExtMap -Source $cfgSub.encode.subtitles.imageExtensions
Assert-Eq   'Mapa: el nuevo entra'     '.dvb' "$($mMerged['dvb_subtitle'])"
Assert-Eq   'Mapa: y sigue el de serie' '.sup' "$($mMerged['hdmv_pgs_subtitle'])"
Assert-True 'help encode/subtitles/dropEmpty' ((Get-CvConfigHelp).Contains('encode/subtitles/dropEmpty'))

# ================================================================================================
# Fps: fuente unica del fps de una pista (fraccion de ffprobe) y del fps de SALIDA (forceFps).
Write-Host "`nFps de origen y de salida (MediaInfo / Video)" -ForegroundColor Cyan
Assert-Eq 'Fps avg 24000/1001' '23.976023976024' ([math]::Round((Get-CvFrameRate ([pscustomobject]@{ avg_frame_rate = '24000/1001'; r_frame_rate = '25/1' })), 12))
Assert-Eq 'Fps avg 0/0 -> r'   25 (Get-CvFrameRate ([pscustomobject]@{ avg_frame_rate = '0/0'; r_frame_rate = '25/1' }))
Assert-Eq 'Fps denominador 0'   0 (Get-CvFrameRate ([pscustomobject]@{ avg_frame_rate = '0/0'; r_frame_rate = '30/0' }))
Assert-Eq 'Fps sin stream'      0 (Get-CvFrameRate $null)
$fpsInfo = [pscustomobject]@{ streams = @(
    [pscustomobject]@{ index = 0; codec_type = 'video'; avg_frame_rate = '24000/1001'; r_frame_rate = '24000/1001' }
    [pscustomobject]@{ index = 1; codec_type = 'audio' }
) }
Assert-Eq 'MediaFps primera de video' '23.98' ([math]::Round((Get-CvMediaFps -Info $fpsInfo), 2))
Assert-Eq 'MediaFps sin video' 0 (Get-CvMediaFps -Info ([pscustomobject]@{ streams = @([pscustomobject]@{ index = 0; codec_type = 'audio' }) }))
# forceFps: manda el fps de config (invariante, '23.976' con punto); sin forzar, el del origen.
Assert-Eq 'OutFps forzado' '23.976' ([math]::Round((Get-CvOutputFps -Context ([pscustomobject]@{ ForceFps = $true; Fps = '23.976' }) -Info $fpsInfo), 3))
Assert-Eq 'OutFps origen'  '23.98'  ([math]::Round((Get-CvOutputFps -Context ([pscustomobject]@{ ForceFps = $false; Fps = '23.976' }) -Info $fpsInfo), 2))
Assert-Eq 'OutFps sin info' 0 (Get-CvOutputFps -Context ([pscustomobject]@{ ForceFps = $false; Fps = '23.976' }))

# ================================================================================================
Write-Host "`nMultipista de audio (Config / Job / MediaInfo)" -ForegroundColor Cyan
Assert-Eq 'encode.multiAudio def true'    $true  (Get-CvConfigDefaultValue 'encode/audio/multiAudio')
Assert-True 'help encode/audio/multiAudio'   ((Get-CvConfigHelp).Contains('encode/audio/multiAudio'))
Assert-Eq 'test.betaMultiAudio ya no existe' $null (Get-CvConfigDefaultValue 'test/betaMultiAudio')
Assert-Eq 'test.betaAv1 ya no existe'  $null (Get-CvConfigDefaultValue 'test/betaAv1')
Assert-Eq 'test.betaOnePass def false' $false (Get-CvConfigDefaultValue 'test/betaOnePass')
Assert-True 'help test/betaOnePass'    ((Get-CvConfigHelp).Contains('test/betaOnePass'))

# Get-CvJobAudioTracks - formato nuevo (multipista): default primero, campos normalizados
$jobNew = [pscustomobject]@{ skip = $false; tracks = @(
    [pscustomobject]@{
        index   = 2
        is51    = $true
        sync    = 0
        lang    = 'spa'
        title   = '5.1'
        default = $true
    }
    [pscustomobject]@{
        index   = 1
        is51    = $false
        sync    = 0.5
        lang    = 'spa'
        title   = '2.0'
        default = $false
    }
) }
$tn = @(Get-CvJobAudioTracks -Audio $jobNew)
Assert-Eq 'multi: 2 pistas'      2     $tn.Count
Assert-Eq 'multi: 1a index=2'    2     $tn[0].Index
Assert-Eq 'multi: 1a default'    $true $tn[0].Default
Assert-Eq 'multi: 2a sync=0.5'   0.5   $tn[1].Sync
Assert-Eq 'multi: 2a lang=spa'   'spa' $tn[1].Lang

# Job ANTIGUO (monopista) -> lista de 1 con default (compat hacia atras)
$jobOld = [pscustomobject]@{
    skip  = $false
    index = 3
    is51  = $true
    sync  = 0
    lang  = 'eng'
}
$toOld = @(Get-CvJobAudioTracks -Audio $jobOld)
Assert-Eq 'compat: 1 pista'  1     $toOld.Count
Assert-Eq 'compat: index=3'  3     $toOld[0].Index
Assert-Eq 'compat: default'  $true $toOld[0].Default
Assert-Eq 'compat: lang=eng' 'eng' $toOld[0].Lang

# Sin ninguna default marcada -> se marca la primera; audio nulo -> lista vacia
$jobNoDef = [pscustomobject]@{ skip = $false; tracks = @(
    [pscustomobject]@{
        index   = 1
        is51    = $false
        sync    = 0
        lang    = 'spa'
        title   = ''
        default = $false
    }
    [pscustomobject]@{
        index   = 2
        is51    = $false
        sync    = 0
        lang    = 'spa'
        title   = ''
        default = $false
    }
) }
Assert-Eq 'sin default -> 1a default' $true (@(Get-CvJobAudioTracks -Audio $jobNoDef))[0].Default
Assert-Eq 'audio null -> 0 pistas'    0     (@(Get-CvJobAudioTracks -Audio $null)).Count

# Select-CvDefaultAudio: gana disposition.default; si ninguna, la de mas canales (mejor calidad)
$sA = [pscustomobject]@{
    index       = 1
    codec_name  = 'aac'
    channels    = 2
    disposition = [pscustomobject]@{ default = 0 }
}
$sB = [pscustomobject]@{
    index       = 2
    codec_name  = 'eac3'
    channels    = 6
    disposition = [pscustomobject]@{ default = 1 }
}
$sC = [pscustomobject]@{
    index       = 3
    codec_name  = 'aac'
    channels    = 6
    disposition = [pscustomobject]@{ default = 0 }
}
Assert-Eq 'default marcado gana'      2 (Select-CvDefaultAudio @($sA, $sB)).index
Assert-Eq 'sin default -> mas canales' 3 (Select-CvDefaultAudio @($sA, $sC)).index

# Resolve-CvAudioTitle: borrar (Keep=false -> '') vs mantener (Keep=true -> titulo del origen)
Assert-Eq 'audioKeepTitle def false' $false (Get-CvConfigDefaultValue 'encode/audio/keepTitle')
Assert-True 'help encode/audio/keepTitle' ((Get-CvConfigHelp).Contains('encode/audio/keepTitle'))
$infoT = [pscustomobject]@{ streams = @(
    [pscustomobject]@{
        index      = 1
        codec_type = 'audio'
        tags       = [pscustomobject]@{ title = 'Castellano 5.1' }
    }
    [pscustomobject]@{
        index      = 2
        codec_type = 'audio'
        tags       = [pscustomobject]@{ title = 'Comentarios' }
    }
    [pscustomobject]@{
        index      = 3
        codec_type = 'audio'
        tags       = [pscustomobject]@{}
    }
) }
Assert-Eq 'keep=false -> blanco'       '' (Resolve-CvAudioTitle -Keep $false -Info $infoT -Index 1)
Assert-Eq 'keep=true -> titulo origen' 'Castellano 5.1' (Resolve-CvAudioTitle -Keep $true -Info $infoT -Index 1)
Assert-Eq 'keep=true idx2'             'Comentarios'    (Resolve-CvAudioTitle -Keep $true -Info $infoT -Index 2)
Assert-Eq 'keep=true sin titulo -> ""' '' (Resolve-CvAudioTitle -Keep $true -Info $infoT -Index 3)
Assert-Eq 'keep=true indice inexistente -> ""' '' (Resolve-CvAudioTitle -Keep $true -Info $infoT -Index 9)

# Get-CvAudioTempPath: nombres por posicion (<name>_aN.*)
$ctxTmp = [pscustomobject]@{ Proceso = [System.IO.Path]::GetTempPath() }
Assert-True 'temp pos0 .m4a'  ((Get-CvAudioTempPath -Context $ctxTmp -Name 'Peli' -Pos 0).M4a     -like '*Peli_a0.m4a')
Assert-True 'temp pos1 .mka'  ((Get-CvAudioTempPath -Context $ctxTmp -Name 'Peli' -Pos 1).Mka     -like '*Peli_a1.mka')
Assert-True 'temp pos1 wav'   ((Get-CvAudioTempPath -Context $ctxTmp -Name 'Peli' -Pos 1).SyncWav -like '*Peli_a1_concat.wav')

# ================================================================================================
Write-Host "`nUtilidades (numeros / args / marcas)" -ForegroundColor Cyan
Assert-Eq 'InvDouble 3.14'          3.14  (ConvertTo-InvDouble '3.14')
Assert-Eq 'InvDouble -2.5'          -2.5  (ConvertTo-InvDouble '-2.5')
Assert-Eq 'InvDouble coma -> null'  $null (ConvertTo-InvDouble '1,5')   # locale-invariante (ffmpeg usa punto)
Assert-Eq 'InvDouble texto -> null' $null (ConvertTo-InvDouble 'abc')
Assert-Eq 'Format-CvNumber 0.5'  '0.5' (Format-CvNumber 0.5)
Assert-Eq 'Format-CvNumber 64'   '64'  (Format-CvNumber 64)
Assert-Eq 'ArgString simple'      'a -i'          (ConvertTo-ArgString @('a','-i'))
Assert-Eq 'ArgString con espacio' '-i "a b.mkv"'  (ConvertTo-ArgString @('-i','a b.mkv'))
Set-CvMarkStyle -Ascii $true
Assert-Eq 'marca ascii OK'    '[OK]'    (Get-CvMark $true)
Assert-Eq 'marca ascii ERROR' '[ERROR]' (Get-CvMark $false)
# Save-CvToolError: log con 2 secciones (ajustes del job + error)
$errDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv-errlog-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$errCtx = [pscustomobject]@{ Logs = $errDir }
$errJob = [pscustomobject]@{ profile = [pscustomobject]@{ VideoEncoder = 'hevc_nvenc' }; audio = [pscustomobject]@{ skip = $false } }
$errPath = Save-CvToolError -Context $errCtx -Name 'Peli [1080p]' -Tool 'ffmpeg-onepass' -StdErr 'Subtitle codec 0 is not supported' -Job $errJob
Assert-True 'ErrLog creado'         ($errPath -and (Test-Path -LiteralPath $errPath))
$errTxt = Get-Content -Raw -LiteralPath $errPath
Assert-True 'ErrLog seccion job'    ($errTxt -match 'AJUSTES DEL JOB')
Assert-True 'ErrLog seccion error'  ($errTxt -match 'ERROR \(stderr')
Assert-True 'ErrLog job serializado'($errTxt -match 'hevc_nvenc')
Assert-True 'ErrLog error incluido' ($errTxt -match 'Subtitle codec 0 is not supported')
Assert-Eq   'ErrLog sin StdErr -> vacio' '' (Save-CvToolError -Context $errCtx -Name 'x' -Tool 't' -StdErr '' -Job $errJob)
Remove-Item -Recurse -Force -LiteralPath $errDir -ErrorAction SilentlyContinue
Set-CvMarkStyle -Ascii $false
Assert-Eq 'marca check U+2713' ([char]::ConvertFromUtf32(0x2713)) (Get-CvMark $true)
Assert-Eq 'marca cruz U+00D7'  ([char]::ConvertFromUtf32(0x00D7)) (Get-CvMark $false)
Assert-Eq 'Resolve-CvSepWidth explicito'     12 (Resolve-CvSepWidth 12)
Assert-Eq 'Resolve-CvProgressBarWidth expl.'  8 (Resolve-CvProgressBarWidth 8)

# ================================================================================================
Write-Host "`nIdioma / rutas / tiempo" -ForegroundColor Cyan
Assert-Eq 'canon spa -> es'        'es'  (Get-CvLangCanon 'spa')
Assert-Eq 'canon es-ES -> es'      'es'  (Get-CvLangCanon 'es-ES')
Assert-Eq 'canon english -> en'    'en'  (Get-CvLangCanon 'english')
Assert-Eq 'canon castellano -> es' 'es'  (Get-CvLangCanon 'castellano')
Assert-Eq 'canon desconocido'      'xyz' (Get-CvLangCanon 'xyz')
Assert-Eq 'lang spa in [es]'   $true  (Test-CvLanguage 'spa'   @('es'))
Assert-Eq 'lang es_ES in [spa]' $true (Test-CvLanguage 'es_ES' @('spa'))
Assert-Eq 'lang eng in [es]'   $false (Test-CvLanguage 'eng'   @('es'))
Assert-Eq 'lang vacio -> false' $false (Test-CvLanguage ''     @('es'))
Assert-Eq 'SafeStart fuera -> 10%'   3  (Get-CvSafeStart 120 30)
Assert-Eq 'SafeStart dentro igual'  10  (Get-CvSafeStart 10 100)
Assert-Eq 'SafeStart dur<=0 igual'   5  (Get-CvSafeStart 5 0)
Assert-Eq 'Resolve-CvPath vacio'  'D:\R\Original' (Resolve-CvPath 'D:\R' '' 'Original')
Assert-Eq 'Resolve-CvPath absoluta' 'C:\abs' (Resolve-CvPath 'D:\R' 'C:\abs' 'X')
Assert-Eq 'Files dir inexistente -> 0' 0 (@(Get-CvFiles -Dir 'X:\no\existe\aqui' -Filters '*.txt')).Count
Assert-True 'Files lista .ps1 del test' ((@(Get-CvFiles -Dir $PSScriptRoot -Filters '*.ps1')).Count -ge 1)
$fdir = Join-Path ([IO.Path]::GetTempPath()) ("cvfiles-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fdir | Out-Null
'x' | Set-Content -LiteralPath (Join-Path $fdir 'a.mp4') -Encoding Ascii
'x' | Set-Content -LiteralPath (Join-Path $fdir 'b.mp4v') -Encoding Ascii
Assert-Eq 'Files -Exact excluye .mp4v' 1 (@(Get-CvFiles -Dir $fdir -Filters '*.mp4' -Exact)).Count
Remove-Item -LiteralPath $fdir -Recurse -Force -ErrorAction SilentlyContinue
Assert-Eq 'Resolve-CvPath relativa' 'D:\R\sub' (Resolve-CvPath 'D:\R' 'sub' 'X')
$infoDur = [pscustomobject]@{ format = [pscustomobject]@{ duration = '3236' } }
Assert-Eq 'DurationText <1h (bug v4.2.1)' '0:53:56' (Get-DurationText $infoDur)
Assert-Eq 'DurationText >1h' '1:01:01' (Get-DurationText ([pscustomobject]@{ format = [pscustomobject]@{ duration = '3661' } }))
Assert-Eq 'DurationText 0 -> ?' '?' (Get-DurationText ([pscustomobject]@{ format = [pscustomobject]@{ duration = '0' } }))
Assert-Eq 'MediaDuration'   3236 (Get-MediaDuration $infoDur)
Assert-Eq 'VideoSize'  '1920x1080' (Get-VideoSize ([pscustomobject]@{
    width  = 1920
    height = 1080
}))
Assert-Eq 'Get-Tag title' 'Hola' (Get-Tag ([pscustomobject]@{ tags = [pscustomobject]@{ title = 'Hola' } }) 'title')
Assert-Eq 'Get-Tag ausente -> null' $null (Get-Tag ([pscustomobject]@{ tags = [pscustomobject]@{} }) 'title')

# Get-CvDisplayWidth: ancho mostrado = almacenado x SAR (anamorfico)
Assert-Eq 'DisplayWidth SAR 1:1'      1920 (Get-CvDisplayWidth -Width 1920 -Sar '1:1')
Assert-Eq 'DisplayWidth SAR vacio'    1920 (Get-CvDisplayWidth -Width 1920 -Sar '')
Assert-Eq 'DisplayWidth SAR N/A'      1920 (Get-CvDisplayWidth -Width 1920 -Sar 'N/A')
Assert-Eq 'DisplayWidth SAR 0:1'      1920 (Get-CvDisplayWidth -Width 1920 -Sar '0:1')
Assert-Eq 'DisplayWidth anamorf 115:87' 2538 (Get-CvDisplayWidth -Width 1920 -Sar '115:87')
Assert-Eq 'DisplayWidth ancho 0'         0 (Get-CvDisplayWidth -Width 0 -Sar '115:87')

# Get-CvMaxWidthResize: compara ANCHO MOSTRADO; con anamorfico apunta a tw = MaxWidth/SAR
Assert-Eq 'MaxWidth cuadrado no supera'  ''       (Get-CvMaxWidthResize -Width 1280 -Sar '1:1'    -MaxWidth 1920)
Assert-Eq 'MaxWidth cuadrado supera'     '1280:-2' (Get-CvMaxWidthResize -Width 1920 -Sar '1:1'    -MaxWidth 1280)
Assert-Eq 'MaxWidth anamorf dispara'     '968:-2'  (Get-CvMaxWidthResize -Width 1920 -Sar '115:87' -MaxWidth 1280)
Assert-Eq 'MaxWidth anamorf no supera'   ''        (Get-CvMaxWidthResize -Width 1920 -Sar '115:87' -MaxWidth 2560)
Assert-Eq 'MaxWidth sin SAR = clasico'   '1280:-2' (Get-CvMaxWidthResize -Width 1920 -Sar ''       -MaxWidth 1280)
Assert-Eq 'MaxWidth <=0 -> vacio'        ''        (Get-CvMaxWidthResize -Width 1920 -Sar '1:1'    -MaxWidth 0)
Assert-Eq 'MaxWidth no amplia origen'    ''        (Get-CvMaxWidthResize -Width 640  -Sar '1:1'    -MaxWidth 1280)

# Get-CvResize: combina anamorfico (keep/square/squareheight) + maxWidth. Ejemplo: 1920x1072 SAR 115:87
Assert-Eq 'Resize keep=clasico'          '968:-2'          (Get-CvResize -Width 1920 -Height 1072 -Sar '115:87' -MaxWidth 1280 -Anamorphic 'keep')
Assert-Eq 'Resize keep sin maxWidth'     ''                (Get-CvResize -Width 1920 -Height 1072 -Sar '115:87' -MaxWidth 0    -Anamorphic 'keep')
Assert-Eq 'Resize square por ancho'      '1920:810,setsar=1' (Get-CvResize -Width 1920 -Height 1072 -Sar '115:87' -MaxWidth 0    -Anamorphic 'square')
Assert-Eq 'Resize square + maxWidth capa' '1280:540,setsar=1' (Get-CvResize -Width 1920 -Height 1072 -Sar '115:87' -MaxWidth 1280 -Anamorphic 'square')
Assert-Eq 'Resize squareheight por alto' '2538:1072,setsar=1' (Get-CvResize -Width 1920 -Height 1072 -Sar '115:87' -MaxWidth 0    -Anamorphic 'squareheight')
Assert-Eq 'Resize square SAR1:1=clasico' '1280:-2'         (Get-CvResize -Width 1920 -Height 1072 -Sar '1:1'    -MaxWidth 1280 -Anamorphic 'square')
Assert-Eq 'Resize square SAR1:1 sin max' ''                (Get-CvResize -Width 1920 -Height 1072 -Sar '1:1'    -MaxWidth 0    -Anamorphic 'square')
Assert-Eq 'Resize dims invalidas -> ""'  ''                (Get-CvResize -Width 0    -Height 1072 -Sar '115:87' -MaxWidth 1280 -Anamorphic 'square')

# Get-CvChangeSizeResize: changeSize fijo que SOLO reduce (no amplia). '1920:-2' sobre 4K reduce; sobre 720p no.
Assert-Eq 'ChangeSize reduce 4K'         '1920:-2' (Get-CvChangeSizeResize -ChangeSize '1920:-2' -Width 3840 -Height 2160)
Assert-Eq 'ChangeSize 720p no amplia'    ''        (Get-CvChangeSizeResize -ChangeSize '1920:-2' -Width 1280 -Height 720)
Assert-Eq 'ChangeSize igual ancho aplica' '1920:-2' (Get-CvChangeSizeResize -ChangeSize '1920:-2' -Width 1920 -Height 1080)
Assert-Eq 'ChangeSize WxH reduce'        '1280:720' (Get-CvChangeSizeResize -ChangeSize '1280:720' -Width 1920 -Height 1080)
Assert-Eq 'ChangeSize WxH ampliaria alto' '' (Get-CvChangeSizeResize -ChangeSize '1280:720' -Width 1000 -Height 480)
Assert-Eq 'ChangeSize vacio -> ""'       ''        (Get-CvChangeSizeResize -ChangeSize '' -Width 3840 -Height 2160)
Assert-Eq 'ChangeSize sin datos aplica'  '1920:-2' (Get-CvChangeSizeResize -ChangeSize '1920:-2' -Width 0 -Height 0)
Assert-Eq 'ChangeSize -2 ancho auto'     ''        (Get-CvChangeSizeResize -ChangeSize '-2:1080' -Width 1920 -Height 720)

# Get-CvAnamorphicWarning: aviso SIEMPRE si SAR != 1 (tamaño almacenado != mostrado)
Assert-Eq   'AnamWarn cuadrado -> ""'     '' (Get-CvAnamorphicWarning -Width 1920 -Height 1080 -Sar '1:1'    -Anamorphic 'keep')
Assert-Eq   'AnamWarn SAR vacio -> ""'    '' (Get-CvAnamorphicWarning -Width 1920 -Height 1080 -Sar ''       -Anamorphic 'keep')
Assert-Eq   'AnamWarn dims invalidas'     '' (Get-CvAnamorphicWarning -Width 0    -Height 1080 -Sar '115:87' -Anamorphic 'keep')
Assert-True 'AnamWarn keep: se VE a 2538'    ((Get-CvAnamorphicWarning -Width 1920 -Height 1072 -Sar '115:87' -Anamorphic 'keep')        -match '2538x1072')
Assert-True 'AnamWarn keep: menciona keep'   ((Get-CvAnamorphicWarning -Width 1920 -Height 1072 -Sar '115:87' -Anamorphic 'keep')        -match "keep")
Assert-True 'AnamWarn square: menciona square' ((Get-CvAnamorphicWarning -Width 1920 -Height 1072 -Sar '115:87' -Anamorphic 'square')    -match "square")

# ================================================================================================
Write-Host "`nAudio (layout / bitrate / rank / seleccion / parseo)" -ForegroundColor Cyan
Assert-Eq 'layout 1' 'mono'   (Get-CvChannelLayout 1)
Assert-Eq 'layout 2' 'stereo' (Get-CvChannelLayout 2)
Assert-Eq 'layout 6' '5.1'    (Get-CvChannelLayout 6)
Assert-Eq 'layout 8' '7.1'    (Get-CvChannelLayout 8)
Assert-Eq 'layout 3 -> stereo' 'stereo' (Get-CvChannelLayout 3)
Assert-Eq 'rank eac3>ac3' $true ((Get-CvAudioCodecRank 'eac3') -gt (Get-CvAudioCodecRank 'ac3'))
Assert-Eq 'rank truehd 100' 100 (Get-CvAudioCodecRank 'truehd')
Assert-Eq 'rank aac 40'      40 (Get-CvAudioCodecRank 'aac')
Assert-Eq 'bitrate de bit_rate' 640000 (Get-CvAudioBitrate ([pscustomobject]@{ bit_rate = '640000' }))
Assert-Eq 'bitrate de tag BPS'  768000 (Get-CvAudioBitrate ([pscustomobject]@{ tags = [pscustomobject]@{ BPS = '768000' } }))
Assert-Eq 'bitrate ausente -> null' $null (Get-CvAudioBitrate ([pscustomobject]@{}))
$sBest = @(
    [pscustomobject]@{
        index      = 3
        codec_name = 'ac3'
        channels   = 6
    }
    [pscustomobject]@{
        index      = 2
        codec_name = 'eac3'
        channels   = 6
    }
)
Assert-Eq 'BestAudio eac3>ac3 (=canales)' 2 (Select-CvBestAudio $sBest).index
$infoSel = [pscustomobject]@{ streams = @(
    [pscustomobject]@{
        index       = 1
        codec_type  = 'audio'
        codec_name  = 'aac'
        channels    = 2
        tags        = [pscustomobject]@{ language = 'eng' }
        disposition = [pscustomobject]@{ default = 1 }
    }
    [pscustomobject]@{
        index      = 2
        codec_type = 'audio'
        codec_name = 'eac3'
        channels   = 6
        tags       = [pscustomobject]@{ language = 'spa' }
    }
    [pscustomobject]@{
        index      = 3
        codec_type = 'audio'
        codec_name = 'ac3'
        channels   = 6
        tags       = [pscustomobject]@{ language = 'spa' }
    }
) }
$selA = Select-AudioStream -Info $infoSel -PrefLangs @('spa')
Assert-Eq 'AudioStream pref spa mejor' 2 $selA.Index
Assert-Eq 'AudioStream Is51'  $true  $selA.Is51
Assert-Eq 'AudioStream Lang'  'spa'  $selA.Language
$asel = ConvertTo-AudioSel ([pscustomobject]@{
    index    = 2
    channels = 6
    tags     = [pscustomobject]@{ language = 'spa' }
})
Assert-Eq 'AudioSel Index' 2 $asel.Index
Assert-Eq 'AudioSel Is51'  $true $asel.Is51
Assert-True 'AudioLine contiene idioma/codec' ((Format-CvAudioLine -Stream ([pscustomobject]@{
    index      = 5
    codec_name = 'aac'
    channels   = 2
    tags       = [pscustomobject]@{
        language = 'spa'
        title    = 'X'
    }
})) -match 'idioma=spa.*codec=aac')
$pv = ConvertFrom-CvPlayCommand 'P 2'
Assert-Eq 'Play P 2 index'    2     $pv.Index
Assert-Eq 'Play P 2 audioonly' $false $pv.AudioOnly
Assert-Eq 'Play P 2 start -1'  -1    $pv.Start
$pa = ConvertFrom-CvPlayCommand 'A 3 300' -AllowAudioOnly
Assert-Eq 'Play A 3 300 audioonly' $true $pa.AudioOnly
Assert-Eq 'Play A 3 300 start'     300   $pa.Start
Assert-Eq 'Play A sin AllowAudioOnly -> null' $null (ConvertFrom-CvPlayCommand 'A 3')
Assert-Eq 'Play indice suelto -> null'        $null (ConvertFrom-CvPlayCommand '5')

# ================================================================================================
Write-Host "`nSubtitulos" -ForegroundColor Cyan
Assert-Eq 'SubForced por flag'   $true  (Test-SubForced ([pscustomobject]@{ disposition = [pscustomobject]@{ forced = 1 } }))
Assert-Eq 'SubForced por titulo' $true  (Test-SubForced ([pscustomobject]@{ tags = [pscustomobject]@{ title = 'Forzados' } }))
Assert-Eq 'SubForced normal'     $false (Test-SubForced ([pscustomobject]@{ tags = [pscustomobject]@{ title = 'Completo' } }))
Assert-Eq 'SubDefault flag'      $true  (Test-SubDefault ([pscustomobject]@{ disposition = [pscustomobject]@{ default = 1 } }))
Assert-Eq 'SubDefault no'        $false (Test-SubDefault ([pscustomobject]@{ disposition = [pscustomobject]@{ default = 0 } }))
# Subtitulo utilizable: codec reconocible sí, codec ausente/'none'/'unknown' no (WEBVTT no soportado)
Assert-Eq 'SubUsable subrip'     $true  (Test-CvSubtitleUsable ([pscustomobject]@{ codec_name = 'subrip' }))
Assert-Eq 'SubUsable pgs'        $true  (Test-CvSubtitleUsable ([pscustomobject]@{ codec_name = 'hdmv_pgs_subtitle' }))
Assert-Eq 'SubUsable sin codec'  $false (Test-CvSubtitleUsable ([pscustomobject]@{ codec_name = $null }))
Assert-Eq 'SubUsable none'       $false (Test-CvSubtitleUsable ([pscustomobject]@{ codec_name = 'none' }))
Assert-Eq 'SubUsable unknown'    $false (Test-CvSubtitleUsable ([pscustomobject]@{ codec_name = 'unknown' }))
# Pista VACIA (sin cues): se detecta por tags (sin demultiplexar) o por un conteo ya hecho. Ante la
# duda (sin tags, sin conteo) NO se considera vacia: nunca se descarta una pista por no saber.
Assert-Eq 'SubEmpty NUMBER_OF_FRAMES 0'  $true  (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ NUMBER_OF_FRAMES = '0' } }))
Assert-Eq 'SubEmpty NUMBER_OF_FRAMES 12' $false (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ NUMBER_OF_FRAMES = '12' } }))
Assert-Eq 'SubEmpty DURATION 0'          $true  (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ DURATION = '00:00:00.000000000' } }))
Assert-Eq 'SubEmpty DURATION real'       $false (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ DURATION = '00:50:09.536000000' } }))
Assert-Eq 'SubEmpty sin tags'            $false (Test-CvSubtitleEmpty ([pscustomobject]@{ codec_name = 'subrip' }))
Assert-Eq 'SubEmpty cues 0 manda'        $true  (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ DURATION = '00:50:09.536000000' } }) -Cues 0)
Assert-Eq 'SubEmpty cues 5 manda'        $false (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ DURATION = '00:00:00.000000000' } }) -Cues 5)
Assert-Eq 'SubEmpty NOF gana a DURATION' $false (Test-CvSubtitleEmpty ([pscustomobject]@{ tags = [pscustomobject]@{ NUMBER_OF_FRAMES = '3'; DURATION = '00:00:00.000000000' } }))
# Conteo de cues: 'N/A' de '-count_packets' = CERO conocido (ffprobe ya demultiplexo), no desconocido.
Assert-Eq 'CueCount numero'   1082 (ConvertTo-CvCueCount '1082')
Assert-Eq 'CueCount N/A -> 0'    0 (ConvertTo-CvCueCount 'N/A')
Assert-Eq 'CueCount n/a -> 0'    0 (ConvertTo-CvCueCount " n/a `n")
Assert-Eq 'CueCount vacio -> -1' -1 (ConvertTo-CvCueCount '')
Assert-Eq 'CueCount basura -> -1' -1 (ConvertTo-CvCueCount 'error')
# Get-SubtitleStreams devuelve TODAS; Resolve-CvSubtitleAction decide copy/srt/rescue/discard
$stInfo = [pscustomobject]@{
    format  = [pscustomobject]@{ format_name = 'matroska,webm' }
    streams = @(
        [pscustomobject]@{ index = 3; codec_type = 'subtitle'; codec_name = $null }       # WEBVTT ilegible
        [pscustomobject]@{ index = 4; codec_type = 'subtitle'; codec_name = 'subrip' }
        [pscustomobject]@{ index = 5; codec_type = 'subtitle'; codec_name = 'ass' }
    )
}
Assert-Eq 'SubStreams todas' 3 (@(Get-SubtitleStreams -Info $stInfo).Count)
$ctxSub  = [pscustomobject]@{ SubtitlesToSrt = @('webvtt') }
$ctxSub2 = [pscustomobject]@{ SubtitlesToSrt = @('webvtt', 'ass') }
$ctxSub0 = [pscustomobject]@{ SubtitlesToSrt = @() }
Assert-Eq 'SubAction subrip copy'    'copy'    (Resolve-CvSubtitleAction -Context $ctxSub  -Info $stInfo -Stream $stInfo.streams[1])
Assert-Eq 'SubAction webvtt rescue'  'rescue'  (Resolve-CvSubtitleAction -Context $ctxSub  -Info $stInfo -Stream $stInfo.streams[0])
Assert-Eq 'SubAction ass->srt'       'srt'     (Resolve-CvSubtitleAction -Context $ctxSub2 -Info $stInfo -Stream $stInfo.streams[2])
Assert-Eq 'SubAction webvtt discard' 'discard' (Resolve-CvSubtitleAction -Context $ctxSub0 -Info $stInfo -Stream $stInfo.streams[0])
$mp4Info = [pscustomobject]@{ format = [pscustomobject]@{ format_name = 'mov,mp4' }; streams = @([pscustomobject]@{ index = 2; codec_type = 'subtitle'; codec_name = $null }) }
Assert-Eq 'SubAction no-mkv discard' 'discard' (Resolve-CvSubtitleAction -Context $ctxSub -Info $mp4Info -Stream $mp4Info.streams[0])
$subSel = ConvertTo-SubSel ([pscustomobject]@{
    index      = 4
    codec_name = 'subrip'
    tags       = [pscustomobject]@{
        language = 'spa'
        title    = 'T'
    }
}) -Forced $true -Default $true
Assert-Eq 'SubSel Index'   4      $subSel.Index
Assert-Eq 'SubSel Forced'  $true  $subSel.Forced
Assert-Eq 'SubSel Default' $true  $subSel.Default
Assert-Eq 'SubSel Lang'    'spa'  $subSel.Lang
# -Lang fuerza el idioma de salida (origen mal etiquetado: 'eng' que es 'spa'); vacio = mantener
$subLangOv = ConvertTo-SubSel ([pscustomobject]@{ index = 2; codec_name = 'ass'; tags = [pscustomobject]@{ language = 'eng' } }) -Forced $false -Default $false -Lang 'spa'
Assert-Eq 'SubSel Lang override' 'spa' $subLangOv.Lang
Assert-Eq 'SubSel Lang sin override' 'eng' (ConvertTo-SubSel ([pscustomobject]@{ index = 2; codec_name = 'ass'; tags = [pscustomobject]@{ language = 'eng' } }) -Forced $false -Default $false).Lang
# Disposition por pista: forzada -> default+forced; completa -> '0' (aunque el origen fuera default)
$dispSubs = @(
    [pscustomobject]@{ Index = 1; Lang = 'spa'; Forced = $true;  Default = $true },
    [pscustomobject]@{ Index = 2; Lang = 'spa'; Forced = $false; Default = $false }
)
$dispStr = (Get-CvSubtitleMapArgs -Subtitles $dispSubs -InputIndex 0) -join ' '
Assert-True 'SubDisp forzada default+forced' ($dispStr -match '-disposition:s:0 default\+forced')
Assert-True 'SubDisp completa 0'             ($dispStr -match '-disposition:s:1 0')
$fSubs = @(
    [pscustomobject]@{
        index       = 1
        codec_name  = 'subrip'
        disposition = [pscustomobject]@{ forced = 1 }
        tags        = [pscustomobject]@{ language = 'spa' }
    }
    [pscustomobject]@{
        index       = 2
        codec_name  = 'subrip'
        disposition = [pscustomobject]@{ forced = 0 }
        tags        = [pscustomobject]@{ language = 'spa' }
    }
)
$roles = Split-CvSubtitlesByRole -Context ([pscustomobject]@{}) -Info ([pscustomobject]@{}) -Subs $fSubs
Assert-Eq 'Split forzado 1'  1 @($roles.Forced).Count
Assert-Eq 'Split completo 1' 1 @($roles.Complete).Count
$infoPos = [pscustomobject]@{ streams = @(
    [pscustomobject]@{
        index      = 0
        codec_type = 'video'
    }
    [pscustomobject]@{
        index      = 1
        codec_type = 'subtitle'
    }
    [pscustomobject]@{
        index      = 2
        codec_type = 'subtitle'
    }
) }
Assert-Eq 'SubStreamPos idx2 -> 1' 1 (Get-SubtitleStreamPos -Info $infoPos -Index 2)

# ================================================================================================
Write-Host "`nSubtitulos .srt (SubtitleSRT: tiempos / bloques / OCR / sincronia)" -ForegroundColor Cyan
# Conversion de tiempos
Assert-Eq 'SrtSeconds hh:mm:ss,mmm' 3723.5 (ConvertTo-CvSrtSeconds '01:02:03,500')
Assert-Eq 'SrtSeconds con punto'    3723.5 (ConvertTo-CvSrtSeconds '01:02:03.500')
Assert-Eq 'SrtSeconds mm:ss'          65   (ConvertTo-CvSrtSeconds '01:05')
Assert-Eq 'SrtSeconds signo +'         3   (ConvertTo-CvSrtSeconds '+3')
Assert-Eq 'SrtSeconds invalido'      $null (ConvertTo-CvSrtSeconds 'xx')
Assert-Eq 'SrtStamp 3723.5'  '01:02:03,500' (ConvertTo-CvSrtStamp 3723.5)
Assert-Eq 'SrtStamp negativo' '00:00:00,000' (ConvertTo-CvSrtStamp -5)
# Bloques / numeros / inicio de cue
$srtDemo = "1`r`n00:00:10,000 --> 00:00:11,000`r`nuno`r`n`r`n2`r`n00:01:00,000 --> 00:01:01,000`r`ndos"
Assert-Eq 'SrtBlocks = 2'    2   (@(Get-CvSrtBlocks $srtDemo)).Count
Assert-Eq 'SrtBlockNum 1o'   1   (Get-CvSrtBlockNum (@(Get-CvSrtBlocks $srtDemo))[0])
Assert-Eq 'SrtCueStart cue2' 60  (Get-CvSrtCueStart (@(Get-CvSrtBlocks $srtDemo)) 2)
Assert-Eq 'SrtCueStart inexistente' $null (Get-CvSrtCueStart (@(Get-CvSrtBlocks $srtDemo)) 9)
# Ajuste lineal
$fit = Get-CvSrtLinearFit 0 10 100 210
Assert-Eq 'LinearFit A' 2  $fit.A
Assert-Eq 'LinearFit B' 10 $fit.B
Assert-Eq 'LinearFit misma cue -> null' $null (Get-CvSrtLinearFit 5 1 5 2)
# OCR (l->I en mayusculas) y espaciado
$ocr = Repair-CvSrtOcr "MANSlON y los que"
Assert-Eq 'OCR: 1 cambio'  1 $ocr.Changed.Count
Assert-True 'OCR: MANSION' ($ocr.Text -match 'MANSION')
Assert-True 'OCR: no toca minusculas' ($ocr.Text -match 'los que')
$esp = Repair-CvSrtSpacing ("{0} Hola {1} Que" -f [char]0xA1, [char]0xBF)
Assert-Eq 'espaciado: 2' 2 $esp.Count
# Resync: offset (B=+5) a todas; y por tramos (FromCue=2)
$rs = Invoke-CvSrtResync -Text $srtDemo -A 1 -B 5
Assert-True 'resync offset cue1 15s' ($rs -match '00:00:15,000')
Assert-True 'resync offset cue2 65s' ($rs -match '00:01:05,000')
$rt = Invoke-CvSrtResync -Text $srtDemo -A 1 -B 5 -FromCue 2
Assert-True 'resync tramos cue1 intacta' ($rt -match '00:00:10,000')
Assert-True 'resync tramos cue2 movida'  ($rt -match '00:01:05,000')
# Find-CvSrtVideo: localiza el video que acompana al .srt (mismo nombre / stem sin idioma)
$vdir = Join-Path ([IO.Path]::GetTempPath()) ("cvsrt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $vdir | Out-Null
'x' | Set-Content -LiteralPath (Join-Path $vdir 'peli.mkv') -Encoding Ascii
Assert-True 'FindVideo por stem (.es.srt)' ((Find-CvSrtVideo -Dir $vdir -SrtPath (Join-Path $vdir 'peli.es.srt')) -like '*peli.mkv')
Assert-Eq   'FindVideo sin match -> null' $null (Find-CvSrtVideo -Dir $vdir -SrtPath (Join-Path $vdir 'otra.srt'))
Remove-Item -LiteralPath $vdir -Recurse -Force -ErrorAction SilentlyContinue

# ================================================================================================
Write-Host "`nPerfiles" -ForegroundColor Cyan
$np = New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23
Assert-Eq 'New-CvProfile audioEncoder def' 'aac_coder' $np.AudioEncoder
Assert-Eq 'New-CvProfile audioCodec def'   'aac'       $np.AudioCodec
Assert-Eq 'New-CvProfile bitrate def'      '192k'      $np.AudioBitrate
Assert-Eq 'ProfileProp presente'  'v' (Get-CvProfileProp ([pscustomobject]@{ k = 'v' }) 'k' 'def')
Assert-Eq 'ProfileProp ausente'   'def' (Get-CvProfileProp ([pscustomobject]@{ k = 'v' }) 'z' 'def')
Assert-Eq 'ProfileProp null obj'  'def' (Get-CvProfileProp $null 'k' 'def')
$cp = ConvertTo-CvProfile ([pscustomobject]@{
    videoEncoder = 'hevc_nvenc'
    qmin         = 1
    qmax         = 23
    detectBorder = 'auto'
})
Assert-Eq 'ConvertTo-CvProfile encoder' 'hevc_nvenc' $cp.VideoEncoder
Assert-Eq 'ConvertTo-CvProfile detectBorder auto' 'auto' $cp.DetectBorder
# NoUpscale: default false en New-CvProfile; ConvertTo-CvProfile lo lee de config (noUpscale).
Assert-Eq 'New-CvProfile NoUpscale def' $false $np.NoUpscale
Assert-Eq 'ConvertTo-CvProfile noUpscale' $true (ConvertTo-CvProfile ([pscustomobject]@{ videoEncoder = 'hevc_nvenc'; changeSize = '1920:-2'; noUpscale = $true })).NoUpscale
Assert-Eq 'ConvertTo-CvProfile noUpscale def false' $false (ConvertTo-CvProfile ([pscustomobject]@{ videoEncoder = 'hevc_nvenc'; changeSize = '1920:-2' })).NoUpscale
Assert-Eq 'Label NVENC' 'A: 192K, V: h265[NV]/M10/L5/Q(1-23)' (Format-CvProfileLabel $np)
# Label: changeSize sin NoUpscale => 'RESIZE 1920:-2'; con NoUpscale => 'RESIZE<= 1920:-2'.
Assert-True 'Label RESIZE escala siempre' ((Format-CvProfileLabel (New-CvProfile -VideoEncoder 'hevc_nvenc' -ChangeSize '1920:-2')) -match 'RESIZE 1920:-2')
Assert-True 'Label RESIZE<= solo reduce'  ((Format-CvProfileLabel (New-CvProfile -VideoEncoder 'hevc_nvenc' -ChangeSize '1920:-2' -NoUpscale $true)) -match 'RESIZE<= 1920:-2')
Assert-Eq 'Label copy' 'A: COPY, V: COPY' (Format-CvProfileLabel (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy'))
Assert-Eq 'catalogo encoders = 7' 7 (Get-CvVideoEncoders).Count
Assert-True 'encoders incluye libsvtav1' (@(Get-CvVideoEncoders | ForEach-Object { $_.Value }) -contains 'libsvtav1')
Assert-True 'encoders incluye av1_nvenc'  (@(Get-CvVideoEncoders | ForEach-Object { $_.Value }) -contains 'av1_nvenc')
Assert-Eq 'codecOptions av1 sin levels' 0 (@((Get-CvCodecOptions -Encoder 'libsvtav1').Levels)).Count
Assert-True 'label av1 CPU (CRF)' ((Format-CvProfileLabel (New-CvProfile -VideoEncoder 'libsvtav1' -Crf 30)) -match 'av1.*CRF30')
Assert-Eq   'CpuEncoders = 3'      3 (@(Get-CvCpuEncoders)).Count
Assert-True 'CpuEncoders svtav1'   (@(Get-CvCpuEncoders) -contains 'libsvtav1')
Assert-Eq   'Multipass2Pass = 2'   2 (@(Get-CvMultipass2Pass)).Count
Assert-Eq   'AutoPriority = 6'     6 (@(Get-CvAutoEncoderPriority)).Count
Assert-Eq   'AutoPriority 1o av1'  'av1_nvenc' (@(Get-CvAutoEncoderPriority)[0].Value)
Assert-True 'CodecRank av1>h265>h264' (((Get-CvCodecRank 'av1') -gt (Get-CvCodecRank 'h265')) -and ((Get-CvCodecRank 'h265') -gt (Get-CvCodecRank 'h264')))
# Filtros de Resolve (Context nulo => la sonda considera todo soportado; se prueban tope y gpuOnly):
Assert-Eq   'Resolve sin tope -> av1'    'av1_nvenc'  (Resolve-CvAutoEncoder -Context $null)
Assert-Eq   'Resolve tope h265 -> hevc'  'hevc_nvenc' (Resolve-CvAutoEncoder -Context $null -MaxCodec 'h265')
Assert-Eq   'Resolve tope h264 -> h264'  'h264_nvenc' (Resolve-CvAutoEncoder -Context $null -MaxCodec 'h264')
Assert-Eq   'Resolve gpuOnly+h265'       'hevc_nvenc' (Resolve-CvAutoEncoder -Context $null -GpuOnly $true -MaxCodec 'h265')
$autoP = New-CvAutoProfile -Context $null
Assert-Eq   'AutoProfile main10'   'main10' $autoP.VideoProfile
Assert-True 'AutoProfile con tasa' (($null -ne $autoP.Qmax) -or ($null -ne $autoP.Crf))
# Get-CvAutoRate: control de tasa por encoder (fuente unica de New-CvAutoProfile / Resolve-CvProfileAuto).
Assert-Eq   'AutoRate libx264 crf 21'      21     (Get-CvAutoRate -Encoder 'libx264').Crf
Assert-Eq   'AutoRate libsvtav1 crf 30'    30     (Get-CvAutoRate -Encoder 'libsvtav1').Crf
Assert-Eq   'AutoRate hevc_nvenc qmax 23'  23     (Get-CvAutoRate -Encoder 'hevc_nvenc').Qmax
Assert-Eq   'AutoRate h264_nvenc profile'  'high' (Get-CvAutoRate -Encoder 'h264_nvenc').VideoProfile
Assert-Eq   'AutoRate av1_nvenc sin level' ''     (Get-CvAutoRate -Encoder 'av1_nvenc').VideoLevel
# Nivel en TODOS los H.26x, incluidos los de CPU (antes CPU quedaba sin level); AV1 CPU sigue sin level.
Assert-Eq   'AutoRate libx264 level 5.0'   '5.0'  (Get-CvAutoRate -Encoder 'libx264').VideoLevel
Assert-Eq   'AutoRate libx265 level 5.0'   '5.0'  (Get-CvAutoRate -Encoder 'libx265').VideoLevel
Assert-Eq   'AutoRate libx265 profile'     'main10' (Get-CvAutoRate -Encoder 'libx265').VideoProfile
Assert-Eq   'AutoRate libsvtav1 sin level' ''     (Get-CvAutoRate -Encoder 'libsvtav1').VideoLevel
# Los valores salen de config (no hardcodeados): un Context con otros valores cambia la tasa.
$rateCtx = [pscustomobject]@{ AutoCrf = 18; AutoCrfAv1 = 26; AutoQmin = 2; AutoQmax = 20; AutoLevel = '4.1' }
Assert-Eq   'AutoRate Context CRF x264'    18     (Get-CvAutoRate -Encoder 'libx264'    -Context $rateCtx).Crf
Assert-Eq   'AutoRate Context CRF av1'     26     (Get-CvAutoRate -Encoder 'libsvtav1'  -Context $rateCtx).Crf
Assert-Eq   'AutoRate Context Qmax NVENC'  20     (Get-CvAutoRate -Encoder 'hevc_nvenc' -Context $rateCtx).Qmax
Assert-Eq   'AutoRate Context level NVENC' '4.1'  (Get-CvAutoRate -Encoder 'hevc_nvenc' -Context $rateCtx).VideoLevel
# Resolve-CvProfileAuto: videoEncoder "auto" en config.json -> encoder concreto conservando el resto.
$fakeFfCtx = [pscustomobject]@{ AutoGpuOnly = $false; AutoMaxCodec = ''; FFmpeg = 'Z:\no\existe\ffmpeg.exe' }
$pAuto = New-CvProfile -VideoEncoder 'auto' -AudioCodec 'ac3' -AudioBitrate '256k' -ChangeSize '1280:-2'
$rAuto = Resolve-CvProfileAuto -Context $fakeFfCtx -Prof $pAuto
Assert-True 'ProfileAuto ya no es auto'     ($rAuto.VideoEncoder -ne 'auto')
Assert-Eq   'ProfileAuto sin tope -> av1'   'av1_nvenc' $rAuto.VideoEncoder
Assert-Eq   'ProfileAuto conserva audio'    'ac3'       $rAuto.AudioCodec
Assert-Eq   'ProfileAuto conserva resize'   '1280:-2'   $rAuto.ChangeSize
$rAutoH264 = Resolve-CvProfileAuto -Context ([pscustomobject]@{ AutoGpuOnly = $false; AutoMaxCodec = 'h264'; FFmpeg = 'Z:\no\existe\ffmpeg.exe' }) -Prof (New-CvProfile -VideoEncoder 'auto')
Assert-Eq   'ProfileAuto tope h264'         'h264_nvenc' $rAutoH264.VideoEncoder
Assert-True 'ProfileAuto rellena QP'        (($null -ne $rAutoH264.Qmin) -and ($null -ne $rAutoH264.Qmax))
Assert-Eq   'ProfileAuto no-op si concreto' 'libx264'   (Resolve-CvProfileAuto -Context $fakeFfCtx -Prof (New-CvProfile -VideoEncoder 'libx264' -Crf 23)).VideoEncoder
Assert-Eq   'Av1Encoders = 2'      2 (@(Get-CvAv1Encoders)).Count
Assert-True 'Av1Encoders svtav1'   (@(Get-CvAv1Encoders) -contains 'libsvtav1')
Assert-True 'Av1Encoders nvenc'    (@(Get-CvAv1Encoders) -contains 'av1_nvenc')
Assert-True 'ningun encoder [BETA]' ((@(Get-CvVideoEncoders | Where-Object { $_.Text -match '\[BETA\]' })).Count -eq 0)
Assert-True 'av1_nvenc [SIN PROBAR]' ((@(Get-CvVideoEncoders | Where-Object { $_.Value -eq 'av1_nvenc' })[0].Text) -match '\[SIN PROBAR\]')
Assert-True 'libsvtav1 sin etiqueta' ((@(Get-CvVideoEncoders | Where-Object { $_.Value -eq 'libsvtav1' })[0].Text) -notmatch '\[(BETA|SIN PROBAR)\]')
Assert-True 'encoders incluye hevc_nvenc' (@(Get-CvVideoEncoders | ForEach-Object { $_.Value }) -contains 'hevc_nvenc')
Assert-True 'codecs incluye flac' (@(Get-CvAudioCodecs | ForEach-Object { $_.Value }) -contains 'flac')
Assert-True 'codecOptions hevc main10' (@((Get-CvCodecOptions 'hevc_nvenc').Profiles | ForEach-Object { $_.Value }) -contains 'main10')
Assert-True 'bitrates ac3 hasta 640k' (@(Get-CvAudioBitrates 'ac3' | ForEach-Object { $_.Value }) -contains '640k')

# ================================================================================================
Write-Host "`nPerfiles propios (guardar en config.json)" -ForegroundColor Cyan
# ConvertTo-CvProfileConfig es el INVERSO de ConvertTo-CvProfile: lo que se guarda en 'profiles'.
$pGuard = New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23 `
    -DetectBorder 'auto' -ChangeSize '1920:-2' -NoUpscale $true -AudioCodec 'ac3' -AudioBitrate '448k'
$eGuard = ConvertTo-CvProfileConfig -Prof $pGuard -Label 'Serie 1080p'
Assert-Eq   'ProfileConfig label'        'Serie 1080p' $eGuard.label
Assert-Eq   'ProfileConfig encoder'      'hevc_nvenc'  $eGuard.videoEncoder
Assert-Eq   'ProfileConfig detectBorder' 'auto'        $eGuard.detectBorder
Assert-Eq   'ProfileConfig noUpscale'    $true         $eGuard.noUpscale
Assert-Eq   'ProfileConfig qmax'         23            $eGuard.qmax
# Lo que NO tiene valor no se escribe: un campo ausente significa "usa el global de encode.*", que
# es como lo lee ConvertTo-CvProfile (asi el perfil sigue al config si manana cambia el global).
Assert-Eq   'ProfileConfig sin crf'      $null ($eGuard.PSObject.Properties['crf'])
Assert-Eq   'ProfileConfig sin maxWidth' $null ($eGuard.PSObject.Properties['maxWidth'])
Assert-Eq   'ProfileConfig detectBorder false no se escribe' $null `
    ((ConvertTo-CvProfileConfig -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 22) -Label 'x').PSObject.Properties['detectBorder'])
# IDA Y VUELTA: guardar y volver a leer tiene que dar el MISMO perfil (es lo que garantiza que un
# perfil guardado se comporte igual que el que se acaba de ajustar).
$pBack = ConvertTo-CvProfile $eGuard
foreach ($k in @('VideoEncoder', 'VideoProfile', 'VideoLevel', 'Qmin', 'Qmax', 'Crf', 'DetectBorder', 'ChangeSize', 'NoUpscale', 'MaxWidth', 'Multipass', 'AudioEncoder', 'AudioCodec', 'AudioBitrate', 'AudioHz', 'AudioChannels', 'DownmixMode')) {
    Assert-Eq ("ProfileConfig ida y vuelta: {0}" -f $k) "$($pGuard.$k)" "$($pBack.$k)"
}
Assert-Eq 'ProfileConfig ida y vuelta: copy' 'copy' (ConvertTo-CvProfile (ConvertTo-CvProfileConfig -Prof (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy') -Label 'c')).VideoEncoder
# Nombre: obligatorio, sin duplicados (sin distinguir mayusculas) y renombrarse a si mismo vale.
$exist = @(
    [pscustomobject]@{ label = 'Serie 1080p'; videoEncoder = 'libx265' }
    [pscustomobject]@{ label = 'Peliculas';   videoEncoder = 'libx265' }
)
Assert-Eq   'Nombre vacio no vale'     $false (Test-CvProfileName -Name '   ' -Existing $exist).Ok
Assert-Eq   'Nombre nuevo vale'        $true  (Test-CvProfileName -Name 'Anime' -Existing $exist).Ok
Assert-Eq   'Nombre duplicado no vale' $false (Test-CvProfileName -Name 'serie 1080p' -Existing $exist).Ok
Assert-Eq   'Renombrarse a si mismo'   $true  (Test-CvProfileName -Name 'Serie 1080p' -Existing $exist -Allow 'Serie 1080p').Ok
Assert-True 'Nombre duplicado lo dice' ((Test-CvProfileName -Name 'Peliculas' -Existing $exist).Error -match 'Peliculas')
# Lista: anadir al final, sustituir por nombre y renombrar (-Replace) sin cambiar de sitio.
$lAdd = @(Set-CvProfileInList -List $exist -Entry ([pscustomobject]@{ label = 'Anime'; videoEncoder = 'libx264' }))
Assert-Eq   'Lista: anade al final'    'Serie 1080p|Peliculas|Anime' ((@($lAdd | ForEach-Object { Get-CvProfileLabel $_ }) -join '|'))
$lRep = @(Set-CvProfileInList -List $exist -Entry ([pscustomobject]@{ label = 'Serie 1080p'; videoEncoder = 'libx264' }))
Assert-Eq   'Lista: sustituye, no duplica' 2 $lRep.Count
Assert-Eq   'Lista: sustituye en su sitio' 'libx264' $lRep[0].videoEncoder
$lRen = @(Set-CvProfileInList -List $exist -Entry ([pscustomobject]@{ label = 'Series HD'; videoEncoder = 'libx265' }) -Replace 'Serie 1080p')
Assert-Eq   'Lista: renombra en su sitio'  'Series HD|Peliculas' ((@($lRen | ForEach-Object { Get-CvProfileLabel $_ }) -join '|'))
Assert-Eq   'Lista: borra por nombre'      'Peliculas' ((@(Remove-CvProfileFromList -List $exist -Label 'Serie 1080p') | ForEach-Object { Get-CvProfileLabel $_ }) -join '|')
Assert-Eq   'Lista: borrar lo que no esta no toca nada' 2 (@(Remove-CvProfileFromList -List $exist -Label 'No existe')).Count
# Seccion 'profiles' ausente: array VACIO, no un elemento fantasma (@($null) cuenta 1 y acabaria
# escrito como 'null' en el fichero).
Assert-Eq   'Lista de un config sin profiles' 0 (@(Get-CvProfileList ([pscustomobject]@{ encode = @{} }))).Count

# Sobre un config.json de verdad (en temporal): guardar, releer, renombrar y borrar.
# Perfiles DE SERIE: se listan para poder DUPLICARLOS (no se editan: viven en el codigo).
$serie = @(Get-CvBuiltinProfileRows)
Assert-True 'Perfiles de serie: hay varios'      ($serie.Count -ge 10)
Assert-Eq   'Perfiles de serie: numeracion desde 1' 1 ([int]$serie[0].Num)
Assert-Eq   'Perfiles de serie: numeracion seguida' $serie.Count ([int]$serie[-1].Num)
Assert-Eq   'Perfiles de serie: etiquetas distintas' $serie.Count (@($serie | ForEach-Object { $_.Label } | Select-Object -Unique)).Count
Assert-Eq   'Perfiles de serie: se marcan como tales' 0 (@($serie | Where-Object { "$($_.Kind)" -ne 'serie' })).Count
Assert-True 'Perfiles de serie: cada uno dice que hace' ((@($serie | Where-Object { "$($_.Text)".Trim() -eq '' })).Count -eq 0)
Assert-True 'Perfiles de serie: se puede partir de ellos' ($null -ne $serie[0].Prof.VideoEncoder)
# Perfil PREDETERMINADO: que clave de menu le toca (la misma numeracion en ventana y consola).
# pscustomobject, que es lo que devuelve leer el config (un hashtable no expone sus claves como
# propiedades y Get-CvProfileProp no las veria).
$exProf = @(
    [pscustomobject]@{ label = 'Series CPU'; videoEncoder = 'libx265' }
    [pscustomobject]@{ label = 'Peliculas';  videoEncoder = 'hevc_nvenc' }
)
Assert-Eq 'Predeterminado: de fabrica es Auto' 'Auto' "$((Get-CvConfigDefaults).defaultProfile)"
Assert-Eq 'Predeterminado: vacio -> Auto'      'A' (Get-CvDefaultProfileKey -Default '' -Extra $exProf)
Assert-Eq 'Predeterminado: Auto -> Auto'       'A' (Get-CvDefaultProfileKey -Default 'auto' -Extra $exProf)
Assert-Eq 'Predeterminado: uno de serie'       '3' (Get-CvDefaultProfileKey -Default 'Perfil 3' -Extra $exProf)
Assert-Eq 'Predeterminado: da igual como se escriba' '3' (Get-CvDefaultProfileKey -Default '  PERFIL 3 ' -Extra $exProf)
Assert-Eq 'Predeterminado: uno propio va detras' "$($serie.Count + 1)" (Get-CvDefaultProfileKey -Default 'Series CPU' -Extra $exProf)
Assert-Eq 'Predeterminado: el segundo propio'       "$($serie.Count + 2)" (Get-CvDefaultProfileKey -Default 'Peliculas' -Extra $exProf)
# Lo que ya no existe (un perfil borrado, o un numero que se fue) no puede dejar la cosa colgada.
Assert-Eq 'Predeterminado: nombre que ya no esta -> Auto' 'A' (Get-CvDefaultProfileKey -Default 'Lo que sea' -Extra $exProf)
Assert-Eq 'Predeterminado: numero fuera de rango -> Auto' 'A' (Get-CvDefaultProfileKey -Default 'Perfil 99' -Extra $exProf)

$profDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_prof_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $profDir -Force | Out-Null
$profCfg = Join-Path $profDir 'config.json'
[void](Save-CvTextFile -Path $profCfg -Text '{ "encode": { "video": { "fps": "25" } } }')
$rSave = Save-CvConfigProfile -Path $profCfg -Prof $pGuard -Label 'Serie 1080p'
Assert-Eq   'Guardar: ok'              $true  $rSave.Ok
Assert-Eq   'Guardar: uno en config'   1      (@(Get-CvConfigProfiles -Path $profCfg)).Count
Assert-Eq   'Guardar: con su nombre'   'Serie 1080p' (Get-CvProfileLabel (@(Get-CvConfigProfiles -Path $profCfg)[0]))
Assert-Eq   'Guardar: no toca el resto' '25' "$((Read-CvConfigFile -Path $profCfg).encode.video.fps)"
# El perfil guardado vuelve IGUAL al pasar por el catalogo del menu (que es como se usa).
$leido = ConvertTo-CvProfile (@(Get-CvConfigProfiles -Path $profCfg)[0])
Assert-Eq   'Guardar: mismo encoder'   'hevc_nvenc' $leido.VideoEncoder
Assert-Eq   'Guardar: misma etiqueta'  (Format-CvProfileLabel $pGuard) (Format-CvProfileLabel $leido)
# Mismo nombre otra vez = EDITAR (sustituye), no duplicar.
$rEdit = Save-CvConfigProfile -Path $profCfg -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 22) -Label 'Serie 1080p'
Assert-Eq   'Editar: ok'               $true  $rEdit.Ok
Assert-Eq   'Editar: sigue habiendo 1' 1      (@(Get-CvConfigProfiles -Path $profCfg)).Count
Assert-Eq   'Editar: con el valor nuevo' 'libx265' "$((@(Get-CvConfigProfiles -Path $profCfg)[0]).videoEncoder)"
# Un nombre que ya usa OTRO perfil se rechaza (y no se escribe nada).
[void](Save-CvConfigProfile -Path $profCfg -Prof (New-CvProfile -VideoEncoder 'libx264') -Label 'Peliculas')
$rDup = Save-CvConfigProfile -Path $profCfg -Prof (New-CvProfile -VideoEncoder 'libx264') -Label 'serie 1080p' -Replace 'Peliculas'
Assert-Eq   'Duplicado: rechazado'     $false $rDup.Ok
Assert-Eq   'Duplicado: no se guarda'  2      (@(Get-CvConfigProfiles -Path $profCfg)).Count
# Renombrar conserva el sitio y no duplica.
$rRen = Save-CvConfigProfile -Path $profCfg -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 22) -Label 'Series HD' -Replace 'Serie 1080p'
Assert-Eq   'Renombrar: ok'            $true  $rRen.Ok
Assert-Eq   'Renombrar: nombres'       'Series HD|Peliculas' ((@(Get-CvConfigProfiles -Path $profCfg) | ForEach-Object { Get-CvProfileLabel $_ }) -join '|')
# Borrar.
Assert-Eq   'Borrar: ok'               $true  (Remove-CvConfigProfile -Path $profCfg -Label 'Peliculas').Ok
Assert-Eq   'Borrar: queda uno'        1      (@(Get-CvConfigProfiles -Path $profCfg)).Count
Assert-Eq   'Borrar: el que no esta'   $false (Remove-CvConfigProfile -Path $profCfg -Label 'No existe').Ok
# Config sin la seccion 'profiles': se crea al guardar el primero.
$profCfg2 = Join-Path $profDir 'config2.json'
[void](Save-CvTextFile -Path $profCfg2 -Text '{ "behavior": { "workers": 2 } }')
Assert-Eq   'Sin seccion: no hay perfiles' 0 (@(Get-CvConfigProfiles -Path $profCfg2)).Count
Assert-Eq   'Sin seccion: se crea'         $true (Save-CvConfigProfile -Path $profCfg2 -Prof (New-CvProfile -VideoEncoder 'copy') -Label 'Solo contenedor').Ok
Assert-Eq   'Sin seccion: y queda uno'     1 (@(Get-CvConfigProfiles -Path $profCfg2)).Count
Assert-Eq   'Sin seccion: no toca lo suyo' 2 ([int]((Read-CvConfigFile -Path $profCfg2).behavior.workers))
Remove-Item -LiteralPath $profDir -Recurse -Force -ErrorAction SilentlyContinue

# ================================================================================================
Write-Host "`nGuardar un valor suelto del config" -ForegroundColor Cyan
# Lo que necesita una ventana para recordar una preferencia (el tema) sin montar el editor entero.
# Guardar el predeterminado: escribe SOLO esa clave y se relee del fichero (no del contexto).
$dpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_defprof_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dpDir -Force | Out-Null
$dpCfg = Join-Path $dpDir 'config.json'
[void](Save-CvTextFile -Path $dpCfg -Text '{ "behavior": { "workers": 3 } }')
Assert-Eq   'Predeterminado: sin nada puesto es Auto' 'Auto' (Get-CvConfigDefaultProfile -Path $dpCfg)
Assert-Eq   'Predeterminado: fichero que no existe'   'Auto' (Get-CvConfigDefaultProfile -Path (Join-Path $dpDir 'no.json'))
Assert-True 'Predeterminado: se guarda'  (Save-CvConfigDefaultProfile -Path $dpCfg -Label 'Series CPU').Ok
Assert-Eq   'Predeterminado: y se relee' 'Series CPU' (Get-CvConfigDefaultProfile -Path $dpCfg)
Assert-Eq   'Predeterminado: no toca el resto del config' 3 ([int](Read-CvConfigFile -Path $dpCfg).behavior.workers)
Assert-True 'Predeterminado: vacio vuelve a Auto' (Save-CvConfigDefaultProfile -Path $dpCfg -Label '').Ok
Assert-Eq   'Predeterminado: queda Auto'  'Auto' (Get-CvConfigDefaultProfile -Path $dpCfg)
Remove-Item -Recurse -Force -LiteralPath $dpDir -ErrorAction SilentlyContinue

$svDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_setval_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $svDir -Force | Out-Null
$svCfg = Join-Path $svDir 'config.json'
[void](Save-CvTextFile -Path $svCfg -Text '{ "behavior": { "workers": 3 }, "gui": { "queueWidth": 1000 } }')
Assert-Eq   'SetValue: ok'                $true (Set-CvConfigValue -Path $svCfg -Key 'gui/theme' -Value 'dark').Ok
Assert-Eq   'SetValue: lo guarda'         'dark' "$((Read-CvConfigFile -Path $svCfg).gui.theme)"
Assert-Eq   'SetValue: no toca lo de al lado' 1000 ([int](Read-CvConfigFile -Path $svCfg).gui.queueWidth)
Assert-Eq   'SetValue: ni otras secciones'    3    ([int](Read-CvConfigFile -Path $svCfg).behavior.workers)
Assert-Eq   'SetValue: sobrescribe'       'light' $(
    [void](Set-CvConfigValue -Path $svCfg -Key 'gui/theme' -Value 'light')
    "$((Read-CvConfigFile -Path $svCfg).gui.theme)")
# Una seccion que no existe se crea (un config minimo puede no tener 'gui').
$svCfg2 = Join-Path $svDir 'config2.json'
[void](Save-CvTextFile -Path $svCfg2 -Text '{ "behavior": { "workers": 1 } }')
Assert-Eq   'SetValue: crea la seccion'   $true  (Set-CvConfigValue -Path $svCfg2 -Key 'gui/theme' -Value 'dark').Ok
Assert-Eq   'SetValue: y queda escrita'   'dark' "$((Read-CvConfigFile -Path $svCfg2).gui.theme)"
Assert-Eq   'SetValue: clave vacia no vale' $false (Set-CvConfigValue -Path $svCfg2 -Key '' -Value 'x').Ok
Remove-Item -LiteralPath $svDir -Recurse -Force -ErrorAction SilentlyContinue

# ================================================================================================
Write-Host "`nTema de las ventanas (claro / oscuro)" -ForegroundColor Cyan
# Que tema toca: 'system' sigue a Windows (el dato se pasa aparte para poder probarlo sin registro).
# REGRESION DE ARRANQUE: la paleta usa tipos de System.Drawing, asi que tiene que cargarlo ella
# sola. Con -Config (como arranca el .cmd) nadie habia llamado a Initialize-CvGui todavia y el
# lanzador moria con 'No se encuentra el tipo [System.Drawing.Color]' ANTES de abrir la ventana.
Assert-True 'Arranque: la paleta carga lo que necesita' ($null -ne (Get-CvGuiPalette -Theme 'dark').Back)
Assert-True 'Arranque: el tema de sesion tambien'       (@('light', 'dark') -contains (Set-CvGuiThemeDefault -Theme 'system'))
Assert-Eq 'Tema: dark es dark'          'dark'  (Resolve-CvGuiTheme -Theme 'dark')
Assert-Eq 'Tema: light es light'        'light' (Resolve-CvGuiTheme -Theme 'light')
Assert-Eq 'Tema: system con Windows oscuro' 'dark'  (Resolve-CvGuiTheme -Theme 'system' -SystemDark $true)
Assert-Eq 'Tema: system con Windows claro'  'light' (Resolve-CvGuiTheme -Theme 'system' -SystemDark $false)
Assert-Eq 'Tema: cualquier cosa rara -> claro' 'light' (Resolve-CvGuiTheme -Theme 'azul')
Assert-Eq 'Config: tema por defecto'    'system' "$((Get-CvConfigDefaults).gui.theme)"
# El alto de la ventana de setup tiene que dar para el MENU entero (medido: necesita 780 px).
Assert-True 'Config: la ventana de setup cabe con su menu' ([int](Get-CvConfigDefaults).gui.setupHeight -ge 780)
Assert-True 'Config: y tiene ancho de partida'             ([int](Get-CvConfigDefaults).gui.setupWidth -ge 860)
Assert-Eq 'Catalogo de temas'           3       (@(Get-CvGuiThemes)).Count
# Las pestanas son PROPIAS (el TabControl de WinForms no se puede oscurecer): el reparto de la fila
# y el saber donde se ha pinchado son puros, asi que se prueban aqui, sin ventana.
$tl = @(Get-CvGuiTabLayout -Widths @(100, 40) -PadX 12 -Gap 2 -Start 2)
Assert-Eq   'Pestanas: cuantas salen'       2   $tl.Count
Assert-Eq   'Pestanas: la primera empieza'  2   ([int]$tl[0].X)
Assert-Eq   'Pestanas: ancho = rotulo + margenes' 124 ([int]$tl[0].Width)
Assert-Eq   'Pestanas: la siguiente va detras'   128 ([int]$tl[1].X)
Assert-Eq   'Pestanas: pinchar en la primera'  0  (Get-CvGuiTabHit -Rects $tl -X 60)
Assert-Eq   'Pestanas: pinchar en la segunda'  1  (Get-CvGuiTabHit -Rects $tl -X 130)
Assert-Eq   'Pestanas: pinchar en el hueco'   -1  (Get-CvGuiTabHit -Rects $tl -X 127)
Assert-Eq   'Pestanas: pinchar mas alla'      -1  (Get-CvGuiTabHit -Rects $tl -X 900)
Assert-Eq   'Pestanas: sin pestanas no hay nada' -1 (Get-CvGuiTabHit -Rects @() -X 10)
# La columna que se come el hueco sobrante (y con el, el trozo de cabecera que no es de ninguna
# columna, que el sistema pinta claro y no hay forma de oscurecer).
Assert-Eq   'Columna elastica: lo que sobra'     400 (Get-CvGuiFillColumnWidth -ClientWidth 800 -OtherWidths 400)
Assert-Eq   'Columna elastica: nunca por debajo del minimo' 120 (Get-CvGuiFillColumnWidth -ClientWidth 300 -OtherWidths 400)
Assert-Eq   'Columna elastica: minimo a medida' 250 (Get-CvGuiFillColumnWidth -ClientWidth 300 -OtherWidths 400 -Min 250)
# Bordes DEDUCIDOS en un archivo ya convertido (sin job): recortar cambia la proporcion, reescalar
# la conserva, asi que comparandolas se sabe si se quitaron barras.
$bc1 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1920 -OutHeight 800
Assert-Eq   'Bordes deducidos: letterbox recortado' '[x]' "$($bc1.Text)"
Assert-True 'Bordes deducidos: y lo sabe'           ([bool]$bc1.Known)
$bc2 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1280 -OutHeight 720
Assert-Eq   'Bordes deducidos: solo reescalado'     '[ ]' "$($bc2.Text)"
Assert-True 'Bordes deducidos: pero cambio de tamano' ([bool]$bc2.Resized)
$bc3 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1920 -OutHeight 1080
Assert-Eq   'Bordes deducidos: igual que el origen' '[ ]' "$($bc3.Text)"
Assert-Eq   'Bordes deducidos: ni se reescalo'      $false ([bool]$bc3.Resized)
# Pillarbox (barras a los lados): la proporcion tambien cambia, al reves.
$bc4 = Get-CvBorderFromSizes -SrcWidth 1440 -SrcHeight 1080 -OutWidth 1080 -OutHeight 1080
Assert-Eq   'Bordes deducidos: pillarbox'           '[x]' "$($bc4.Text)"
# Recorte + reescalado despues: la proporcion del recorte se conserva al escalar, asi que se pilla.
$bc5 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1280 -OutHeight 534
Assert-Eq   'Bordes deducidos: recorte y luego escalado' '[x]' "$($bc5.Text)"
# El redondeo a tamano PAR del escalado (un pixel arriba o abajo) NO puede contar como recorte.
$bc6 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1280 -OutHeight 721
Assert-Eq   'Bordes deducidos: un pixel no es recorte' '[ ]' "$($bc6.Text)"
# Sin datos no se afirma nada (mejor la celda vacia que una mentira).
$bc7 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 0 -OutHeight 0
Assert-Eq   'Bordes deducidos: sin datos, nada'     '' "$($bc7.Text)"
Assert-Eq   'Bordes deducidos: y no lo sabe'        $false ([bool]$bc7.Known)
# El margen manda: con uno muy fino, hasta 8px de barras cuentan.
$bc8 = Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1920 -OutHeight 1072 -Tolerance 0.001
Assert-Eq   'Bordes deducidos: margen fino'         '[x]' "$($bc8.Text)"
Assert-Eq   'Bordes deducidos: margen normal'       '[ ]' "$((Get-CvBorderFromSizes -SrcWidth 1920 -SrcHeight 1080 -OutWidth 1920 -OutHeight 1072).Text)"
Assert-Eq   'Config: cuantos convertidos se analizan por refresco' 2 ([int](Get-CvConfigDefaults).gui.queueDoneProbe)
# La lista NO se relee sola: el temporizador solo repinta el progreso mientras hay workers, y sin
# nada en marcha se para (0 = solo cuando lo pidas). La huella de los workers es lo que decide si
# hace falta releer las carpetas.
Assert-Eq   'Config: ritmo del progreso'      1000 ([int](Get-CvConfigDefaults).gui.queueRefreshMs)
Assert-Eq   'Config: parada, no relee sola'   0    ([int](Get-CvConfigDefaults).gui.queueIdleRefreshMs)
Assert-Eq   'Config: relee al volver a la ventana' $true ([bool](Get-CvConfigDefaults).gui.queueRefreshOnActivate)
Assert-Eq   'Config: la lista sigue al que se codifica' $true ([bool](Get-CvConfigDefaults).gui.queueFollowWorker)
Assert-Eq   'Config: plazo para que el worker aparezca' 20 ([int](Get-CvConfigDefaults).gui.queueStartGraceSec)
Assert-Eq   'Config: la lista quieta mientras la usas'  3 ([int](Get-CvConfigDefaults).gui.queueFollowHoldSec)
$w1 = @([pscustomobject]@{ Pid = 10; File = 'Serie_1x01'; Status = 'working' })
$w2 = @([pscustomobject]@{ Pid = 10; File = 'Serie_1x01'; Status = 'working' })
Assert-Eq   'Huella: el porcentaje no cuenta' (Get-CvWorkerSignature -Workers $w1) (Get-CvWorkerSignature -Workers $w2)
$w3 = @([pscustomobject]@{ Pid = 10; File = 'Serie_1x02'; Status = 'working' })
Assert-True 'Huella: cambiar de archivo si'  ((Get-CvWorkerSignature -Workers $w1) -ne (Get-CvWorkerSignature -Workers $w3))
$w4 = @([pscustomobject]@{ Pid = 10; File = 'Serie_1x01'; Status = 'done' })
Assert-True 'Huella: terminar tambien'       ((Get-CvWorkerSignature -Workers $w1) -ne (Get-CvWorkerSignature -Workers $w4))
Assert-True 'Huella: un worker mas'          ((Get-CvWorkerSignature -Workers $w1) -ne (Get-CvWorkerSignature -Workers ($w1 + $w3)))
Assert-Eq   'Huella: sin workers, vacia'     '' (Get-CvWorkerSignature -Workers @())
# El orden en que lleguen los workers no puede cambiar la huella (si no, releeria por nada).
Assert-Eq   'Huella: no depende del orden' (Get-CvWorkerSignature -Workers ($w1 + $w3)) (Get-CvWorkerSignature -Workers ($w3 + $w1))

# ================================================================================================
Write-Host "`nPiezas comunes de las ventanas" -ForegroundColor Cyan
# HUELLA de un fichero: es lo que evita repintar un panel (o re-leer un json) cuando nada ha cambiado.
$hDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_huella_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $hDir -Force | Out-Null
$hFile = Join-Path $hDir 'log.txt'
[void](Save-CvTextFile -Path $hFile -Text 'uno')
$h1 = Get-CvFileStamp -Path $hFile
Assert-Eq   'Huella: estable si no cambia'  $h1 (Get-CvFileStamp -Path $hFile)
Assert-True 'Huella: lleva la ruta'         ($h1 -like "$hFile|*")
[void](Save-CvTextFile -Path $hFile -Text 'uno y dos')
Assert-True 'Huella: cambia si cambia'      ((Get-CvFileStamp -Path $hFile) -ne $h1)
Assert-Eq   'Huella: fichero que no esta'   ((Join-Path $hDir 'no.txt') + '|?') (Get-CvFileStamp -Path (Join-Path $hDir 'no.txt'))
Assert-Eq   'Huella: ruta vacia'            '' (Get-CvFileStamp -Path '')
Remove-Item -LiteralPath $hDir -Recurse -Force -ErrorAction SilentlyContinue
# ABRIR algo con Windows: la decision, sin lanzar nada.
$oFile = 'D:\Videos\Serie_1x01.mkv'
$oSel = Get-CvOpenCommand -Path $oFile -Select
Assert-Eq   'Abrir: marcar en el explorador' 'explorer.exe' "$($oSel.Exe)"
Assert-True 'Abrir: usa /select'             ((@($oSel.Args) -join ' ') -match '/select,')
Assert-Eq   'Abrir: carpeta'                 'explorer.exe' (Get-CvOpenCommand -Path 'D:\Videos' -Folder).Exe
Assert-True 'Abrir: la carpeta entrecomillada' ((@((Get-CvOpenCommand -Path 'D:\Videos' -Folder).Args) -join ' ') -match '^"D:')
$oDef = Get-CvOpenCommand -Path $oFile
Assert-Eq   'Abrir: fichero -> el asociado'  $oFile "$($oDef.Exe)"
Assert-Eq   'Abrir: y por la shell'          $true  ([bool]$oDef.Shell)
Assert-Eq   'Abrir: ruta vacia no abre nada' $false (Open-CvGuiPath -Path '' -Quiet)

# ================================================================================================
Write-Host "`nReproducir un video (original / convertido)" -ForegroundColor Cyan
# Con que se abre un video para VERLO entero. Es una decision pura (Get-CvPlayerCommand): que
# ejecutable y con que argumentos, o si lo abre el asociado de Windows.
$plDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_play_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $plDir -Force | Out-Null
$plFF   = Join-Path $plDir 'ffplay.exe'      # de mentira: solo hace falta que EXISTA
$plExe  = Join-Path $plDir 'reproductor.exe'
$plFile = Join-Path $plDir 'Serie_1x01.mkv'
foreach ($f in @($plFF, $plExe, $plFile)) { [void](Save-CvTextFile -Path $f -Text 'x') }
$plNoExe = Join-Path $plDir 'no-existe.exe'

# 'start' (el de fabrica): lo abre el programa asociado de Windows, sin argumentos.
$c1 = Get-CvPlayerCommand -Mode 'start' -FFplay $plFF -File $plFile
Assert-Eq   'Player start: modo'     'start'  "$($c1.Mode)"
Assert-Eq   'Player start: shell'    $true    ([bool]$c1.Shell)
Assert-Eq   'Player start: el propio archivo' $plFile "$($c1.Exe)"
# 'ffplay': el de tools, con el nombre del archivo como titulo de la ventana.
$c2 = Get-CvPlayerCommand -Mode 'ffplay' -FFplay $plFF -File $plFile
Assert-Eq   'Player ffplay: modo'    'ffplay' "$($c2.Mode)"
Assert-Eq   'Player ffplay: exe'     $plFF    "$($c2.Exe)"
Assert-Eq   'Player ffplay: sin shell' $false ([bool]$c2.Shell)
Assert-True 'Player ffplay: el archivo va al final' ((@($c2.Args)[-1]) -eq $plFile)
Assert-True 'Player ffplay: pone titulo' ((@($c2.Args) -join ' ') -match 'window_title')
# Sin ffplay instalado no se inventa nada: se cae al asociado.
$c3 = Get-CvPlayerCommand -Mode 'ffplay' -FFplay (Join-Path $plDir 'no-hay.exe') -File $plFile
Assert-Eq   'Player ffplay ausente -> start' 'start' "$($c3.Mode)"
# 'external': el reproductor configurado, con el archivo como argumento.
$c4 = Get-CvPlayerCommand -Mode 'external' -Exe $plExe -FFplay $plFF -File $plFile
Assert-Eq   'Player external: exe'   $plExe   "$($c4.Exe)"
Assert-Eq   'Player external: le pasa el archivo' $plFile ((@($c4.Args) -join '|'))
# Un external que NO existe no se lanza a ciegas: ffplay, y si tampoco, el asociado.
Assert-Eq   'Player external ausente -> ffplay' 'ffplay' (Get-CvPlayerCommand -Mode 'external' -Exe $plNoExe -FFplay $plFF -File $plFile).Mode
Assert-Eq   'Player external ausente y sin ffplay -> start' 'start' (Get-CvPlayerCommand -Mode 'external' -Exe $plNoExe -FFplay '' -File $plFile).Mode
Assert-Eq   'Player modo vacio -> start' 'start' (Get-CvPlayerCommand -Mode '' -FFplay $plFF -File $plFile).Mode
Assert-Eq   'Player modo raro -> start'  'start' (Get-CvPlayerCommand -Mode 'loquesea' -FFplay $plFF -File $plFile).Mode
# Un archivo que no esta no abre nada (y no lanza).
$plCtx = [pscustomobject]@{ PreviewPlayer = 'start'; PreviewPlayerExe = ''; FFplay = $plFF }
$rNo = Start-CvVideoPlayer -Context $plCtx -File (Join-Path $plDir 'no-existe.mkv')
Assert-Eq   'Player: archivo que no esta' $false ([bool]$rNo.Ok)
Assert-True 'Player: y lo explica'        ("$($rNo.Error)" -match 'No existe')
Remove-Item -LiteralPath $plDir -Recurse -Force -ErrorAction SilentlyContinue
# Config: el modo por defecto y su catalogo.
Assert-Eq   'Config: player por defecto' 'start' "$((Get-CvConfigDefaults).preview.player)"
Assert-Eq   'Config: playerExe vacio'    ''      "$((Get-CvConfigDefaults).preview.playerExe)"
Assert-Eq   'Catalogo de reproductores'  3       (@(Get-CvPlayerModes)).Count
Assert-Eq   'Catalogo: el 1o es start'   'start' (@(Get-CvPlayerModes)[0].Value)

# ================================================================================================
Write-Host "`nVideo args / Config" -ForegroundColor Cyan
$ctxV = [pscustomobject]@{
    Fps       = '23.976'
    ForceFps  = $true
    Multipass = 'off'
}
$vaN = (Get-VideoArgs -Context $ctxV -Prof $np)
Assert-True 'VideoArgs hevc_nvenc' ($vaN -contains 'hevc_nvenc')
Assert-True 'VideoArgs p010le (main10)' ($vaN -contains 'p010le')
Assert-True 'VideoArgs qmin/qmax' (($vaN -contains '-qmin') -and ($vaN -contains '-qmax'))
Assert-True 'VideoArgs -r (forceFps)' ($vaN -contains '-r')
$vaCqp = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'hevc_nvenc' -Qmin 20 -Qmax 20))
Assert-True 'VideoArgs constqp (qmin=qmax)' (($vaCqp -join ' ') -match 'constqp')
$vaX = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libx264' -Crf 23) -Anim $true)
Assert-True 'VideoArgs libx264 crf'  (($vaX -contains '-crf') -and ($vaX -contains '23'))
$vaSvt = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libsvtav1' -VideoProfile 'main10' -Crf 30))
Assert-True 'VideoArgs libsvtav1 crf'    (($vaSvt -contains '-c:v') -and ($vaSvt -contains 'libsvtav1') -and ($vaSvt -contains '-crf') -and ($vaSvt -contains '30'))
Assert-True 'VideoArgs libsvtav1 10-bit' ($vaSvt -contains 'yuv420p10le')
$vaAv1 = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'av1_nvenc' -Qmin 20 -Qmax 20))
Assert-True 'VideoArgs av1_nvenc'        (($vaAv1 -contains 'av1_nvenc') -and ($vaAv1 -contains 'constqp'))
# AV1 (svtav1/nvenc) NO emite -profile:v/-level:v (el codec no los usa; los 10 bits van por pix_fmt).
Assert-Eq 'VideoArgs libsvtav1 sin profile' $false ($vaSvt -contains '-profile:v')
Assert-Eq 'VideoArgs libsvtav1 sin level'   $false ($vaSvt -contains '-level:v')
Assert-Eq 'VideoArgs av1_nvenc sin profile' $false ($vaAv1 -contains '-profile:v')
# h264_nvenc SI emite -profile:v/-level:v cuando el perfil los trae (bug corregido: antes los ignoraba).
$vaH264 = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'h264_nvenc' -VideoProfile 'high' -VideoLevel '5' -Qmin 1 -Qmax 23))
Assert-True 'VideoArgs h264_nvenc profile' (($vaH264 -join ' ') -match '-profile:v high')
Assert-True 'VideoArgs h264_nvenc level'   (($vaH264 -join ' ') -match '-level:v 5')
# Get-CvVideoCopyRemuxWarning: avisa al copiar video desde AVI (stream-copy a MKV falla por timestamps).
Assert-True 'copy remux warn avi'      (-not [string]::IsNullOrEmpty((Get-CvVideoCopyRemuxWarning -Path 'X:\peli.avi')))
Assert-True 'copy remux warn avi mayus'(-not [string]::IsNullOrEmpty((Get-CvVideoCopyRemuxWarning -Path 'X:\PELI.AVI')))
Assert-Eq   'copy remux sin aviso mkv' '' (Get-CvVideoCopyRemuxWarning -Path 'X:\peli.mkv')
Assert-Eq   'copy remux sin aviso mp4' '' (Get-CvVideoCopyRemuxWarning -Path 'X:\peli.mp4')
# libx264 tambien emite -profile:v/-level:v cuando el perfil los trae (antes los ignoraba).
$vaX264 = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libx264' -VideoProfile 'high' -VideoLevel '5' -Crf 21))
Assert-True 'VideoArgs libx264 profile' (($vaX264 -join ' ') -match '-profile:v high')
Assert-True 'VideoArgs libx264 level'   (($vaX264 -join ' ') -match '-level:v 5')
# pix_fmt segun profundidad en CPU x26x: 10 bits (main10/high10) -> yuv420p10le; 8 bits -> yuv420p.
# (Emitir -profile:v 10-bit con pix_fmt de 8 bits hacia que x264/x265 IGNORARAN el perfil -> bug.)
Assert-True 'VideoArgs libx264 high => 8bit'  (($vaX264 -contains 'yuv420p') -and -not ($vaX264 -contains 'yuv420p10le'))
$vaX264_10 = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libx264' -VideoProfile 'high10' -Crf 21))
Assert-True 'VideoArgs libx264 high10 => 10le' ($vaX264_10 -contains 'yuv420p10le')
$vaX265_8  = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libx265' -VideoProfile 'main' -Crf 21))
Assert-True 'VideoArgs libx265 main => 8bit'   (($vaX265_8 -contains 'yuv420p') -and -not ($vaX265_8 -contains 'yuv420p10le'))
$vaX265_10 = (Get-VideoArgs -Context $ctxV -Prof (New-CvProfile -VideoEncoder 'libx265' -VideoProfile 'main10' -Crf 21))
Assert-True 'VideoArgs libx265 main10 => 10le' ($vaX265_10 -contains 'yuv420p10le')
Assert-True 'VideoArgs tune animation' (($vaX -join ' ') -match 'tune animation')
$vaNoFps = (Get-VideoArgs -Context ([pscustomobject]@{
    Fps       = '23.976'
    ForceFps  = $false
    Multipass = 'off'
}) -Prof $np)
Assert-Eq 'VideoArgs sin -r (forceFps=false)' $false ($vaNoFps -contains '-r')
# GOLDEN Get-CvVideoRunArgs (emisor puro del comando de video; libx264 + resize + indice, sin HDR)
$vrCtx = [pscustomobject]@{ Threads=4; TonemapHdr='auto'; TonemapCurve='bt.2390'; TestLimit=0; Fps='23.976'; ForceFps=$true; Multipass='off'
    PresetNvenc='slow'; PresetX26x='slow'; PresetSvtav1='6'; PresetAv1Nvenc='p6'; RcLookahead=32; Refs=4; Tier='high' }
$vrArgs = Get-CvVideoRunArgs -Context $vrCtx -Prof (New-CvProfile -VideoEncoder 'libx264' -Crf 23) -File 'in.mkv' -OutTmp 'v.mkv' -Crop '' -Resize '1280:-2' -Anim $false -Index 0 -Hdr $false
Assert-Eq 'GOLDEN video-run args' '-hide_banner -y -threads 4 -i in.mkv -an -sn -map_chapters -1 -metadata title= -metadata:s:v title= -metadata:s:v language=und -vf scale=1280:-2 -c:v libx264 -pix_fmt yuv420p -crf 23 -preset slow -refs 4 -r 23.976 -movflags +faststart -map 0:0 -f matroska v.mkv' ($vrArgs -join ' ')
# HDR -> tonemap: init_hw_device vulkan + libplacebo + etiquetado bt709
$vrHdr = Get-CvVideoRunArgs -Context $vrCtx -Prof (New-CvProfile -VideoEncoder 'libx264' -Crf 23) -File 'in.mkv' -OutTmp 'v.mkv' -Hdr $true
Assert-True 'GOLDEN video-run HDR vulkan'   (($vrHdr -join ' ') -match '-init_hw_device vulkan')
Assert-True 'GOLDEN video-run HDR libplacebo' (($vrHdr -join ' ') -match 'libplacebo=tonemapping=bt\.2390')
Assert-True 'GOLDEN video-run HDR bt709'    (($vrHdr -join ' ') -match '-colorspace bt709')
# Tuning configurable (encode.video.tuning): preset/tier/lookahead/refs vienen del Context, no hardcodeado.
$ctxTune = [pscustomobject]@{
    Fps = '23.976'; ForceFps = $true; Multipass = 'off'
    PresetNvenc = 'p5'; PresetX26x = 'veryslow'; PresetSvtav1 = '4'; PresetAv1Nvenc = 'p4'
    RcLookahead = 48; Refs = 6; Tier = 'main'
}
$vaTn = (Get-VideoArgs -Context $ctxTune -Prof (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -Qmin 1 -Qmax 23))
Assert-True 'VideoArgs tuning preset NVENC' (($vaTn -join ' ') -match '-preset p5')
Assert-True 'VideoArgs tuning tier'         (($vaTn -join ' ') -match '-tier main')
Assert-True 'VideoArgs tuning rc-lookahead' (($vaTn -join ' ') -match '-rc-lookahead:v 48')
$vaTx = (Get-VideoArgs -Context $ctxTune -Prof (New-CvProfile -VideoEncoder 'libx264' -Crf 23))
Assert-True 'VideoArgs tuning preset x264'  (($vaTx -join ' ') -match '-preset veryslow')
Assert-True 'VideoArgs tuning refs'         (($vaTx -join ' ') -match '-refs 6')
# Fallback: sin tuning en el Context (contexto minimo), cae a los defaults de config (slow/high).
Assert-True 'VideoArgs preset fallback slow' (($vaN -join ' ') -match '-preset slow')
Assert-True 'VideoArgs tier fallback high'   (($vaN -join ' ') -match '-tier high')
# Control de calidad (SSIM/VMAF): filtro -lavfi y parseo de la puntuacion.
Assert-True 'QualityLavfi ssim'    ((Get-CvQualityLavfi -Metric 'ssim') -match 'scale2ref.*\bssim$')
Assert-True 'QualityLavfi vmaf'    ((Get-CvQualityLavfi -Metric 'vmaf') -match 'libvmaf$')
Assert-True 'QualityLavfi sin fps' ((Get-CvQualityLavfi -Metric 'ssim') -notmatch '\bfps=')
Assert-Eq 'QualityScore ssim' 0.987654 (Get-CvQualityScore -Metric 'ssim' -Text '[Parsed_ssim_0 @ 0x1] SSIM Y:0.99 U:0.98 V:0.98 All:0.987654 (18.4dB)')
Assert-Eq 'QualityScore vmaf' 95.12    (Get-CvQualityScore -Metric 'vmaf' -Text '[libvmaf @ 0x1] VMAF score: 95.12')
Assert-True 'QualityScore invalido -> null' ($null -eq (Get-CvQualityScore -Metric 'ssim' -Text 'sin datos'))

# ================================================================================================
Write-Host "`nUna sola pasada (beta)" -ForegroundColor Cyan
# Context sintetico con los campos que leen Test-CvOnePassEligible y Get-CvOnePassArgs (por defecto
# elegibles: encode+encode, sincronia adelay, volumen loudnorm, sin HDR).
function New-OpCtx {
    param([bool]$Beta = $true, [bool]$SyncAdelay = $true, [string]$Volume = 'loudnorm', [string]$Tonemap = 'off',
          [string]$DownmixMode = 'default', [bool]$BetaDownmix = $false, $Attachments = $null)
    [pscustomobject]@{
        BetaOnePass    = $Beta
        SyncAdelay     = $SyncAdelay
        VolumeMethod   = $Volume
        TonemapHdr     = $Tonemap
        Threads        = 4
        DefaultAudioHz = 44100
        LoudnormI      = -16.0
        LoudnormTP     = -1.5
        LoudnormLRA    = 11.0
        AudioChannels  = 2
        DownmixMode    = $DownmixMode
        DownmixCoeffs  = [pscustomobject]@{ Center = 0.5; Front = 0.35; Surround = 0.15 }
        BetaDownmix    = $BetaDownmix
        AudioKeepTitle = $false
        Attachments    = $Attachments
        Fps            = '23.976'
        ForceFps       = $true
        Multipass      = 'off'
        AacCoder       = 'twoloop'
        TestLimit      = 0
        TonemapCurve   = 'bt.2390'
    }
}
# Helper: extrae el valor de -filter_complex de un comando ffmpeg (para los golden de una pasada).
function Get-OpFc($cmd) { $i = [array]::IndexOf([object[]]$cmd, '-filter_complex'); return $cmd[$i + 1] }
$opProf = New-CvProfile -VideoEncoder 'libx264' -Crf 23 -AudioCodec 'aac' -AudioBitrate '192k' -AudioHz 44100
$opJob = [pscustomobject]@{
    video     = [pscustomobject]@{ skip = $false; index = 0; crop = ''; resize = '1920:-2'; anim = $false; hdr = $false }
    audio     = [pscustomobject]@{ skip = $false; tracks = @([pscustomobject]@{ index = 1; is51 = $true; sync = 5.1; lang = 'spa'; default = $true }) }
    subtitles = @()
}
$opInfo = [pscustomobject]@{ streams = @(
    [pscustomobject]@{ index = 0; codec_type = 'video'; codec_name = 'h264' }
    [pscustomobject]@{ index = 1; codec_type = 'audio'; codec_name = 'ac3'; channels = 6 }
) }
$opJobVCopy = [pscustomobject]@{ video = [pscustomobject]@{ skip = $true;  index = 0; crop = ''; resize = ''; anim = $false; hdr = $false }; audio = $opJob.audio; subtitles = @() }
$opJobACopy = [pscustomobject]@{ video = $opJob.video; audio = [pscustomobject]@{ skip = $true; tracks = $opJob.audio.tracks }; subtitles = @() }
$opJobHdr   = [pscustomobject]@{ video = [pscustomobject]@{ skip = $false; index = 0; crop = ''; resize = ''; anim = $false; hdr = $true };  audio = $opJob.audio; subtitles = @() }

# Elegibilidad
Assert-True 'OnePass elegible'              (Test-CvOnePassEligible -Context (New-OpCtx) -Job $opJob -Prof $opProf).Ok
Assert-Eq   'OnePass no si beta off'  $false (Test-CvOnePassEligible -Context (New-OpCtx -Beta $false)       -Job $opJob -Prof $opProf).Ok
Assert-Eq   'OnePass no si sync WAV'  $false (Test-CvOnePassEligible -Context (New-OpCtx -SyncAdelay $false) -Job $opJob -Prof $opProf).Ok
Assert-True 'OnePass SI con vol peak'        (Test-CvOnePassEligible -Context (New-OpCtx -Volume 'peak')      -Job $opJob -Prof $opProf).Ok
Assert-Eq   'OnePass no si vol aacgain' $false (Test-CvOnePassEligible -Context (New-OpCtx -Volume 'aacgain') -Job $opJob -Prof $opProf).Ok
Assert-Eq   'OnePass no si video copy' $false (Test-CvOnePassEligible -Context (New-OpCtx) -Job $opJobVCopy -Prof $opProf).Ok
Assert-Eq   'OnePass no si audio copy' $false (Test-CvOnePassEligible -Context (New-OpCtx) -Job $opJobACopy -Prof $opProf).Ok
Assert-Eq   'OnePass no si HDR tonemap' $false (Test-CvOnePassEligible -Context (New-OpCtx -Tonemap 'auto') -Job $opJobHdr -Prof $opProf).Ok
Assert-True 'OnePass reason no vacio' (-not [string]::IsNullOrEmpty((Test-CvOnePassEligible -Context (New-OpCtx -Beta $false) -Job $opJob -Prof $opProf).Reason))

# Constructor de args (puro): un solo comando con filtergraph y mapeos.
$opArgs = Get-CvOnePassArgs -Context (New-OpCtx) -Prof $opProf -File 'X:\in.mkv' -Info $opInfo -Job $opJob -Out 'X:\out.mkv'
$opStr  = ($opArgs -join ' ')
Assert-True 'OnePassArgs filter_complex'   ($opArgs -contains '-filter_complex')
Assert-True 'OnePassArgs loudnorm'         ($opStr -match 'loudnorm=')
Assert-True 'OnePassArgs adelay (sync>0)'  ($opStr -match 'adelay=')
Assert-True 'OnePassArgs video filtrado'   ($opStr -match '\[v\]')
Assert-True 'OnePassArgs -ac por pista'    ($opArgs -contains '-ac:a:0')
Assert-True 'OnePassArgs -b:a por pista'   ($opArgs -contains '-b:a:0')
Assert-True 'OnePassArgs map_chapters 0'   (($opArgs -contains '-map_chapters') -and ($opArgs -contains '0'))
Assert-True 'OnePassArgs -c:a aac'         (($opArgs -contains '-c:a') -and ($opArgs -contains 'aac'))
Assert-True 'OnePassArgs -c:v libx264'     (($opArgs -contains '-c:v') -and ($opArgs -contains 'libx264'))
Assert-True 'OnePassArgs salida matroska'  (($opArgs -contains 'matroska') -and ($opArgs[-1] -eq 'X:\out.mkv'))
# GOLDEN (red de seguridad del refactor a fuente unica): filter_complex EXACTO del job canonico
# (vídeo scale=1920:-2 + audio adelay 5.1s -> loudnorm). Cualquier deriva lo rompe.
$opFcIdx = [array]::IndexOf([object[]]$opArgs, '-filter_complex')
Assert-Eq 'OnePass filter_complex EXACTO' '[0:0]scale=1920:-2[v];[0:1]adelay=5100:all=1,loudnorm=I=-16:TP=-1.5:LRA=11[a0]' $opArgs[$opFcIdx + 1]
# Resolve-CvRenderSpec (job -> decisiones estructuradas; lo consume el emisor de una pasada)
$spec = Resolve-CvRenderSpec -Context (New-OpCtx) -Prof $opProf -Job $opJob -Info $opInfo
Assert-Eq 'spec video srcpad'   '0:0'          $spec.Video.SrcPad
Assert-Eq 'spec video filtro'   'scale=1920:-2' ($spec.Video.Filters -join ',')
Assert-Eq 'spec audio pistas'   1               $spec.Audio.Count
Assert-Eq 'spec audio canales'  2               $spec.Audio[0].Channels   # origen 5.1 capado a 2
Assert-Eq 'spec audio srcCh'    6               $spec.Audio[0].SourceChannels  # entrada de la decision (la reusa etapas)
Assert-Eq 'spec audio is51'     $true           $spec.Audio[0].Is51
Assert-Eq 'spec audio sync'     5.1             $spec.Audio[0].Sync
Assert-Eq 'spec audio lang'     'spa'           $spec.Audio[0].Lang
Assert-Eq 'spec audio default'  $true           $spec.Audio[0].Default
Assert-Eq 'spec audio bitrate'  '192k'          $spec.Audio[0].Bitrate
Assert-Eq 'spec codec'          'aac'           $spec.AudioCodec
Assert-Eq 'spec aaccoder'       'twoloop'       $spec.AacCoder
Assert-Eq 'spec loudnorm'       'loudnorm=I=-16:TP=-1.5:LRA=11' $spec.Loudnorm
# --- GOLDEN adicionales de una pasada (red de seguridad Fase 0) ---
# Multipista: 2 pistas (default 1a); pista 2 con sync 0.5s (adelay 500). Ambas 5.1/estereo -> -ac 2.
$goM = Get-CvOnePassArgs -Context (New-OpCtx) -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -Job ([pscustomobject]@{
    video     = [pscustomobject]@{ skip=$false; index=0; crop=''; resize=''; anim=$false; hdr=$false }
    audio     = [pscustomobject]@{ skip=$false; tracks=@(
        [pscustomobject]@{ index=1; is51=$true;  sync=0;   lang='spa'; default=$true },
        [pscustomobject]@{ index=2; is51=$false; sync=0.5; lang='eng'; default=$false }) }
    subtitles = @() }) -Info ([pscustomobject]@{ streams=@(
        [pscustomobject]@{ index=0; codec_type='video'; codec_name='h264' }
        [pscustomobject]@{ index=1; codec_type='audio'; codec_name='ac3'; channels=6 }
        [pscustomobject]@{ index=2; codec_type='audio'; codec_name='aac'; channels=2 }) })
Assert-Eq 'GOLDEN multipista fc' '[0:1]loudnorm=I=-16:TP=-1.5:LRA=11[a0];[0:2]adelay=500:all=1,loudnorm=I=-16:TP=-1.5:LRA=11[a1]' (Get-OpFc $goM)
Assert-True 'GOLDEN multipista acodec' (($goM -join ' ') -match ([regex]::Escape('-ac:a:0 2 -ar:a:0 44100 -b:a:0 192k -ac:a:1 2 -ar:a:1 44100 -b:a:1 192k')))
# Downmix dialogue (beta on): la rama de la pista 5.1 lleva el pan de voz reforzada antes del loudnorm.
$goD = Get-CvOnePassArgs -Context (New-OpCtx -DownmixMode 'dialogue' -BetaDownmix $true) -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -Job ([pscustomobject]@{
    video     = [pscustomobject]@{ skip=$false; index=0; crop=''; resize=''; anim=$false; hdr=$false }
    audio     = [pscustomobject]@{ skip=$false; tracks=@([pscustomobject]@{ index=1; is51=$true; sync=0; lang='spa'; default=$true }) }
    subtitles = @() }) -Info ([pscustomobject]@{ streams=@(
        [pscustomobject]@{ index=0; codec_type='video'; codec_name='h264' }
        [pscustomobject]@{ index=1; codec_type='audio'; codec_name='ac3'; channels=6 }) })
Assert-Eq 'GOLDEN downmix dialogue fc' '[0:1]pan=stereo|c0=0.5*c2+0.35*c0+0.15*c4|c1=0.5*c2+0.35*c1+0.15*c5,loudnorm=I=-16:TP=-1.5:LRA=11[a0]' (Get-OpFc $goD)
# Subtitulos (forzado+completo) + adjunto (fuente): mapeo exacto en el comando de una pasada.
$goS = Get-CvOnePassArgs -Context (New-OpCtx -Attachments ([pscustomobject]@{ Keep=$true; Fonts=$true; Covers=$false; Other=$false })) -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -Job ([pscustomobject]@{
    video     = [pscustomobject]@{ skip=$false; index=0; crop=''; resize=''; anim=$false; hdr=$false }
    audio     = [pscustomobject]@{ skip=$false; tracks=@([pscustomobject]@{ index=1; is51=$false; sync=0; lang='spa'; default=$true }) }
    subtitles = @(
        [pscustomobject]@{ Index=3; Lang='spa'; Forced=$true;  Default=$true },
        [pscustomobject]@{ Index=4; Lang='spa'; Forced=$false; Default=$false }) }) -Info ([pscustomobject]@{ streams=@(
        [pscustomobject]@{ index=0; codec_type='video'; codec_name='h264' }
        [pscustomobject]@{ index=1; codec_type='audio'; codec_name='aac'; channels=2 }
        [pscustomobject]@{ index=3; codec_type='subtitle' }
        [pscustomobject]@{ index=4; codec_type='subtitle' }
        [pscustomobject]@{ index=5; codec_type='attachment'; tags=[pscustomobject]@{ filename='f.ttf'; mimetype='application/x-truetype-font' } }) })
Assert-True 'GOLDEN subs+adjuntos mapeo' (($goS -join ' ') -match ([regex]::Escape('-map 0:3? -metadata:s:s:0 language=spa -metadata:s:s:0 title=Forzados -disposition:s:0 default+forced -c:s:0 copy -map 0:4? -metadata:s:s:1 language=spa -metadata:s:s:1 title= -disposition:s:1 0 -c:s:1 copy -map 0:5? -metadata:s:t:0 filename=f.ttf -metadata:s:t:0 mimetype=application/x-truetype-font')))
Assert-True 'GOLDEN subs -> -c:s:0 copy por pista' (($goS -join ' ') -match '-c:s:0 copy')
Assert-True 'GOLDEN adjuntos -> -c:t copy' (($goS -join ' ') -match '-c:t copy')
# Peak en una pasada: VolumeFilters por pista (resueltos en runtime). Con ganancia -> volume=XdB;
# ganancia 0 pero con sync -> solo adelay; ganancia 0 sin sync/downmix -> 'anull' (conserva [aN]).
$goPk = Get-CvOnePassArgs -Context (New-OpCtx -Volume 'peak') -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -VolumeFilters @('volume=3dB:precision=fixed') -Job $opJob -Info $opInfo
Assert-Eq 'GOLDEN peak fc (gain)' '[0:0]scale=1920:-2[v];[0:1]adelay=5100:all=1,volume=3dB:precision=fixed[a0]' (Get-OpFc $goPk)
$goPk0 = Get-CvOnePassArgs -Context (New-OpCtx -Volume 'peak') -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -VolumeFilters @('') -Job $opJob -Info $opInfo
Assert-Eq 'GOLDEN peak fc (gain 0, con sync)' '[0:0]scale=1920:-2[v];[0:1]adelay=5100:all=1[a0]' (Get-OpFc $goPk0)
# ganancia 0 + sin sync + sin downmix -> anull
$goPkNull = Get-CvOnePassArgs -Context (New-OpCtx -Volume 'peak') -Prof $opProf -File 'X:\in.mkv' -Out 'X:\out.mkv' -VolumeFilters @('') -Info $opInfo -Job ([pscustomobject]@{
    video     = [pscustomobject]@{ skip=$false; index=0; crop=''; resize=''; anim=$false; hdr=$false }
    audio     = [pscustomobject]@{ skip=$false; tracks=@([pscustomobject]@{ index=1; is51=$false; sync=0; lang='spa'; default=$true }) }
    subtitles = @() })
Assert-Eq 'GOLDEN peak fc (anull)' '[0:1]anull[a0]' (Get-OpFc $goPkNull)
# Sin resize -> el video se mapea directo (sin etiqueta [v] del filtergraph).
$opArgs2 = Get-CvOnePassArgs -Context (New-OpCtx) -Prof $opProf -File 'X:\in.mkv' -Info $opInfo -Job $opJobHdr -Out 'X:\out.mkv'
Assert-True 'OnePassArgs sin resize -> map 0:0' (($opArgs2 -join ' ') -match '-map 0:0')
# Anamorfico (SAR != 1) 'cuadrar por ancho': el resize (W:H,setsar=1) que calcula Get-CvResize en PREPARAR
# se guarda en job.video.resize y el one-pass lo aplica en la rama de video (scale=...,setsar=1). El
# squaring NO obliga a pipeline por etapas (solo el tonemap HDR lo hace). Regresion: bug reportado.
$opRz     = Get-CvResize -Width 1918 -Height 1040 -Sar '962:959' -MaxWidth 0 -Anamorphic 'square'
$opJobAnam = [pscustomobject]@{ video = [pscustomobject]@{ skip=$false; index=0; crop=''; resize=$opRz; anim=$false; hdr=$false }; audio = $opJob.audio; subtitles = @() }
$opArgs3  = Get-CvOnePassArgs -Context (New-OpCtx) -Prof $opProf -File 'X:\in.mkv' -Info $opInfo -Job $opJobAnam -Out 'X:\out.mkv'
$opFc3    = $opArgs3[([array]::IndexOf([object[]]$opArgs3,'-filter_complex')) + 1]
Assert-True 'OnePass anamorfico square -> setsar' ($opRz -match 'setsar=1')
Assert-True 'OnePass anamorfico filter_complex setsar' ($opFc3 -match 'scale=\d+:\d+,setsar=1\[v\]')
Assert-Eq   'OnePass anamorfico elegible (SAR no bloquea)' $true (Test-CvOnePassEligible -Context (New-OpCtx) -Job $opJobAnam -Prof $opProf).Ok
$defM = [ordered]@{
    a   = 1
    sub = [ordered]@{
        x = 1
        y = 2
    }
}
Merge-CvConfig -Default $defM -Override ([pscustomobject]@{
    a     = 9
    sub   = [pscustomobject]@{ y = 5 }
    nuevo = 'z'
})
Assert-Eq 'Merge escalar sobreescrito' 9   $defM.a
Assert-Eq 'Merge subclave conservada'  1   $defM.sub.x
Assert-Eq 'Merge subclave sobreescrita' 5  $defM.sub.y
Assert-Eq 'Merge clave nueva'          'z' $defM.nuevo
$json = ConvertTo-CvJson ([ordered]@{
    a = 1
    b = $true
    c = 'x'
})
Assert-True 'Json numero'  ($json -match '"a": 1')
Assert-True 'Json bool'    ($json -match '"b": true')
Assert-True 'Json string'  ($json -match '"c": "x"')
Assert-True 'HelpFor conocido' ((Get-CvHelpFor 'console/sepWidth') -ne '')
Assert-Eq   'HelpFor desconocido' '' (Get-CvHelpFor 'no/existe')

# ================================================================================================
Write-Host "`nJob / Tools / Attachment" -ForegroundColor Cyan
$ctxJ = [pscustomobject]@{
    Proceso    = 'D:\P'
    Convertido = 'D:\C'
    OutExt     = 'mkv'
}
Assert-Eq 'JobPath'    'D:\P\Peli.job.json' (Get-CvJobPath $ctxJ 'Peli')
Assert-Eq 'OutputPath' 'D:\C\Peli_fix.mkv'  (Get-OutputPath $ctxJ 'Peli')
Assert-True 'TempPaths .mkv' ((Get-CvTempPaths -Context $ctxJ -Name 'Peli').Video -like '*Peli.mkv')
Assert-Eq 'platform 64'    'x64' (ConvertTo-CvPlatform 'amd64')
Assert-Eq 'platform win32' 'x86' (ConvertTo-CvPlatform 'win32')
Assert-Eq 'platform i386'  'x86' (ConvertTo-CvPlatform 'i386')
$platsOk = @('x64', 'x86')
Assert-True 'Get-CvPlatform x64/x86' ((Get-CvPlatform) -in $platsOk)
Assert-Eq 'Attachment font'  'font'  (Get-AttachmentKind ([pscustomobject]@{
    codec_name = 'ttf'
    tags       = [pscustomobject]@{
        mimetype = 'application/x-truetype-font'
        filename = 'arial.ttf'
    }
}))
Assert-Eq 'Attachment cover' 'cover' (Get-AttachmentKind ([pscustomobject]@{
    codec_name = 'mjpeg'
    tags       = [pscustomobject]@{
        mimetype = 'image/jpeg'
        filename = 'cover.jpg'
    }
}))
Assert-Eq 'Attachment other' 'other' (Get-AttachmentKind ([pscustomobject]@{
    codec_name = 'bin'
    tags       = [pscustomobject]@{
        mimetype = 'application/octet-stream'
        filename = 'x.bin'
    }
}))
Assert-True 'NvencCause extrae' (((Get-CvNvencCause "ruido`n[hevc_nvenc @ 0x1] No capable devices found`nmas ruido") -join ' ') -match 'No capable devices')
Assert-True 'NvencCause vacio -> mensaje' (@(Get-CvNvencCause '').Count -ge 1)

# ================================================================================================
Write-Host "`nHelpers extraidos (audio/video/config/mux)" -ForegroundColor Cyan
# Resolve-CvAudioChannels (perfil->global + no-upmix)
$rc = Resolve-CvAudioChannels -ProfChannels 6 -GlobalChannels 2 -SourceChannels 0
Assert-Eq 'chan perfil 6'        6 $rc.Channels
Assert-Eq 'chan no capado'       $false $rc.Capped
Assert-Eq 'chan perfil null->global' 2 (Resolve-CvAudioChannels -ProfChannels $null -GlobalChannels 2 -SourceChannels 0).Channels
Assert-Eq 'chan <1 -> 2'         2 (Resolve-CvAudioChannels -ProfChannels 0 -GlobalChannels 0 -SourceChannels 0).Channels
$rcap = Resolve-CvAudioChannels -ProfChannels 6 -GlobalChannels 2 -SourceChannels 2
Assert-Eq 'no-upmix: final=origen' 2 $rcap.Channels
Assert-Eq 'no-upmix: target=6'     6 $rcap.Target
Assert-Eq 'no-upmix: capped'       $true $rcap.Capped
Assert-Eq 'source 0 no capa'       $false (Resolve-CvAudioChannels -ProfChannels 6 -GlobalChannels 2 -SourceChannels 0).Capped
# Resolve-CvDownmixMode
Assert-Eq 'downmixmode perfil gana' 'dialogue' (Resolve-CvDownmixMode 'dialogue' 'default')
Assert-Eq 'downmixmode vacio->global' 'dialogue' (Resolve-CvDownmixMode '' 'dialogue')
Assert-Eq 'downmixmode lower' 'default' (Resolve-CvDownmixMode 'DEFAULT' 'dialogue')
# Get-CvDownmixPan (string exacto, locale-safe)
Assert-Eq 'pan downmix' 'pan=stereo|c0=0.5*c2+0.35*c0+0.15*c4|c1=0.5*c2+0.35*c1+0.15*c5' (Get-CvDownmixPan -Coeffs ([pscustomobject]@{
    Center   = 0.5
    Front    = 0.35
    Surround = 0.15
}))
# Resolve-CvAudioTrackPlan (decision por pista compartida etapas/one-pass)
$planCtx = [pscustomobject]@{ AudioChannels = 2; DownmixMode = 'dialogue'; BetaDownmix = $true
    DownmixCoeffs = [pscustomobject]@{ Center = 0.5; Front = 0.35; Surround = 0.15 } }
$planProf = New-CvProfile -AudioChannels 0   # 0 -> usa el global (2)
$plan51   = Resolve-CvAudioTrackPlan -Context $planCtx -Prof $planProf -SourceChannels 6 -Is51 $true
Assert-Eq 'plan 5.1->2 canales'   2     $plan51.Channels
Assert-Eq 'plan 5.1 downmix on'   $true $plan51.Downmix
Assert-True 'plan 5.1 pan no vacio' ($plan51.DownmixPan -match '^pan=stereo')
# beta off: se pidio dialogue pero no se refuerza (pan vacio), downmix estandar via -ac
$planCtxOff = [pscustomobject]@{ AudioChannels = 2; DownmixMode = 'dialogue'; BetaDownmix = $false
    DownmixCoeffs = $planCtx.DownmixCoeffs }
$planOff = Resolve-CvAudioTrackPlan -Context $planCtxOff -Prof $planProf -SourceChannels 6 -Is51 $true
Assert-Eq 'plan beta off wantdialogue' $true  $planOff.WantDialogue
Assert-Eq 'plan beta off downmix'      $false $planOff.Downmix
Assert-Eq 'plan beta off pan vacio'    ''     $planOff.DownmixPan
# origen estereo (no 5.1): sin downmix aunque el modo sea dialogue
$planStereo = Resolve-CvAudioTrackPlan -Context $planCtx -Prof $planProf -SourceChannels 2 -Is51 $false
Assert-Eq 'plan estereo sin downmix' $false $planStereo.Downmix
# no upmix: objetivo 6 pero origen 2 -> capado a 2
$planCapCtx = [pscustomobject]@{ AudioChannels = 6; DownmixMode = 'default'; BetaDownmix = $false
    DownmixCoeffs = $planCtx.DownmixCoeffs }
$planCap = Resolve-CvAudioTrackPlan -Context $planCapCtx -Prof $planProf -SourceChannels 2 -Is51 $false
Assert-Eq 'plan capado canales' 2     $planCap.Channels
Assert-Eq 'plan capado flag'    $true $planCap.Capped
# Resolve-CvVolumeMethod
Assert-Eq 'vol peak/aac' 'peak' (Resolve-CvVolumeMethod -Method 'peak' -Codec 'aac').Method
Assert-Eq 'vol aacgain/aac ok' 'aacgain' (Resolve-CvVolumeMethod -Method 'aacgain' -Codec 'aac').Method
# aacgain con un codec que no es AAC cae al DEFAULT de config (loudnorm), no al fijo 'peak' (legacy).
$vg = Resolve-CvVolumeMethod -Method 'aacgain' -Codec 'eac3'
Assert-Eq 'vol aacgain/eac3 -> default' 'loudnorm' $vg.Method
Assert-Eq 'vol aacgain downgraded'   $true  $vg.AacgainDowngraded
Assert-Eq 'vol peak/aac no degrada'  $false (Resolve-CvVolumeMethod -Method 'peak' -Codec 'aac').AacgainDowngraded
Assert-Eq 'vol LOUDNORM lower' 'loudnorm' (Resolve-CvVolumeMethod -Method 'LOUDNORM' -Codec 'aac').Method
Assert-Eq 'vol invalido -> default' 'loudnorm' (Resolve-CvVolumeMethod -Method 'xxx' -Codec 'aac').Method
Assert-True 'vol invalido -> valido' ((Resolve-CvVolumeMethod -Method 'xxx' -Codec 'aac').Method -in (Get-CvVolumeMethodValues))
# Get-CvAdelayFilter (ms enteros redondeados)
Assert-Eq 'adelay 5s'     'adelay=5000:all=1' (Get-CvAdelayFilter 5.0)
Assert-Eq 'adelay 0.005s' 'adelay=5:all=1'    (Get-CvAdelayFilter 0.005)
Assert-Eq 'adelay redondeo' 'adelay=1:all=1'  (Get-CvAdelayFilter 0.0011)
# Get-CvLoudnormFilter (string exacto, locale-safe) — fuente unica de etapas + one-pass
Assert-Eq 'loudnorm string' 'loudnorm=I=-16:TP=-1.5:LRA=11' (Get-CvLoudnormFilter -I -16.0 -TP -1.5 -LRA 11.0)
# Get-CvAudioFilterChain (ORDEN sync -> downmix -> volumen; omite las partes vacias). Asignacion
# directa (como Get-CvVideoFilterChain): la funcion hace 'return ,$parts', no envolver en @().
$acOrden = Get-CvAudioFilterChain -SyncFilter 'adelay=5000:all=1' -DownmixPan 'PAN' -VolumeFilter 'loudnorm=X'
Assert-Eq 'audiochain orden' 'adelay=5000:all=1,PAN,loudnorm=X' ($acOrden -join ',')
$acVol = Get-CvAudioFilterChain -VolumeFilter 'loudnorm=X'
Assert-Eq 'audiochain solo vol' 'loudnorm=X' ($acVol -join ',')
$acNoDmx = Get-CvAudioFilterChain -SyncFilter 'adelay=5000:all=1' -VolumeFilter 'loudnorm=X'
Assert-Eq 'audiochain sin downmix' 'adelay=5000:all=1,loudnorm=X' ($acNoDmx -join ',')
$acEmpty = Get-CvAudioFilterChain
Assert-Eq 'audiochain vacio -> 0' 0 ($acEmpty.Count)
# GOLDEN Get-CvAudioEncodeArgs (emisor puro del encode de audio)
$aeCtx = [pscustomobject]@{ Threads=4; AacCoder='twoloop'; TestLimit=0 }
$aeChain = Get-CvAudioFilterChain -SyncFilter 'adelay=5000:all=1' -VolumeFilter 'loudnorm=I=-16:TP=-1.5:LRA=11'
$aeFilt = Get-CvAudioEncodeArgs -Context $aeCtx -Codec 'aac' -Channels 2 -Ar 44100 -Bitrate '192k' -SourceInput @('-i','in.mkv') -MapPre @('-map','0:1','-vn','-sn','-map_chapters','-1') -ALabel '0:1' -ChainParts $aeChain -FromWav $false -OutFile 'a0.m4a'
Assert-Eq 'GOLDEN audio-encode filtro' '-hide_banner -y -threads 4 -i in.mkv -filter_complex [0:1]adelay=5000:all=1,loudnorm=I=-16:TP=-1.5:LRA=11[a] -map [a] -c:a aac -aac_coder twoloop -ac 2 -ar 44100 -b:a 192k a0.m4a' ($aeFilt -join ' ')
# sin filtro (mapeo directo) + flac sin bitrate
$aeDir = Get-CvAudioEncodeArgs -Context $aeCtx -Codec 'flac' -Channels 6 -Ar 48000 -Bitrate '' -SourceInput @('-i','in.mkv') -MapPre @('-map','0:2','-vn','-sn','-map_chapters','-1') -ALabel '0:2' -ChainParts @() -FromWav $false -OutFile 'a0.mka'
Assert-Eq 'GOLDEN audio-encode directo' '-hide_banner -y -threads 4 -i in.mkv -map 0:2 -vn -sn -map_chapters -1 -c:a flac -ac 6 -ar 48000 a0.mka' ($aeDir -join ' ')
# Resolve-CvAudioAhead (audio adelantado = acaba antes que el video)
Assert-Eq 'audioAhead 5.1s'        5.1  (Resolve-CvAudioAhead -VideoEnd 5726.22 -AudioEnd 5721.12 -Threshold 2.0)
Assert-Eq 'audioAhead bajo umbral' 0.0  (Resolve-CvAudioAhead -VideoEnd 5726.0 -AudioEnd 5725.5 -Threshold 2.0)
Assert-Eq 'audioAhead umbral 0'    0.0  (Resolve-CvAudioAhead -VideoEnd 5726.0 -AudioEnd 5700.0 -Threshold 0)
Assert-Eq 'audioAhead sin datos'   0.0  (Resolve-CvAudioAhead -VideoEnd 0 -AudioEnd 0 -Threshold 2.0)
# Get-CvTonemapFormat
Assert-Eq 'tonemap main10 hevc -> p010le' 'p010le'  (Get-CvTonemapFormat -VideoProfile 'main10' -VideoEncoder 'hevc_nvenc')
Assert-Eq 'tonemap main10 x264 -> yuv420p' 'yuv420p' (Get-CvTonemapFormat -VideoProfile 'main10' -VideoEncoder 'libx264')
Assert-Eq 'tonemap main10 av1_nvenc -> p010le'   'p010le'      (Get-CvTonemapFormat -VideoProfile 'main10' -VideoEncoder 'av1_nvenc')
Assert-Eq 'tonemap main10 libsvtav1 -> 420p10le' 'yuv420p10le' (Get-CvTonemapFormat -VideoProfile 'main10' -VideoEncoder 'libsvtav1')
Assert-Eq 'tonemap main hevc -> yuv420p'   'yuv420p' (Get-CvTonemapFormat -VideoProfile 'main' -VideoEncoder 'hevc_nvenc')
# Get-CvVideoFilterChain (orden crop->scale->tonemap)
$fc1 = Get-CvVideoFilterChain -Crop '1920:800:0:140'
Assert-Eq 'vf crop 1 elem'  1 $fc1.Count
Assert-Eq 'vf crop valor'   'crop=1920:800:0:140' $fc1[0]
$fc2 = Get-CvVideoFilterChain -Crop '10:10:0:0' -Resize '1280:-2'
Assert-Eq 'vf crop+scale orden' 'crop=10:10:0:0|scale=1280:-2' ($fc2 -join '|')
$fc3 = Get-CvVideoFilterChain -Resize '1280:-2' -Tonemap $true -Fmt 'p010le'
Assert-True 'vf tonemap libplacebo' (($fc3 -join '|') -match 'libplacebo')
Assert-True 'vf tonemap format' ($fc3 -contains 'format=p010le')
Assert-True 'vf tonemap algo def bt.2390' (($fc3 -join '|') -match 'tonemapping=bt\.2390')
Assert-True 'vf tonemap algo configurable' (((Get-CvVideoFilterChain -Tonemap $true -TonemapCurve 'mobius') -join '|') -match 'tonemapping=mobius')
Assert-Eq 'vf vacio -> 0' 0 (Get-CvVideoFilterChain).Count
# Resolve-CvOneOf
Assert-Eq 'oneof valido'      'qres' (Resolve-CvOneOf 'qres' @('off','qres','fullres') 'off')
Assert-Eq 'oneof invalido->def' 'off' (Resolve-CvOneOf 'xxx' @('off','qres','fullres') 'off')
Assert-Eq 'oneof lower'       'dialogue' (Resolve-CvOneOf 'Dialogue' @('default','dialogue') 'default')
# Resolve-CvMuxInputIndex
$mi1 = Resolve-CvMuxInputIndex -TempAudioCount 2 -IsEncode $true
Assert-Eq 'mux orig (2 temp)'  3 $mi1.Orig
Assert-Eq 'mux chap encode'    3 $mi1.Chap
$mi2 = Resolve-CvMuxInputIndex -TempAudioCount 0 -IsEncode $false
Assert-Eq 'mux orig (copy)'    1 $mi2.Orig
Assert-Eq 'mux chap copy -> 0' 0 $mi2.Chap
# Get-CvSubtitleMapArgs / Get-CvAttachmentMapArgs (fuente unica multiplex + one-pass)
$smSubs = @([pscustomobject]@{ Index=5; Lang='spa'; Forced=$true; Default=$true }, [pscustomobject]@{ Index=6; Lang='eng'; Forced=$false; Default=$false })
$sm = Get-CvSubtitleMapArgs -Subtitles $smSubs -InputIndex 3
Assert-Eq 'submap exacto' '-map 3:5? -metadata:s:s:0 language=spa -metadata:s:s:0 title=Forzados -disposition:s:0 default+forced -c:s:0 copy -map 3:6? -metadata:s:s:1 language=eng -metadata:s:s:1 title= -disposition:s:1 0 -c:s:1 copy' ($sm -join ' ')
Assert-Eq 'submap input0' '-map 0:5?' (((Get-CvSubtitleMapArgs -Subtitles @($smSubs[0]) -InputIndex 0))[0..1] -join ' ')
Assert-Eq 'submap vacio -> 0' 0 (Get-CvSubtitleMapArgs -Subtitles @() -InputIndex 0).Count
# aplanado con += (patron return ,$a como Get-VideoArgs)
$smFF = @('X'); $smFF += (Get-CvSubtitleMapArgs -Subtitles $smSubs -InputIndex 0)
Assert-Eq 'submap += aplana' 21 $smFF.Count
# ToSrt + fichero externo (rescatado): mapea input propio, pista 0, '-c:s:0 srt'
$smSrt = @([pscustomobject]@{ Index = 0; Lang = 'spa'; Forced = $false; Default = $false; ToSrt = $true; File = 'X:\t.vtt'; InputIndex = 1 })
Assert-Eq 'submap srt+externo' '-map 1:0? -metadata:s:s:0 language=spa -metadata:s:s:0 title= -disposition:s:0 0 -c:s:0 srt' ((Get-CvSubtitleMapArgs -Subtitles $smSrt -InputIndex 0) -join ' ')
# Resolve-CvSubtitleInputs asigna un -i por sub externo y le fija InputIndex; deja el embebido intacto
$ri = Resolve-CvSubtitleInputs -Subtitles @([pscustomobject]@{ Index = 3; File = 'X:\a.vtt' }, [pscustomobject]@{ Index = 4 }) -NextInput 2
Assert-Eq 'SubInputs -i externo'       '-i X:\a.vtt' ($ri.Inputs -join ' ')
Assert-Eq 'SubInputs idx externo'      2 ([int]$ri.Subs[0].InputIndex)
Assert-Eq 'SubInputs embebido intacto' 4 ([int]$ri.Subs[1].Index)
$amAtt = @([pscustomobject]@{ index=7; tags=[pscustomobject]@{ filename='f.ttf'; mimetype='font/ttf' } })
Assert-Eq 'attmap exacto' '-map 3:7? -metadata:s:t:0 filename=f.ttf -metadata:s:t:0 mimetype=font/ttf' ((Get-CvAttachmentMapArgs -Attachments $amAtt -InputIndex 3) -join ' ')
Assert-Eq 'attmap vacio -> 0' 0 (Get-CvAttachmentMapArgs -Attachments @() -InputIndex 0).Count
# GOLDEN Get-CvMultiplexArgs (emisor puro del multiplex; encode + 1 audio temp + 1 sub, sin adjuntos)
$muxCtx  = [pscustomobject]@{ Threads=4; AudioKeepTitle=$false; TestLimit=0 }
$muxInfo = [pscustomobject]@{ streams=@([pscustomobject]@{index=0;codec_type='video'}, [pscustomobject]@{index=1;codec_type='audio'}) }
$muxPlan = [pscustomobject]@{
    File='X:\in.mkv'; Out='X:\out.mkv'; VideoSrc='X:\proc\v.mkv'; Vmap='0:v:0'
    TempAudio=@([pscustomobject]@{ File='X:\proc\a0.m4a'; Index=1; Lang='spa'; Default=$true })
    CopyAudio=@(); LegacyCopy=$false
    Subs=@([pscustomobject]@{ Index=3; Lang='spa'; Forced=$false; Default=$true }); KeepAtt=@()
    OrigInput=2; ChapInput=2; NeedOrig=$true; HasSubs=$true }
Assert-Eq 'GOLDEN multiplex args' '-hide_banner -y -threads 4 -i X:\proc\v.mkv -i X:\proc\a0.m4a -i X:\in.mkv -map_metadata -1 -fflags +bitexact -map_chapters 2 -metadata title= -map 0:v:0 -metadata:s:v title= -metadata:s:v language=und -map 1:a:0 -metadata:s:a:0 language=spa -metadata:s:a:0 title= -disposition:a:0 default -map 2:3? -metadata:s:s:0 language=spa -metadata:s:s:0 title= -disposition:s:0 default -c:s:0 copy -c:v copy -c:a copy -f matroska X:\out.mkv' ((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlan) -join ' ')
# copy clasico monopista: el audio se mapea del ORIGINAL por su input (OrigInput), NO del input 0.
# full-copy: video=original en input0 y original tambien en input1 (NeedOrig) -> OrigInput=1.
$muxPlanCopy = [pscustomobject]@{ File='X:\in.mkv'; Out='X:\out.mkv'; VideoSrc='X:\in.mkv'; Vmap='0:v:0'
    TempAudio=@(); CopyAudio=@(); LegacyCopy=$true; Subs=@(); KeepAtt=@(); OrigInput=1; ChapInput=0; NeedOrig=$true; HasSubs=$false; HasOrigAudio=$true }
Assert-True 'GOLDEN multiplex copy (full) audio de OrigInput' (((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlanCopy) -join ' ') -match ([regex]::Escape('-map 1:a:0? -map_metadata:s:a:0 1:s:a:0')))
# REGRESION (bug): recodificar video + copy audio monopista -> input0 es el temporal de video SIN audio;
# el audio DEBE venir del original (OrigInput=1), no de 0:a:0 (que no existe y hacia fallar ffmpeg).
$muxPlanEncCopy = [pscustomobject]@{ File='X:\in.mkv'; Out='X:\out.mkv'; VideoSrc='X:\proc\v.mkv'; Vmap='0:v:0'
    TempAudio=@(); CopyAudio=@(); LegacyCopy=$true; Subs=@(); KeepAtt=@(); OrigInput=1; ChapInput=1; NeedOrig=$true; HasSubs=$false; HasOrigAudio=$true }
$muxEncCopyStr = ((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlanEncCopy) -join ' ')
Assert-True 'GOLDEN multiplex encode+copy audio de OrigInput' ($muxEncCopyStr -match ([regex]::Escape('-map 1:a:0? -map_metadata:s:a:0 1:s:a:0')))
Assert-Eq   'GOLDEN multiplex encode+copy NO mapea 0:a:0' $false ($muxEncCopyStr -match '-map 0:a:0')
# REGRESION (bug): fuente MUDA (sin audio) -> NO se mapea audio (ni -map ni -map_metadata:s:a:0), salida
# solo-video; si se emitiera, ffmpeg abortaria con -22 ("matches no streams" / metadata a stream inexistente).
$muxPlanSilent = [pscustomobject]@{ File='X:\in.mkv'; Out='X:\out.mkv'; VideoSrc='X:\proc\v.mkv'; Vmap='0:v:0'
    TempAudio=@(); CopyAudio=@(); LegacyCopy=$true; Subs=@(); KeepAtt=@(); OrigInput=1; ChapInput=1; NeedOrig=$true; HasSubs=$false; HasOrigAudio=$false }
$muxSilentStr = ((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlanSilent) -join ' ')
Assert-Eq 'GOLDEN multiplex mudo sin -map a:0'      $false ($muxSilentStr -match '-map 1:a:0')
Assert-Eq 'GOLDEN multiplex mudo sin map_metadata a' $false ($muxSilentStr -match '-map_metadata:s:a:0')
Assert-True 'GOLDEN multiplex mudo mapea video'      ($muxSilentStr -match '-map 0:v:0')
# ================================================================================================
Write-Host "`nRecodificar que engorda: quedarse con el video ORIGINAL" -ForegroundColor Cyan
# Config: de serie NO se toca nada (es una opcion), y el 1.00 dice "solo si sale mas grande".
Assert-Eq   'Config: no se queda el original de serie' $false ([bool](Get-CvConfigDefaults).encode.video.keepOriginalIfBigger)
Assert-Eq   'Config: proporcion 1.00'                  1.0   ([double](Get-CvConfigDefaults).encode.video.keepOriginalRatio)

# Cuanto ocupa la pista de video sin leer el fichero entero. Por orden: tag de mkvmerge, bit_rate,
# tag BPS y, si no hay nada, el tamano del archivo como cota superior (conservador).
$kvTag = [pscustomobject]@{
    format  = [pscustomobject]@{ duration = '100' }
    streams = @([pscustomobject]@{ index = 0; codec_type = 'video'; tags = [pscustomobject]@{ NUMBER_OF_BYTES = '12345678' } })
}
$rTag = Get-CvVideoStreamBytes -Info $kvTag
Assert-Eq   'Tamano pista: del tag de mkvmerge' 12345678 ([long]$rTag.Bytes)
Assert-Eq   'Tamano pista: y lo dice'           'tag'    "$($rTag.From)"
$kvBr = [pscustomobject]@{
    format  = [pscustomobject]@{ duration = '100' }
    streams = @([pscustomobject]@{ index = 0; codec_type = 'video'; bit_rate = '8000' })
}
$rBr = Get-CvVideoStreamBytes -Info $kvBr
Assert-Eq   'Tamano pista: por bit_rate x duracion' 100000 ([long]$rBr.Bytes)
Assert-Eq   'Tamano pista: y lo dice'               'bitrate' "$($rBr.From)"
$kvBps = [pscustomobject]@{
    format  = [pscustomobject]@{ duration = '100' }
    streams = @([pscustomobject]@{ index = 0; codec_type = 'video'; tags = [pscustomobject]@{ BPS = '8000' } })
}
Assert-Eq   'Tamano pista: por el tag BPS' 100000 ([long](Get-CvVideoStreamBytes -Info $kvBps).Bytes)
$kvNada = [pscustomobject]@{
    format  = [pscustomobject]@{ duration = '100' }
    streams = @([pscustomobject]@{ index = 0; codec_type = 'video' })
}
$rArch = Get-CvVideoStreamBytes -Info $kvNada -FileBytes 999
Assert-Eq   'Tamano pista: sin datos, el archivo como tope' 999 ([long]$rArch.Bytes)
Assert-Eq   'Tamano pista: y lo dice'                       'archivo' "$($rArch.From)"
Assert-Eq   'Tamano pista: sin nada de nada, 0' 0 ([long](Get-CvVideoStreamBytes -Info $kvNada).Bytes)
Assert-Eq   'Tamano pista: sin info, 0'         0 ([long](Get-CvVideoStreamBytes -Info $null).Bytes)

# Cuando el original SIRVE de sustituto: solo si la imagen no cambia.
Assert-True 'Imagen intacta: recodificar y ya' ([bool](Get-CvVideoPictureState).Untouched)
Assert-Eq   'Imagen intacta: con recorte no'   $false ([bool](Get-CvVideoPictureState -Crop '1920:800:0:140' -SrcWidth 1920 -SrcHeight 1080).Untouched)
Assert-Eq   'Imagen intacta: con escalado no'  $false ([bool](Get-CvVideoPictureState -Resize '1280:-2' -SrcWidth 1920 -SrcHeight 1080).Untouched)
Assert-Eq   'Imagen intacta: con tone-mapping no' $false ([bool](Get-CvVideoPictureState -Hdr $true -TonemapHdr 'auto').Untouched)
Assert-True 'Imagen intacta: HDR sin tonemapear si' ([bool](Get-CvVideoPictureState -Hdr $true -TonemapHdr 'off').Untouched)
# El fps solo descalifica si CAMBIA (forceFps viene puesto de serie: forzar 23.976 sobre un origen
# que ya va a 23.976 no cambia nada).
Assert-True 'Imagen intacta: mismo fps forzado' ([bool](Get-CvVideoPictureState -SrcFps 23.976 -OutFps 23.976).Untouched)
Assert-Eq   'Imagen intacta: 30 -> 23.976 no'   $false ([bool](Get-CvVideoPictureState -SrcFps 30 -OutFps 23.976).Untouched)
Assert-True 'Imagen intacta: fps desconocido no estorba' ([bool](Get-CvVideoPictureState -SrcFps 0 -OutFps 23.976).Untouched)
# Y dice QUE la cambia (va al log, para no tener que adivinar por que no se sustituyo).
$imgR = Get-CvVideoPictureState -Resize '1280:-2' -SrcFps 30 -OutFps 23.976 -SrcWidth 1920 -SrcHeight 1080
Assert-True 'Imagen: cuenta el escalado' ("$($imgR.Reason)" -match 'escalado 1280:-2')
Assert-True 'Imagen: y el cambio de fps' ("$($imgR.Reason)" -match 'fps 30')
# LO IMPORTANTE (caso real): un perfil con ChangeSize 1920:-2 sobre un video que YA es de 1920 pide
# un escalado que no escala nada; eso no puede impedir quedarse con el original.
Assert-True 'Escalado: al mismo tamano no es tocar la imagen' ([bool](Get-CvVideoPictureState -Resize '1920:-2' -SrcWidth 1920 -SrcHeight 1080).Untouched)
Assert-True 'Escalado: sin escalado, tampoco'  (Test-CvResizeNoop -Resize '' -SrcWidth 1920 -SrcHeight 1080)
Assert-True 'Escalado: 1920:1080 sobre 1920x1080' (Test-CvResizeNoop -Resize '1920:1080' -SrcWidth 1920 -SrcHeight 1080)
Assert-Eq   'Escalado: 1280:-2 sobre 1920 si escala' $false (Test-CvResizeNoop -Resize '1280:-2' -SrcWidth 1920 -SrcHeight 1080)
Assert-Eq   'Escalado: sin medidas no se sabe'       $false (Test-CvResizeNoop -Resize '1920:-2')
Assert-Eq   'Escalado: alto impar con -2 redondea'   $false (Test-CvResizeNoop -Resize '1920:-2' -SrcWidth 1920 -SrcHeight 1081)
Assert-Eq   'Escalado: raro (-2:-2) no se sabe'      $false (Test-CvResizeNoop -Resize '-2:-2' -SrcWidth 1920 -SrcHeight 1080)
# Lo mismo con un recorte que abarca el fotograma entero.
Assert-True 'Recorte: el fotograma entero no recorta' (Test-CvCropNoop -Crop '1920:1080:0:0' -SrcWidth 1920 -SrcHeight 1080)
Assert-Eq   'Recorte: de verdad si'                   $false (Test-CvCropNoop -Crop '1920:800:0:140' -SrcWidth 1920 -SrcHeight 1080)
Assert-True 'Recorte: sin recorte, nada'              (Test-CvCropNoop -Crop '' -SrcWidth 1920 -SrcHeight 1080)

# La decision.
$kpSi = Get-CvVideoKeepPlan -EncodedBytes 2000 -OriginalBytes 1000 -Enabled $true
Assert-True 'Engorda: se queda el original'   ([bool]$kpSi.UseOriginal)
Assert-True 'Engorda: y cuenta por que'       ("$($kpSi.Reason)" -match 'no compensa')
Assert-Eq   'Adelgaza: se queda lo codificado' $false ([bool](Get-CvVideoKeepPlan -EncodedBytes 500 -OriginalBytes 1000 -Enabled $true).UseOriginal)
Assert-Eq   'Justo igual: no es mas grande'    $false ([bool](Get-CvVideoKeepPlan -EncodedBytes 1000 -OriginalBytes 1000 -Enabled $true).UseOriginal)
# Con la proporcion se puede pedir que AHORRE algo, no solo que no engorde.
Assert-True 'Proporcion: si no ahorra un 5%, original' ([bool](Get-CvVideoKeepPlan -EncodedBytes 960 -OriginalBytes 1000 -Enabled $true -Ratio 0.95).UseOriginal)
Assert-Eq   'Proporcion: si ahorra mas, lo codificado' $false ([bool](Get-CvVideoKeepPlan -EncodedBytes 900 -OriginalBytes 1000 -Enabled $true -Ratio 0.95).UseOriginal)
Assert-Eq   'Apagado: no se compara nada'      $false ([bool](Get-CvVideoKeepPlan -EncodedBytes 2000 -OriginalBytes 1000).UseOriginal)
$kpToc = Get-CvVideoKeepPlan -EncodedBytes 2000 -OriginalBytes 1000 -Enabled $true -Untouched $false
Assert-Eq   'Imagen cambiada: no se sustituye' $false ([bool]$kpToc.UseOriginal)
Assert-True 'Imagen cambiada: y dice por que'  ("$($kpToc.Reason)" -match 'la imagen cambia')
$kpNs = Get-CvVideoKeepPlan -EncodedBytes 2000 -OriginalBytes 0 -Enabled $true
Assert-Eq   'Sin tamanos no se decide'         $false ([bool]$kpNs.UseOriginal)
Assert-True 'Sin tamanos: y lo dice'           ("$($kpNs.Reason)" -match 'no se sabe')

# En el JOB: se decide por archivo, y un job de antes de la opcion hereda lo que diga la config.
$kjCtx = [pscustomobject]@{ FFmpegVersion = '7.1.1'; AacGainVersion = '1.9' }
$kjRec = ConvertTo-CvJobRecord -Context $kjCtx -File 'X:\a.mkv' -Prof ([pscustomobject]@{ VideoEncoder = 'libx265' }) -KeepOriginal $true
Assert-Eq   'Job: lleva keepOriginal'          $true ([bool]$kjRec.video.keepOriginal)
Assert-Eq   'Job: keepOriginal de serie'       $false ([bool](ConvertTo-CvJobRecord -Context $kjCtx -File 'X:\a.mkv' -Prof ([pscustomobject]@{ VideoEncoder = 'libx265' })).video.keepOriginal)
Assert-Eq   'Job viejo: manda la config (si)'  $true  (Get-CvJobKeepOriginal -Job ([pscustomobject]@{ video = [pscustomobject]@{ skip = $false } }) -Default $true)
Assert-Eq   'Job viejo: manda la config (no)'  $false (Get-CvJobKeepOriginal -Job ([pscustomobject]@{ video = [pscustomobject]@{ skip = $false } }) -Default $false)
Assert-Eq   'Job nuevo: manda el job'          $false (Get-CvJobKeepOriginal -Job ([pscustomobject]@{ video = [pscustomobject]@{ keepOriginal = $false } }) -Default $true)
Assert-Eq   'Job nuevo: manda el job (si)'     $true  (Get-CvJobKeepOriginal -Job ([pscustomobject]@{ video = [pscustomobject]@{ keepOriginal = $true } }) -Default $false)
Assert-Eq   'Sin job: manda el defecto'        $true  (Get-CvJobKeepOriginal -Job $null -Default $true)

# La SALIDA queda marcada, que es lo unico que sobrevive (el job se borra al terminar).
$muxPlanKeep = [pscustomobject]@{ File='X:\in.mkv'; Out='X:\out.mkv'; VideoSrc='X:\in.mkv'; Vmap='0:v:0'
    TempAudio=@(); CopyAudio=@(); LegacyCopy=$true; Subs=@(); KeepAtt=@(); OrigInput=1; ChapInput=0; NeedOrig=$true; HasSubs=$false; HasOrigAudio=$true
    VideoFromSource=$true }
Assert-True 'Multiplex: marca el video original' (((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlanKeep) -join ' ') -match ([regex]::Escape('-metadata CV_VIDEO=original')))
Assert-Eq   'Multiplex: sin marca si no aplica'  $false (((Get-CvMultiplexArgs -Context $muxCtx -Info $muxInfo -Plan $muxPlanCopy) -join ' ') -match 'CV_VIDEO')
# Y la cola la lee de la salida.
Assert-Eq   'Marca: se lee de la salida' 'original' (Get-CvOutputVideoSource -Info ([pscustomobject]@{ format = [pscustomobject]@{ tags = [pscustomobject]@{ CV_VIDEO = 'original' } } }))
Assert-Eq   'Marca: en minusculas tambien' 'original' (Get-CvOutputVideoSource -Info ([pscustomobject]@{ format = [pscustomobject]@{ tags = [pscustomobject]@{ cv_video = 'ORIGINAL' } } }))
Assert-Eq   'Marca: salida normal, nada'  '' (Get-CvOutputVideoSource -Info ([pscustomobject]@{ format = [pscustomobject]@{ tags = [pscustomobject]@{ title = 'x' } } }))
Assert-Eq   'Marca: sin tags, nada'       '' (Get-CvOutputVideoSource -Info ([pscustomobject]@{ format = [pscustomobject]@{} }))
Assert-Eq   'Marca: sin info, nada'       '' (Get-CvOutputVideoSource -Info $null)

# La beta de UNA PASADA sigue sirviendo con la opcion puesta: alli no hay un momento intermedio
# donde mirar el video, asi que se compara el FICHERO ya hecho y se le cambia el video con un remux.
$kpCtx1 = [pscustomobject]@{ BetaOnePass = $true; SyncAdelay = $true; VolumeMethod = 'loudnorm'; TonemapHdr = 'off'; KeepOriginal = $true }
$kpJob1 = [pscustomobject]@{ video = [pscustomobject]@{ skip = $false; hdr = $false; keepOriginal = $true }; audio = [pscustomobject]@{ skip = $false } }
Assert-True 'Una pasada: vale con keepOriginal' ([bool](Test-CvOnePassEligible -Context $kpCtx1 -Job $kpJob1 -Prof ([pscustomobject]@{ AudioCodec = 'aac' })).Ok)
# El cambiazo: el video sale del ORIGINAL (input 1) y todo lo demas de la salida ya hecha (input 0),
# copiando (no se recodifica nada) y dejando la marca.
$swCtx = [pscustomobject]@{ Threads = 4 }
# OJO: devuelve ',$a' (como los demas emisores), asi que NO se envuelve en @() al leerlo.
$swArgs = (Get-CvVideoSwapArgs -Context $swCtx -OutFile 'X:\out.mkv' -SrcFile 'X:\in.mkv' -TmpFile 'X:\tmp.mkv' -VideoIndex 2)
Assert-Eq 'GOLDEN cambiazo de video' '-hide_banner -y -threads 4 -i X:\out.mkv -i X:\in.mkv -map 1:2 -map 0:a? -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0 -metadata:s:v title= -metadata:s:v language=und -metadata CV_VIDEO=original -c copy -f matroska X:\tmp.mkv' ($swArgs -join ' ')
Assert-True 'Cambiazo: sin indice, la primera de video' (((Get-CvVideoSwapArgs -Context $swCtx -OutFile 'X:\out.mkv' -SrcFile 'X:\in.mkv' -TmpFile 'X:\tmp.mkv') -join ' ') -match ([regex]::Escape('-map 1:v:0')))


# ================================================================================================
Write-Host "`nGet-CvNvencFallbackCandidates (Tools)" -ForegroundColor Cyan
# solo las anteriores a la fallida, de mas nueva a mas antigua (excluye la fallida y las mas nuevas)
Assert-Eq 'candidatos < fallida (desc)' @('7.1.1','6.0') (Get-CvNvencFallbackCandidates -Failed '8.1.2' -Available @('8.1.2','7.1.1','6.0'))
Assert-Eq 'excluye mas nuevas'          @('7.1.1','6.0') (Get-CvNvencFallbackCandidates -Failed '8.1.2' -Available @('9.0','8.1.2','7.1.1','6.0'))
Assert-Eq 'solo mas nuevas -> vacio'    @()             (Get-CvNvencFallbackCandidates -Failed '8.1.2' -Available @('8.1.2','8.1.3'))
Assert-Eq 'sin catalogo -> vacio'       @()             (Get-CvNvencFallbackCandidates -Failed '8.1.2' -Available @())
Assert-Eq 'orden desc'                  @('7.1.1','6.0','5.0') (Get-CvNvencFallbackCandidates -Failed '8.0' -Available @('5.0','7.1.1','6.0'))

Write-Host "`nSoporte de encoders por GPU (Tools / Profile)" -ForegroundColor Cyan
Reset-CvGpuEncCache
Assert-Eq   'GpuEncoders = 3'          3 (@(Get-CvGpuEncoders)).Count
Assert-True 'GpuEncoders av1_nvenc'    (@(Get-CvGpuEncoders) -contains 'av1_nvenc')
Assert-True 'GpuEncoders hevc_nvenc'   (@(Get-CvGpuEncoders) -contains 'hevc_nvenc')
# CPU / copy: siempre soportados (no se prueba la GPU).
Assert-True 'Supported libx264'        (Test-CvEncoderSupported -Context $null -Encoder 'libx264')
Assert-True 'Supported libsvtav1'      (Test-CvEncoderSupported -Context $null -Encoder 'libsvtav1')
Assert-True 'Supported copy'           (Test-CvEncoderSupported -Context $null -Encoder 'copy')
# GPU con contexto nulo -> no bloquea (true).
Assert-True 'GPU ctx nulo -> true'     (Test-CvEncoderSupported -Context $null -Encoder 'av1_nvenc')
# GPU con ffmpeg no resoluble -> no bloquea (true), sin tocar la GPU.
$fakeFf = [pscustomobject]@{ FFmpeg = 'Z:\no\existe\ffmpeg.exe' }
Assert-True 'GPU sin ffmpeg -> true'   (Test-CvGpuEncoder -Context $fakeFf -Encoder 'av1_nvenc')
# Cache persistente de la sonda (Read/Save-CvGpuCache): clavada por version de ffmpeg + GPU.
$gpuTmp = Join-Path $env:TEMP ("cv-ut-gpucache-{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
Set-Content -Path $gpuTmp -Value '{}'
Save-CvGpuCache -CfgPath $gpuTmp -Ffmpeg '7.1.1' -Gpu 'GPU-X' -Encoders ([ordered]@{ h264_nvenc = $true; hevc_nvenc = $true; av1_nvenc = $false })
$rc = Read-CvGpuCache -CfgPath $gpuTmp -Ffmpeg '7.1.1' -Gpu 'GPU-X'
Assert-True 'GpuCache round-trip h264'         ([bool](Get-CvNodeVal $rc 'h264_nvenc'))
Assert-Eq   'GpuCache round-trip av1'    $false ([bool](Get-CvNodeVal $rc 'av1_nvenc'))
Assert-True 'GpuCache ffmpeg distinto -> null'  ($null -eq (Read-CvGpuCache -CfgPath $gpuTmp -Ffmpeg '8.0'   -Gpu 'GPU-X'))
Assert-True 'GpuCache gpu distinta -> null'     ($null -eq (Read-CvGpuCache -CfgPath $gpuTmp -Ffmpeg '7.1.1' -Gpu 'GPU-Y'))
Assert-True 'GpuName es string'                 ((Get-CvGpuName) -is [string])
Remove-Item $gpuTmp -Force -ErrorAction SilentlyContinue

# ================================================================================================
Write-Host "`nWorkerCore - estados de la cola" -ForegroundColor Cyan
# El ORDEN de las reglas es lo que se prueba aqui: quien esta trabajando el archivo manda sobre que
# exista la salida, porque el fichero de salida EXISTE mientras se escribe (la ruta de una sola
# pasada escribe directamente en Convertido\) y marcaba 'Hecho' con el worker aun codificando.
Assert-Eq 'Cola: reclamado por un worker' 'working' (Resolve-CvQueueState -HasJob $true -Claimed $true)
Assert-Eq 'Cola: bloqueo vivo'           'working' (Resolve-CvQueueState -Locked $true -HasJob $true)
Assert-Eq 'Cola: salida a medio escribir' 'working' (Resolve-CvQueueState -Done $true -Locked $true -HasJob $true)
Assert-Eq 'Cola: salida a medio escribir (reclamado)' 'working' (Resolve-CvQueueState -Done $true -Claimed $true)
# 'Hecho' de verdad = hay salida y YA NO queda job: el worker borra el job solo cuando acaba bien.
# Si la salida esta pero el job sigue, la conversion se corto a medias (cancelada): 'partial'. Importa
# porque el worker SALTA los archivos que ya tienen salida, asi que ese resto bloquea el reintento.
Assert-Eq 'Cola: salida + job = sin terminar' 'partial' (Resolve-CvQueueState -Done $true -HasJob $true)
Assert-Eq 'Cola: hecho (salida sin job)'      'done'    (Resolve-CvQueueState -Done $true)
Assert-Eq 'Cola: hecho con bloqueo caducado'  'done'    (Resolve-CvQueueState -Done $true -Locked $true -Stale $true)
Assert-Eq 'Cola: bloqueo caducado'       'stale'   (Resolve-CvQueueState -Locked $true -Stale $true -HasJob $true)
Assert-Eq 'Cola: con job, en cola'       'queued'  (Resolve-CvQueueState -HasJob $true)
Assert-Eq 'Cola: sin job, sin preparar'  'pending' (Resolve-CvQueueState)
# Catalogo de estados: fuente unica del texto que ensenan consola y ventana.
$qs = @(Get-CvQueueStates)
Assert-Eq   'Cola: 6 estados en el catalogo' 6 $qs.Count
Assert-True 'Cola: todos con texto'      (@($qs | Where-Object { [string]::IsNullOrWhiteSpace($_.Text) }).Count -eq 0)
foreach ($q in $qs) { Assert-Eq ("Cola: texto de {0}" -f $q.Value) $q.Text (Get-CvQueueStateText -State $q.Value) }
Assert-Eq 'Cola: estado desconocido tal cual' 'loquesea' (Get-CvQueueStateText -State 'loquesea')
# Recuento por estado (lo que resume la ventana bajo la lista).
$fakeRows = @(
    [pscustomobject]@{ State = 'done' }
    [pscustomobject]@{ State = 'partial' }
    [pscustomobject]@{ State = 'working' }
    [pscustomobject]@{ State = 'queued' }
    [pscustomobject]@{ State = 'pending' }
    [pscustomobject]@{ State = 'stale' }
)
$tot = Get-CvQueueTotals -Rows $fakeRows
Assert-Eq 'Totales: total'   6 $tot.Total
Assert-Eq 'Totales: hechos'  1 $tot.Done
Assert-Eq 'Totales: sin terminar' 1 $tot.Partial
Assert-Eq 'Totales: en curso' 1 $tot.Working
Assert-Eq 'Totales: en cola' 1 $tot.Queued
Assert-Eq 'Totales: sin preparar' 1 $tot.Pending
Assert-Eq 'Totales: huerfanos' 1 $tot.Stale
$totVacio = Get-CvQueueTotals -Rows @()
Assert-Eq 'Totales: cola vacia' 0 $totVacio.Total
# Argumentos con los que la ventana abre un worker (puro: se comprueba sin abrir procesos).
$wa = @(Get-CvConvertWorkerArgs -Root 'D:\cv')
Assert-True 'Worker args: sin perfil ni config'  (($wa -join ' ') -eq '-NoProfile -ExecutionPolicy Bypass -File "D:\cv\Convert.ps1" -WorkerOnly -Unattended')
$wc = @(Get-CvConvertWorkerArgs -Root 'D:\cv' -CfgPath 'D:\cv\config.debug.json')
Assert-True 'Worker args: con -Config'           (($wc -join ' ').Contains('-Config "D:\cv\config.debug.json"'))
# -Only: la ventana lo manda en UN argumento con los nombres separados por '|', porque
# 'powershell -File' no sabe pasar listas (con comas, el worker recibia 'A,B,C' como un solo nombre
# y no encontraba ninguno: se abrian los workers y se morian sin codificar nada).
$wo = @(Get-CvConvertWorkerArgs -Root 'D:\cv' -Only @('Serie_1x01', 'Serie 1x05', 'Peli_[2024]'))
Assert-True 'Worker args: pasa -Only'            (($wo -join ' ').Contains('-Only "Serie_1x01|Serie 1x05|Peli_[2024]"'))
Assert-Eq   'Worker args: -Only en UN argumento'  1 @(@($wo)[[array]::IndexOf($wo, '-Only') + 1]).Count
# Y el worker lo desdobla: ida y vuelta completa.
$woIda = @('Serie_1x01', 'Serie 1x05', 'Peli_[2024]', 'Peli, con coma')
$woArg = @(Get-CvConvertWorkerArgs -Root 'D:\cv' -Only $woIda)
$woVuelta = @(Expand-CvOnlyList -Values @(("$(@($woArg)[[array]::IndexOf($woArg, '-Only') + 1])").Trim('"')))
Assert-Eq   'Worker args: ida y vuelta' ($woIda -join '|') ($woVuelta -join '|')
Assert-Eq   'Only: un nombre suelto'    'Serie_1x01' ((Expand-CvOnlyList -Values @('Serie_1x01')) -join '|')
Assert-Eq   'Only: varios pegados'      'A|B|C'      ((Expand-CvOnlyList -Values @('A|B|C')) -join '|')
Assert-Eq   'Only: ya en lista (consola)' 'A|B'      ((Expand-CvOnlyList -Values @('A', 'B')) -join '|')
Assert-Eq   'Only: la coma NO separa'   'Peli, con coma' ((Expand-CvOnlyList -Values @('Peli, con coma')) -join '|')
Assert-Eq   'Only: sin vacios'          'A'          ((Expand-CvOnlyList -Values @('', '  ', 'A')) -join '|')
Assert-Eq   'Only: sin repetidos'       'A|B'        ((Expand-CvOnlyList -Values @('A', 'B', 'A')) -join '|')
Assert-Eq   'Only: nada es nada'        0            (@(Expand-CvOnlyList -Values @()).Count)
# Lo que NO cabe en la linea de comandos se avisa antes de abrir workers (Windows corta en 32767).
Assert-True 'Only: una lista normal cabe' ([bool](Test-CvWorkerOnlyFits -Argv $woArg).Ok)
$woMucho = @(Get-CvConvertWorkerArgs -Root 'D:\cv' -Only @(1..1200 | ForEach-Object { 'Serie_Muy_Larga_De_Nombre_{0:d4}' -f $_ }))
Assert-Eq   'Only: 1200 nombres no caben' $false ([bool](Test-CvWorkerOnlyFits -Argv $woMucho).Ok)
Assert-Eq   'Only: el limite es a medida' 10 ([int](Test-CvWorkerOnlyFits -Argv @('12345') -Max 10).Max)
Assert-Eq   'Worker args: sin -Only si esta vacio' 0 @(@(Get-CvConvertWorkerArgs -Root 'D:\cv' -Only @()) | Where-Object { $_ -eq '-Only' }).Count
Assert-Eq   'Worker args: ignora nombres vacios'   0 @(@(Get-CvConvertWorkerArgs -Root 'D:\cv' -Only @('', '   ')) | Where-Object { $_ -eq '-Only' }).Count

# Los ficheros de control de los workers se limpian con los bloqueos (misma fuente unica que usa
# setup para limpiar Proceso\): si no, un estado o una bandera huerfana se quedarian ahi para siempre.
$pl = @(Get-CvProcesoPatterns -What locks)
Assert-True 'Patrones: bloqueos'   ($pl -contains '*.lock')
Assert-True 'Patrones: estado de workers' ($pl -contains '*.worker.json')
Assert-True 'Patrones: bandera de parada' ($pl -contains 'stop.flag')
Assert-True 'Patrones: all incluye el estado' ((Get-CvProcesoPatterns -What all) -contains '*.worker.json')

# ================================================================================================
Write-Host "`nSubtitulos: codecs de texto y pistas vacias en las opciones del job" -ForegroundColor Cyan
Assert-True 'Texto: subrip'      (Test-CvSubtitleTextCodec -Codec 'subrip')
Assert-True 'Texto: ass'         (Test-CvSubtitleTextCodec -Codec 'ASS')
Assert-True 'Texto: mov_text'    (Test-CvSubtitleTextCodec -Codec 'mov_text')
Assert-Eq   'Imagen: PGS'        $false (Test-CvSubtitleTextCodec -Codec 'hdmv_pgs_subtitle')
Assert-Eq   'Imagen: VobSub'     $false (Test-CvSubtitleTextCodec -Codec 'dvd_subtitle')
Assert-Eq   'Codec vacio'        $false (Test-CvSubtitleTextCodec -Codec '')
# Nº de lineas (cues) por el TAG de mkvmerge: instantaneo y sin demultiplexar. -1 = no se sabe, y
# entonces quien lo use (el resumen de la cola) NO debe inventarse nada.
$stTag = [pscustomobject]@{ index = 4; tags = [pscustomobject]@{ NUMBER_OF_FRAMES = '1082' } }
$stCero = [pscustomobject]@{ index = 5; tags = [pscustomobject]@{ NUMBER_OF_FRAMES = '0' } }
$stSin = [pscustomobject]@{ index = 6; tags = [pscustomobject]@{ language = 'spa' } }
Assert-Eq 'Cues por tag'            1082 (Get-CvSubtitleCueTag -Stream $stTag)
Assert-Eq 'Cues por tag: cero'      0    (Get-CvSubtitleCueTag -Stream $stCero)
Assert-Eq 'Cues por tag: sin tag'   -1   (Get-CvSubtitleCueTag -Stream $stSin)

# El SubSel puede llevar el recuento ya hecho (se guarda en el job y el resumen no lo recuenta).
$sPgs = [pscustomobject]@{ index = 4; codec_name = 'subrip'; disposition = [pscustomobject]@{ default = 0; forced = 0 }; tags = [pscustomobject]@{ language = 'spa' } }
Assert-Eq 'SubSel: sin recuento -> -1' -1  (ConvertTo-SubSel $sPgs).Cues
Assert-Eq 'SubSel: guarda el recuento' 842 (ConvertTo-SubSel $sPgs -Cues 842).Cues

# A que fichero se saca cada pista para abrirla fuera: texto a .srt (transcodificado) y las de
# IMAGEN a su formato tal cual, que es lo unico que se puede hacer con ellas (no hay texto).
Assert-Eq   'Fichero: subrip -> .srt'  '.srt' (Get-CvSubtitleFileExt -Codec 'subrip')
Assert-Eq   'Fichero: ass -> .srt'     '.srt' (Get-CvSubtitleFileExt -Codec 'ass')
Assert-Eq   'Fichero: PGS -> .sup'     '.sup' (Get-CvSubtitleFileExt -Codec 'hdmv_pgs_subtitle')
Assert-Eq   'Fichero: VobSub -> .idx'  '.idx' (Get-CvSubtitleFileExt -Codec 'dvd_subtitle')
Assert-Eq   'Fichero: codec raro'      ''     (Get-CvSubtitleFileExt -Codec 'loquesea')
Assert-Eq   'Fichero: sin codec'       ''     (Get-CvSubtitleFileExt -Codec '')
# Con contexto mandan sus listas (las de config.json): asi se anade un codec nuevo sin tocar codigo.
$ctxSub = [pscustomobject]@{
    SubtitleTextCodecs = @('subrip', 'miformato')
    SubtitleFileExts   = @{ 'dvb_subtitle' = '.dvb' }
}
Assert-Eq   'Fichero: codec nuevo de config' '.dvb' (Get-CvSubtitleFileExt -Codec 'DVB_SUBTITLE' -Context $ctxSub)
Assert-Eq   'Fichero: texto nuevo de config' '.srt' (Get-CvSubtitleFileExt -Codec 'miformato' -Context $ctxSub)
Assert-True 'Texto: la lista sale del contexto' (Test-CvSubtitleTextCodec -Codec 'miformato' -Context $ctxSub)
Assert-Eq   'Texto: y lo que no esta, no'  $false (Test-CvSubtitleTextCodec -Codec 'ass' -Context $ctxSub)

# REGRESION: una pista de subtitulo VACIA (0 cues) NO puede venir marcada para conservar. Es el caso
# real de 4.5.5: mapearla deja el '-progress' de ffmpeg en N/A y la barra congelada en 0%. La consola
# la descarta (Select-Subtitles con encode.subtitles.dropEmpty) y las opciones del editor en ventana
# tienen que hacer lo MISMO: se ensena (marcada como VACIO) pero no se auto-selecciona.
# Contexto y streams sinteticos: con el tag NUMBER_OF_FRAMES no hace falta ffprobe.
$subCtx = [pscustomobject]@{
    SubtitlesToSrt     = @()
    SubLangs           = @('spa')
    SubtitlesDropEmpty = $true
    FFprobe            = ''
}
$subInfo = [pscustomobject]@{
    format  = [pscustomobject]@{ format_name = 'matroska,webm'; filename = 'x.mkv' }
    streams = @(
        [pscustomobject]@{
            index = 4; codec_type = 'subtitle'; codec_name = 'hdmv_pgs_subtitle'
            disposition = [pscustomobject]@{ default = 0; forced = 0 }
            tags = [pscustomobject]@{ language = 'spa'; NUMBER_OF_FRAMES = '0' }
        }
        [pscustomobject]@{
            index = 5; codec_type = 'subtitle'; codec_name = 'hdmv_pgs_subtitle'
            disposition = [pscustomobject]@{ default = 0; forced = 0 }
            tags = [pscustomobject]@{ language = 'spa'; NUMBER_OF_FRAMES = '1082' }
        }
    )
}
$so = @(Get-CvJobSubtitleOptions -Context $subCtx -Info $subInfo)
Assert-Eq   'Subs: se ensenan las dos'      2 $so.Count
$so0 = $so | Where-Object { $_.Index -eq 4 } | Select-Object -First 1
$so1 = $so | Where-Object { $_.Index -eq 5 } | Select-Object -First 1
Assert-True 'Subs: la de 0 cues sale VACIA' $so0.Empty
Assert-Eq   'Subs: la vacia NO se marca'    $false $so0.Auto
Assert-True 'Subs: la buena si se marca'    $so1.Auto
Assert-Eq   'Subs: la buena no es forzada'  $false $so1.AutoForced
Assert-Eq   'Subs: PGS no es texto'         $false $so1.IsText
Assert-True 'Subs: las dos son utilizables' ($so0.Usable -and $so1.Usable)
# Con dropEmpty = false (el comportamiento antiguo) la vacia vuelve a entrar, como en consola.
$subCtx2 = [pscustomobject]@{
    SubtitlesToSrt     = @()
    SubLangs           = @('spa')
    SubtitlesDropEmpty = $false
    FFprobe            = ''
}
$so2 = @(Get-CvJobSubtitleOptions -Context $subCtx2 -Info $subInfo)
Assert-True 'Subs: sin dropEmpty entra la vacia' (@($so2 | Where-Object { $_.Index -eq 4 })[0].Auto)

# ================================================================================================
Write-Host "`nTest-CvCropSignificant (barras de verdad vs ruido de borde)" -ForegroundColor Cyan
# Un recorte es BARRA si reduce al menos minCropPct; cropdetect casi siempre quita unos pixeles.
Assert-Eq   'Crop: barras 21:9 en 1080p' $true  (Test-CvCropSignificant -Crop '1920:800:0:140' -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq   'Crop: 8px de ruido no es barra' $false (Test-CvCropSignificant -Crop '1912:1072:4:4' -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq   'Crop: sin recorte'          $false (Test-CvCropSignificant -Crop '1920:1080:0:0' -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq   'Crop: recorte lateral'      $true  (Test-CvCropSignificant -Crop '1440:1080:240:0' -Width 1920 -Height 1080 -MinPct 2)
# Con el umbral a 0 cualquier reduccion cuenta; sin dimensiones o con basura, $false (no revienta).
Assert-Eq   'Crop: umbral 0'             $true  (Test-CvCropSignificant -Crop '1912:1080:4:0' -Width 1920 -Height 1080 -MinPct 0)
Assert-Eq   'Crop: sin dimensiones'      $false (Test-CvCropSignificant -Crop '1920:800:0:140' -Width 0 -Height 0 -MinPct 2)
Assert-Eq   'Crop: texto no valido'      $false (Test-CvCropSignificant -Crop 'nada' -Width 1920 -Height 1080 -MinPct 2)

# ================================================================================================
Write-Host "`nGet-CvOutputSize / Format-CvCropCut (que tamano queda y que se quita)" -ForegroundColor Cyan
# Lo que ensena el resumen debajo de la pista: de que se parte, que se recorta y con que se queda.
$g1 = Get-CvOutputSize -Width 1920 -Height 1080 -Crop '1920:960:0:60'
Assert-Eq   'Tamano: recorte 2:1'        '1920x960' ("{0}x{1}" -f $g1.Width, $g1.Height)
Assert-Eq   'Tamano: 60px arriba'        60 $g1.Top
Assert-Eq   'Tamano: 60px abajo'         60 $g1.Bottom
Assert-Eq   'Tamano: nada a los lados'   0  ($g1.Left + $g1.Right)
Assert-True 'Tamano: se recorta'         $g1.Cropped
# Escalado automatico: '-2' conserva el aspecto y deja el lado en par.
$g2 = Get-CvOutputSize -Width 1920 -Height 1080 -Resize '1280:-2'
Assert-Eq   'Escalado: 1280:-2'          '1280x720' ("{0}x{1}" -f $g2.Width, $g2.Height)
# '-2' redondea al par MAS CERCANO, como hace ffmpeg (800*1280/1920 = 533,3 -> 534, no 532).
$g3 = Get-CvOutputSize -Width 1920 -Height 800 -Resize '1280:-2'
Assert-Eq   'Escalado: alto par'         '1280x534' ("{0}x{1}" -f $g3.Width, $g3.Height)
$g4 = Get-CvOutputSize -Width 1920 -Height 1080 -Resize '-2:480'
Assert-Eq   'Escalado: ancho automatico' '854x480'  ("{0}x{1}" -f $g4.Width, $g4.Height)
Assert-Eq   'Escalado: -1 sin paridad'   '853x480'  ("{0}x{1}" -f ((Get-CvOutputSize -Width 1920 -Height 1080 -Resize '-1:480')).Width, ((Get-CvOutputSize -Width 1920 -Height 1080 -Resize '-1:480')).Height)
# Recorte Y escalado, en ese orden (es el del filtro).
$g5 = Get-CvOutputSize -Width 1920 -Height 1080 -Crop '1920:960:0:60' -Resize '1280:-2'
Assert-Eq   'Tamano: recorte + escalado' '1280x640' ("{0}x{1}" -f $g5.Width, $g5.Height)
# Un escalado que no cambia nada se detecta (el resumen lo dice: 'no cambia el tamano').
$g6 = Get-CvOutputSize -Width 1920 -Height 1080 -Crop '1920:960:0:60' -Resize '1920:-2'
Assert-Eq   'Tamano: escalado que no cambia' '1920x960' ("{0}x{1}" -f $g6.Width, $g6.Height)
Assert-Eq   'Tamano: setsar se ignora'   '1920x800' (("{0}x{1}" -f ((Get-CvOutputSize -Width 1920 -Height 1080 -Resize '1920:800,setsar=1')).Width, ((Get-CvOutputSize -Width 1920 -Height 1080 -Resize '1920:800,setsar=1')).Height))
Assert-Eq   'Tamano: sin datos de origen' 0 (Get-CvOutputSize -Width 0 -Height 0 -Crop '1920:960:0:60').Width
Assert-Eq   'Tamano: recorte imposible'  '1920x1080' ("{0}x{1}" -f ((Get-CvOutputSize -Width 1920 -Height 1080 -Crop '4000:4000:0:0')).Width, ((Get-CvOutputSize -Width 1920 -Height 1080 -Crop '4000:4000:0:0')).Height)

Assert-Eq   'Corte: barras horizontales' 'quita 60px arriba y abajo (barras horizontales)' (Format-CvCropCut -Top 60 -Bottom 60)
Assert-Eq   'Corte: barras verticales'   'quita 240px a cada lado (barras verticales)'     (Format-CvCropCut -Left 240 -Right 240)
Assert-Eq   'Corte: asimetrico'          'quita 60px arriba y 4px a la derecha'            (Format-CvCropCut -Top 60 -Right 4)
Assert-Eq   'Corte: sin recorte'         ''                                                (Format-CvCropCut)

# La celda de BORDES del recorrido de 'Preparar pendientes': un vistazo por archivo.
Assert-Eq 'Celda: con barras'    '[x] 1920x960'   (Format-CvJobBorderCell -Crop '1920:960:0:60' -Width 1920 -Height 1080 -Detect $true)
Assert-Eq 'Celda: con escalado'  '[x] 1280x640'   (Format-CvJobBorderCell -Crop '1920:960:0:60' -Resize '1280:-2' -Width 1920 -Height 1080 -Detect $true)
Assert-Eq 'Celda: sin barras'    '[ ] sin barras' (Format-CvJobBorderCell -Width 1920 -Height 1080 -Detect $true)
Assert-Eq 'Celda: solo escalado' '1280x720'       (Format-CvJobBorderCell -Resize '1280:-2' -Width 1920 -Height 1080 -Detect $false)
Assert-Eq 'Celda: nada que decir' ''              (Format-CvJobBorderCell -Width 1920 -Height 1080 -Detect $false)
Assert-Eq 'Celda: sin datos'      ''              (Format-CvJobBorderCell -Detect $false)

# Nombre corto del encoder para ensenarlo: sale del catalogo del menu, no de una lista aparte.
Assert-Eq   'Encoder: hevc_nvenc' 'h265 (GPU)' (Get-CvEncoderShortName -Encoder 'hevc_nvenc')
Assert-Eq   'Encoder: libx265'    'h265 (CPU)' (Get-CvEncoderShortName -Encoder 'libx265')
Assert-Eq   'Encoder: libsvtav1'  'AV1 (CPU)'  (Get-CvEncoderShortName -Encoder 'libsvtav1')
Assert-Eq   'Encoder: copy'       'se copia'   (Get-CvEncoderShortName -Encoder 'copy')
Assert-Eq   'Encoder: desconocido' 'raro'      (Get-CvEncoderShortName -Encoder 'RARO')
Assert-Eq   'Encoder: vacio'      ''           (Get-CvEncoderShortName -Encoder '')

# ================================================================================================
Write-Host "`nMerge-CvCropBoxes / Resolve-CvCropAutoDecision (la decision del modo 'auto')" -ForegroundColor Cyan
# Los puntos NO se votan: se COMBINAN (union + simetria + ruido por eje). Los casos con numeros
# raros son cajas REALES medidas con ffmpeg sobre tres archivos distintos.
$decAuto = {
    param($Boxes, [int]$W, [int]$H, [int]$Max = 40)
    Resolve-CvCropAutoDecision -Groups @($Boxes | ForEach-Object { @{ Crop = $_; Count = 1 } }) `
        -Width $W -Height $H -MinCropPct 2 -MaxCropPct $Max
}
# --- La combinacion, paso a paso ---
Assert-Eq 'Union: dos cajas' '1920:960:0:60' (Merge-CvCropBoxes -Boxes @('1920:960:0:60', '1600:960:160:60') -Width 1920 -Height 1080 -MinPct 2)
# Simetria: 94px a un lado y 2px al otro no son barra; se queda el menor, y 2px es ruido -> no recorta ese eje.
Assert-Eq 'Union: simetriza y limpia' '1920:960:0:60' (Merge-CvCropBoxes -Boxes @('1824:960:94:60') -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq 'Union: solo ruido -> vacio' '' (Merge-CvCropBoxes -Boxes @('1916:1076:2:2') -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq 'Union: pillarbox' '1440:1080:240:0' (Merge-CvCropBoxes -Boxes @('1440:1080:240:0') -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq 'Union: caja imposible se ignora' '' (Merge-CvCropBoxes -Boxes @('4000:4000:0:0') -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq 'Union: sin cajas' '' (Merge-CvCropBoxes -Boxes @() -Width 1920 -Height 1080 -MinPct 2)
Assert-Eq 'Union: sin tamano de origen' '' (Merge-CvCropBoxes -Boxes @('1920:960:0:60') -Width 0 -Height 0 -MinPct 2)

# --- REGRESION (archivo real): 3 puntos de 5s, NINGUNO da las barras buenas y dos son planos
# oscuros. Con votos no se recortaba nada; combinando, salen las barras de verdad.
$d204 = & $decAuto @('1168:640:366:174', '1824:960:94:60', '528:672:694:196') 1920 1080
Assert-Eq 'Auto: barras que antes se escapaban' 'crop' $d204.Decision
Assert-Eq 'Auto: el recorte es el bueno'        '1920:960:0:60' $d204.Crop
# --- REGRESION (otro archivo real): barras 2:1 + una escena oscura.
$dReal = & $decAuto @('1920:960:0:60', '224:608:818:228') 1920 1080
Assert-Eq 'Auto: barras 2:1 se recortan'   'crop' $dReal.Decision
Assert-Eq 'Auto: no se lo come la oscura'  '1920:960:0:60' $dReal.Crop
# --- REGRESION (tercer archivo real): SIN barras, solo 2-4px de borde sucio.
$dNone = & $decAuto @('1424:1072:2:4', '1168:704:238:264') 1428 1080
Assert-Eq 'Auto: sin barras no recorta' 'none' $dNone.Decision
Assert-Eq 'Auto: y no propone recorte'  ''     $dNone.Crop
# Un punto ve el fotograma ENTERO: eso manda (la union no recorta nada).
Assert-Eq 'Auto: un punto a pantalla completa manda' 'none' (& $decAuto @('1920:800:0:140', '1920:1080:0:0') 1920 1080).Decision
Assert-Eq 'Auto: unanime'          'crop' (& $decAuto @('1920:800:0:140', '1920:800:0:140') 1920 1080).Decision
Assert-Eq 'Auto: sin candidatos'   'none' (& $decAuto @() 1920 1080).Decision
# Un recorte desproporcionado no se aplica solo: se propone y se confirma.
$dBig = & $decAuto @('1200:500:360:290') 1920 1080
Assert-Eq 'Auto: recorte enorme -> a mano' 'manual' $dBig.Decision
Assert-True 'Auto: dice cuanto quitaria'   ($dBig.Reason -match '% de alto')
Assert-Eq 'Auto: con tope alto, se aplica' 'crop' (& $decAuto @('1200:500:360:290') 1920 1080 90).Decision

# ================================================================================================
Write-Host "`nIo - ficheros (JSON atomico, UTF-8 sin BOM) y helpers genericos" -ForegroundColor Cyan
# Un solo sitio para escribir y leer: lo usan el job, el estado de los workers, config.json y el
# tamano recordado de las ventanas.
$ioDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_io_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $ioDir -Force | Out-Null
try {
    $ioJson = Join-Path $ioDir 'x.json'
    Assert-True 'Io: guarda json'      (Save-CvJsonFile -Path $ioJson -Object ([pscustomobject]@{ a = 1; b = 'dos' }))
    Assert-Eq   'Io: releido'          'dos' "$((Read-CvJsonFile -Path $ioJson).b)"
    Assert-True 'Io: sin .tmp de sobra' (-not (Test-Path -LiteralPath "$ioJson.tmp"))
    # UTF-8 SIN BOM: con BOM, ffmpeg y media herramienta se atragantan.
    $ioBytes = [System.IO.File]::ReadAllBytes($ioJson)
    Assert-True 'Io: sin BOM'          (-not ($ioBytes[0] -eq 0xEF -and $ioBytes[1] -eq 0xBB))
    Assert-Eq   'Io: no existe -> null' $null (Read-CvJsonFile -Path (Join-Path $ioDir 'no-hay.json') -Quiet)
    Set-Content -Path (Join-Path $ioDir 'roto.json') -Value '{ esto no es json' -Encoding UTF8
    Assert-Eq   'Io: roto -> null'      $null (Read-CvJsonFile -Path (Join-Path $ioDir 'roto.json') -Quiet)
    Assert-Eq   'Io: escribe texto'     'hola' (Get-Content -Raw -LiteralPath (Save-CvTextFile -Path (Join-Path $ioDir 't.txt') -Text 'hola')).Trim()

    # REGRESION: escribir mientras OTRO proceso tiene el fichero abierto leyendo. Pasaba de verdad
    # -la ventana de la cola relee los estados de los workers cada segundo y el worker se llevaba un
    # 'el proceso no puede obtener acceso al archivo porque esta siendo utilizado en otro proceso'-.
    # Se arregla por los dos lados: el lector comparte (ReadWrite+Delete) y el escritor reintenta.
    $ioOcup = Join-Path $ioDir 'ocupado.json'
    [void](Save-CvJsonFile -Path $ioOcup -Object ([pscustomobject]@{ a = 1 }))
    $fsOcup = [System.IO.File]::Open($ioOcup, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        Assert-True 'Io: se escribe aunque otro lea' (Save-CvJsonFile -Path $ioOcup -Object ([pscustomobject]@{ a = 2 }) -Quiet)
    } finally { $fsOcup.Dispose() }
    Assert-Eq   'Io: y queda el valor nuevo'  2 ([int](Read-CvJsonFile -Path $ioOcup).a)
    # Y al reves: leer NO impide que el duenyo reemplace el fichero (el lector comparte el borrado).
    $fsLee = $null
    try {
        $ioTxt = Join-Path $ioDir 'leyendo.txt'
        [void](Save-CvTextFile -Path $ioTxt -Text 'uno')
        $fsLee = [System.IO.File]::Open($ioTxt, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        Assert-Eq 'Io: lectura compartida' 'uno' (Read-CvTextFileShared -Path $ioTxt).Trim()
    } finally { if ($null -ne $fsLee) { $fsLee.Dispose() } }
    # Con un lector que NO comparte (antivirus, Get-Content de otro), se reintenta y si no se puede
    # se dice que no (sin lanzar) y sin dejar el .tmp tirado.
    $ioDuro = Join-Path $ioDir 'bloqueado.json'
    [void](Save-CvJsonFile -Path $ioDuro -Object ([pscustomobject]@{ a = 1 }))
    $fsDuro = [System.IO.File]::Open($ioDuro, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        Assert-Eq   'Io: bloqueado de verdad -> false' $false (Save-CvJsonFile -Path $ioDuro -Object ([pscustomobject]@{ a = 3 }) -Quiet)
    } finally { $fsDuro.Dispose() }
    Assert-True 'Io: no deja el .tmp tirado' (-not (Test-Path -LiteralPath "$ioDuro.tmp"))
} finally {
    Remove-Item -Recurse -Force -LiteralPath $ioDir -ErrorAction SilentlyContinue
}

# ¿Sigue vivo ese proceso? (bloqueos y estado de workers preguntan lo mismo)
Assert-True 'Proceso: yo estoy vivo'   (Test-CvProcessAlive -ProcessId $PID)
Assert-Eq   'Proceso: pid 0'    $false (Test-CvProcessAlive -ProcessId 0)
Assert-Eq   'Proceso: pid absurdo' $false (Test-CvProcessAlive -ProcessId 999999)

# Reloj H:MM:SS (duracion de un archivo y ETA larga) y MB para comparar tamanos.
Assert-Eq   'Reloj: 50 min'     '0:50:10' (Format-CvClock -Seconds 3010)
Assert-Eq   'Reloj: 1 hora'     '1:00:00' (Format-CvClock -Seconds 3600)
Assert-Eq   'Reloj: trunca'     '0:00:59' (Format-CvClock -Seconds 59.9)
Assert-Eq   'Reloj: negativo'   '0:00:00' (Format-CvClock -Seconds -5)
Assert-Eq   'MB: cero'          '0'       (Format-CvMb -Bytes 0)
Assert-True 'MB: un mega'       ((Format-CvMb -Bytes 1MB) -match '^1([.,]0)?$')
Assert-True 'MB: decimal'       ((Format-CvMb -Bytes (1536 * 1024)) -match '^1[.,]5$')

# ================================================================================================
Write-Host "`nJobCore - forma del job y validacion" -ForegroundColor Cyan
# ConvertTo-CvJobRecord es la FUENTE UNICA de la estructura del .job.json: la usan la consola
# (Convert.ps1) y el editor en ventana. Si cambia aqui, cambia en los dos sitios a la vez.
$jctxFake = [pscustomobject]@{ FFmpegVersion = '7.1.1'; AacGainVersion = '1.9' }
$rec = ConvertTo-CvJobRecord -Context $jctxFake -File 'D:\x\peli.mkv' -Prof ([pscustomobject]@{ VideoEncoder = 'libx265' }) `
    -VideoIndex 0 -Crop '1920:800:0:140' -Resize '1280:-2' -Anim $true `
    -AudioTracks @([pscustomobject]@{ Index = 1; Is51 = $true; Sync = 1.5; Lang = 'spa'; Default = $true }) `
    -Subtitles @([pscustomobject]@{ Index = 4 })
Assert-Eq   'Job: claves de primer nivel' 'file|profile|ffmpegVersion|aacgainVersion|video|audio|subtitles|subtitleCues' (@($rec.Keys) -join '|')
Assert-True 'Job: video trae sus 6 campos' ((@('skip','index','crop','resize','anim','hdr') | Where-Object { -not $rec.video.ContainsKey($_) }).Count -eq 0)
Assert-Eq   'Job: ffmpeg del contexto'  '7.1.1' $rec.ffmpegVersion
Assert-Eq   'Job: aacgain del contexto' '1.9'   $rec.aacgainVersion
Assert-Eq   'Job: archivo de origen' 'D:\x\peli.mkv' $rec.file
Assert-Eq   'Job: recorte'   '1920:800:0:140' $rec.video.crop
Assert-Eq   'Job: escalado'  '1280:-2'        $rec.video.resize
Assert-Eq   'Job: animacion' $true            $rec.video.anim
Assert-Eq   'Job: sin Info no marca HDR' $false $rec.video.hdr
# ================================================================================================
# Editar VARIOS jobs a la vez: se cambia solo lo marcado y lo demas se queda como esta en cada uno.
Write-Host "`nJobCore - editar jobs en bloque" -ForegroundColor Cyan
$bfCampos = @(Get-CvJobBulkFields)
Assert-Eq   'Bloque: siete ajustes' 7 $bfCampos.Count
Assert-Eq   'Bloque: claves unicas' $bfCampos.Count (@($bfCampos | ForEach-Object { $_.Key } | Sort-Object -Unique)).Count
Assert-Eq   'Bloque: el perfil es lo primero' 'prof' "$($bfCampos[0].Key)"

# Un borrador con cosas MUY de ese archivo: pista de audio 3, retardo, subtitulos y recorte.
$bdOrig = [pscustomobject]@{
    Name       = 'Serie_1x01'
    File       = 'X:\Original\Serie_1x01.mkv'
    Prof       = (New-CvProfile -VideoEncoder 'libx265' -Crf 28 -AudioEncoder 'aac_coder' -AudioBitrate '128k')
    SubCues    = @{ '2' = 750 }
    VideoSkip  = $false
    VideoIndex = 0
    Crop       = '1920:800:0:140'
    Resize     = '1280:-2'
    Anim       = $false
    Hdr        = $true
    Audio      = @([pscustomobject]@{ Index = 3; Is51 = $true; Sync = 0.4; Lang = 'spa'; Default = $true })
    Subtitles  = @(@{ index = 2; forced = $true })
}
$bdCopia = Set-CvJobBulkChanges -Draft $bdOrig -Changes @{ videoCopy = $true }
Assert-Eq   'Bloque: cambia lo marcado'        $true  ([bool]$bdCopia.VideoSkip)
Assert-Eq   'Bloque: no toca la pista elegida' 3      ([int]@($bdCopia.Audio)[0].Index)
Assert-Eq   'Bloque: no toca el retardo'       0.4    ([double]@($bdCopia.Audio)[0].Sync)
Assert-Eq   'Bloque: no toca los subtitulos'   1      (@($bdCopia.Subtitles).Count)
Assert-Eq   'Bloque: no toca el recorte'       '1920:800:0:140' "$($bdCopia.Crop)"
Assert-Eq   'Bloque: no toca el escalado'      '1280:-2' "$($bdCopia.Resize)"
Assert-Eq   'Bloque: no toca el audio'         $false ([bool]$bdCopia.AudioSkip)
Assert-Eq   'Bloque: no toca el HDR'           $true  ([bool]$bdCopia.Hdr)
Assert-Eq   'Bloque: el original no se toca'   $false ([bool]$bdOrig.VideoSkip)
# Quitar el recorte de todos = marcarlo vacio.
Assert-Eq   'Bloque: quitar el recorte' '' "$((Set-CvJobBulkChanges -Draft $bdOrig -Changes @{ crop = '' }).Crop)"
# El perfil arrastra si se recodifica (como al preparar), y lo marcado a mano manda sobre el.
$bdProf = Set-CvJobBulkChanges -Draft $bdOrig -Changes @{ prof = (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy') }
Assert-Eq   'Bloque: perfil copy -> copia video' $true ([bool]$bdProf.VideoSkip)
Assert-Eq   'Bloque: perfil copy -> copia audio' $true ([bool]$bdProf.AudioSkip)
$bdMix = Set-CvJobBulkChanges -Draft $bdOrig -Changes ([ordered]@{ prof = (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy'); audioCopy = $false })
Assert-Eq   'Bloque: lo marcado manda sobre el perfil' $false ([bool]$bdMix.AudioSkip)

# Lo que se puede aplicar y lo que no.
Assert-Eq   'Bloque: sin marcar nada no hay nada que hacer' $false ([bool](Test-CvJobBulkChanges -Changes @{}).Ok)
Assert-Eq   'Bloque: recorte mal escrito'  $false ([bool](Test-CvJobBulkChanges -Changes @{ crop = '1920x800' }).Ok)
Assert-True 'Bloque: recorte bien escrito' ([bool](Test-CvJobBulkChanges -Changes @{ crop = '1920:800:0:140' }).Ok)
Assert-True 'Bloque: recorte vacio vale (quitarlo)' ([bool](Test-CvJobBulkChanges -Changes @{ crop = '' }).Ok)
Assert-Eq   'Bloque: escalado mal escrito' $false ([bool](Test-CvJobBulkChanges -Changes @{ resize = '1280' }).Ok)
Assert-True 'Bloque: escalado con alto automatico' ([bool](Test-CvJobBulkChanges -Changes @{ resize = '1280:-2' }).Ok)
Assert-Eq   'Bloque: perfil sin elegir'    $false ([bool](Test-CvJobBulkChanges -Changes @{ prof = $null }).Ok)
# Y lo que se va a hacer, en una linea.
Assert-Eq   'Bloque: cuenta lo que cambia' (Get-CvText -Key 'bulk.sum.video' -Values @((Get-CvText -Key 'bulk.sum.copiar'))) (Get-CvJobBulkSummary -Changes @{ videoCopy = $true })
Assert-True 'Bloque: y lo que se quita'    ((Get-CvJobBulkSummary -Changes @{ crop = '' }) -match 'sin recorte')
Assert-Eq   'Bloque: sin nada, nada que contar' '' (Get-CvJobBulkSummary -Changes @{})

# El HDR ya congelado NO se pierde al reescribir un job sin volver a analizar el archivo.
$recHdr = ConvertTo-CvJobRecord -Context $jctxFake -File 'X:\Original\Serie_1x01.mkv' -Prof (New-CvProfile -VideoEncoder 'libx265') -Hdr $true
Assert-Eq   'Job: sin Info, el HDR sabido se conserva' $true ([bool]$recHdr.video.hdr)

Assert-Eq   'Job: una pista de audio' 1 @($rec.audio.tracks).Count
Assert-Eq   'Job: idioma de la pista' 'spa' $rec.audio.tracks[0].lang
Assert-Eq   'Job: sync numerico'      1.5   $rec.audio.tracks[0].sync
Assert-True 'Job: sync es double'     ($rec.audio.tracks[0].sync -is [double])
Assert-Eq   'Job: pista predeterminada' $true $rec.audio.tracks[0].default
Assert-Eq   'Job: subtitulos'         1 @($rec.subtitles).Count
# Lineas de TODAS las pistas de subtitulo (no solo de las elegidas): asi el resumen puede
# ensenarlas sin volver a demultiplexar el fichero. Sin pasarlas, la clave queda vacia.
Assert-True 'Job: mapa de lineas vacio por defecto' ($null -ne $rec.subtitleCues -and @($rec.subtitleCues.Keys).Count -eq 0)
$recCue = ConvertTo-CvJobRecord -Context $jctxFake -File 'x.mkv' -Prof ([pscustomobject]@{}) -SubtitleCues @{ '4' = 0; '5' = 1082 }
Assert-Eq   'Job: guarda las lineas de la 5' 1082 $recCue.subtitleCues['5']
Assert-Eq   'Job: y las de la vacia'         0    $recCue.subtitleCues['4']
# Sin pistas de audio la clave sigue existiendo (lista vacia), no desaparece.
$recVacio = ConvertTo-CvJobRecord -Context $jctxFake -File 'x.mkv' -Prof ([pscustomobject]@{}) -AudioSkip $true
Assert-Eq   'Job: audio.skip en copy'    $true $recVacio.audio.skip
Assert-Eq   'Job: tracks vacio es lista' 0     @($recVacio.audio.tracks).Count

# Validacion del borrador (lo que impide guardar).
$okDraft = [pscustomobject]@{
    File = 'x.mkv'; VideoSkip = $false; VideoIndex = 0; Crop = ''; AudioSkip = $false
    Audio = @([pscustomobject]@{ Index = 1; Lang = 'spa'; Sync = 0; Default = $true })
}
$v1 = Test-CvJobDraft -Draft $okDraft
Assert-True 'Borrador correcto'        $v1.Ok
Assert-Eq   'Borrador sin avisos'  0   @($v1.Warnings).Count
$badCrop = $okDraft.PSObject.Copy(); $badCrop.Crop = '1920x800'
Assert-Eq   'Borrador: recorte mal escrito' $false (Test-CvJobDraft -Draft $badCrop).Ok
$noDef = $okDraft.PSObject.Copy()
$noDef.Audio = @([pscustomobject]@{ Index = 1; Lang = 'spa'; Sync = 0; Default = $false })
Assert-Eq   'Borrador: sin predeterminada' $false (Test-CvJobDraft -Draft $noDef).Ok
$twoDef = $okDraft.PSObject.Copy()
$twoDef.Audio = @(
    [pscustomobject]@{ Index = 1; Lang = 'spa'; Sync = 0; Default = $true }
    [pscustomobject]@{ Index = 2; Lang = 'eng'; Sync = 0; Default = $true }
)
Assert-Eq   'Borrador: dos predeterminadas' $false (Test-CvJobDraft -Draft $twoDef).Ok
$noVid = $okDraft.PSObject.Copy(); $noVid.VideoIndex = -1
Assert-Eq   'Borrador: sin pista de video'  $false (Test-CvJobDraft -Draft $noVid).Ok
$copyVid = $okDraft.PSObject.Copy(); $copyVid.VideoIndex = -1; $copyVid.VideoSkip = $true
Assert-True 'Borrador: en copy no hace falta indice' (Test-CvJobDraft -Draft $copyVid).Ok
$badLang = $okDraft.PSObject.Copy()
$badLang.Audio = @([pscustomobject]@{ Index = 1; Lang = 'castellano'; Sync = 0; Default = $true })
$v2 = Test-CvJobDraft -Draft $badLang
Assert-True 'Borrador: idioma raro solo avisa' ($v2.Ok -and @($v2.Warnings).Count -eq 1)
Assert-Eq   'Borrador vacio no es valido' $false (Test-CvJobDraft -Draft $null).Ok

# ================================================================================================
# I18N: el texto, fuera del codigo. Lo que se prueba aqui es lo que de verdad rompe una traduccion:
# que idioma sale elegido, que pasa con una clave que falta, y que los huecos ({0}, {1}) cuadren.
Write-Host "`nI18n - idioma de la interfaz y textos" -ForegroundColor Cyan

# --- Que idioma toca (puro; sin tocar disco) ---
$disp = @('es', 'en')
Assert-Eq 'Idioma: auto con Windows en ingles'      'en' (Resolve-CvLanguage -Lang 'auto' -SystemLang 'en'    -Available $disp)
Assert-Eq 'Idioma: auto con Windows en castellano'  'es' (Resolve-CvLanguage -Lang 'auto' -SystemLang 'es-ES' -Available $disp)
# Un Windows en aleman NO obliga a traducir el aleman: se cae al castellano y se sigue trabajando.
Assert-Eq 'Idioma: auto sin traduccion cae al base' 'es' (Resolve-CvLanguage -Lang 'auto' -SystemLang 'de'    -Available $disp)
Assert-Eq 'Idioma: se pide uno concreto'            'en' (Resolve-CvLanguage -Lang 'en'   -SystemLang 'es'    -Available $disp)
Assert-Eq 'Idioma: es-ES vale como es'              'es' (Resolve-CvLanguage -Lang 'es-ES' -SystemLang 'en'   -Available $disp)
# Un config con un idioma que no existe no puede dejar la interfaz en blanco.
Assert-Eq 'Idioma: uno que no hay cae al base'      'es' (Resolve-CvLanguage -Lang 'fr'   -SystemLang 'en'    -Available $disp)
Assert-Eq 'Idioma: sin nada, el base'               'es' (Resolve-CvLanguage -Lang ''     -SystemLang ''      -Available $disp)

# --- Huecos de una frase ---
Assert-Eq 'Huecos: los cuenta ordenados y sin repetir' '0,1' ((Get-CvTextPlaceholders -Text 'de {1} a {0}, {0} otra vez') -join ',')
Assert-Eq 'Huecos: una frase sin datos no tiene'       ''    ((Get-CvTextPlaceholders -Text 'Iniciar') -join ',')

# --- Textos de verdad, sobre una carpeta de idiomas de mentira ---
$ldir = Join-Path ([IO.Path]::GetTempPath()) ("cvlang-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $ldir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ldir 'es.json') -Encoding UTF8 -Value @'
{
  "boton.iniciar": "Iniciar",
  "solo.en.base":  "Solo en castellano",
  "con.dato":      "Quedan {0} archivos"
}
'@
Set-Content -LiteralPath (Join-Path $ldir 'en.json') -Encoding UTF8 -Value @'
{
  "boton.iniciar": "Start",
  "con.dato":      "{0} files left"
}
'@

Assert-Eq 'Textos: se ve que idiomas hay' 'en,es' ((Get-CvLangAvailable -Dir $ldir | Sort-Object) -join ',')
Assert-Eq 'Textos: se fija el pedido'     'en'    (Set-CvLanguage -Lang 'en' -Dir $ldir)
Assert-Eq 'Textos: en el idioma elegido'  'Start' (Get-CvText -Key 'boton.iniciar')
# Lo que no este traducido sale en castellano, no en blanco: se puede traducir a medias y usarlo.
Assert-Eq 'Textos: lo que falta cae al castellano' 'Solo en castellano' (Get-CvText -Key 'solo.en.base')
# Y una clave que no existe en ningun sitio se VE (es la propia clave), que es como se detecta.
Assert-Eq 'Textos: una clave que no existe se ve'  'no.existe.esta' (Get-CvText -Key 'no.existe.esta')
Assert-Eq 'Textos: el dato va dentro de la frase'  '3 files left'   (Get-CvText -Key 'con.dato' -Values @(3))
Assert-Eq 'Textos: en castellano, otra frase'      'es'             (Set-CvLanguage -Lang 'es' -Dir $ldir)
Assert-Eq 'Textos: y el dato en su sitio'          'Quedan 3 archivos' (Get-CvText -Key 'con.dato' -Values @(3))

# --- Comparar una traduccion con el base ---
$cmp = Test-CvLangResources -Base (Get-CvLangResources -Lang 'es' -Dir $ldir) -Other (Get-CvLangResources -Lang 'en' -Dir $ldir)
Assert-Eq 'Comparar: dice lo que falta'  'solo.en.base' (@($cmp.Faltan) -join ',')
Assert-Eq 'Comparar: nada sobra'         ''             (@($cmp.Sobran) -join ',')
Assert-Eq 'Comparar: los huecos cuadran' ''             (@($cmp.Huecos) -join ',')

# Una traduccion con un hueco de mas es lo que revienta al formatear, y por eso se caza aqui.
$cmpMal = Test-CvLangResources -Base @{ 'x' = 'Van {0}' } -Other @{ 'x' = 'Van {0} de {1}' }
Assert-Eq 'Comparar: caza un hueco de mas' 'x' (@($cmpMal.Huecos) -join ',')
Assert-Eq 'Comparar: y lo que sobra'       'y' (@((Test-CvLangResources -Base @{} -Other @{ 'y' = 'z' }).Sobran) -join ',')
Remove-Item -LiteralPath $ldir -Recurse -Force -ErrorAction SilentlyContinue

# --- Los ficheros DE VERDAD del programa: ninguna clave suelta y los huecos cuadrando ---
# TODOS los idiomas contra el castellano, no solo el ingles: asi el dia que se anada un .json
# nuevo entra solo en la comprobacion, sin tocar la bateria.
$faltanReal = @()
$sobranReal = @()
$huecosReal = @()
$baseReal = Get-CvLangResources -Lang 'es'
foreach ($cod in (Get-CvLangAvailable)) {
    if ($cod -eq 'es') { continue }
    $r = Test-CvLangResources -Base $baseReal -Other (Get-CvLangResources -Lang $cod)
    foreach ($k in @($r.Faltan)) { $faltanReal += ("{0}:{1}" -f $cod, $k) }
    foreach ($k in @($r.Sobran)) { $sobranReal += ("{0}:{1}" -f $cod, $k) }
    foreach ($k in @($r.Huecos)) { $huecosReal += ("{0}:{1}" -f $cod, $k) }
}
Assert-Eq 'lang\: ninguna traduccion se deja claves' '' ($faltanReal -join ', ')
Assert-Eq 'lang\: ni arrastra claves muertas'        '' ($sobranReal -join ', ')
Assert-Eq 'lang\: los huecos cuadran en todas'       '' ($huecosReal -join ', ')
# TODA clave usada en el codigo tiene que existir en castellano. Es la red que hace barata cada
# fase: una clave mal escrita no da error -Get-CvText devuelve la propia clave-, asi que sin esto
# se descubriria mirando la ventana una por una.
$raizRepo = Split-Path -Parent $PSScriptRoot
$usadas = @{}
# OJO: -Path y no -LiteralPath. Con -LiteralPath, el -Include NO filtra (devuelve TODO), y aqui
# eso significaba intentar leer un video entero de Original\ con -Raw: OutOfMemoryException.
foreach ($f in (Get-ChildItem -Path $raizRepo -Recurse -Include *.ps1,*.psm1 -File |
                Where-Object { $_.FullName -notmatch '\\tools\\' -and $_.FullName -notmatch '\\test\\' })) {
    foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), "Get-CvText\s+-Key\s+'([^']+)'")) {
        $usadas[$m.Groups[1].Value] = $f.Name
    }
}
$baseKeys = Get-CvLangResources -Lang 'es'
$huerfanas = @()
foreach ($k in ($usadas.Keys | Sort-Object)) {
    if (-not $baseKeys.ContainsKey($k)) { $huerfanas += ("{0} ({1})" -f $k, $usadas[$k]) }
}
Assert-True 'Textos: el codigo ya pide claves'   ($usadas.Count -gt 0)
Assert-Eq   'Textos: ninguna clave sin traducir' '' ($huerfanas -join ', ')

# NINGUNA ventana puede llevar su texto escrito dentro. Se barren liborm\ y Gui.psm1 buscando
# literales en lo que se ENSENA (.Text, .ToolTipText, -Title, -Message, -Tooltip, -EmptyText) que no
# pasen por Get-CvText. Sin esto, la siguiente ventana que alguien toque vuelve a traer su texto
# pegado y no se nota hasta que se mira en otro idioma.
$uiFiles = @((Join-Path $raizRepo 'lib\Gui.psm1'))
$uiFiles += @(Get-ChildItem -Path (Join-Path $raizRepo 'lib\form') -Filter *.psm1 -File | ForEach-Object { $_.FullName })
$pegados = @()
foreach ($f in $uiFiles) {
    $dentro = $false
    $n = 0
    foreach ($l in (Get-Content -LiteralPath $f)) {
        $n++
        $t = $l.Trim()
        if ($t -match '<#') { $dentro = $true }
        if ($t -match '#>') { $dentro = $false; continue }
        if ($dentro -or $t.StartsWith('#') -or $l -match 'Get-CvText') { continue }
        if ($l -match "(\.Text\s*=|\.ToolTipText\s*=|-Title |-Message |-Tooltip |-EmptyText )\s*'([^']*[A-Za-z][^']*)'") {
            $pegados += ("{0}:{1} {2}" -f (Split-Path -Leaf $f), $n, $Matches[2])
        }
    }
}
Assert-True 'Textos: se han barrido las ventanas' ($uiFiles.Count -ge 15)
Assert-Eq   'Textos: ninguna ventana lleva el texto pegado' '' (($pegados | Select-Object -First 5) -join ' | ')

# Y el idioma de la sesion se deja como estaba para el resto de la bateria.
[void](Set-CvLanguage -Lang 'es')

Assert-Eq   'Config: el idioma de partida es auto' 'auto' "$((Get-CvConfigDefaults).ui.language)"
# El catalogo de idiomas NO esta escrito a mano: sale de los ficheros de lang\, y el nombre de
# cada uno lo da SU PROPIO fichero. Asi anadir un idioma es soltar un .json; si el nombre lo diera
# otro, cada idioma nuevo obligaria a tocar todos los demas para traducir como se llama.
$cat = Get-CvUiLanguages
$disp = Get-CvLangAvailable
Assert-Eq   'Idiomas: auto va el primero' 'auto' "$(@($cat)[0].Value)"
# Y detras, exactamente los ficheros que haya: anadir un idioma no obliga a tocar esta bateria.
Assert-Eq   'Idiomas: detras, los que hay en lang' (($disp | Sort-Object) -join ',') ((@($cat) | Select-Object -Skip 1 | ForEach-Object { "$($_.Value)" }) -join ',')
Assert-Eq   'Idiomas: el ingles se llama a si mismo en ingles' 'English' "$(@($cat | Where-Object { $_.Value -eq 'en' })[0].Text)"
Assert-Eq   'Idiomas: y el castellano, en castellano'  'castellano' "$(@($cat | Where-Object { $_.Value -eq 'es' })[0].Text)"
# Todo fichero de idioma tiene que decir como se llama, o no habria como ofrecerlo en la lista.
# (Get-CvLangAvailable devuelve ,$array: por tuberia llegaria el array entero como UN elemento.)
$sinNombre = @()
foreach ($cod in (Get-CvLangAvailable)) {
    if ("$((Get-CvLangResources -Lang $cod)['lang.name'])" -eq '') { $sinNombre += $cod }
}
Assert-Eq   'Idiomas: todos dicen su nombre' '' ($sinNombre -join ', ')


# ================================================================================================
$total = $script:pass + $script:fail
Write-Host ("`n{0}" -f ('=' * 48))
if ($script:fail -eq 0) {
    Write-Host ("OK  {0}/{1} tests unitarios pasados." -f $script:pass, $total) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FALLO  {0}/{1} pasados, {2} fallidos." -f $script:pass, $total, $script:fail) -ForegroundColor Red
    exit 1
}
