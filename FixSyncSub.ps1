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
if (-not (Test-Path -LiteralPath $Path)) { Write-CvLog 'SUB' ("[ERROR] - No existe: {0}" -f $Path) -Indent 3; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).Path

$text  = Read-CvSrtText -Path $Path
$blocks = @(Get-CvSrtBlocks $text)
Write-CvLog 'SUB' ("[INFO] - {0}  ({1} cues)" -f (Split-Path -Leaf $Path), $blocks.Count) -Indent 3

# 2) Correcciones de texto
if (Read-YesNo '  Corregir OCR (l->I en mayusculas) y espaciado (signos invertidos)?' $true) {
    $r1 = Repair-CvSrtOcr $text
    $r2 = Repair-CvSrtSpacing $r1.Text
    $text = $r2.Text
    Write-CvLog 'SUB' ("OCR corregidos: {0}   espaciados: {1}" -f $r1.Changed.Count, $r2.Count) -Indent 5
    $r1.Changed | Select-Object -Unique | ForEach-Object { Write-CvLog 'SUB' "$_" -Indent 7 }
    if (Read-YesNo '  Anadir sustituciones manuales (buscar=reemplazar)?' $false) {
        while ($true) {
            $r = (Read-CvLine -Prompt '    buscar=reemplazar (vacio para terminar)').Trim()
            if ($r -eq '') { break }
            $i = $r.IndexOf('=')
            if ($i -lt 1) { Write-CvLog 'SUB' '[AVISO] - formato invalido (usa buscar=reemplazar)' -Indent 5; continue }
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
        Text  = 'no sincronizar'
    }
    @{
        Value = 'offset'
        Text  = 'offset constante (adelanta/retrasa todo por igual)'
    }
    @{
        Value = 'lineal'
        Text  = 'lineal por 2 cues (escala + desplazamiento)'
    }
    @{
        Value = 'tramos'
        Text  = 'por tramos (deja intactas las cues anteriores a N)'
    }
    @{
        Value = 'extremos'
        Text  = 'por extremos (primer y ultimo subtitulo)'
    }
)
$mode = Select-FromList -Title 'Sincronizacion' -Options $syncOpts -DefaultValue 'no' -NoNone

$A = 1.0; $B = 0.0; $fromCue = 1; $doSync = $true
switch ($mode) {
    'offset' {
        $off = Read-CvSrtTime -Prompt '    Offset en segundos (+ retrasa, - adelanta), o vacio para darlo por cue' -AllowEmpty
        if ($null -eq $off) { $s1 = 0.0; $r1 = 0.0; Read-CvSrtAnchor $blocks 'Referencia' ([ref]$s1) ([ref]$r1); $off = $r1 - $s1 }
        $A = 1.0; $B = $off
        Write-CvLog 'SUB' ("offset = {0:N3}s" -f $B) -Indent 5
    }
    'lineal' {
        $s1 = 0.0; $r1 = 0.0; $s2 = 0.0; $r2 = 0.0; $fit = $null
        Read-CvSrtAnchor $blocks 'Punto 1' ([ref]$s1) ([ref]$r1)
        while ($null -eq $fit) {
            Read-CvSrtAnchor $blocks 'Punto 2' ([ref]$s2) ([ref]$r2)
            $fit = Get-CvSrtLinearFit $s1 $r1 $s2 $r2
            if ($null -eq $fit) { Write-CvLog 'SUB' '[AVISO] - el punto 2 debe ser una cue distinta del punto 1' -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        Write-CvLog 'SUB' ("A={0:N6}  B={1:N3}s" -f $A, $B) -Indent 5
    }
    'tramos' {
        $fromCue = Read-CvInt -Prompt '    Aplicar DESDE el cue numero (las anteriores no se tocan)'
        $s1 = 0.0; $r1 = 0.0; $s2 = 0.0; $r2 = 0.0; $fit = $null
        Read-CvSrtAnchor $blocks 'Punto 1 (>= ese cue)' ([ref]$s1) ([ref]$r1)
        while ($null -eq $fit) {
            Read-CvSrtAnchor $blocks 'Punto 2 (>= ese cue)' ([ref]$s2) ([ref]$r2)
            $fit = Get-CvSrtLinearFit $s1 $r1 $s2 $r2
            if ($null -eq $fit) { Write-CvLog 'SUB' '[AVISO] - el punto 2 debe ser una cue distinta del punto 1' -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        Write-CvLog 'SUB' ("desde cue {0}:  A={1:N6}  B={2:N3}s" -f $fromCue, $A, $B) -Indent 5
    }
    'extremos' {
        # Por extremos: primer subtitulo A AJUSTAR (ENTER = el 1o, o empiezas en otro si el principio
        # ya esta bien) y el ULTIMO. Las cues anteriores al de inicio quedan intactas.
        $lastNum = Get-CvSrtBlockNum $blocks[-1]
        $srtL = Get-CvSrtCueStart -Blocks $blocks -Num $lastNum
        $fit = $null
        while ($null -eq $fit) {
            $sc = Read-CvSrtCueNum -Blocks $blocks -Prompt '    Desde que subtitulo ajustar? (numero, ENTER = el primero)' -AllowEmpty
            $fromCue = if ($null -eq $sc) { Get-CvSrtBlockNum $blocks[0] } else { $sc }
            $srtF = Get-CvSrtCueStart -Blocks $blocks -Num $fromCue
            Write-CvLog 'SUB' ("PRIMER subtitulo a ajustar (cue {0}) esta en {1}" -f $fromCue, (ConvertTo-CvSrtStamp $srtF)) -Indent 5
            $realF = Read-CvSrtTime -Prompt '      tiempo REAL de esa cue (h:mm:ss.mmm)'
            Write-CvLog 'SUB' ("ULTIMO subtitulo (cue {0}) esta en {1}" -f $lastNum, (ConvertTo-CvSrtStamp $srtL)) -Indent 5
            $realL = Read-CvSrtTime -Prompt '      tiempo REAL del ULTIMO subtitulo (h:mm:ss.mmm)'
            $fit = Get-CvSrtLinearFit $srtF $realF $srtL $realL
            if ($null -eq $fit) { Write-CvLog 'SUB' '[AVISO] - la cue de inicio no puede ser la ultima; elige una anterior' -Indent 5 }
        }
        $A = $fit.A; $B = $fit.B
        if ($fromCue -gt 1) { Write-CvLog 'SUB' ("cues 1..{0} sin tocar" -f ($fromCue - 1)) -Indent 5 }
        Write-CvLog 'SUB' ("desde cue {0}:  A={1:N6}  B={2:N3}s" -f $fromCue, $A, $B) -Indent 5
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
    Write-CvLog 'SUB' ("Resultado: {0} cues. primera (cue {1}) {2}  ...  ultima (cue {3}) {4}" -f `
        $rb.Count, $fN, (ConvertTo-CvSrtStamp (Get-CvSrtCueStart $rb $fN)), $lN, (ConvertTo-CvSrtStamp (Get-CvSrtCueStart $rb $lN))) -Indent 3
}

# 5) Previsualizacion opcional con ffplay (si hay un video con el mismo nombre junto al .srt)
$video = Find-CvSrtVideo -Dir $dir -SrtPath $Path
if ($video) {
    while (Read-YesNo ("  Previsualizar con el video ({0})?" -f (Split-Path -Leaf $video)) $false) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'fixsyncsub-preview.srt'
        Write-CvSrtText -Text $text -Path $tmp -Bom $false
        $esc = ($tmp -replace '\\', '/') -replace ':', '\:'   # escape para el filtro subtitles de ffmpeg
        try { Invoke-CvPreview -Context $ctx -File $video -ExtraArgs @('-vf', "subtitles='$esc'") -Label 'PREVIEW SUBTITULO' }
        catch { Write-CvLog 'SUB' ("[AVISO] - no se pudo previsualizar: {0}" -f $_.Exception.Message) -Indent 3 }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# 6) Guardar
if (-not (Read-YesNo '  Guardar el resultado?' $true)) { Write-CvLog 'SUB' 'Cancelado: no se ha guardado nada.' -Indent 3; exit 0 }
$defOut = Join-Path $dir ("{0}.es.srt" -f $base)
$outPath = (Read-CvLine -Prompt ("  Guardar en [{0}]" -f $defOut)).Trim()
if ($outPath -eq '') { $outPath = $defOut } else { $outPath = $outPath.Trim('"') }
$withBom = Read-YesNo '  Escribir con BOM (UTF-8)?' $false
Write-CvSrtText -Text $text -Path $outPath -Bom $withBom

Write-Host ''
Write-CvLog 'SUB' ("[OK] - {0}" -f $outPath) -Indent 3
