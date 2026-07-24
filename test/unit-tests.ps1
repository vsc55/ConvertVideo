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
    'Config'
    'Context'
    'Console'
    'Exec'
    'Job'
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
Assert-Eq 'console/windowWidth = 150'    150  (Get-CvConfigDefaultValue 'console/windowWidth')
Assert-Eq 'console/asciiMarks def false' $false (Get-CvConfigDefaultValue 'console/asciiMarks')
Assert-Eq 'behavior/asciiMarks ya no existe' $null (Get-CvConfigDefaultValue 'behavior/asciiMarks')
Assert-True 'help console/asciiMarks'    ((Get-CvConfigHelp).Contains('console/asciiMarks'))
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
Assert-True 'help encode/audio/syncThreshold' ((Get-CvConfigHelp).Contains('encode/audio/syncThreshold'))
# customProfile: paridad de campos con un profiles[] (nuevos defaults + 'auto' en videoEncoder).
Assert-Eq 'customProfile/detectBorder def' $false      (Get-CvConfigDefaultValue 'customProfile/detectBorder')
Assert-Eq 'customProfile/changeSize def'   ''           (Get-CvConfigDefaultValue 'customProfile/changeSize')
Assert-Eq 'customProfile/maxWidth def 0'   0            (Get-CvConfigDefaultValue 'customProfile/maxWidth')
Assert-Eq 'customProfile/audioEncoder def' 'aac_coder'  (Get-CvConfigDefaultValue 'customProfile/audioEncoder')
Assert-Eq 'customProfile/audioHz def'      44100        (Get-CvConfigDefaultValue 'customProfile/audioHz')
Assert-Eq 'customProfile/audioChannels def' 2           (Get-CvConfigDefaultValue 'customProfile/audioChannels')
Assert-Eq 'customProfile/downmixMode def'  'default'    (Get-CvConfigDefaultValue 'customProfile/downmixMode')
Assert-Eq 'customProfile/downmixCoeffs/center def' 0.5  (Get-CvConfigDefaultValue 'customProfile/downmixCoeffs/center')
Assert-True 'help customProfile/detectBorder' ((Get-CvConfigHelp).Contains('customProfile/detectBorder'))
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

# ================================================================================================
Write-Host "`nMetodos de volumen y coeficientes (Config)" -ForegroundColor Cyan
Assert-Eq 'volume methods'  @('peak','loudnorm','aacgain') (Get-CvVolumeMethods)
Assert-Eq   'tonemapCurve 1a = bt.2390' 'bt.2390' (@(Get-CvTonemapCurves)[0])
Assert-True 'tonemapCurve incluye mobius' (@(Get-CvTonemapCurves) -contains 'mobius')
Assert-Eq 'fallback = 1o (peak)' 'peak' (Get-CvVolumeMethods)[0]
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
Assert-Eq   'locks = *.lock'  @('*.lock') (Get-CvProcesoPatterns -What locks)
Assert-True 'temps incluye *.mkv'      ((Get-CvProcesoPatterns -What temps) -contains '*.mkv')
Assert-True 'temps incluye *.m4a'      ((Get-CvProcesoPatterns -What temps) -contains '*.m4a')
$all = Get-CvProcesoPatterns -What all
Assert-True 'all incluye lock'         ($all -contains '*.lock')
Assert-True 'all incluye job'          ($all -contains '*.job.json')
Assert-Eq   'all sin duplicados'       $all.Count ($all | Select-Object -Unique).Count

# ================================================================================================
Write-Host "`nFuentes unicas (Context / Profile)" -ForegroundColor Cyan
Assert-Eq 'Get-CvAppName' 'ConvertVideo' (Get-CvAppName)
Assert-Eq 'Get-CvVersion' '4.5.1'        (Get-CvVersion)
Assert-Eq 'perfiles de serie = 13' 13 ((Get-CvProfiles | ForEach-Object { $_.Profiles } | Measure-Object).Count)

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
Assert-Eq 'Label NVENC' 'A: 192K, V: h265[NV]/M10/L5/Q(1-23)' (Format-CvProfileLabel $np)
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
$vg = Resolve-CvVolumeMethod -Method 'aacgain' -Codec 'eac3'
Assert-Eq 'vol aacgain/eac3 -> peak' 'peak' $vg.Method
Assert-Eq 'vol aacgain downgraded'   $true  $vg.AacgainDowngraded
Assert-Eq 'vol LOUDNORM lower' 'loudnorm' (Resolve-CvVolumeMethod -Method 'LOUDNORM' -Codec 'aac').Method
Assert-True 'vol invalido -> valido' ((Resolve-CvVolumeMethod -Method 'xxx' -Codec 'aac').Method -in (Get-CvVolumeMethods))
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
$total = $script:pass + $script:fail
Write-Host ("`n{0}" -f ('=' * 48))
if ($script:fail -eq 0) {
    Write-Host ("OK  {0}/{1} tests unitarios pasados." -f $script:pass, $total) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FALLO  {0}/{1} pasados, {2} fallidos." -f $script:pass, $total, $script:fail) -ForegroundColor Red
    exit 1
}
