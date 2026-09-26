<#
    Gui.psm1 - Ventanas GUI (WinForms) del conversor.

    Lo que comparten las TRES ventanas del programa (setup, cola de conversion y editor de jobs):
    arrancar WinForms, la fuente, el doble bufer, los avisos y confirmaciones modales, el dialogo de
    varias salidas y el tamano recordado de cada ventana. Vivian en GuiSetup.psm1 por historia -la
    primera ventana fue la del setup-, lo que obligaba a la cola a depender del modulo del setup solo
    para abrir un aviso; ahora cada modulo Gui* se queda con SU ventana y lo comun esta aqui.

    Separado de Console.psm1 (que es la CONSOLA de texto: menus, prompts, colores) porque esto es
    interfaz grafica: otro paradigma y con su propia dependencia (System.Windows.Forms / System.Drawing).
    Requiere hilo STA, lo normal en powershell.exe (el runtime objetivo). Cada funcion carga WinForms
    en su primera llamada (Add-Type) y es fail-soft: si no hay GUI/STA devuelve $false para que el
    llamador caiga a otra via.
#>

$script:CvGuiInit = $null   # resultado de la primera carga: se llama muchas veces por ventana

function Initialize-CvGui {
    <# Carga WinForms/Drawing y activa los estilos visuales. $false si no hay GUI/STA (el llamador cae
       a la consola). Idempotente y CACHEADO: se puede llamar en cada entrada sin coste. #>
    if ($null -ne $script:CvGuiInit) { return $script:CvGuiInit }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:CvGuiInit = $true
    } catch {
        $script:CvGuiInit = $false
    }
    return $script:CvGuiInit
}

function New-CvGuiFont {
    <# Fuente monoespaciada para los paneles de salida (texto alineado en columnas). #>
    param([int]$Size = 9)
    New-Object System.Drawing.Font('Consolas', $Size)
}

function Get-CvGuiLayoutPath {
    <#
        Fichero donde se apunta COMO QUEDARON las ventanas: junto al config en uso y con su mismo
        nombre ('config.json' -> 'config.gui.json'). Va por config a proposito -cada config tiene su
        Original\ y su cola, y se mira de otra manera- y fuera del repo por el .gitignore de config.*.

        Es ESTADO, no configuracion: si se borra, las ventanas vuelven a abrir con los tamanos de
        config.json ('gui'). Lo que se guarda o no lo manda gui.rememberLayout.
    #>
    param([Parameter(Mandatory)]$Context)
    $cfg = "$($Context.ConfigPath)"
    if ([string]::IsNullOrWhiteSpace($cfg)) { $cfg = Join-Path "$($Context.Root)" 'config.json' }
    $dir = Split-Path -Parent $cfg
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = "$($Context.Root)" }
    return (Join-Path $dir ("{0}.gui.json" -f [System.IO.Path]::GetFileNameWithoutExtension($cfg)))
}

function Get-CvGuiLayout {
    <#
        Lo apuntado para UNA ventana ('cola', 'setup'...), o $null si no hay nada (o es ilegible).
        Nunca lanza: esto se llama al abrir, y un fichero a medio escribir no puede impedir arrancar.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Key
    )
    $p = Get-CvGuiLayoutPath -Context $Context
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $all = ConvertFrom-Json ((Get-Content -LiteralPath $p -Raw -Encoding UTF8))
        if ($null -ne $all -and $all.PSObject.Properties[$Key]) { return $all.$Key }
    } catch { }
    return $null
}

function Save-CvGuiLayout {
    <#
        Apunta como ha quedado UNA ventana, conservando lo de las demas. Devuelve $true/$false y no
        lanza nunca: se llama desde FormClosing, donde una excepcion se lleva por delante la app.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Layout
    )
    try {
        $p   = Get-CvGuiLayoutPath -Context $Context
        $all = [ordered]@{}
        if (Test-Path -LiteralPath $p) {
            try {
                $old = ConvertFrom-Json ((Get-Content -LiteralPath $p -Raw -Encoding UTF8))
                if ($null -ne $old) {
                    foreach ($pr in @($old.PSObject.Properties)) { $all[$pr.Name] = $pr.Value }
                }
            } catch { }
        }
        $all[$Key] = $Layout
        ([pscustomobject]$all | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Get-CvGuiCacheStatus {
    <#
        Que hay guardado en '<config>.gui.json' y cuanto ocupa, SIN borrar nada: lo ensena setup para
        que se pueda decidir. Ahi dentro conviven dos cosas distintas:

          - el ESTADO DE LAS VENTANAS (una clave por ventana: 'cola', 'setup'...): tamano, divisor y
            anchos de columna;
          - la CACHE DE ARCHIVOS ('colaBordes'): lo deducido de cada archivo ya convertido, que se
            guarda para no repetir dos ffprobe por archivo cada vez que se abre la cola.

        Devuelve @{ Path; Exists; SizeKb; Layouts; LayoutKeys; Files; Total }, donde Layouts es
        cuantas ventanas hay apuntadas y Files cuantos archivos hay cacheados.
    #>
    param([Parameter(Mandatory)]$Context)
    $p = Get-CvGuiLayoutPath -Context $Context
    $r = [ordered]@{
        Path       = $p
        Exists     = (Test-Path -LiteralPath $p)
        SizeKb     = 0
        Layouts    = 0
        LayoutKeys = @()
        Files      = 0
        Total      = 0
    }
    if (-not $r.Exists) { return [pscustomobject]$r }
    try { $r.SizeKb = [math]::Round((Get-Item -LiteralPath $p).Length / 1024.0, 1) } catch { }
    try {
        $all = ConvertFrom-Json ((Get-Content -LiteralPath $p -Raw -Encoding UTF8))
        foreach ($pr in @($all.PSObject.Properties)) {
            if ($pr.Name -eq 'colaBordes') { $r.Files = @($pr.Value).Count; continue }
            $r.Layouts++
            $r.LayoutKeys += $pr.Name
        }
    } catch { }
    $r.Total = [int]$r.Layouts + [int]$r.Files
    return [pscustomobject]$r
}

function Clear-CvGuiCache {
    <#
        Borra lo guardado en '<config>.gui.json': -What 'layout' (como quedaron las ventanas),
        'files' (lo deducido de los archivos ya convertidos) o 'all' (el fichero entero).

        Es ESTADO: borrarlo no pierde nada que no se pueda volver a calcular -las ventanas vuelven a
        abrirse con los tamanos de config.json y los bordes se vuelven a deducir-. Devuelve
        @{ Ok; Removed; Error }, con Removed = cuantas cosas se han quitado.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('layout', 'files', 'all')][string]$What = 'all'
    )
    $p = Get-CvGuiLayoutPath -Context $Context
    $antes = Get-CvGuiCacheStatus -Context $Context
    if (-not $antes.Exists) { return @{ Ok = $true; Removed = 0; Error = '' } }
    try {
        if ($What -eq 'all') {
            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            return @{ Ok = $true; Removed = [int]$antes.Total; Error = '' }
        }
        $all = ConvertFrom-Json ((Get-Content -LiteralPath $p -Raw -Encoding UTF8))
        $queda = [ordered]@{}
        $fuera = 0
        foreach ($pr in @($all.PSObject.Properties)) {
            $esCache = ($pr.Name -eq 'colaBordes')
            if (($What -eq 'files' -and $esCache) -or ($What -eq 'layout' -and -not $esCache)) {
                $fuera += $(if ($esCache) { @($pr.Value).Count } else { 1 })
                continue
            }
            $queda[$pr.Name] = $pr.Value
        }
        # Si no queda nada dentro, mejor sin fichero que con un '{}' suelto.
        if ($queda.Count -eq 0) { Remove-Item -LiteralPath $p -Force -ErrorAction Stop }
        else { ([pscustomobject]$queda | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8 }
        return @{ Ok = $true; Removed = $fuera; Error = '' }
    } catch {
        return @{ Ok = $false; Removed = 0; Error = "$_" }
    }
}

function Get-CvGuiLayoutValue {
    <# PURO. Un campo de lo apuntado, venga como hashtable (codigo) o como objeto (JSON leido). #>
    param($Layout, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Layout) { return $Default }
    if ($Layout -is [System.Collections.IDictionary]) {
        if ($Layout.Contains($Name)) { return $Layout[$Name] }
        return $Default
    }
    $p = $Layout.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Resolve-CvGuiWindowSize {
    <#
        PURO. Con que tamano abrir una ventana: el recordado si es USABLE y, si no, el de la config.
        Se valida contra los minimos y contra el escritorio de HOY: un tamano guardado con dos
        monitores no puede dejar la ventana mas grande que la pantalla que queda (-MaxWidth/-MaxHeight,
        0 = sin tope). Devuelve @{ Width; Height; Maximized }.
    #>
    param(
        $Layout,
        [Parameter(Mandatory)][int]$DefaultWidth,
        [Parameter(Mandatory)][int]$DefaultHeight,
        [int]$MinWidth  = 400,
        [int]$MinHeight = 300,
        [int]$MaxWidth  = 0,
        [int]$MaxHeight = 0
    )
    $w = [int]$DefaultWidth
    $h = [int]$DefaultHeight
    $n = 0
    $sw = "$(Get-CvGuiLayoutValue -Layout $Layout -Name 'width')"
    if ([int]::TryParse($sw, [ref]$n) -and $n -gt 0) { $w = $n }
    $sh = "$(Get-CvGuiLayoutValue -Layout $Layout -Name 'height')"
    if ([int]::TryParse($sh, [ref]$n) -and $n -gt 0) { $h = $n }
    if ($MaxWidth  -gt 0 -and $w -gt $MaxWidth)  { $w = $MaxWidth }
    if ($MaxHeight -gt 0 -and $h -gt $MaxHeight) { $h = $MaxHeight }
    if ($w -lt $MinWidth)  { $w = $MinWidth }
    if ($h -lt $MinHeight) { $h = $MinHeight }
    return @{
        Width     = $w
        Height    = $h
        Maximized = [bool](Get-CvGuiLayoutValue -Layout $Layout -Name 'maximized' -Default $false)
    }
}

function Resolve-CvGuiSplitDistance {
    <#
        PURO. Donde dejar el divisor de un SplitContainer: lo recordado (-Saved, 0 = nada) si cabe en
        el alto de HOY, y si no el -Percent de la config. Siempre respetando los minimos de los dos
        paneles: asignar un SplitterDistance que no cabe LANZA, y esto corre al mostrar la ventana.
    #>
    param(
        [Parameter(Mandatory)][int]$Height,
        [int]$Percent       = 50,
        [int]$Saved         = 0,
        [int]$Min1          = 40,
        [int]$Min2          = 40,
        [int]$SplitterWidth = 4
    )
    $max = $Height - $Min2 - $SplitterWidth
    # Ventana tan baja que los minimos no caben: mitad y mitad, que es lo menos malo.
    if ($max -lt $Min1) { return [Math]::Max(0, [int]($Height / 2)) }
    $d = if ($Saved -gt 0) { $Saved } else { [int]($Height * ($Percent / 100.0)) }
    if ($d -gt $max)  { $d = $max }
    if ($d -lt $Min1) { $d = $Min1 }
    return $d
}

function New-CvGuiRoundedPath {
    <# Rectangulo con las esquinas redondeadas, para pintarlo o recortarlo. #>
    param(
        [Parameter(Mandatory)][System.Drawing.RectangleF]$Rect,
        [float]$Radius = 4
    )
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [float]($Radius * 2)
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc(($Rect.Right - $d), $Rect.Y, $d, $d, 270, 90)
    $p.AddArc(($Rect.Right - $d), ($Rect.Bottom - $d), $d, $d, 0, 90)
    $p.AddArc($Rect.X, ($Rect.Bottom - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Add-CvGuiArcArrow {
    <#
        La PUNTA de flecha del final de un arco. Se calcula sobre la TANGENTE de la circunferencia,
        no a ojo: asi sale del anillo en su misma direccion y no parece un pegote pegado encima.
    #>
    param(
        [Parameter(Mandatory)]$Graphics,
        [float]$Cx,
        [float]$Cy,
        [float]$Radius,
        [float]$Degrees,
        [float]$Size,
        [Parameter(Mandatory)]$Brush
    )
    $a  = [float]($Degrees * [Math]::PI / 180)
    $px = [float]($Cx + $Radius * [Math]::Cos($a))
    $py = [float]($Cy + $Radius * [Math]::Sin($a))
    $tx = [float](-[Math]::Sin($a))      # tangente: hacia donde avanza el arco
    $ty = [float]([Math]::Cos($a))
    $nx = [float]([Math]::Cos($a))       # normal: hacia fuera del circulo
    $ny = [float]([Math]::Sin($a))
    $pts = @(
        (New-Object System.Drawing.PointF(($px + $tx * $Size * 1.15), ($py + $ty * $Size * 1.15)))
        (New-Object System.Drawing.PointF(($px - $tx * $Size * 0.35 + $nx * $Size), ($py - $ty * $Size * 0.35 + $ny * $Size)))
        (New-Object System.Drawing.PointF(($px - $tx * $Size * 0.35 - $nx * $Size), ($py - $ty * $Size * 0.35 - $ny * $Size)))
    )
    $Graphics.FillPolygon($Brush, $pts)
}

function New-CvGuiAppBitmap {
    <#
        El icono de la APLICACION, dibujado con GDI+ igual que los de la barra: nada de .png que
        instalar, y sale nitido a cualquier tamano y DPI porque se pinta al tamano que se pida.

        Que se ve: una FLECHA CIRCULAR (convertir, volver a codificar) con un PLAY dentro (video),
        sobre una tira de pelicula -las perforaciones de arriba y abajo-. Las dos cosas hacen falta:
        solo el play es "un reproductor mas", y el doble triangulo que se probo antes era, ni mas ni
        menos, el simbolo de AVANCE RAPIDO.

        Las perforaciones solo se pintan de 32 px para arriba: mas abajo no hay pixeles y solo
        ensucian; ahi se queda el anillo con el play, que es lo que aguanta a 16 px.
    #>
    param([int]$Size = 32)
    [void](Initialize-CvGui)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $S = [float]$Size

        # La pastilla azul.
        $m = [float]([Math]::Max(1, $S * 0.055))
        $rect = New-Object System.Drawing.RectangleF($m, $m, ($S - 2 * $m), ($S - 2 * $m))
        $path = New-CvGuiRoundedPath -Rect $rect -Radius ([float]($S * 0.21))
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
            [System.Drawing.Color]::FromArgb(56, 160, 245),
            [System.Drawing.Color]::FromArgb(10, 92, 176), 90)
        $g.FillPath($br, $path)
        $br.Dispose()
        $path.Dispose()

        # Tira de pelicula: perforaciones arriba y abajo.
        if ($Size -ge 32) {
            $pw = [float]($S * 0.088)
            $ph = [float]($S * 0.062)
            $brP = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140, 255, 255, 255))
            foreach ($k in 0..2) {
                $x = [float]($rect.X + $S * 0.118 + $k * $S * 0.265)
                foreach ($y in @([float]($rect.Y + $S * 0.052), [float]($rect.Bottom - $S * 0.052 - $ph))) {
                    $rp = New-Object System.Drawing.RectangleF($x, $y, $pw, $ph)
                    $pp = New-CvGuiRoundedPath -Rect $rp -Radius ([float]($ph * 0.35))
                    $g.FillPath($brP, $pp)
                    $pp.Dispose()
                }
            }
            $brP.Dispose()
        }

        # Anillo de conversion + play.
        $blanco = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $cx = [float]($S / 2)
        $cy = [float]($S / 2)
        $diam = [float]($S * $(if ($Size -ge 32) { 0.54 } else { 0.60 }))
        $r = [float]($diam / 2)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([float]($S * 0.108))
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Flat
        # OJO con los angulos: en GDI+ la Y crece HACIA ABAJO, asi que 0 grados es las 3 en punto y
        # el arco avanza en el sentido de las agujas del reloj. El arco va de 45 a 330 grados (hueco
        # a la derecha) y la punta va donde TERMINA -330-, no donde empieza: puesta al principio
        # apunta al reves y parece un gancho colgando (se vio al dibujarlo a 256 px).
        $g.DrawArc($pen, ($cx - $r), ($cy - $r), $diam, $diam, 45, 285)
        $pen.Dispose()
        Add-CvGuiArcArrow -Graphics $g -Cx $cx -Cy $cy -Radius $r -Degrees 330 -Size ([float]($S * 0.125)) -Brush $blanco

        $t = [float]($S * $(if ($Size -ge 32) { 0.095 } else { 0.105 }))
        $pts = @(
            (New-Object System.Drawing.PointF([float]($cx - $t * 0.72), [float]($cy - $t)))
            (New-Object System.Drawing.PointF([float]($cx - $t * 0.72), [float]($cy + $t)))
            (New-Object System.Drawing.PointF([float]($cx + $t * 0.95), [float]$cy))
        )
        $g.FillPolygon($blanco, $pts)
        $blanco.Dispose()
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function Get-CvGuiAppFrameBytes {
    <#
        Un fotograma del .ico. Los grandes (128, 256) van en PNG, que es como se hace desde Vista y
        ahorra la mitad del fichero; los PEQUENOS van en DIB, el formato clasico.

        Conviene saberlo antes de "arreglar" nada: Icon.ToBitmap() de .NET NO sabe sacar un fotograma
        en PNG (revienta con "el intervalo solicitado se extiende mas alla del final de la matriz"),
        y eso no quiere decir que el .ico este mal - Windows lo pinta perfectamente-. Con los
        pequenos en DIB, que son los que se usan en la ventana, .NET tambien los lee.

        El DIB de un icono lleva la cabecera con el ALTO DOBLE (la imagen y su mascara), los pixeles
        de abajo arriba y, detras, la mascara AND a ceros (la transparencia ya va en el canal alfa).
    #>
    param([Parameter(Mandatory)]$Bitmap)
    $s = $Bitmap.Width
    if ($s -ge 128) {
        $ms = New-Object System.IO.MemoryStream
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b = $ms.ToArray()
        $ms.Dispose()
        return , $b
    }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s, $s)
    $datos = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($datos.Stride * $s)
    [System.Runtime.InteropServices.Marshal]::Copy($datos.Scan0, $buf, 0, $buf.Length)
    $Bitmap.UnlockBits($datos)

    $filaMascara = [int]([Math]::Floor(($s + 31) / 32) * 4)   # la mascara va alineada a 4 bytes
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([uint32]40)                       # tamano de la cabecera
    $w.Write([int32]$s)                        # ancho
    $w.Write([int32]($s * 2))                  # alto: imagen + mascara
    $w.Write([uint16]1)                        # planos
    $w.Write([uint16]32)                       # bits por pixel
    $w.Write([uint32]0)                        # sin compresion
    $w.Write([uint32](($s * $s * 4) + ($filaMascara * $s)))
    $w.Write([int32]0)                         # resolucion horizontal (da igual)
    $w.Write([int32]0)                         # resolucion vertical
    $w.Write([uint32]0)                        # colores usados
    $w.Write([uint32]0)                        # colores importantes
    for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($buf, ($y * $datos.Stride), ($s * 4)) }
    $w.Write((New-Object byte[] ($filaMascara * $s)))
    $w.Flush()
    $b = $out.ToArray()
    $w.Dispose()
    $out.Dispose()
    return , $b
}

function Get-CvGuiAppIconBytes {
    <#
        El icono de la aplicacion como fichero .ICO en memoria, con VARIOS tamanos dentro: Windows
        coge el que necesita en cada sitio (16 en la barra de titulo, 32 en Alt+Tab, 256 en el
        explorador), y asi ninguno sale de reescalar otro.

        Se monta el contenedor a mano -cabecera, una entrada por tamano y los fotogramas detras-
        porque System.Drawing no sabe guardar un .ico de varios tamanos (Icon.Save escribe el que le
        den). Cada fotograma, con Get-CvGuiAppFrameBytes.
    #>
    param([int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256))
    [void](Initialize-CvGui)
    $tam = @($Sizes | Sort-Object)
    $marcos = @()
    foreach ($s in $tam) {
        $bmp = New-CvGuiAppBitmap -Size $s
        $marcos += , (Get-CvGuiAppFrameBytes -Bitmap $bmp)
        $bmp.Dispose()
    }
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([uint16]0)              # reservado
    $w.Write([uint16]1)              # tipo: 1 = icono
    $w.Write([uint16]$tam.Count)
    $offset = 6 + (16 * $tam.Count)  # cabecera + tabla de entradas
    for ($i = 0; $i -lt $tam.Count; $i++) {
        # 256 se escribe como 0: en la tabla el tamano es un BYTE.
        $b = [byte]$(if ($tam[$i] -ge 256) { 0 } else { $tam[$i] })
        $w.Write($b)                 # ancho
        $w.Write($b)                 # alto
        $w.Write([byte]0)            # colores de la paleta (0 = sin paleta)
        $w.Write([byte]0)            # reservado
        $w.Write([uint16]1)          # planos
        $w.Write([uint16]32)         # bits por pixel
        $w.Write([uint32]$marcos[$i].Length)
        $w.Write([uint32]$offset)
        $offset += $marcos[$i].Length
    }
    foreach ($m in $marcos) { $w.Write($m) }
    $w.Flush()
    $bytes = $out.ToArray()
    $w.Dispose()
    $out.Dispose()
    return , $bytes
}

function Get-CvGuiAppIcon {
    <# El icono de la aplicacion listo para una ventana. Se monta UNA vez y se reparte. #>
    if ($null -ne $script:CvGuiAppIcon) { return $script:CvGuiAppIcon }
    try {
        $ms = New-Object System.IO.MemoryStream (, (Get-CvGuiAppIconBytes))
        $script:CvGuiAppIcon = New-Object System.Drawing.Icon $ms
        $ms.Dispose()
    } catch { $script:CvGuiAppIcon = $null }
    return $script:CvGuiAppIcon
}

function Set-CvGuiAppIcon {
    <#
        Le pone a la ventana el icono de la aplicacion. Sin esto sale el de WinForms (el formulario
        gris de toda la vida), que es lo que se veia en la barra de titulo y en Alt+Tab.
    #>
    param([Parameter(Mandatory)]$Form)
    try {
        $ico = Get-CvGuiAppIcon
        if ($null -ne $ico) { $Form.Icon = $ico }
    } catch { }
    return $Form
}

function Get-CvGuiIconGlyphs {
    <#
        PURO. Que glifo de 'Segoe MDL2 Assets' -la fuente de iconos de Windows 10/11- le toca a cada
        icono, y de que color. Se referencian por CODIGO (0xE768), no escribiendo el caracter: los
        .psm1 sin BOM los lee PowerShell 5.1 como Windows-1252 y un caracter asi acabaria en mojibake.

        Fuente unica del aspecto de la barra: cambiar aqui un codigo cambia el icono en todas partes.
    #>
    @{
        play    = @{ Code = 0xE768; Color = @(46, 125, 50) }    # triangulo de reproducir
        stop    = @{ Code = 0xE71A; Color = @(199, 119, 0) }    # cuadrado (parada ordenada)
        cancel  = @{ Code = 0xE711; Color = @(198, 40, 40) }    # aspa
        prepare = @{ Code = 0xE9D5; Color = @(21, 101, 192) }   # lista con marcas
        edit    = @{ Code = 0xE70F; Color = @(69, 90, 100) }    # lapiz
        refresh = @{ Code = 0xE72C; Color = @(21, 101, 192) }   # flecha circular
        options = @{ Code = 0xE713; Color = @(69, 90, 100) }    # rueda dentada
        folder  = @{ Code = 0xED25; Color = @(198, 155, 40) }   # carpeta
        console = @{ Code = 0xE756; Color = @(69, 90, 100) }    # ventana de comandos
        theme   = @{ Code = 0xE706; Color = @(120, 120, 130) }  # brillo (cambiar claro/oscuro)
    }
}

function Get-CvGuiIconRgb {
    <#
        PURO. El color de un icono, aclarado si hace falta. Los del catalogo estan pensados para
        fondo claro (verde oscuro, azul marino, gris pizarra) y sobre un fondo casi negro se pierden;
        con -Light se mezclan con blanco al 55%, que es lo justo para que se vean sin deslumbrar.
    #>
    param(
        [Parameter(Mandatory)]$Rgb,
        [bool]$Light = $false
    )
    $c = @($Rgb)
    if (-not $Light) { return @([int]$c[0], [int]$c[1], [int]$c[2]) }
    return @(
        [int]([Math]::Min(255, [int]$c[0] + [int]((255 - [int]$c[0]) * 0.55)))
        [int]([Math]::Min(255, [int]$c[1] + [int]((255 - [int]$c[1]) * 0.55)))
        [int]([Math]::Min(255, [int]$c[2] + [int]((255 - [int]$c[2]) * 0.55)))
    )
}

function New-CvGuiIcon {
    <#
        Icono para la barra de botones. Se pinta el glifo que toca de 'Segoe MDL2 Assets' (la fuente
        de iconos que trae Windows 10/11): son los mismos simbolos que usa el sistema, asi que la
        ventana no parece de otra epoca, y al ser una fuente escalan nitidos a cualquier tamano y DPI.

        Si esa fuente NO esta (Windows viejo), se cae a los iconos DIBUJADOS a mano con GDI+ que habia
        antes: mas pobres, pero siempre disponibles. En ningun caso hay ficheros .png que instalar.

        -Kind: play | stop | cancel | prepare | edit | refresh | options | console. Devuelve un Bitmap
        (o $null si algo falla: un boton sin icono sigue siendo un boton).
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [int]$Size = 20
    )
    $k = "$Kind".ToLower()
    try {
        $glyphs = Get-CvGuiIconGlyphs
        if ($glyphs.ContainsKey($k)) {
            $fnt = New-Object System.Drawing.Font('Segoe MDL2 Assets', [single]($Size * 0.72), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            if ("$($fnt.Name)" -eq 'Segoe MDL2 Assets') {
                $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
                $g   = [System.Drawing.Graphics]::FromImage($bmp)
                $g.Clear([System.Drawing.Color]::Transparent)
                # AntiAliasGridFit y no ClearType: sobre fondo transparente, ClearType deja halos.
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
                $c  = @(Get-CvGuiIconRgb -Rgb $glyphs[$k].Color -Light (Get-CvGuiCurrentPalette).IconLight)
                $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2]))
                $sf = New-Object System.Drawing.StringFormat
                $sf.Alignment     = [System.Drawing.StringAlignment]::Center
                $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
                $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
                $g.DrawString([string][char][int]$glyphs[$k].Code, $fnt, $br, $rect, $sf)
                $br.Dispose(); $sf.Dispose(); $g.Dispose(); $fnt.Dispose()
                return $bmp
            }
            $fnt.Dispose()
        }
    } catch { }
    return (New-CvGuiIconDrawn -Kind $k -Size $Size)
}

function New-CvGuiIconDrawn {
    <#
        RESPALDO: los iconos dibujados a mano con GDI+, para equipos sin 'Segoe MDL2 Assets'. Cuatro
        trazos cada uno, pero siempre disponibles y sin ficheros que instalar.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [int]$Size = 16
    )
    try {
        $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $k = "$Kind".ToLower()
        $verde = [System.Drawing.Color]::FromArgb(30, 130, 60)
        $ambar = [System.Drawing.Color]::FromArgb(190, 120, 20)
        $rojo  = [System.Drawing.Color]::FromArgb(170, 45, 45)
        $azul  = [System.Drawing.Color]::FromArgb(50, 90, 150)
        $gris  = [System.Drawing.Color]::FromArgb(90, 90, 90)
        switch ($k) {
            'play' {
                $br = New-Object System.Drawing.SolidBrush $verde
                $g.FillPolygon($br, @(
                    (New-Object System.Drawing.Point(4, 2)),
                    (New-Object System.Drawing.Point(14, 8)),
                    (New-Object System.Drawing.Point(4, 14))
                ))
                $br.Dispose()
            }
            'stop' {
                # Cuadrado hueco: 'Parar' es ordenado (terminan lo que tienen), no un corte en seco.
                $pen = New-Object System.Drawing.Pen ($ambar, 2)
                $g.DrawRectangle($pen, 3, 3, 10, 10)
                $pen.Dispose()
            }
            'cancel' {
                $pen = New-Object System.Drawing.Pen ($rojo, 2.4)
                $g.DrawLine($pen, 3, 3, 13, 13)
                $g.DrawLine($pen, 13, 3, 3, 13)
                $pen.Dispose()
            }
            'prepare' {
                # Lista con una marca: preparar es dejar cada archivo decidido.
                $pen = New-Object System.Drawing.Pen ($azul, 1.6)
                $g.DrawLine($pen, 2, 3, 13, 3)
                $g.DrawLine($pen, 2, 7, 10, 7)
                $g.DrawLine($pen, 2, 11, 7, 11)
                $pen.Dispose()
                $pv = New-Object System.Drawing.Pen ($verde, 2)
                $g.DrawLine($pv, 9, 12, 11, 14)
                $g.DrawLine($pv, 11, 14, 15, 8)
                $pv.Dispose()
            }
            'edit' {
                $pen = New-Object System.Drawing.Pen ($ambar, 2)
                $g.DrawLine($pen, 4, 12, 12, 4)     # cuerpo del lapiz
                $pen.Dispose()
                $br = New-Object System.Drawing.SolidBrush $gris
                $g.FillPolygon($br, @(
                    (New-Object System.Drawing.Point(2, 14)),
                    (New-Object System.Drawing.Point(3, 10)),
                    (New-Object System.Drawing.Point(6, 13))
                ))
                $br.Dispose()
            }
            'console' {
                $pen = New-Object System.Drawing.Pen ($gris, 1.6)
                $g.DrawRectangle($pen, 2, 3, 12, 10)
                $g.DrawLine($pen, 4, 6, 7, 8)
                $g.DrawLine($pen, 7, 8, 4, 10)
                $g.DrawLine($pen, 8, 11, 12, 11)
                $pen.Dispose()
            }
            'options' {
                # Rueda dentada simplificada: circulo + cuatro dientes.
                $pen = New-Object System.Drawing.Pen ($gris, 1.8)
                $g.DrawEllipse($pen, 5, 5, 6, 6)
                $g.DrawLine($pen, 8, 1, 8, 4)
                $g.DrawLine($pen, 8, 12, 8, 15)
                $g.DrawLine($pen, 1, 8, 4, 8)
                $g.DrawLine($pen, 12, 8, 15, 8)
                $pen.Dispose()
            }
            'refresh' {
                $pen = New-Object System.Drawing.Pen ($azul, 2)
                $g.DrawArc($pen, 3, 3, 10, 10, 40, 280)
                $pen.Dispose()
                $br = New-Object System.Drawing.SolidBrush $azul
                $g.FillPolygon($br, @(
                    (New-Object System.Drawing.Point(11, 1)),
                    (New-Object System.Drawing.Point(15, 5)),
                    (New-Object System.Drawing.Point(10, 6))
                ))
                $br.Dispose()
            }
            default {
                $pen = New-Object System.Drawing.Pen ($gris, 1.6)
                $g.DrawRectangle($pen, 3, 3, 10, 10)
                $pen.Dispose()
            }
        }
        $g.Dispose()
        return $bmp
    } catch {
        return $null
    }
}

function Set-CvGuiDoubleBuffered {
    <#
        Activa el DOBLE BUFER de un control (se pinta en memoria y se vuelca de golpe). Sin esto, un
        ListView que se refresca solo -la cola se repinta cada segundo- PARPADEA de forma muy visible,
        aunque solo se cambie el texto de una celda.

        Va por reflexion a proposito: 'DoubleBuffered' es una propiedad PROTEGIDA de Control, asi que
        desde fuera no se puede asignar (lo normal seria heredar, y aqui no se puede: los controles se
        crean con New-Object). Fail-soft: si la reflexion falla, solo se pierde la mejora.
    #>
    param([Parameter(Mandatory)]$Control)
    try {
        $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
        $prop  = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $flags)
        if ($prop) { $prop.SetValue($Control, $true, $null) }
        return $true
    } catch {
        return $false
    }
}

function Show-CvGuiInfo {
    <#
        Aviso modal simple. Es el dialogo PROPIO (Show-CvGuiChoice con un solo boton) y no el
        MessageBox del sistema: ese se pinta siempre claro, asi que en modo oscuro era un fogonazo
        blanco en mitad de la ventana.
    #>
    param([string]$Title = 'Setup', [string]$Message = '')
    [void](Show-CvGuiChoice -Title $Title -Message $Message -Name 'cvInfo' -Options @(
        @{
            Value = 'ok'
            Text  = (Get-CvText -Key 'comun.aceptar')
        }
    ))
}

function Show-CvGuiConfirm {
    <#
        Confirmacion modal (Si/No). Devuelve $true si el usuario acepta. El equivalente del
        'Confirmar? (s/N)' de la consola: cerrar con la X o con ESC es NO, para no borrar nada de
        un despiste. Tambien con el dialogo propio, por lo mismo que el aviso.
    #>
    param([string]$Title = 'Confirmar', [string]$Message = '')
    $r = Show-CvGuiChoice -Title $Title -Message $Message -Name 'cvConfirm' -Options @(
        @{
            Value = 'si'
            Text  = (Get-CvText -Key 'comun.si')
        }
        @{
            Value = 'no'
            Text  = (Get-CvText -Key 'comun.no')
        }
    )
    return ("$r" -eq 'si')
}

function Show-CvGuiChoice {
    <#
        Dialogo modal de VARIAS salidas, que es lo que MessageBox no da: mas de tres opciones y con
        el texto que toque en cada boton ('Dejarlos en segundo plano' dice mucho mas que 'Si').
        -Options es la lista de botones en orden, cada uno @{ Value; Text } (y opcionalmente Hint,
        que va de tooltip). Devuelve el Value del pulsado, o '' si se cierra con la X o con Escape:
        quien llama decide que significa eso (normalmente, no hacer nada).

        Los botones van con AutoSize: un ancho fijo corta el texto en cuanto cambia la fuente o el
        DPI (ver ref-gotchas.md), y aqui los textos son largos a proposito.
    #>
    param(
        [string]$Title   = '',
        [string]$Message = '',
        [Parameter(Mandatory)]$Options,
        [string]$Name    = 'cvChoice'
    )
    $opts = @($Options)
    if ($opts.Count -eq 0) { return '' }
    $pick = [pscustomobject]@{ Value = '' }   # hashtable mutable: asignar dentro del manejador crearia una local

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = $Title
    $f.Name            = $Name
    $f.FormBorderStyle = 'FixedDialog'
    $f.StartPosition   = 'CenterParent'
    $f.MinimizeBox     = $false
    $f.MaximizeBox     = $false
    $f.ShowInTaskbar   = $false
    $f.AutoSize        = $true
    $f.AutoSizeMode    = 'GrowAndShrink'

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.AutoSize    = $true
    $grid.Padding     = New-Object System.Windows.Forms.Padding(14)
    $grid.ColumnCount = 1
    $grid.RowCount    = 2
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $f.Controls.Add($grid)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text        = $Message
    $lbl.AutoSize    = $true
    $lbl.MaximumSize = New-Object System.Drawing.Size(560, 0)   # ancho maximo: el alto lo pone el texto
    $lbl.Margin      = New-Object System.Windows.Forms.Padding(3, 3, 3, 14)
    $grid.Controls.Add($lbl, 0, 0)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.AutoSize      = $true
    $flow.FlowDirection = 'LeftToRight'
    $flow.WrapContents  = $false
    $flow.Margin        = New-Object System.Windows.Forms.Padding(0)
    $grid.Controls.Add($flow, 0, 1)

    foreach ($o in $opts) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text         = "$($o.Text)"
        $b.Name         = ("{0}_{1}" -f $Name, $o.Value)
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.Padding      = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
        $b.Margin       = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        if ($o.PSObject.Properties['Hint'] -or ($o -is [System.Collections.IDictionary] -and $o.Contains('Hint'))) {
            $tt = New-Object System.Windows.Forms.ToolTip
            $tt.SetToolTip($b, "$($o.Hint)")
        }
        $val = "$($o.Value)"
        $b.Add_Click({ $pick.Value = $val; $f.Close() }.GetNewClosure())
        $flow.Controls.Add($b)
    }
    [void](Set-CvGuiTheme -Form $f)   # tema de la sesion
    [void]$f.ShowDialog()
    $f.Dispose()
    return "$($pick.Value)"
}

# ===========================================================================
#  TEMA (claro / oscuro)
#
#  WinForms no tiene modo oscuro: cada control se pinta con los colores que le
#  pongas, y unos cuantos (barra de titulo, cabeceras de lista, pestanas, barra
#  de progreso) ni eso -hay que decirselo a Windows o pintarlos a mano-. Todo
#  eso vive AQUI, y cada ventana se limita a llamar a Set-CvGuiTheme al final.
#
#  Los colores NO se escriben en las ventanas: se piden por ROL (fondo, panel,
#  texto, apagado, ok, aviso, error...). Asi un aviso en rojo sigue siendo
#  legible en oscuro, que es lo que no pasa reutilizando el 'Firebrick' de toda
#  la vida sobre un fondo casi negro.
# ===========================================================================

# Lo que hay que pedirle a Windows: la barra de titulo oscura (DWM) y el tema
# oscuro del explorador para listas y arbol (cabeceras y barras de scroll).
Add-Type -Namespace CvGui -Name Native -MemberDefinition @'
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(System.IntPtr hwnd, string app, string idlist);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(System.IntPtr hwnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
'@ -ErrorAction SilentlyContinue

$script:CvGuiTheme   = ''     # tema RESUELTO de esta sesion ('light' / 'dark')
$script:CvGuiPalette = $null  # su paleta ya montada: la piden los Paint, no se rehace cada vez

function Test-CvWindowsDarkMode {
    <# Windows esta en modo oscuro para las aplicaciones? (AppsUseLightTheme del usuario). #>
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$v -eq 0)
    } catch {
        return $false      # sin esa clave (Windows viejo o politica): claro, como siempre
    }
}

function Resolve-CvGuiTheme {
    <#
        PURO. Convierte lo que diga la config (system / light / dark) en el tema REAL: 'light' o
        'dark'. 'system' sigue a Windows (-SystemDark, que sale de Test-CvWindowsDarkMode; se pasa
        aparte para poder probar esto sin tocar el registro). Cualquier otra cosa = claro.
    #>
    param(
        [string]$Theme = 'system',
        [bool]$SystemDark = $false
    )
    switch ("$Theme".ToLower()) {
        'dark'  { return 'dark' }
        'light' { return 'light' }
        default { return $(if ($SystemDark) { 'dark' } else { 'light' }) }
    }
}

function Get-CvGuiPalette {
    <#
        PURO. Los colores POR ROL de un tema. Las ventanas piden roles, no colores: 'Muted' para la
        letra pequena, 'Error'/'Warn'/'Ok' para los avisos, 'Panel' para las cajas de contenido.

          Back   fondo de la ventana          Panel  fondo de listas y cajas de texto
          Fore   texto normal                 Muted  texto secundario (pistas, ayudas)
          Border lineas y separadores         Accent seleccion y barras de progreso
          Ok / Warn / Error                   los tres estados de los mensajes

        En oscuro los tres estados NO son los de siempre (Firebrick / DarkOrange / ForestGreen):
        sobre un fondo casi negro se leen fatal, asi que van sus versiones claras.
    #>
    param([string]$Theme = 'light')
    # Los colores son tipos de System.Drawing: hay que asegurarse de que esta cargado. Sin esto, un
    # lanzador que arranca con -Config (y por tanto no pasa por el selector, que era quien llamaba a
    # Initialize-CvGui) moria aqui con 'No se encuentra el tipo [System.Drawing.Color]' ANTES de
    # abrir ninguna ventana.
    [void](Initialize-CvGui)
    # Solo 'system' pregunta al registro; 'light'/'dark' se resuelven sin tocar nada (esto se llama
    # desde manejadores de Paint, hasta 16 veces por segundo en la barra de progreso animada).
    $nombre = $(if ("$Theme".ToLower() -eq 'system') {
        Resolve-CvGuiTheme -Theme 'system' -SystemDark (Test-CvWindowsDarkMode)
    } else {
        Resolve-CvGuiTheme -Theme $Theme
    })
    if ($nombre -eq 'dark') {
        return @{
            Name       = 'dark'
            Back       = [System.Drawing.Color]::FromArgb(32, 32, 32)
            Panel      = [System.Drawing.Color]::FromArgb(45, 45, 48)
            Fore       = [System.Drawing.Color]::FromArgb(228, 228, 228)
            Muted      = [System.Drawing.Color]::FromArgb(150, 150, 150)
            Border     = [System.Drawing.Color]::FromArgb(80, 80, 85)
            Accent     = [System.Drawing.Color]::FromArgb(0, 120, 215)
            Ok         = [System.Drawing.Color]::FromArgb(106, 190, 106)
            Warn       = [System.Drawing.Color]::FromArgb(230, 170, 60)
            Error      = [System.Drawing.Color]::FromArgb(240, 110, 110)
            Edited     = [System.Drawing.Color]::FromArgb(105, 175, 255)
            IconLight  = $true
        }
    }
    return @{
        Name       = 'light'
        Back       = [System.Drawing.SystemColors]::Control
        Panel      = [System.Drawing.Color]::White
        Fore       = [System.Drawing.Color]::Black
        Muted      = [System.Drawing.Color]::DimGray
        Border     = [System.Drawing.Color]::FromArgb(190, 190, 190)
        Accent     = [System.Drawing.Color]::FromArgb(0, 120, 215)
        Ok         = [System.Drawing.Color]::ForestGreen
        Warn       = [System.Drawing.Color]::DarkOrange
        Error      = [System.Drawing.Color]::Firebrick
        Edited     = [System.Drawing.Color]::FromArgb(0, 70, 170)
        IconLight  = $false
    }
}

function Get-CvGuiRoleColor {
    <# PURO. El color de un rol de mensaje (fore / muted / ok / warn / error) en una paleta. #>
    param(
        [Parameter(Mandatory)]$Palette,
        [string]$Role = 'fore'
    )
    switch ("$Role".ToLower()) {
        'muted' { return $Palette.Muted }
        'ok'    { return $Palette.Ok }
        'warn'  { return $Palette.Warn }
        'error' { return $Palette.Error }
        'edited' { return $Palette.Edited }
        default { return $Palette.Fore }
    }
}

function Set-CvGuiThemeDefault {
    <# Fija el tema de la SESION (lo llaman los lanzadores con lo que diga la config). #>
    param([string]$Theme = 'system')
    $script:CvGuiTheme   = Resolve-CvGuiTheme -Theme $Theme -SystemDark (Test-CvWindowsDarkMode)
    $script:CvGuiPalette = Get-CvGuiPalette -Theme $script:CvGuiTheme
    return $script:CvGuiTheme
}

function Get-CvGuiThemeName {
    <# El tema de esta sesion ya resuelto. Si nadie lo ha fijado, el de Windows. #>
    if ("$script:CvGuiTheme" -eq '') { [void](Set-CvGuiThemeDefault -Theme 'system') }
    return $script:CvGuiTheme
}

function Get-CvGuiCurrentPalette {
    <# La paleta del tema de esta sesion, ya montada (la piden hasta los manejadores de Paint). #>
    if ($null -eq $script:CvGuiPalette) { [void](Set-CvGuiThemeDefault -Theme 'system') }
    return $script:CvGuiPalette
}

function Set-CvGuiWrapLabel {
    <#
        Ata una etiqueta de AYUDA al ancho de su contenedor: usa TODO el ancho disponible y parte en
        las lineas que haga falta en vez de cortarse. Con AutoSize y MaximumSize.Width, WinForms
        envuelve el texto y le da el alto que necesite; el ancho se recalcula al redimensionar la
        ventana (un ancho fijo se queda corto en una ventana ancha y sobra en una estrecha).

        -Gap es lo que se deja por los lados (margen del contenedor).
    #>
    param(
        [Parameter(Mandatory)]$Label,
        [Parameter(Mandatory)]$Container,
        [int]$Gap = 24,
        [int]$Min = 120
    )
    $Label.AutoSize = $true
    $ajustar = {
        $w = [int]$Container.ClientSize.Width - $Gap
        if ($w -lt $Min) { $w = $Min }
        if ([int]$Label.MaximumSize.Width -ne $w) { $Label.MaximumSize = New-Object System.Drawing.Size($w, 0) }
    }.GetNewClosure()
    & $ajustar
    $Container.Add_ClientSizeChanged($ajustar)
    return $Label
}

function Set-CvGuiRole {
    <#
        Marca un control con su ROL de mensaje y le pone el color que le toca AHORA. La marca va en
        AccessibleDescription ('cv-role:error'), que no usamos para nada mas, y sirve para que al
        aplicar el tema no se le pise el color con el del texto normal: un aviso en rojo tiene que
        seguir en rojo en los dos temas.
    #>
    param(
        [Parameter(Mandatory)]$Control,
        [string]$Role = 'muted',
        $Palette = $null
    )
    $pal = $(if ($null -ne $Palette) { $Palette } else { Get-CvGuiCurrentPalette })
    $Control.AccessibleDescription = ("cv-role:{0}" -f "$Role".ToLower())
    $Control.ForeColor = Get-CvGuiRoleColor -Palette $pal -Role $Role
    return $Control
}

function Set-CvGuiThemeControl {
    <#
        Aplica la paleta a un control y a todo lo que cuelga de el. Por TIPO, porque cada uno se
        deja pintar de una manera:

          - listas y arbol: ademas del color, se les pide a Windows el tema oscuro del explorador
            (SetWindowTheme 'DarkMode_Explorer'), que es lo unico que oscurece las CABECERAS de
            columna y las barras de scroll;
          - desplegables: FlatStyle 'Flat', o la flecha se queda blanca;
          - botones: planos con borde del color del tema (los del sistema ignoran el BackColor);
          - menus contextuales: colores + RenderMode 'System' (el 'Professional' mete degradados);
          - NumericUpDown: sus flechitas son un control HIJO, hay que colorearlas aparte.

        Los controles marcados con Set-CvGuiRole conservan SU color (el rojo de un error).
    #>
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)]$Palette
    )
    $oscuro = ("$($Palette.Name)" -eq 'dark')
    $tipo = $Control.GetType().Name
    try {
        switch ($tipo) {
            'TextBox'        {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                # El borde lo dibuja el sistema en claro: en oscuro se quita (el fondo ya lo separa).
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                # Las barras de scroll tambien se oscurecen con el tema del explorador.
                if ($oscuro -and $Control.IsHandleCreated) { [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null) }
            }
            'RichTextBox'    {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($oscuro -and $Control.IsHandleCreated) { [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null) }
            }
            'ListBox'        {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($oscuro -and $Control.IsHandleCreated) { [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null) }
            }
            'ListView'       {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                # La REJILLA y el BORDE los pinta el sistema con sus colores claros y no hay
                # propiedad para cambiarlos: en oscuro la ventana se llenaba de lineas blancas. Se
                # quitan (el contraste entre el fondo de la lista y el de la ventana ya separa las
                # cosas, que es como lo hacen las aplicaciones oscuras de Windows) y se recuerda lo
                # que habia para poder volver a claro.
                if ($oscuro) {
                    if ("$($Control.Tag)" -ne 'cv-grid-off' -and [bool]$Control.GridLines) { $Control.Tag = 'cv-grid-off' }
                    $Control.GridLines = $false
                } else {
                    if ("$($Control.Tag)" -eq 'cv-grid-off') { $Control.GridLines = $true }
                }
                # OJO: aqui NO se toca BorderStyle. Cambiarlo RECREA el control, y al recrearse se
                # pierde el tema oscuro del explorador: la cabecera de columnas volvia a salir
                # BLANCA (comprobado), y volver a pedir el tema despues ya no la recupera. El borde
                # de la lista es una linea fina; la rejilla era lo que llenaba la ventana de blanco.
                if ($oscuro) { [void](Set-CvGuiListDarkPaint -List $Control) }
                else { try { $Control.OwnerDraw = $false } catch { } }
                if ($oscuro -and $Control.IsHandleCreated) { [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null) }
            }
            'TreeView'       {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.LineColor = $Palette.Border
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($oscuro -and $Control.IsHandleCreated) { [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null) }
            }
            'ComboBox'       {
                $Control.FlatStyle = 'Flat'
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                [void](Set-CvGuiRepaintOnResize -Control $Control)
            }
            'NumericUpDown'  {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.BorderStyle = 'FixedSingle'
                foreach ($hijo in @($Control.Controls)) {
                    try { $hijo.BackColor = $Palette.Panel; $hijo.ForeColor = $Palette.Fore } catch { }
                }
            }
            'Button'         {
                $Control.ForeColor = $Palette.Fore
                [void](Set-CvGuiButtonDisabledPaint -Button $Control)
                if ($Control.FlatStyle -eq 'Flat' -and $Control.FlatAppearance.BorderSize -eq 0) {
                    # Boton de barra de herramientas: se funde con la barra, sin caja.
                    $Control.BackColor = $Palette.Back
                } else {
                    $Control.FlatStyle = 'Flat'
                    $Control.BackColor = $Palette.Panel
                    $Control.FlatAppearance.BorderColor = $Palette.Border
                }
            }
            'GroupBox'       {
                # El marco y el titulo de un GroupBox los pinta el sistema en gris claro; en oscuro
                # se repintan (el marco con el color de borde de la paleta).
                $Control.BackColor = $Palette.Back
                $Control.ForeColor = $Palette.Fore
                [void](Set-CvGuiGroupBoxPaint -Box $Control)
            }
            'ProgressBar'    { $Control.ForeColor = $Palette.Accent; $Control.BackColor = $Palette.Panel }
            'Panel'          {
                # Un separador se reconoce por su MARCA, no por su color: cuando se reconocia por el
                # color (ControlDark), la primera pasada del tema se lo cambiaba a 'Border' y la
                # segunda -el tema se aplica otra vez en 'Shown'- ya no lo reconocia y lo pintaba del
                # color del fondo: las lineas de la barra DESAPARECIAN.
                $Control.BackColor = $(if ("$($Control.AccessibleName)" -eq 'cv-sep') { $Palette.Border } else { $Palette.Back })
                # Los paneles que se pintan solos (la tira de pestanas, la barra de progreso) leen
                # la paleta al dibujar: hay que pedirles que se redibujen o se quedan del tema viejo.
                try { $Control.Invalidate() } catch { }
            }
            'Form'           { $Control.BackColor = $Palette.Back; $Control.ForeColor = $Palette.Fore }
            default          {
                # Etiquetas, casillas, paneles de rejilla, pestanas...: fondo y texto y ya.
                try { $Control.BackColor = $Palette.Back } catch { }
                try { $Control.ForeColor = $Palette.Fore } catch { }
            }
        }
        # Un control con ROL conserva SU color (el aviso rojo sigue rojo).
        $marca = "$($Control.AccessibleDescription)"
        if ($marca -like 'cv-role:*') {
            $Control.ForeColor = Get-CvGuiRoleColor -Palette $Palette -Role ($marca -replace '^cv-role:', '')
        }
        # Menu contextual colgado del control (la lista de la cola, el resumen...).
        if ($Control.ContextMenuStrip) { [void](Set-CvGuiMenuTheme -Menu $Control.ContextMenuStrip -Palette $Palette) }
    } catch { }
    foreach ($hijo in @($Control.Controls)) { [void](Set-CvGuiThemeControl -Control $hijo -Palette $Palette) }
    return $Control
}

function New-CvGuiSeparator {
    <#
        Linea vertical para separar grupos de botones en una barra (lo que en una barra de verdad es
        la rayita gris). Va MARCADA (AccessibleName) para que el tema la pinte con el color de borde
        en vez de con el del fondo.
    #>
    param(
        [int]$Height = 20,
        [int]$MarginX = 12
    )
    $sep = New-Object System.Windows.Forms.Panel
    $sep.AccessibleName = 'cv-sep'
    $sep.Width     = 1
    $sep.Height    = $Height
    $sep.BackColor = (Get-CvGuiCurrentPalette).Border
    $sep.Margin    = New-Object System.Windows.Forms.Padding($MarginX, 5, $MarginX, 5)
    return $sep
}

function Set-CvGuiSplitGrip {
    <#
        Le pinta el AGARRE a un divisor (la linea con tres puntos de toda la vida) y lo ensancha para
        que haya donde pinchar. Un divisor de serie es una franja del color del fondo: se puede
        arrastrar, pero nadie lo descubre — paso en la cola y volvio a pasar con el arbol del editor
        de configuracion, donde parecia que el reparto era fijo.

        Vale para las dos orientaciones. Se repinta al soltarlo, porque el agarre va en su sitio nuevo.
    #>
    param(
        [Parameter(Mandatory)]$Split,
        [string]$Tooltip = '',
        [int]$Width = 10
    )
    $Split.SplitterWidth = $Width
    if ("$($Split.AccessibleName)" -eq 'cv-grip') { return $Split }
    $Split.AccessibleName = 'cv-grip'
    $Split.Add_Paint({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            $pen = New-Object System.Drawing.Pen $pal.Border
            $br  = New-Object System.Drawing.SolidBrush $pal.Muted
            if ("$($s.Orientation)" -eq 'Horizontal') {
                $cy = $s.SplitterDistance + [int]($s.SplitterWidth / 2)
                $cx = [int]($s.Width / 2)
                $e.Graphics.DrawLine($pen, 0, $cy, ($cx - 32), $cy)
                $e.Graphics.DrawLine($pen, ($cx + 32), $cy, $s.Width, $cy)
                for ($i = -3; $i -le 3; $i++) { $e.Graphics.FillRectangle($br, ($cx + ($i * 8)), ($cy - 1), 3, 3) }
            } else {
                $cx = $s.SplitterDistance + [int]($s.SplitterWidth / 2)
                $cy = [int]($s.Height / 2)
                $e.Graphics.DrawLine($pen, $cx, 0, $cx, ($cy - 32))
                $e.Graphics.DrawLine($pen, $cx, ($cy + 32), $cx, $s.Height)
                for ($i = -3; $i -le 3; $i++) { $e.Graphics.FillRectangle($br, ($cx - 1), ($cy + ($i * 8)), 3, 3) }
            }
            $pen.Dispose()
            $br.Dispose()
        } catch { }
    })
    $Split.Add_SplitterMoved({ param($s, $e) try { $s.Invalidate() } catch { } })
    # Y tambien al cambiar de TAMANO: el agarre va en el centro del divisor, asi que al redimensionar
    # la ventana le toca otro sitio. WinForms solo repinta lo que se acaba de descubrir, asi que sin
    # esto los puntos se quedaban en el hueco viejo (o sea: desaparecian).
    $Split.Add_Resize({ param($s, $e) try { $s.Invalidate() } catch { } })
    if ("$Tooltip" -ne '') {
        $tip = New-Object System.Windows.Forms.ToolTip
        $tip.SetToolTip($Split, $Tooltip)
    }
    return $Split
}

function Set-CvGuiRepaintOnResize {
    <#
        Repinta un control ENTERO cada vez que cambia de tamano.

        Hace falta en los desplegables PLANOS (FlatStyle 'Flat', que es como se oscurecen): la flecha
        la dibuja WinForms y, al estirarse el control, no repinta lo que ocupaba antes — queda una
        flecha FANTASMA en el ancho viejo. Pasa en el editor de config, donde el combo nace con su
        ancho de serie (121 px) y lo estira el divisor en 'Shown'; al desplegarlo se repinta entero y
        ya no vuelve, que es justo lo que despista al buscarlo.

        La marca (AccessibleName) evita engancharlo dos veces: el tema se aplica al montar la ventana
        y otra vez en 'Shown'.
    #>
    param([Parameter(Mandatory)]$Control)
    if ("$($Control.AccessibleName)" -eq 'cv-repaint') { return $Control }
    $Control.AccessibleName = 'cv-repaint'
    $Control.Add_Resize({ param($s, $e) try { $s.Invalidate() } catch { } })
    return $Control
}

function Set-CvGuiButtonDisabledPaint {
    <#
        Repinta el rotulo de un boton DESACTIVADO. WinForms lo dibuja con el gris del sistema y no
        hay propiedad que lo cambie: sobre un fondo oscuro sale casi negro y no se lee (paso con el
        'Iniciar' de la barra mientras hay workers en marcha).

        Solo hace falta en oscuro: se pinta el fondo, la imagen atenuada y el texto con el color
        'apagado' de la paleta, respetando la alineacion que tenga el boton.
    #>
    param([Parameter(Mandatory)]$Button)
    if ("$($Button.AccessibleDescription)" -eq 'cv-btn-off') { return $Button }   # ya tiene el pintor
    $Button.AccessibleDescription = 'cv-btn-off'
    $Button.Add_Paint({
        param($s, $e)
        try {
            if ($s.Enabled) { return }
            $pal = Get-CvGuiCurrentPalette
            if ("$($pal.Name)" -ne 'dark') { return }
            $br = New-Object System.Drawing.SolidBrush $s.BackColor
            $e.Graphics.FillRectangle($br, $s.ClientRectangle)
            $br.Dispose()
            $x = [int]$s.Padding.Left
            if ($null -ne $s.Image) {
                # La imagen, a media tinta: es la senal de que el boton no esta disponible.
                $m = New-Object System.Drawing.Imaging.ColorMatrix
                $m.Matrix33 = 0.45
                $ia = New-Object System.Drawing.Imaging.ImageAttributes
                $ia.SetColorMatrix($m)
                $iy = [int](($s.Height - $s.Image.Height) / 2)
                $dst = New-Object System.Drawing.Rectangle($x, $iy, $s.Image.Width, $s.Image.Height)
                $e.Graphics.DrawImage($s.Image, $dst, 0, 0, $s.Image.Width, $s.Image.Height,
                    [System.Drawing.GraphicsUnit]::Pixel, $ia)
                $ia.Dispose()
                $x += $s.Image.Width + 4
            }
            $al = "$($s.TextAlign)"
            $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter
            if ($al -like '*Left*')       { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Left }
            elseif ($al -like '*Right*')  { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
            else                          { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
            $r = New-Object System.Drawing.Rectangle($x, 0, [Math]::Max(0, ($s.Width - $x - [int]$s.Padding.Right)), $s.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($s.Text)", $s.Font, $r, $pal.Muted, $flags)
        } catch { }
    })
    # Al cambiar de estado hay que repintar, o se queda el rotulo del sistema.
    $Button.Add_EnabledChanged({ param($s, $e) try { $s.Invalidate() } catch { } })
    return $Button
}

function Get-CvGuiFillColumnWidth {
    <#
        PURO. Lo que le toca a la columna que se queda con el hueco que sobra en una lista.
        -ClientWidth es el ancho util (sin la barra de scroll) y -OtherWidths la suma de las demas.
        Nunca baja de -Min: con la ventana muy estrecha es preferible que salga scroll horizontal a
        que esa columna quede en dos caracteres.
    #>
    param([int]$ClientWidth, [int]$OtherWidths, [int]$Min = 120)
    # Sin respiro: las columnas llegan JUSTO al borde. Se dejaban 4 px "por si sale scroll", y lo que
    # salia era una franja de cabecera de 4 px que el sistema pinta en blanco. Medido (con el estilo
    # WS_HSCROLL de la lista, no a ojo): con 0 no aparece scroll horizontal, y con 4 quedaban 4
    # pixeles claros a la derecha.
    $w = $ClientWidth - $OtherWidths
    if ($w -lt $Min) { return $Min }
    return $w
}

function Set-CvGuiListFillColumn {
    <#
        Hace que una columna se quede con el hueco sobrante, al abrir y al cambiar el tamano.

        Ademas de aprovechar el ancho, quita el trozo de CABECERA que queda MAS ALLA de la ultima
        columna: ese pedazo no pertenece a ninguna, lo pinta Windows con su gris claro y no hay
        evento donde meter mano -probado incluso a quitar el recorte del dibujo (ResetClip) desde la
        cabecera de la ultima columna: no se llega-. Si las columnas cubren el ancho, no hay trozo.
    #>
    param(
        [Parameter(Mandatory)]$List,
        [int]$Index = 0,
        [int]$Min = 120
    )
    # GetNewClosure: esto se registra desde AQUI, y cuando salte el evento esta funcion ya habra
    # terminado; sin el, $List y $Index ya no existen y no se ajusta nada.
    $ajustar = {
        try {
            if ($List.Columns.Count -le $Index) { return }
            $otras = 0
            for ($i = 0; $i -lt $List.Columns.Count; $i++) {
                if ($i -ne $Index) { $otras += $List.Columns[$i].Width }
            }
            $w = Get-CvGuiFillColumnWidth -ClientWidth $List.ClientSize.Width -OtherWidths $otras -Min $Min
            if ($List.Columns[$Index].Width -ne $w) { $List.Columns[$Index].Width = $w }
        } catch { }
    }.GetNewClosure()
    $List.Add_Resize($ajustar)
    & $ajustar
    return $List
}

function Set-CvGuiListDarkPaint {
    <#
        Pinta la lista ENTERA en oscuro: cabecera y filas.

        La cabecera es lo unico que no se puede oscurecer de otra forma -medido una a una: ni los
        colores ni SetWindowTheme, sobre la lista o sobre el propio control de cabecera, la cambian;
        se queda en el gris claro del sistema-, y eso obliga a OwnerDraw.

        Y en cuanto se toma OwnerDraw hay que pintar TAMBIEN las filas. Dejarlas en 'DrawDefault'
        -que es lo que dice el ejemplo tipico para tocar solo la cabecera- rompe la lista: al
        refrescar, las filas dejan de pintarse y la lista se queda medio vacia, con suerte solo la
        marcada (pasa de verdad, y de forma aleatoria, porque depende de que trozo se invalide).

        En las listas con CASILLAS (las pistas del editor de jobs) hay que dibujar tambien el
        cuadradito, porque con OwnerDraw deja de pintarlo el control: se le pide a Windows el mismo
        que pinta en una casilla suelta (CheckBoxRenderer), que es el que ya se ve en el resto de la
        ventana en oscuro. Marcar y desmarcar lo sigue llevando la lista: OwnerDraw solo cambia lo
        que se PINTA, no donde se puede pulsar.
    #>
    param([Parameter(Mandatory)]$List)
    if ("$($List.AccessibleDescription)" -eq 'cv-list-dark') { $List.OwnerDraw = $true; return $List }
    $List.AccessibleDescription = 'cv-list-dark'
    $List.OwnerDraw = $true

    $List.Add_DrawColumnHeader({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            if ("$($pal.Name)" -ne 'dark') { $e.DrawDefault = $true; return }
            $br = New-Object System.Drawing.SolidBrush $pal.Panel
            $e.Graphics.FillRectangle($br, $e.Bounds)
            $br.Dispose()
            # Separador de columna y linea inferior, para que se siga leyendo como una cabecera.
            $pen = New-Object System.Drawing.Pen $pal.Border
            $e.Graphics.DrawLine($pen, ($e.Bounds.Right - 1), ($e.Bounds.Top + 4), ($e.Bounds.Right - 1), ($e.Bounds.Bottom - 4))
            $e.Graphics.DrawLine($pen, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
            $pen.Dispose()
            # Margen de 2 px: con columnas estrechas (la de 'Bordes'), 4 se comian el texto.
            $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 2), $e.Bounds.Y, ($e.Bounds.Width - 3), $e.Bounds.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($e.Header.Text)", $e.Font, $r, $pal.Fore,
                ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
        } catch { $e.DrawDefault = $true }
    })

    # En vista 'Details' las filas se pintan por SUBITEM; DrawItem no pinta nada (si se deja en
    # DrawDefault vuelve el problema de las filas que desaparecen).
    $List.Add_DrawItem({ param($s, $e) })
    $List.Add_DrawSubItem({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            if ("$($pal.Name)" -ne 'dark') { $e.DrawDefault = $true; return }
            # La celda: para la primera columna, Bounds devuelve la FILA entera (es asi desde
            # siempre en WinForms), asi que se recorta al ancho de su columna.
            $r = $e.Bounds
            if ($e.ColumnIndex -eq 0) {
                $r = New-Object System.Drawing.Rectangle($e.Item.Bounds.X, $e.Item.Bounds.Y, $s.Columns[0].Width, $e.Item.Bounds.Height)
            }
            $fondo = $(if ($e.Item.Selected) { $pal.Accent } else { $pal.Panel })
            # El color de la FILA, no el del tema: si alguien le ha puesto uno (las filas de solo
            # lectura de la ventana de perfiles van en gris), aqui se respeta. Sin tocar nada,
            # Item.ForeColor ya devuelve el de la lista, que es el del tema.
            $texto = $(if ($e.Item.Selected) { [System.Drawing.Color]::White } else { $e.Item.ForeColor })
            $br = New-Object System.Drawing.SolidBrush $fondo
            $e.Graphics.FillRectangle($br, $r)
            $br.Dispose()
            $al = "$($s.Columns[$e.ColumnIndex].TextAlign)"
            $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            if ($al -eq 'Right')       { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
            elseif ($al -eq 'Center')  { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
            else                       { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Left }
            $margen = 2
            if ($e.ColumnIndex -eq 0 -and [bool]$s.CheckBoxes) {
                $tam = [System.Windows.Forms.CheckBoxRenderer]::GetGlyphSize($e.Graphics, [System.Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal)
                $cy  = $r.Y + [int](($r.Height - $tam.Height) / 2)
                $est = $(if ($e.Item.Checked) {
                    [System.Windows.Forms.VisualStyles.CheckBoxState]::CheckedNormal
                } else {
                    [System.Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal
                })
                [System.Windows.Forms.CheckBoxRenderer]::DrawCheckBox($e.Graphics, (New-Object System.Drawing.Point(($r.X + 4), $cy)), $est)
                $margen = $tam.Width + 8
            }
            $rt = New-Object System.Drawing.Rectangle(($r.X + $margen), $r.Y, [Math]::Max(0, ($r.Width - $margen - 2)), $r.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($e.SubItem.Text)", $s.Font, $rt, $texto, $flags)
        } catch { $e.DrawDefault = $true }
    })
    return $List
}

function Set-CvGuiGroupBoxPaint {
    <#
        Repinta el marco de un GroupBox. WinForms lo dibuja con el gris del sistema (y el titulo con
        el color de texto del sistema), asi que en oscuro queda un recuadro claro alrededor de cada
        seccion del editor de jobs. Se pinta el marco con el color de borde y el titulo con el de
        texto de la paleta.
    #>
    param([Parameter(Mandatory)]$Box)
    if ("$($Box.AccessibleDescription)" -eq 'cv-box-dark') { return $Box }
    $Box.AccessibleDescription = 'cv-box-dark'
    $Box.Add_Paint({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            if ("$($pal.Name)" -ne 'dark') { return }
            $br = New-Object System.Drawing.SolidBrush $s.BackColor
            $e.Graphics.FillRectangle($br, $s.ClientRectangle)
            $br.Dispose()
            $tam = [System.Windows.Forms.TextRenderer]::MeasureText("$($s.Text)", $s.Font)
            $y   = [int]($tam.Height / 2)
            $pen = New-Object System.Drawing.Pen $pal.Border
            $e.Graphics.DrawRectangle($pen, 0, $y, ($s.Width - 1), ($s.Height - $y - 1))
            $pen.Dispose()
            if ("$($s.Text)" -ne '') {
                $hueco = New-Object System.Drawing.Rectangle(8, 0, ($tam.Width + 6), $tam.Height)
                $br2 = New-Object System.Drawing.SolidBrush $s.BackColor
                $e.Graphics.FillRectangle($br2, $hueco)
                $br2.Dispose()
                [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($s.Text)", $s.Font,
                    (New-Object System.Drawing.Point(11, 0)), $pal.Fore)
            }
        } catch { }
    })
    return $Box
}

function Set-CvGuiMenuTheme {
    <# Menu contextual con los colores del tema (RenderMode System: el otro pinta degradados claros). #>
    param(
        [Parameter(Mandatory)]$Menu,
        [Parameter(Mandatory)]$Palette
    )
    try {
        $Menu.RenderMode = 'System'
        $Menu.BackColor  = $Palette.Panel
        $Menu.ForeColor  = $Palette.Fore
        foreach ($it in @($Menu.Items)) {
            try { $it.BackColor = $Palette.Panel; $it.ForeColor = $Palette.Fore } catch { }
        }
    } catch { }
    return $Menu
}

function Get-CvGuiTabLayout {
    <#
        PURO. Reparte la fila de pestanas: dado el ANCHO del rotulo de cada una, donde empieza y
        cuanto ocupa. Se separa del dibujo para poder probarlo sin ventana.
    #>
    param(
        [int[]]$Widths = @(),
        [int]$PadX = 12,
        [int]$Gap = 2,
        [int]$Start = 2
    )
    $res = @()
    $x = $Start
    foreach ($w in $Widths) {
        $ancho = [int]$w + (2 * $PadX)
        $res += @{
            X     = $x
            Width = $ancho
        }
        $x += $ancho + $Gap
    }
    # Sin la coma: cada pestana es un hashtable (no se desenrolla), y devolverlas sueltas evita el
    # array DENTRO de un array que sale al envolver la salida con @().
    return $res
}

function Get-CvGuiTabHit {
    <# PURO. Que pestana cae bajo una X (-1 si ninguna). #>
    param(
        $Rects = @(),
        [int]$X = 0
    )
    $lista = @($Rects)
    for ($i = 0; $i -lt $lista.Count; $i++) {
        if ($X -ge [int]$lista[$i].X -and $X -lt ([int]$lista[$i].X + [int]$lista[$i].Width)) { return $i }
    }
    return -1
}

function New-CvGuiTabs {
    <#
        Pestanas PROPIAS, sin TabControl. El de WinForms no se puede oscurecer: medido una a una, la
        TIRA que queda a la derecha de las pestanas y el MARCO del contenido salen en 240,240,240
        hagas lo que hagas -colores, SetWindowTheme vacio, Appearance Buttons/FlatButtons-, y lo
        unico que quedaba era taparlos con paneles encima, que es lo que se destapaba en cuanto la
        ventana cambiaba de tamano. Aqui la tira es un panel que se pinta entero con la paleta, asi
        que no hay nada claro que tapar; en claro se ve como siempre.

        Devuelve el CONTENEDOR (fila de pestanas arriba, paginas debajo). Las paginas se anaden con
        Add-CvGuiTab, se cambia con Select-CvGuiTab y se escucha con Add-CvGuiTabChanged.
    #>
    param([string]$Name = 'cvTabs')
    $caja = New-Object System.Windows.Forms.TableLayoutPanel
    $caja.Name        = $Name
    $caja.Dock        = 'Fill'
    $caja.ColumnCount = 1
    $caja.RowCount    = 2
    [void]$caja.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$caja.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $tira = New-Object System.Windows.Forms.Panel
    $tira.Name   = ("{0}Strip" -f $Name)
    $tira.Dock   = 'Fill'
    $tira.Margin = New-Object System.Windows.Forms.Padding(0)
    $tira.Cursor = [System.Windows.Forms.Cursors]::Hand
    $caja.Controls.Add($tira, 0, 0)

    $zona = New-Object System.Windows.Forms.Panel
    $zona.Name   = ("{0}Zone" -f $Name)
    $zona.Dock   = 'Fill'
    $zona.Margin = New-Object System.Windows.Forms.Padding(0)
    $caja.Controls.Add($zona, 0, 1)

    $caja.Tag = @{
        Kind     = 'cv-tabs'
        Strip    = $tira
        Zone     = $zona
        Pages    = @()
        Texts    = @()
        Rects    = @()
        Index    = -1
        Hover    = -1
        OnChange = @()
    }

    # OJO: los manejadores llevan GetNewClosure porque se disparan cuando ESTA funcion ya ha
    # terminado; sin el, $caja ya no existe y se quedan sin hacer nada (callado, porque va en un try).
    $tira.Add_Paint({
        param($s, $e)
        try {
            $t   = $caja.Tag
            $pal = Get-CvGuiCurrentPalette
            $g   = $e.Graphics
            $g.Clear($pal.Back)
            $anchos = @()
            foreach ($tx in @($t.Texts)) {
                $anchos += [System.Windows.Forms.TextRenderer]::MeasureText($g, "$tx", $s.Font).Width
            }
            $t.Rects = @(Get-CvGuiTabLayout -Widths $anchos)
            $alto = $s.ClientSize.Height
            $pen  = New-Object System.Drawing.Pen $pal.Border
            # Linea de base a lo ancho: separa las pestanas del contenido. Bajo la pestana activa se
            # tapa despues, que es lo que la hace leerse como una carpeta abierta.
            $g.DrawLine($pen, 0, ($alto - 1), $s.ClientSize.Width, ($alto - 1))
            $rects = @($t.Rects)
            for ($i = 0; $i -lt $rects.Count; $i++) {
                $caj = New-Object System.Drawing.Rectangle([int]$rects[$i].X, 0, [int]$rects[$i].Width, $alto)
                if ($i -eq [int]$t.Index) {
                    $br = New-Object System.Drawing.SolidBrush $pal.Back
                    $g.FillRectangle($br, $caj)
                    $br.Dispose()
                    $brA = New-Object System.Drawing.SolidBrush $pal.Accent
                    $g.FillRectangle($brA, (New-Object System.Drawing.Rectangle($caj.X, 0, $caj.Width, 2)))
                    $brA.Dispose()
                    $g.DrawLine($pen, $caj.X, 1, $caj.X, ($alto - 1))
                    $g.DrawLine($pen, ($caj.Right - 1), 1, ($caj.Right - 1), ($alto - 1))
                }
                $color = $(if ($i -eq [int]$t.Index -or $i -eq [int]$t.Hover) { $pal.Fore } else { $pal.Muted })
                [System.Windows.Forms.TextRenderer]::DrawText($g, "$(@($t.Texts)[$i])", $s.Font, $caj, $color,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
            }
            $pen.Dispose()
        } catch { }
    }.GetNewClosure())

    $tira.Add_MouseDown({
        param($s, $e)
        try {
            $i = Get-CvGuiTabHit -Rects $caja.Tag.Rects -X $e.X
            if ($i -ge 0) { [void](Select-CvGuiTab -Tabs $caja -Index $i) }
        } catch { }
    }.GetNewClosure())

    $tira.Add_MouseMove({
        param($s, $e)
        try {
            $i = Get-CvGuiTabHit -Rects $caja.Tag.Rects -X $e.X
            # Solo se repinta si CAMBIA la pestana senalada: si no, parpadea con cada movimiento.
            if ($i -ne [int]$caja.Tag.Hover) { $caja.Tag.Hover = $i; $s.Invalidate() }
        } catch { }
    }.GetNewClosure())

    $tira.Add_MouseLeave({
        param($s, $e)
        try {
            if ([int]$caja.Tag.Hover -ne -1) { $caja.Tag.Hover = -1; $s.Invalidate() }
        } catch { }
    }.GetNewClosure())

    return $caja
}

function Add-CvGuiTab {
    <#
        Anade una pagina y devuelve el PANEL donde va su contenido. La primera que se anade queda
        seleccionada.
    #>
    param(
        [Parameter(Mandatory)]$Tabs,
        [Parameter(Mandatory)][string]$Text,
        [int]$Padding = 4
    )
    $t = $Tabs.Tag
    $pag = New-Object System.Windows.Forms.Panel
    $pag.Name    = ("{0}Page{1}" -f $Tabs.Name, (@($t.Pages).Count + 1))
    $pag.Dock    = 'Fill'
    $pag.Padding = New-Object System.Windows.Forms.Padding($Padding)
    $pag.Visible = $false
    $t.Zone.Controls.Add($pag)
    $t.Pages = @($t.Pages) + @($pag)
    $t.Texts = @($t.Texts) + @("$Text")
    # El alto de la fila sale de la FUENTE: con otro DPI o una fuente mayor, 24 px se quedaban
    # cortos y el rotulo se cortaba por abajo.
    try {
        $alto = [System.Windows.Forms.TextRenderer]::MeasureText('Xg', $t.Strip.Font).Height + 8
        $Tabs.RowStyles[0].Height = [Math]::Max(24, $alto)
    } catch { }
    if (@($t.Pages).Count -eq 1) { [void](Select-CvGuiTab -Tabs $Tabs -Index 0) }
    return $pag
}

function Select-CvGuiTab {
    <# Cambia de pestana (por indice o por pagina) y avisa a quien lo haya pedido. #>
    param(
        [Parameter(Mandatory)]$Tabs,
        [int]$Index = -1,
        $Page = $null
    )
    $t = $Tabs.Tag
    $pags = @($t.Pages)
    if ($null -ne $Page) {
        for ($i = 0; $i -lt $pags.Count; $i++) { if ($pags[$i] -eq $Page) { $Index = $i } }
    }
    if ($Index -lt 0 -or $Index -ge $pags.Count -or $Index -eq [int]$t.Index) { return $Tabs }
    $t.Index = $Index
    for ($i = 0; $i -lt $pags.Count; $i++) {
        $pags[$i].Visible = ($i -eq $Index)
        if ($i -eq $Index) { $pags[$i].BringToFront() }
    }
    try { $t.Strip.Invalidate() } catch { }
    foreach ($acc in @($t.OnChange)) {
        try { & $acc } catch { }
    }
    return $Tabs
}

function Get-CvGuiTabPage {
    <# La pagina que se esta viendo (null si aun no hay ninguna). #>
    param([Parameter(Mandatory)]$Tabs)
    $t = $Tabs.Tag
    if ([int]$t.Index -lt 0) { return $null }
    return @($t.Pages)[[int]$t.Index]
}

function Add-CvGuiTabChanged {
    <#
        Registra algo que hacer al cambiar de pestana. OJO: el bloque se ejecuta desde otra funcion,
        asi que si usa variables de la ventana tiene que pasarse con .GetNewClosure().
    #>
    param(
        [Parameter(Mandatory)]$Tabs,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $t = $Tabs.Tag
    $t.OnChange = @($t.OnChange) + @($Action)
    return $Tabs
}

function Set-CvGuiTheme {
    <#
        Aplica el tema a una ventana ENTERA, justo antes de ensenarla: colores por control, barra de
        titulo oscura (DWM), las cabeceras de lista y barras de scroll en oscuro, y el icono de la
        aplicacion (que no depende del tema, pero este es el sitio por el que pasan todas).

        -Theme es lo que diga la config ('system' / 'light' / 'dark'); sin el, el de la sesion. La
        barra de titulo se pide en Shown ademas de ahora: antes de que la ventana tenga handle, DWM
        no tiene a quien aplicarselo.
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [string]$Theme = ''
    )
    $nombre = $(if ("$Theme" -ne '') { Set-CvGuiThemeDefault -Theme $Theme } else { Get-CvGuiThemeName })
    $pal = Get-CvGuiPalette -Theme $nombre
    # El icono de la aplicacion se pone aqui porque es el unico sitio por el que pasan TODAS las
    # ventanas; no depende del tema (es el mismo en claro y en oscuro).
    [void](Set-CvGuiAppIcon -Form $Form)
    [void](Set-CvGuiThemeControl -Control $Form -Palette $pal)
    $oscuro = ($nombre -eq 'dark')
    $poner = {
        try {
            $uno = [int]$(if ($oscuro) { 1 } else { 0 })
            # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 1809+); 19 en las primeras builds.
            if ([CvGui.Native]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$uno, 4) -ne 0) {
                [void][CvGui.Native]::DwmSetWindowAttribute($Form.Handle, 19, [ref]$uno, 4)
            }
            # Si la ventana ya estaba dibujada, el atributo no se ve hasta que se rehace el MARCO:
            # SWP_NOMOVE|NOSIZE|NOZORDER|FRAMECHANGED (sin esto, la barra de titulo se quedaba clara
            # con la ventana oscura, que es justo lo que canta).
            [void][CvGui.Native]::SetWindowPos($Form.Handle, [System.IntPtr]::Zero, 0, 0, 0, 0, 0x0027)
        } catch { }
    }
    # Cuanto ANTES, mejor: en Windows 10 la barra de titulo oscura se aplica limpia si se pide antes
    # de que la ventana se dibuje. Si ya tiene handle se pide ahora (y el SetWindowPos de arriba
    # rehace el marco); si no, en cuanto lo tenga.
    if ($Form.IsHandleCreated) { & $poner }
    else { $Form.Add_HandleCreated({ & $poner }.GetNewClosure()) }
    $Form.Add_Shown({
        & $poner
        # Las listas y el arbol solo aceptan el tema del explorador cuando ya tienen handle.
        [void](Set-CvGuiThemeControl -Control $Form -Palette $pal)
    }.GetNewClosure())
    return $pal
}

function New-CvGuiProgressPanel {
    <#
        Barra de progreso PINTADA a mano. La del sistema ignora los colores (la dibuja Windows), asi
        que en oscuro se queda como una franja clara; esta se pinta con el color de acento del tema y
        vale para los dos.

        Se maneja con Set-CvGuiProgressValue (0-100) o, con -Marquee, se mueve sola mientras se
        analiza algo (es un temporizador propio: acuerdate de Stop-CvGuiProgress al cerrar).
    #>
    param(
        [switch]$Marquee,
        [string]$Name = 'cvProgress'
    )
    $pb = New-Object System.Windows.Forms.Panel
    $pb.Name = $Name
    $pb.Tag  = @{ Percent = 0; Marquee = [bool]$Marquee; Pos = 0; Timer = $null }
    $pb.Add_Paint({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            $est = $s.Tag
            $br  = New-Object System.Drawing.SolidBrush $pal.Panel
            $e.Graphics.FillRectangle($br, (New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)))
            $br.Dispose()
            $brA = New-Object System.Drawing.SolidBrush $pal.Accent
            if ([bool]$est.Marquee) {
                $w = [int]($s.Width / 5)
                $x = [int]$est.Pos
                $e.Graphics.FillRectangle($brA, (New-Object System.Drawing.Rectangle($x, 0, $w, $s.Height)))
            } else {
                $w = [int]($s.Width * [Math]::Max(0, [Math]::Min(100, [int]$est.Percent)) / 100)
                if ($w -gt 0) { $e.Graphics.FillRectangle($brA, (New-Object System.Drawing.Rectangle(0, 0, $w, $s.Height))) }
            }
            $brA.Dispose()
            $pen = New-Object System.Drawing.Pen $pal.Border
            $e.Graphics.DrawRectangle($pen, (New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))))
            $pen.Dispose()
        } catch { }
    })
    if ($Marquee) {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 60
        $t.Add_Tick({
            try {
                $est = $pb.Tag
                $paso = [Math]::Max(4, [int]($pb.Width / 40))
                $est.Pos = [int]$est.Pos + $paso
                if ([int]$est.Pos -gt $pb.Width) { $est.Pos = -[int]($pb.Width / 5) }
                $pb.Invalidate()
            } catch { }
        }.GetNewClosure())
        $est = $pb.Tag
        $est.Timer = $t
        $t.Start()
    }
    return $pb
}

function Set-CvGuiProgressValue {
    <# Porcentaje (0-100) de una barra de New-CvGuiProgressPanel. #>
    param(
        [Parameter(Mandatory)]$Bar,
        [int]$Percent = 0
    )
    try {
        $est = $Bar.Tag
        $est.Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        $Bar.Invalidate()
    } catch { }
    return $Bar
}

function Stop-CvGuiProgress {
    <# Para la animacion de una barra -Marquee (al cerrar la ventana o al terminar el analisis). #>
    param([Parameter(Mandatory)]$Bar)
    try {
        $est = $Bar.Tag
        if ($null -ne $est.Timer) { $est.Timer.Stop(); $est.Timer.Dispose(); $est.Timer = $null }
        $est.Marquee = $false
        $Bar.Invalidate()
    } catch { }
    return $Bar
}

# ===========================================================================
#  Piezas que comparten VARIAS ventanas (antes estaban copiadas en cada una)
# ===========================================================================

function Update-CvGuiLogView {
    <#
        Vuelca un log en un cuadro de texto y lo mantiene al dia SIN parpadear. Lo usan la pestana
        'Log' de la cola y la ventana del proceso de un worker, que hacian esto mismo cada una por su
        lado -con lo que un arreglo aqui habia que acordarse de hacerlo dos veces-.

        La gracia esta en las dos comprobaciones: se relee el fichero SOLO si ha cambiado (huella de
        Get-CvFileStamp) y se repinta SOLO si el texto es otro. Sin eso, volcar lo mismo cada segundo
        hace parpadear el panel y salta el scroll mientras se intenta leer algo.

        Del fichero se leen los ultimos -MaxKb (el rabo es lo que interesa de un log en marcha, y asi
        no se lee un fichero de decenas de MB cada vez); el texto sale de Get-CvSetupLogText, que es
        quien sabe leer un log EN USO y colapsar los repintados de la barra de progreso.

        -State es un hashtable del llamador donde se guarda la huella (-Key, por si el mismo estado
        sigue dos paneles). Devuelve $true si ha repintado.
    #>
    param(
        [Parameter(Mandatory)]$TextBox,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowEmptyString()][string]$Path = '',
        [string]$Key = 'LogStamp',
        [bool]$Follow = $true,
        [int]$MaxKb = 128,
        # Que poner cuando no hay log que seguir (p. ej. un worker que corrio con behavior.log off).
        [string]$EmptyText = ''
    )
    if ("$Path" -eq '') {
        $State[$Key] = ''
        if ($TextBox.Text -ne $EmptyText) { $TextBox.Text = $EmptyText; return $true }
        return $false
    }
    $stamp = Get-CvFileStamp -Path $Path
    if ($stamp -eq "$($State[$Key])") { return $false }
    $State[$Key] = $stamp
    $texto = Get-CvSetupLogText -Path $Path -MaxKb $MaxKb
    if ($texto -eq $TextBox.Text) { return $false }
    $TextBox.Text = $texto
    if ($Follow) {
        $TextBox.SelectionStart  = $TextBox.TextLength
        $TextBox.SelectionLength = 0
        $TextBox.ScrollToCaret()
    }
    return $true
}

function New-CvGuiCatalogCombo {
    <#
        Desplegable a partir de un catalogo @{Value;Text} (los del repo: encoders, codecs, canales,
        modos...). Los VALORES se guardan en el Tag del propio control, asi que se lee lo elegido con
        Get-CvGuiComboValue sin volver a parsear la etiqueta y CONSERVANDO EL TIPO (un 6 sigue siendo
        entero, un $false sigue siendo booleano).

        Y lo importante: si -Current no esta en el catalogo, se ANADE como una entrada mas y se deja
        elegida. Un valor legitimo que no salga en la lista -el encoder ya resuelto de un perfil
        'auto', un level de otra familia de codec- no puede convertirse en otro solo por abrir el
        dialogo. Eso paso de verdad: caia en la primera entrada y el job se guardaba en 'copy'.

        -EmptyText anade delante una entrada "sin valor" (''), que es como se dice "usa el global".
    #>
    param(
        $Items = @(),
        $Current = $null,
        [string]$EmptyText = '',
        [string]$Name = '',
        [string]$CurrentText = '{0}  -  (el del perfil)',
        [string]$Format = '{0}  -  {1}',
        [int]$FontSize = 9
    )
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Font          = (New-CvGuiFont $FontSize)
    if ($Name) { $cb.Name = $Name }
    $vals = @()
    if ($EmptyText) { [void]$cb.Items.Add($EmptyText); $vals += '' }
    foreach ($it in @($Items)) {
        [void]$cb.Items.Add(($Format -f $it.Value, $it.Text))
        $vals += $it.Value
    }
    $cur = "$Current"
    if ($cur -ne '' -and -not (@($vals | ForEach-Object { "$_" }) -contains $cur)) {
        [void]$cb.Items.Add(($CurrentText -f $cur))
        $vals += $Current
    }
    $cb.Tag = @($vals)
    $sel = 0
    for ($i = 0; $i -lt $vals.Count; $i++) {
        if ("$($vals[$i])" -eq $cur) { $sel = $i; break }
    }
    if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = $sel }
    return $cb
}

function Get-CvGuiComboValue {
    <# El VALOR (no la etiqueta) de lo elegido en un combo de New-CvGuiCatalogCombo. '' si no hay. #>
    param([Parameter(Mandatory)]$Combo)
    $vals = @($Combo.Tag)
    $i = $Combo.SelectedIndex
    if ($i -lt 0 -or $i -ge $vals.Count) { return '' }
    return $vals[$i]
}

function Get-CvOpenCommand {
    <#
        PURO. Como se le pide a Windows que abra algo: @{ Exe; Args; Shell }.
          -Select : el explorador con el fichero YA MARCADO (para "abrir la carpeta del archivo").
          -Folder : el explorador en esa carpeta.
          (nada)  : el fichero con su programa asociado (Shell = $true; lo resuelve la shell).
        Separado del lanzamiento para poder probar la decision sin abrir ventanas.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Folder,
        [switch]$Select
    )
    if ($Select) {
        return @{
            Exe   = 'explorer.exe'
            Args  = @(('/select,"{0}"' -f $Path))
            Shell = $false
        }
    }
    if ($Folder) {
        return @{
            Exe   = 'explorer.exe'
            Args  = @(('"{0}"' -f $Path))
            Shell = $false
        }
    }
    return @{
        Exe   = $Path
        Args  = @()
        Shell = $true
    }
}

function Open-CvGuiPath {
    <#
        Abre un fichero con su programa asociado, una carpeta en el explorador (-Folder) o el
        explorador MARCANDO un fichero (-Select). Con -Create la carpeta se crea si no existe.

        Estaba repartido en cinco sitios con cinco maneras distintas de tratar el fallo: unos
        avisaban y otros se lo tragaban en silencio. Aqui se avisa (Show-CvGuiInfo) salvo -Quiet, y
        se devuelve $true/$false por si el llamador quiere hacer algo mas.
    #>
    param(
        [AllowEmptyString()][string]$Path = '',
        [switch]$Folder,
        [switch]$Select,
        [switch]$Create,
        [string]$Title = 'Abrir',
        [switch]$Quiet
    )
    if ("$Path" -eq '') { return $false }
    try {
        if ($Folder -and $Create -and -not (Test-Path -LiteralPath $Path)) {
            [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
        }
        $cmd = Get-CvOpenCommand -Path $Path -Folder:$Folder -Select:$Select
        if ([bool]$cmd.Shell) { [void](Start-Process -FilePath "$($cmd.Exe)" -ErrorAction Stop) }
        else { [void](Start-Process -FilePath "$($cmd.Exe)" -ArgumentList @($cmd.Args) -ErrorAction Stop) }
        return $true
    } catch {
        if (-not $Quiet) {
            Show-CvGuiInfo -Title $Title -Message ("No se pudo abrir {0}:`n`n{1}" -f $Path, $_.Exception.Message)
        }
        return $false
    }
}

function Add-CvGuiListColumns {
    <#
        Columnas de un ListView a partir de un CATALOGO (@{ Key; Text; Width }): la ventana dice
        DONDE va la lista y el catalogo dice QUE columnas lleva. Asi el orden y los anchos se miran
        -y se prueban- sin abrir ninguna ventana, y quien necesite una columna concreta la busca por
        su Key con Get-CvGuiCatalogIndex en vez de escribir el numero a mano.
    #>
    param(
        [Parameter(Mandatory = $true)]$List,
        $Columns = @()
    )
    foreach ($c in @($Columns)) { [void]$List.Columns.Add("$($c.Text)", [int]$c.Width) }
}

function Get-CvGuiCatalogIndex {
    <#
        PURO. En que posicion esta la entrada con esa Key (-1 si no esta). Es lo que evita el numero
        magico: "la columna de progreso es la 6" deja de ser algo que hay que recordar cada vez que
        se anade una columna delante.
    #>
    param(
        $Items = @(),
        [string]$Key = ''
    )
    $i = 0
    foreach ($it in @($Items)) {
        if ("$($it.Key)" -eq $Key) { return $i }
        $i++
    }
    return -1
}

function New-CvGuiCatalogControl {
    <#
        UN control a partir de su entrada de catalogo. Los tipos que se usan en una barra o en una
        rejilla de formulario: 'label', 'text', 'check', 'button' y 'combo'.

        Campos que entiende: Kind, Name, Text, Width, Height, Gap (margen por la izquierda) y Fill
        ($true = Dock Fill, lo normal dentro de una rejilla). Un Kind que no conozca es un error y
        no un control en blanco: un hueco silencioso en una ventana no se ve hasta que falta algo.
    #>
    param(
        [Parameter(Mandatory = $true)]$Item,
        [int]$FontSize = 9
    )
    $gap = 3
    if ($null -ne $Item.Gap) { $gap = [int]$Item.Gap }
    $fill = [bool]$Item.Fill

    switch ("$($Item.Kind)") {
        'label' {
            $c = New-Object System.Windows.Forms.Label
            $c.Text     = "$($Item.Text)"
            $c.AutoSize = $true
            $c.Anchor   = 'Left'
            $c.Margin   = New-Object System.Windows.Forms.Padding($gap, 7, 3, 3)
        }
        'check' {
            $c = New-Object System.Windows.Forms.CheckBox
            $c.Text     = "$($Item.Text)"
            $c.AutoSize = $true
            $top = 7
            if ($null -ne $Item.Top) { $top = [int]$Item.Top }
            $c.Margin   = New-Object System.Windows.Forms.Padding($gap, $top, 3, 3)
        }
        'text' {
            $c = New-Object System.Windows.Forms.TextBox
            $c.Font = (New-CvGuiFont $FontSize)
            if ($fill) { $c.Dock = 'Fill' } else { $c.Width = [int]$Item.Width }
        }
        'button' {
            $c = New-Object System.Windows.Forms.Button
            $c.Text = "$($Item.Text)"
            if ($fill) {
                $c.Dock = 'Fill'
            } else {
                $c.Width  = [int]$Item.Width
                $c.Height = 26
                if ($null -ne $Item.Height) { $c.Height = [int]$Item.Height }
                $c.Margin = New-Object System.Windows.Forms.Padding($gap, 3, 3, 3)
            }
        }
        'combo' {
            $c = New-Object System.Windows.Forms.ComboBox
            $c.DropDownStyle = 'DropDownList'
            $c.Font          = (New-CvGuiFont $FontSize)
            if ($fill) { $c.Dock = 'Fill' } else { $c.Width = [int]$Item.Width }
        }
        default { throw ("New-CvGuiCatalogControl: no se que es un control de tipo '{0}'" -f $Item.Kind) }
    }
    if ("$($Item.Name)" -ne '') { $c.Name = "$($Item.Name)" }
    return $c
}

function Add-CvGuiBarItems {
    <#
        Una barra de abajo (FlowLayoutPanel) montada desde un CATALOGO, de izquierda a derecha.
        Devuelve una tabla Nombre -> control para que la ventana se quede con los que va a usar en
        sus manejadores (los que no llevan Name son etiquetas, y no hacen falta despues).
    #>
    param(
        [Parameter(Mandatory = $true)]$Bar,
        $Items = @(),
        [int]$FontSize = 9
    )
    $out = @{}
    foreach ($it in @($Items)) {
        $c = New-CvGuiCatalogControl -Item $it -FontSize $FontSize
        $Bar.Controls.Add($c)
        if ("$($it.Name)" -ne '') { $out["$($it.Name)"] = $c }
    }
    return $out
}

function Add-CvGuiFormRows {
    <#
        Las filas de un formulario (TableLayoutPanel) desde un CATALOGO: la columna 0 es la etiqueta
        y las demas, los controles de esa fila.

        Cada fila: @{ Label = 'Recorte:'; Cells = @(...) }, y cada celda una entrada de catalogo
        (ver New-CvGuiCatalogControl) con Span opcional. Las celdas se van colocando a partir de la
        columna 1, cada una detras de la anterior. Devuelve la tabla Nombre -> control.
    #>
    param(
        [Parameter(Mandatory = $true)]$Grid,
        $Rows = @(),
        [int]$FontSize = 9
    )
    $out = @{}
    $y = 0
    foreach ($row in @($Rows)) {
        if ("$($row.Label)" -ne '') {
            $lb = New-CvGuiCatalogControl -Item @{ Kind = 'label'; Text = "$($row.Label)" } -FontSize $FontSize
            $Grid.Controls.Add($lb, 0, $y)
        }
        $x = 1
        foreach ($cell in @($row.Cells)) {
            $c = New-CvGuiCatalogControl -Item $cell -FontSize $FontSize
            $Grid.Controls.Add($c, $x, $y)
            $span = 1
            if ($null -ne $cell.Span) { $span = [int]$cell.Span }
            if ($span -gt 1) { $Grid.SetColumnSpan($c, $span) }
            if ("$($cell.Name)" -ne '') { $out["$($cell.Name)"] = $c }
            $x += $span
        }
        $y++
    }
    return $out
}

function Show-CvTextWindow {
    <#
        Abre una ventana con un RichTextBox de SOLO LECTURA, monoespaciado y con scroll, mostrando el
        texto dado. MODAL: bloquea hasta que se cierra (ESC o el boton cerrar). Devuelve $true si la
        mostro; $false si no se pudo (sin GUI/STA), para que el llamador use otra forma de abrir.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Text)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text          = $Title
        $form.StartPosition = 'CenterScreen'
        $form.Size          = New-Object System.Drawing.Size(800, 600)
        $rtb = New-Object System.Windows.Forms.RichTextBox
        $rtb.Dock       = 'Fill'
        $rtb.ReadOnly   = $true
        $rtb.WordWrap   = $false
        $rtb.Font       = New-Object System.Drawing.Font('Consolas', 10)
        $rtb.DetectUrls = $false
        $rtb.Text       = $Text
        $form.Controls.Add($rtb)
        # ESC cierra la ventana.
        $form.KeyPreview = $true
        $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
        [void]$form.ShowDialog()
        $form.Dispose()
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function *
