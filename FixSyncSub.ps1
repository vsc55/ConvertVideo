<#
    FixSyncSub.ps1 - Corrige y sincroniza subtitulos .srt (asistente interactivo).

    Es una herramienta aparte del conversor (no se mete en Convert.ps1), pero comparte su config y sus
    piezas: arranca con Start-CvSession (mismo config.json y argumento -Config), reutiliza los menus de
    lib\Console.psm1 y toda la logica de .srt vive en lib\Subtitle.psm1 (funciones *-CvSrt*), asi que
    queda disponible tambien para futuras funciones del conversor.

    Hace, en este orden (todo opcional):
      1. Detecta la codificacion de entrada y la normaliza a UTF-8.
      2. Correcciones de texto: OCR (l->I en mayusculas), espaciado tras los signos invertidos, y
         sustituciones manuales (buscar=reemplazar) para nombres propios.
      3. Sincronizacion (modelo lineal t' = A*t + B): offset, lineal por 2 cues, por tramos, o por extremos.

    Uso:  .\FixSyncSub.ps1 [-Config <ruta>] [ruta.srt]      (o arrastra un .srt sobre FixSyncSub.cmd)
          Sin ruta: lista los .srt de la carpeta Original\ (segun el config) para elegir.
#>
param([string]$Path = '', [string]$Config = '')

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
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
    'Tools'
    'MediaInfo'
    'Profile'
    'Video'
    'Audio'
    'Subtitle'
    'SubtitleSRT'
    'Attachment'
    'Multiplex'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# Arranque comun (mismo config/-Config, apariencia, cabecera y log que Convert.ps1 / setup.ps1).
$sess = Start-CvSession -Root $Root -Config $Config -TitleSuffix ' - FixSyncSub' -Subtitle 'FixSyncSub' -LogPrefix 'FixSyncSub'
$ctx  = $sess.Context

# Los auxiliares del asistente viven en lib\: Read-CvInt (Console.psm1) y, en SubtitleSRT.psm1,
# Read-CvSrtTime / Read-CvSrtCueNum / Read-CvSrtAnchor (anclas), Find-CvSrtVideo y Select-CvSrtFile.

# ============================================================
# 1) Entrada
if (-not $Path) { $Path = Select-CvSrtFile -Dir "$($ctx.Original)" }
$Path = "$Path".Trim('"').Trim()
if (-not (Test-Path -LiteralPath $Path)) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.noexiste' -Values @($Path)) -Indent 3; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).Path

$text  = Read-CvSrtText -Path $Path
$blocks = @(Get-CvSrtBlocks $text)
Write-CvLog 'SUB' (Get-CvText -Key 'fss.info' -Values @((Split-Path -Leaf $Path), $blocks.Count)) -Indent 3

# 2) Correcciones de texto
if (Read-YesNo (Get-CvText -Key 'fss.ocr') $true) {
    $r1 = Repair-CvSrtOcr $text
    $r2 = Repair-CvSrtSpacing $r1.Text
    $text = $r2.Text
    Write-CvLog 'SUB' (Get-CvText -Key 'fss.ocr.n' -Values @($r1.Changed.Count, $r2.Count)) -Indent 5
    $r1.Changed | Select-Object -Unique | ForEach-Object { Write-CvLog 'SUB' "$_" -Indent 7 }
    if (Read-YesNo (Get-CvText -Key 'fss.sust') $false) {
        while ($true) {
            $r = (Read-CvLine -Prompt (Get-CvText -Key 'fss.sust.pide')).Trim()
            if ($r -eq '') { break }
            $i = $r.IndexOf('=')
            if ($i -lt 1) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.sust.mal') -Indent 5; continue }
            $find = $r.Substring(0, $i); $repl = $r.Substring($i + 1)
            $c = ([regex]::Matches($text, [regex]::Escape($find))).Count
            $text = $text.Replace($find, $repl)
            Write-CvLog 'SUB' ("'{0}' -> '{1}'  ({2} veces)" -f $find, $repl, $c) -Indent 5
        }
    }
    $blocks = @(Get-CvSrtBlocks $text)
}

# 3) Sincronizacion
$syncOpts = @(
    @{
        Value = 'no'
        Text  = (Get-CvText -Key 'fss.no')
    }
    @{
        Value = 'offset'
        Text  = (Get-CvText -Key 'fss.offset')
    }
    @{
        Value = 'lineal'
        Text  = (Get-CvText -Key 'fss.lineal')
    }
    @{
        Value = 'tramos'
        Text  = (Get-CvText -Key 'fss.tramos')
    }
    @{
        Value = 'extremos'
        Text  = (Get-CvText -Key 'fss.extremos')
    }
)
$mode = Select-FromList -Title (Get-CvText -Key 'fss.tit') -Options $syncOpts -DefaultValue 'no' -NoNone

$A = 1.0; $B = 0.0; $fromCue = 1; $doSync = $true
switch ($mode) {
    'offset' {
        $off = Read-CvSrtTime -Prompt (Get-CvText -Key 'fss.offset.q') -AllowEmpty
        if ($null -eq $off) { $s1 = 0.0; $r1 = 0.0; Read-CvSrtAnchor $blocks (Get-CvText -Key 'fss.ref') ([ref]$s1) ([ref]$r1); $off = $r1 - $s1 }
        $A = 1.0; $B = $off
        Write-CvLog 'SUB' (Get-CvText -Key 'fss.offset.r' -Values @($B)) -Indent 5
    }
    'lineal' {
        $s1 = 0.0; $r1 = 0.0; $s2 = 0.0; $r2 = 0.0; $fit = $null
        Read-CvSrtAnchor $blocks (Get-CvText -Key 'fss.p1') ([ref]$s1) ([ref]$r1)
        while ($null -eq $fit) {
            Read-CvSrtAnchor $blocks (Get-CvText -Key 'fss.p2') ([ref]$s2) ([ref]$r2)
            $fit = Get-CvSrtLinearFit $s1 $r1 $s2 $r2
            if ($null -eq $fit) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.p2.mal') -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        Write-CvLog 'SUB' ("A={0:N6}  B={1:N3}s" -f $A, $B) -Indent 5
    }
    'tramos' {
        $fromCue = Read-CvInt -Prompt (Get-CvText -Key 'fss.desde')
        $s1 = 0.0; $r1 = 0.0; $s2 = 0.0; $r2 = 0.0; $fit = $null
        Read-CvSrtAnchor $blocks (Get-CvText -Key 'fss.p1.desde') ([ref]$s1) ([ref]$r1)
        while ($null -eq $fit) {
            Read-CvSrtAnchor $blocks (Get-CvText -Key 'fss.p2.desde') ([ref]$s2) ([ref]$r2)
            $fit = Get-CvSrtLinearFit $s1 $r1 $s2 $r2
            if ($null -eq $fit) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.p2.mal') -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        Write-CvLog 'SUB' (Get-CvText -Key 'fss.desde.r' -Values @($fromCue, $A, $B)) -Indent 5
    }
    'extremos' {
        # Por extremos: primer subtitulo A AJUSTAR (ENTER = el 1o, o empiezas en otro si el principio
        # ya esta bien) y el ULTIMO. Las cues anteriores al de inicio quedan intactas.
        $lastNum = Get-CvSrtBlockNum $blocks[-1]
        $srtL = Get-CvSrtCueStart -Blocks $blocks -Num $lastNum
        $fit = $null
        while ($null -eq $fit) {
            $sc = Read-CvSrtCueNum -Blocks $blocks -Prompt (Get-CvText -Key 'fss.desdecual') -AllowEmpty
            $fromCue = if ($null -eq $sc) { Get-CvSrtBlockNum $blocks[0] } else { $sc }
            $srtF = Get-CvSrtCueStart -Blocks $blocks -Num $fromCue
            Write-CvLog 'SUB' (Get-CvText -Key 'fss.primero' -Values @($fromCue, (ConvertTo-CvSrtStamp $srtF))) -Indent 5
            $realF = Read-CvSrtTime -Prompt (Get-CvText -Key 'fss.primero.q')
            Write-CvLog 'SUB' (Get-CvText -Key 'fss.ultimo' -Values @($lastNum, (ConvertTo-CvSrtStamp $srtL))) -Indent 5
            $realL = Read-CvSrtTime -Prompt (Get-CvText -Key 'fss.ultimo.q')
            $fit = Get-CvSrtLinearFit $srtF $realF $srtL $realL
            if ($null -eq $fit) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.inicio.mal') -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        if ($fromCue -gt 1) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.sintocar' -Values @(($fromCue - 1))) -Indent 5 }
        Write-CvLog 'SUB' (Get-CvText -Key 'fss.desde.r' -Values @($fromCue, $A, $B)) -Indent 5
    }
    default { $doSync = $false }
}
if ($doSync) { $text = Invoke-CvSrtResync -Text $text -A $A -B $B -FromCue $fromCue }

# 4) Resumen del resultado
$dir  = Split-Path -Parent $Path
$base = [IO.Path]::GetFileNameWithoutExtension($Path)
$rb = @(Get-CvSrtBlocks $text)
if ($rb.Count -gt 0) {
    $fN = Get-CvSrtBlockNum $rb[0]; $lN = Get-CvSrtBlockNum $rb[-1]
    Write-CvLog 'SUB' (Get-CvText -Key 'fss.resultado' -Values @($rb.Count, $fN, (ConvertTo-CvSrtStamp (Get-CvSrtCueStart $rb $fN)), $lN, (ConvertTo-CvSrtStamp (Get-CvSrtCueStart $rb $lN)))) -Indent 3
}

# 5) Previsualizacion opcional con ffplay (si hay un video con el mismo nombre junto al .srt)
$video = Find-CvSrtVideo -Dir $dir -SrtPath $Path
if ($video) {
    while (Read-YesNo (Get-CvText -Key 'fss.preview' -Values @((Split-Path -Leaf $video))) $false) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'fixsyncsub-preview.srt'
        Write-CvSrtText -Text $text -Path $tmp -Bom $false
        $esc = ($tmp -replace '\\', '/') -replace ':', '\:'   # escape para el filtro subtitles de ffmpeg
        try { Invoke-CvPreview -Context $ctx -File $video -ExtraArgs @('-vf', "subtitles='$esc'") -Label (Get-CvText -Key 'fss.preview.t') }
        catch { Write-CvLog 'SUB' (Get-CvText -Key 'fss.preview.no' -Values @($_.Exception.Message)) -Indent 3 }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# 6) Guardar
if (-not (Read-YesNo (Get-CvText -Key 'fss.guardar') $true)) { Write-CvLog 'SUB' (Get-CvText -Key 'fss.nogurdado') -Indent 3; exit 0 }
$defOut = Join-Path $dir ("{0}.es.srt" -f $base)
$outPath = (Read-CvLine -Prompt (Get-CvText -Key 'fss.guardar.en' -Values @($defOut))).Trim()
if ($outPath -eq '') { $outPath = $defOut } else { $outPath = $outPath.Trim('"') }
$withBom = Read-YesNo (Get-CvText -Key 'fss.bom') $false
Write-CvSrtText -Text $text -Path $outPath -Bom $withBom

Write-Host ''
Write-CvLog 'SUB' ("[OK] - {0}" -f $outPath) -Indent 3
