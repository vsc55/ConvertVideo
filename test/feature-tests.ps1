<#
    feature-tests.ps1 - Bateria E2E de FEATURES del pipeline (complementa a run-tests.ps1).

    Mientras run-tests.ps1 prueba la seleccion de pistas/decodificacion sobre las fixtures, esta
    bateria ejercita las RUTAS DE FEATURE que aquella no cubre, llamando directamente a las etapas
    (Invoke-VideoRun / Invoke-AudioRun / Invoke-Multiplex) con perfiles/contexto a medida sobre
    entradas SINTETICAS efimeras (lavfi, no se commitea nada) y verificando la salida con ffprobe:

      VIDEO   : tone-mapping HDR->SDR [GPU], resize, tune animation, multipass [GPU], forceFps=false, copy
      AUDIO   : loudnorm, aacgain, codecs no-AAC (ac3/eac3/flac/opus/mp3), downmix estandar y dialogue,
                sincronia (adelay + WAV clasico), no-upmix, copy
      MULTIPLEX: multipista (default primero), capitulos conservados, adjuntos conservados
      MODO    : pruebas (-t / TestLimit)

    Los casos que dependen de GPU (NVENC / libplacebo) se SALTAN (SKIP, no FAIL) si Test-CvNvenc falla,
    para que la bateria sirva tambien en equipos sin GPU.

    Uso:  powershell -ExecutionPolicy Bypass -File test\feature-tests.ps1
    Sale con 0 si todo pasa (los SKIP no cuentan como fallo), 1 si algo falla.
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
    'Gui'
    'Exec'
    'Job'
    'Tools'
    'MediaInfo'
    'Profile'
    'Video'
    'Audio'
    'Subtitle'
    'Attachment'
    'ConfigEditor'
    'Multiplex'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# --- Root aislado (config headless + junctions a lib/tools), igual que run-tests ---
$stamp = [System.IO.Path]::GetRandomFileName().Replace('.', '')
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cv-feat-{0}" -f $stamp)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
New-Item -ItemType Junction  -Path (Join-Path $tempRoot 'lib')   -Target (Join-Path $Root 'lib')   | Out-Null
New-Item -ItemType Junction  -Path (Join-Path $tempRoot 'tools') -Target (Join-Path $Root 'tools') | Out-Null

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Assert-Eq   { param($Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") { $script:pass++; Write-Host ("  [OK]    {0}" -f $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FALLO] {0}  (esperado <{1}>, obtenido <{2}>)" -f $Name, $Expected, $Actual) -ForegroundColor Red } }
function Assert-True { param($Name, $Cond) Assert-Eq $Name $true ([bool]$Cond) }
function Skip-Case   { param($Name, $Why) $script:skip++; Write-Host ("  [SKIP]  {0}  ({1})" -f $Name, $Why) -ForegroundColor DarkGray }

try {
    $cfg = Get-CvConfig -Root $Root
    $cfg['behavior']['separateWindow'] = $false
    $cfg['behavior']['progress']       = $false
    $cfg['behavior']['log']            = $false
    Save-CvConfigFile -Path (Join-Path $tempRoot 'config.json') -Config $cfg
    $ctx = New-CvContext -Root $tempRoot
    New-Item -ItemType Directory -Force -Path $ctx.Original, $ctx.Proceso, $ctx.Convertido | Out-Null
    $FF = $ctx.FFmpeg; $FP = $ctx.FFprobe

    # GPU disponible? (NVENC; proxy tambien para el tonemap con libplacebo)
    $gpu = $false
    try { $gpu = [bool](Test-CvNvenc -Context $ctx -Version $ctx.FFmpegVersion).Ok } catch { $gpu = $false }
    Write-Host ("`nGPU (NVENC) disponible: {0}" -f $gpu) -ForegroundColor Cyan

    # --- Generadores de entradas sinteticas (efimeras, en Original\ del root aislado) ---
    function Invoke-FF {
        param([string[]]$A)
        $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $script:ffLog = (& $FF -hide_banner -y @A 2>&1)
        $c = $LASTEXITCODE; $ErrorActionPreference = $o
        return $c
    }
    function New-In {
        # Entrada video+audio sintetica; -Layout = channel_layout del audio; -Extra = flags extra de salida.
        param([string]$Name, [string]$Size = '320x240', [int]$Rate = 30, [double]$Dur = 2, [string]$Layout = 'stereo', [string[]]$Extra = @(), [string]$VCodec = 'libx264')
        $out = Join-Path $ctx.Original $Name
        # OJO: ${Size}/${Layout} con llaves; "$Size:rate" tomaria "Size:" como cualificador de scope
        # de PowerShell y se comeria el valor (bug -> "size==30").
        $a = @('-f','lavfi','-t',"$Dur",'-i',"testsrc2=size=${Size}:rate=$Rate",
               '-f','lavfi','-t',"$Dur",'-i',"anullsrc=channel_layout=${Layout}:sample_rate=48000",
               '-map','0:v','-map','1:a','-c:v',$VCodec,'-pix_fmt','yuv420p','-c:a','aac') + $Extra + @("$out")
        $c = Invoke-FF $a
        if ($c -ne 0 -or -not (Test-Path -LiteralPath $out)) {
            Write-Host ("    ffmpeg exit=$c; ultimas lineas:") -ForegroundColor Yellow
            @($script:ffLog) | Select-Object -Last 5 | ForEach-Object { Write-Host ("      $_") }
            throw "No se pudo generar la entrada $Name"
        }
        return "$out"
    }
    function Get-Info { param([string]$File) Get-MediaInfo -Context $ctx -File $File }
    function Get-V    { param($Info) @($Info.streams | Where-Object { $_.codec_type -eq 'video' })[0] }
    function Get-A    { param($Info) @($Info.streams | Where-Object { $_.codec_type -eq 'audio' })[0] }
    function Get-Dur  { param([string]$File) [double](Get-MediaDuration (Get-Info $File)) }
    # Reset de los flags mutables del contexto a un estado base antes de cada caso.
    function Reset-Ctx {
        $ctx.TonemapHdr = 'auto'; $ctx.VolumeMethod = 'peak'; $ctx.SyncAdelay = $false; $ctx.BetaDownmix = $false
        $ctx.DownmixMode = 'default'; $ctx.AudioChannels = 2; $ctx.ForceFps = $true; $ctx.Multipass = 'off'
        $ctx.TestLimit = 0; $ctx.AudioKeepTitle = $false
        $ctx.Attachments = [pscustomobject]@{
            Keep   = $false
            Fonts  = $false
            Covers = $false
            Other  = $false
        }
    }
    # Limpia temporales/salidas entre casos (Proceso y Convertido).
    function Clear-Work { Get-ChildItem -LiteralPath $ctx.Proceso, $ctx.Convertido -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }

    # ============================ VIDEO ============================
    Write-Host "`n== VIDEO ==" -ForegroundColor Cyan

    # tonemap HDR->SDR (GPU/libplacebo)
    Reset-Ctx; Clear-Work
    if ($gpu) {
        # setparams fuerza los parametros de color a nivel de frame (libx264 8-bit descarta -color_trc).
        $f = New-In -Name 'hdr.mkv' -Extra @('-vf','setparams=color_trc=smpte2084:color_primaries=bt2020:colorspace=bt2020nc')
        $prof = New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23
        $hdr = Test-CvHdr -Info (Get-Info $f)
        Assert-True 'HDR detectado en la entrada' $hdr
        $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $hdr -Duration (Get-Dur $f)
        Assert-True 'tonemap: encode OK' $ok
        $tv = Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'hdr').Video)
        Assert-Eq 'tonemap: salida BT.709' 'bt709' "$($tv.color_transfer)"
    } else { Skip-Case 'tonemap HDR->SDR' 'sin GPU' }

    # resize (scale a 1920 desde 4K)
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'uhd.mkv' -Size '1280x720'   # (usamos 1280 como origen; resize a 640 de ancho)
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '640:-2' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'resize: encode OK' $ok
    Assert-Eq 'resize: ancho 640' 640 ([int](Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'uhd').Video)).width)

    # maxWidth anamorfico: origen 640x360 con SAR 2:1 se MUESTRA a 1280 de ancho. maxWidth debe mirar el
    # ancho mostrado (no el almacenado 640) y reescalar conservando el aspecto (DAR). Ver ref-gotchas.
    Reset-Ctx; Clear-Work
    $f   = New-In -Name 'anam.mkv' -Size '640x360' -Extra @('-vf','setsar=2/1')
    $vin = Get-V (Get-Info $f)
    Assert-Eq 'anamorf: SAR entrada 2:1'        '2:1' "$($vin.sample_aspect_ratio)"
    Assert-Eq 'anamorf: ancho mostrado 1280'    1280  (Get-CvDisplayWidth -Width ([int]$vin.width) -Sar "$($vin.sample_aspect_ratio)")
    $rz = Get-CvMaxWidthResize -Width ([int]$vin.width) -Sar "$($vin.sample_aspect_ratio)" -MaxWidth 640
    Assert-Eq 'anamorf: resize 320:-2'          '320:-2' "$rz"
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize $rz -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'anamorf: encode OK' $ok
    $vout = Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'anam').Video)
    $dwOut = Get-CvDisplayWidth -Width ([int]$vout.width) -Sar "$($vout.sample_aspect_ratio)"
    Assert-True ("anamorf keep: ancho mostrado salida <=640 y anamorfico (dw=$dwOut, w=$($vout.width))") ($dwOut -le 640 -and $dwOut -gt [int]$vout.width)

    # anamorfico modo 'square': de-anamorfiza a pixeles cuadrados (SAR 1:1) fijando el ancho de
    # almacenamiento (640). Salida 640x180, SAR 1:1, mismo aspecto mostrado (640:180) sin depender del SAR.
    Reset-Ctx; Clear-Work
    $f   = New-In -Name 'sq.mkv' -Size '640x360' -Extra @('-vf','setsar=2/1')
    $vin = Get-V (Get-Info $f)
    $rz  = Get-CvResize -Width ([int]$vin.width) -Height ([int]$vin.height) -Sar "$($vin.sample_aspect_ratio)" -MaxWidth 0 -Anamorphic 'square'
    Assert-Eq 'square: resize 640:180,setsar=1' '640:180,setsar=1' "$rz"
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize $rz -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'square: encode OK' $ok
    $vs = Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'sq').Video)
    Assert-Eq 'square: salida 640x180' '640x180' ("{0}x{1}" -f [int]$vs.width, [int]$vs.height)
    Assert-Eq 'square: salida SAR 1:1'  '1:1'     "$($vs.sample_aspect_ratio)"

    # tune animation (libx264 + Anim)
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'anim.mkv'
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $true -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'tune animation: encode OK' $ok
    Assert-Eq 'tune animation: salida h264' 'h264' "$((Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'anim').Video)).codec_name)"

    # AV1 por CPU (libsvtav1) - no necesita GPU
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'av1.mkv'
    $prof = New-CvProfile -VideoEncoder 'libsvtav1' -Crf 50
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'libsvtav1: encode OK' $ok
    Assert-Eq 'libsvtav1: salida av1' 'av1' "$((Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'av1').Video)).codec_name)"

    # multipass NVENC (GPU)
    Reset-Ctx; Clear-Work
    if ($gpu) {
        $f = New-In -Name 'mp.mkv'
        $ctx.Multipass = 'qres'
        $prof = New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 23
        $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
        Assert-True 'multipass qres: encode OK' $ok
        Assert-Eq 'multipass qres: salida hevc' 'hevc' "$((Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'mp').Video)).codec_name)"
    } else { Skip-Case 'multipass NVENC' 'sin GPU' }

    # forceFps = false (conserva el fps de origen)
    Reset-Ctx; Clear-Work
    $ctx.ForceFps = $false
    $f = New-In -Name 'fps.mkv' -Rate 30
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'forceFps=false: encode OK' $ok
    $rfr = "$((Get-V (Get-Info (Get-CvTempPaths -Context $ctx -Name 'fps').Video)).r_frame_rate)"
    Assert-Eq 'forceFps=false: fps de origen (30)' '30/1' $rfr

    # deteccion de bordes (cropdetect): contenido 320x160 con barras negras de 32px -> marco 320x224.
    # Dimensiones multiplo de 16 para que el 'round=16' por defecto de cropdetect de un recorte exacto.
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'border.mkv' -Size '320x160' -Extra @('-vf','pad=320:224:0:32:black')
    $crop = Find-CropDetect -Context $ctx -File $f -Start 0 -Duration 1 -Index 0
    Assert-True 'cropdetect: detecta recorte' ($null -ne $crop)
    Assert-Eq   'cropdetect: recorte 320:160:0:32' '320:160:0:32' "$crop"

    # ============================ AUDIO ============================
    Write-Host "`n== AUDIO ==" -ForegroundColor Cyan

    # loudnorm (necesita señal real: se usa un tono, no silencio)
    Reset-Ctx; Clear-Work
    $ctx.VolumeMethod = 'loudnorm'
    $f = Join-Path $ctx.Original 'ln.mkv'
    [void](Invoke-FF @('-f','lavfi','-t','2','-i','testsrc2=size=320x240:rate=30','-f','lavfi','-t','2','-i','sine=frequency=440:sample_rate=48000','-map','0:v','-map','1:a','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-ac','2',"$f"))
    $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
    Assert-True 'loudnorm: temporal creado' ($o -and (Test-Path -LiteralPath $o))
    if ($o) { Assert-Eq 'loudnorm: salida aac' 'aac' "$((Get-A (Get-Info $o)).codec_name)" }

    # aacgain (requiere aacgain.exe)
    Reset-Ctx; Clear-Work
    if (Test-Path -LiteralPath $ctx.AacGain) {
        $ctx.VolumeMethod = 'aacgain'
        $f = New-In -Name 'ag.mkv'
        $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioBitrate '128k'
        $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
        Assert-True 'aacgain: temporal creado' ($o -and (Test-Path -LiteralPath $o))
        if ($o) { Assert-Eq 'aacgain: salida aac' 'aac' "$((Get-A (Get-Info $o)).codec_name)" }
    } else { Skip-Case 'aacgain' 'aacgain.exe no instalado' }

    # codecs de audio no-AAC
    Reset-Ctx
    $codecMap = @{
        ac3        = 'ac3'
        eac3       = 'eac3'
        flac       = 'flac'
        libopus    = 'opus'
        libmp3lame = 'mp3'
    }
    foreach ($c in 'ac3','eac3','flac','libopus','libmp3lame') {
        Reset-Ctx; Clear-Work
        $f = New-In -Name ("cod-$c.mkv")
        $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioCodec $c -AudioBitrate '128k'
        $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
        Assert-True ("codec ${c}: temporal creado") ($o -and (Test-Path -LiteralPath $o))
        if ($o) { Assert-Eq ("codec ${c}: salida {0}" -f $codecMap[$c]) $codecMap[$c] "$((Get-A (Get-Info $o)).codec_name)" }
    }

    # downmix 5.1 -> estereo ESTANDAR (BetaDownmix off) y DIALOGUE (beta on)
    foreach ($beta in $false, $true) {
        Reset-Ctx; Clear-Work
        $ctx.AudioChannels = 2; $ctx.DownmixMode = 'dialogue'; $ctx.BetaDownmix = $beta
        $f = New-In -Name ("dm-$beta.mkv") -Layout '5.1'
        $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioBitrate '128k'
        $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Is51 $true -Duration (Get-Dur $f) -SourceChannels 6 -Pos 0
        $lbl = if ($beta) { 'dialogue (beta)' } else { 'estandar' }
        Assert-True ("downmix ${lbl}: temporal creado") ($o -and (Test-Path -LiteralPath $o))
        if ($o) { Assert-Eq ("downmix ${lbl}: 5.1->2ch") 2 ([int](Get-A (Get-Info $o)).channels) }
    }

    # sincronia: adelay (por defecto) y WAV clasico -> el audio se alarga ~Sync
    foreach ($ade in $false, $true) {
        Reset-Ctx; Clear-Work
        $ctx.SyncAdelay = $ade
        $f = New-In -Name ("sync-$ade.mkv") -Dur 2
        $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioBitrate '128k'
        $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Sync 0.5 -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
        $lbl = if ($ade) { 'adelay' } else { 'WAV clasico' }
        Assert-True ("sync ${lbl}: temporal creado") ($o -and (Test-Path -LiteralPath $o))
        if ($o) { Assert-True ("sync ${lbl}: duracion +~0.5s") ((Get-Dur $o) -ge 2.4) }
    }

    # no-upmix: origen estereo + audioChannels 6 -> se mantiene 2ch
    Reset-Ctx; Clear-Work
    $ctx.AudioChannels = 6
    $f = New-In -Name 'noup.mkv' -Layout 'stereo'
    $prof = New-CvProfile -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    $o = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
    Assert-True 'no-upmix: temporal creado' ($o -and (Test-Path -LiteralPath $o))
    if ($o) { Assert-Eq 'no-upmix: se mantienen 2ch' 2 ([int](Get-A (Get-Info $o)).channels) }

    # ============================ MULTIPLEX ============================
    Write-Host "`n== MULTIPLEX ==" -ForegroundColor Cyan

    # multipista de audio: 2 temporales -> 2 pistas, la default primero
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'mux.mkv'
    $info = Get-Info $f
    $prof = New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    $o0 = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 0
    $o1 = Invoke-AudioRun -Context $ctx -Prof $prof -File $f -Index 1 -Duration (Get-Dur $f) -SourceChannels 2 -Pos 1
    $tracks = @(
        [pscustomobject]@{
            Source  = 'temp'
            File    = "$o0"
            Index   = 1
            Lang    = 'spa'
            Default = $true
        }
        [pscustomobject]@{
            Source  = 'temp'
            File    = "$o1"
            Index   = 1
            Lang    = 'eng'
            Default = $false
        }
    )
    $ok = Invoke-Multiplex -Context $ctx -File $f -Info $info -VideoSkipped $true -AudioSkipped $false -AudioTracks $tracks -Subtitles @() -VideoIndex 0
    Assert-True 'multipista: multiplex OK' $ok
    $mo = Get-Info (Get-OutputPath $ctx 'mux')
    $ma = @($mo.streams | Where-Object { $_.codec_type -eq 'audio' })
    Assert-Eq 'multipista: 2 pistas de audio' 2 $ma.Count
    Assert-Eq 'multipista: 1a = spa'          'spa' "$($ma[0].tags.language)"
    Assert-Eq 'multipista: 1a default'        1 ([int]$ma[0].disposition.default)
    Assert-Eq 'multipista: 2a no default'     0 ([int]$ma[1].disposition.default)

    # copy video + audio (perfil copy) -> mismos codecs de origen
    Reset-Ctx; Clear-Work
    $f = New-In -Name 'cpy.mkv'
    $info = Get-Info $f
    $ok = Invoke-Multiplex -Context $ctx -File $f -Info $info -VideoSkipped $true -AudioSkipped $true -AudioTracks @() -Subtitles @() -VideoIndex 0
    Assert-True 'copy: multiplex OK' $ok
    $mo = Get-Info (Get-OutputPath $ctx 'cpy')
    Assert-Eq 'copy: video h264' 'h264' "$((Get-V $mo).codec_name)"
    Assert-Eq 'copy: audio aac'  'aac'  "$((Get-A $mo).codec_name)"

    # capitulos conservados
    Reset-Ctx; Clear-Work
    $meta = Join-Path $ctx.Original 'chap.txt'
    Set-Content -LiteralPath $meta -Value ";FFMETADATA1`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=1000`ntitle=Uno`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=1000`nEND=2000`ntitle=Dos`n" -Encoding Ascii
    $fc = Join-Path $ctx.Original 'caps.mkv'
    [void](Invoke-FF @('-f','lavfi','-t','2','-i','testsrc2=size=320x240:rate=30','-f','lavfi','-t','2','-i','anullsrc=channel_layout=stereo:sample_rate=48000','-f','ffmetadata','-i',$meta,'-map','0:v','-map','1:a','-map_chapters','2','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',"$fc"))
    $info = Get-Info $fc
    # re-encode video para forzar la rama isEncode (capitulos se toman del original)
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30 -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    [void](Invoke-VideoRun -Context $ctx -Prof $prof -File $fc -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $fc))
    $oa = Invoke-AudioRun -Context $ctx -Prof $prof -File $fc -Index 1 -Duration (Get-Dur $fc) -SourceChannels 2 -Pos 0
    $ok = Invoke-Multiplex -Context $ctx -File $fc -Info $info -VideoSkipped $false -AudioSkipped $false -AudioTracks @([pscustomobject]@{
        Source  = 'temp'
        File    = "$oa"
        Index   = 1
        Lang    = 'spa'
        Default = $true
    }) -Subtitles @() -VideoIndex 0
    Assert-True 'capitulos: multiplex OK' $ok
    Assert-Eq 'capitulos: entrada tiene 2'  2 (Get-CvChapterCount -Context $ctx -File $fc)
    Assert-Eq 'capitulos: 2 conservados'    2 (Get-CvChapterCount -Context $ctx -File (Get-OutputPath $ctx 'caps'))

    # adjuntos conservados (fuente) con postprocess.attachments = fonts
    Reset-Ctx; Clear-Work
    $ctx.Attachments = [pscustomobject]@{
        Keep   = $true
        Fonts  = $true
        Covers = $true
        Other  = $false
    }   # conservar fuentes
    $fontf = Join-Path $ctx.Original 'f.ttf'; Set-Content -LiteralPath $fontf -Value 'dummy-font' -Encoding Ascii
    $fa = Join-Path $ctx.Original 'att.mkv'
    [void](Invoke-FF @('-f','lavfi','-t','2','-i','testsrc2=size=320x240:rate=30','-f','lavfi','-t','2','-i','anullsrc=channel_layout=stereo:sample_rate=48000','-map','0:v','-map','1:a','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-attach',$fontf,'-metadata:s:t:0','mimetype=application/x-truetype-font','-metadata:s:t:0','filename=f.ttf',"$fa"))
    $info = Get-Info $fa
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30 -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    [void](Invoke-VideoRun -Context $ctx -Prof $prof -File $fa -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $fa))
    $oa = Invoke-AudioRun -Context $ctx -Prof $prof -File $fa -Index 1 -Duration (Get-Dur $fa) -SourceChannels 2 -Pos 0
    $ok = Invoke-Multiplex -Context $ctx -File $fa -Info $info -VideoSkipped $false -AudioSkipped $false -AudioTracks @([pscustomobject]@{
        Source  = 'temp'
        File    = "$oa"
        Index   = 1
        Lang    = 'spa'
        Default = $true
    }) -Subtitles @() -VideoIndex 0
    Assert-True 'adjuntos: multiplex OK' $ok
    $natt = @(Get-Info (Get-OutputPath $ctx 'att')).streams | Where-Object { $_.codec_type -eq 'attachment' }
    Assert-Eq 'adjuntos: 1 conservado' 1 (@($natt).Count)

    # ============================ MODO PRUEBAS ============================
    Write-Host "`n== MODO PRUEBAS ==" -ForegroundColor Cyan
    Reset-Ctx; Clear-Work
    $ctx.TestLimit = 1
    $f = New-In -Name 'tl.mkv' -Dur 4
    $prof = New-CvProfile -VideoEncoder 'libx264' -Crf 30
    $ok = Invoke-VideoRun -Context $ctx -Prof $prof -File $f -Crop '' -Resize '' -Anim $false -Index 0 -Hdr $false -Duration (Get-Dur $f)
    Assert-True 'modo pruebas: encode OK' $ok
    Assert-True 'modo pruebas: salida <= ~1.5s' ((Get-Dur (Get-CvTempPaths -Context $ctx -Name 'tl').Video) -le 1.5)
}
finally {
    try { [System.IO.Directory]::Delete((Join-Path $tempRoot 'lib'), $false) } catch {}
    try { [System.IO.Directory]::Delete((Join-Path $tempRoot 'tools'), $false) } catch {}
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

$total = $script:pass + $script:fail
Write-Host ("`n{0}" -f ('=' * 60))
if ($script:fail -eq 0) {
    Write-Host ("OK  {0}/{1} features; {2} saltados (sin GPU/herramienta)." -f $script:pass, $total, $script:skip) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FALLO  {0}/{1} pasados, {2} fallidos, {3} saltados." -f $script:pass, $total, $script:fail, $script:skip) -ForegroundColor Red
    exit 1
}
