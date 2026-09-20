# ================================================================================================
#  ConvertVideo - generador del ICONO y del LOGO
# ================================================================================================
#  El icono NO es un fichero que alguien dibujo una vez y nadie sabe rehacer: se pinta con GDI+ en
#  lib\Gui.psm1 (New-CvGuiAppBitmap), que es lo mismo que usan las ventanas para el suyo. Este guion
#  solo lo VUELCA a disco para lo que necesita un fichero:
#
#    icon.ico               (raiz)  - accesos directos, y el que ve el explorador
#    manual\img\logo.png            - logo con el nombre, para fondo claro
#    manual\img\logo-oscuro.png     - el mismo, para fondo oscuro
#
#  Si se cambia el dibujo, se cambia en Gui.psm1 y se vuelve a lanzar esto: no hay dos verdades.
#
#  Uso:  powershell -ExecutionPolicy Bypass -File manual\generar-logo.ps1
# ================================================================================================
param(
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
foreach ($m in @('Log', 'Io', 'Config', 'Context', 'Console', 'Gui')) {
    Import-Module (Join-Path $Root ("lib\{0}.psm1" -f $m)) -Force
}
if (-not (Initialize-CvGui)) { throw 'No hay entorno grafico (System.Drawing / WinForms).' }

$imgDir = $(if ("$Out" -ne '') { $Out } else { Join-Path $PSScriptRoot 'img' })
if (-not (Test-Path -LiteralPath $imgDir)) { New-Item -ItemType Directory -Path $imgDir -Force | Out-Null }

# ---- 1) icon.ico (varios tamanos dentro) --------------------------------------------------------
$icoPath = $(if ("$Out" -ne '') { Join-Path $Out 'icon.ico' } else { Join-Path $Root 'icon.ico' })
[System.IO.File]::WriteAllBytes($icoPath, (Get-CvGuiAppIconBytes))
Write-Host ("  [ICO]  {0}" -f $icoPath)

# ---- 2) el logo: icono + nombre -----------------------------------------------------------------
function New-Logo {
    <# Logo horizontal: el icono, el nombre y una linea de que es. -Dark para fondo oscuro. #>
    param([switch]$Dark)
    $alto  = 160
    $ico   = 112
    # El ancho sale de MEDIR el texto, no a ojo: si se deja fijo, el logo arrastra un pegote de fondo
    # a la derecha (y con otra fuente instalada se cortaria).
    $medidor = New-Object System.Drawing.Bitmap(1, 1)
    $gm = [System.Drawing.Graphics]::FromImage($medidor)
    $sfM = [System.Drawing.StringFormat]::GenericTypographic
    $fA = New-Object System.Drawing.Font('Segoe UI', 40, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fB = New-Object System.Drawing.Font('Segoe UI Semibold', 40, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fC = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $anchoTexto = [Math]::Max(
        ($gm.MeasureString('Convert', $fA, 2000, $sfM).Width + $gm.MeasureString('Video', $fB, 2000, $sfM).Width + 2),
        $gm.MeasureString('Conversor de video por lotes para Windows, con FFmpeg', $fC, 2000, $sfM).Width)
    $fA.Dispose(); $fB.Dispose(); $fC.Dispose(); $gm.Dispose(); $medidor.Dispose()
    $ancho = 24 + $ico + 26 + [int][Math]::Ceiling($anchoTexto) + 24

    $bmp = New-Object System.Drawing.Bitmap($ancho, $alto)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $fondo = $(if ($Dark) { [System.Drawing.Color]::FromArgb(32, 32, 32) } else { [System.Drawing.Color]::White })
        $g.Clear($fondo)

        $badge = New-CvGuiAppBitmap -Size $ico
        $g.DrawImage($badge, 24, [int](($alto - $ico) / 2))
        $badge.Dispose()

        # 'Convert' en el color del texto y 'Video' en el azul del icono: el nombre se lee de un
        # golpe y el color ata el logo con el icono.
        $x = 24 + $ico + 26
        $f1 = New-Object System.Drawing.Font('Segoe UI', 40, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $f2 = New-Object System.Drawing.Font('Segoe UI Semibold', 40, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $c1 = $(if ($Dark) { [System.Drawing.Color]::FromArgb(235, 235, 235) } else { [System.Drawing.Color]::FromArgb(32, 32, 32) })
        $c2 = [System.Drawing.Color]::FromArgb(41, 150, 235)
        $y  = 40
        $sf = [System.Drawing.StringFormat]::GenericTypographic
        $g.DrawString('Convert', $f1, (New-Object System.Drawing.SolidBrush $c1), $x, $y, $sf)
        $w1 = $g.MeasureString('Convert', $f1, 2000, $sf).Width
        $g.DrawString('Video', $f2, (New-Object System.Drawing.SolidBrush $c2), ($x + $w1 + 2), $y, $sf)

        $f3 = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $c3 = $(if ($Dark) { [System.Drawing.Color]::FromArgb(150, 150, 150) } else { [System.Drawing.Color]::FromArgb(110, 110, 110) })
        $g.DrawString('Conversor de video por lotes para Windows, con FFmpeg', $f3, (New-Object System.Drawing.SolidBrush $c3), $x, ($y + 54), $sf)
        $f1.Dispose(); $f2.Dispose(); $f3.Dispose()
    } finally {
        $g.Dispose()
    }
    return $bmp
}

foreach ($par in @(@{ N = 'logo.png'; D = $false }, @{ N = 'logo-oscuro.png'; D = $true })) {
    $b = New-Logo -Dark:$par.D
    $ruta = Join-Path $imgDir $par.N
    $b.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    Write-Host ("  [PNG]  {0}" -f $ruta)
}

Write-Host ''
Write-Host 'Icono y logo generados.' -ForegroundColor Green
