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
    <#
        Fuente monoespaciada para los paneles de salida (texto alineado en columnas). UNA por tamano
        para toda la sesion (Get-CvGuiFont): antes cada control estrenaba la suya y ninguna se liberaba.
    #>
    param([int]$Size = 9)
    return (Get-CvGuiFont -Family 'Consolas' -Size $Size)
}

function Get-CvGuiFont {
    <#
        Una fuente COMPARTIDA por familia, tamano y estilo: se crea la primera vez y se reutiliza. Las
        fuentes no cambian (son inmutables) y WinForms no las libera al cerrar una ventana, asi que
        crear una por control -una negrita por cada titulo de seccion de setup, una Consolas por panel-
        las iba acumulando. No se hace Dispose de lo que devuelve: es de todos.
    #>
    param(
        [string]$Family = 'Segoe UI',
        [single]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    if ($null -eq $script:CvGuiFonts) { $script:CvGuiFonts = @{} }
    $k = "{0}|{1}|{2}" -f $Family, $Size, [int]$Style
    if (-not $script:CvGuiFonts.ContainsKey($k)) { $script:CvGuiFonts[$k] = New-Object System.Drawing.Font($Family, $Size, $Style) }
    return $script:CvGuiFonts[$k]
}

function Register-CvGuiDisposeWith {
    <#
        Libera -Object (una ayuda emergente, un temporizador...) cuando se destruye -Control (su
        ventana o el control al que acompana). Una ToolTip suelta tiene su propia ventana nativa y se
        quedaba viva hasta que pasara el recolector; cada dialogo abierto dejaba las suyas.
    #>
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)]$Object)
    try { $Control.Add_Disposed({ try { $Object.Dispose() } catch { } }.GetNewClosure()) } catch { }
    return $Object
}

function Get-CvGuiLayoutSuffix {
    <#
        Lo que convierte el nombre de un config en el de su fichero de layout: 'config.json' ->
        'config.gui.json'. Fuente UNICA: Get-CvGuiLayoutPath lo usa para NOMBRARLO, y el selector de
        configuraciones (Get-CvSetupConfigCandidates) para NO ofrecerlo como si fuera un config -encaja
        con 'config*.json' y salia en la lista; elegirlo arrancaba el programa sobre un fichero de
        tamanos de ventana-.
    #>
    return '.gui.json'
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
    if ([string]::IsNullOrWhiteSpace($cfg)) { $cfg = Get-CvDefaultConfigPath -Root "$($Context.Root)" }
    $dir = Split-Path -Parent $cfg
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = "$($Context.Root)" }
    return (Join-Path $dir ("{0}{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($cfg), (Get-CvGuiLayoutSuffix)))
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
        # Atomico y en UTF-8 sin BOM (Save-CvJsonFile): la cola y setup son procesos distintos que
        # escriben este mismo fichero, y uno cortado a medias perdia TODO (ventanas y caches).
        [void](Save-CvJsonFile -Path $p -Object ([pscustomobject]$all) -Depth 6)
        return $true
    } catch {
        return $false
    }
}

function Get-CvGuiCacheKeys {
    <#
        PURO. Las claves de '<config>.gui.json' que son CACHE DE ARCHIVOS (lo deducido de cada archivo,
        una entrada por archivo) y no el estado de una ventana. Una sola lista para el recuento y el
        borrado: antes solo se conocia 'colaBordes', y 'colaVideo' contaba como una ventana mas.
    #>
    return @(
        'colaBordes'
        'colaVideo'
    )
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
            if ((Get-CvGuiCacheKeys) -contains $pr.Name) { $r.Files += @($pr.Value).Count; continue }
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
            $esCache = ((Get-CvGuiCacheKeys) -contains $pr.Name)
            if (($What -eq 'files' -and $esCache) -or ($What -eq 'layout' -and -not $esCache)) {
                $fuera += $(if ($esCache) { @($pr.Value).Count } else { 1 })
                continue
            }
            $queda[$pr.Name] = $pr.Value
        }
        # Si no queda nada dentro, mejor sin fichero que con un '{}' suelto.
        if ($queda.Count -eq 0) { Remove-Item -LiteralPath $p -Force -ErrorAction Stop }
        else { [void](Save-CvJsonFile -Path $p -Object ([pscustomobject]$queda) -Depth 6) }
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

        Los FOTOGRAMAS del icono animado del area de notificacion (Get-CvTrayAnimFrame) son este
        mismo dibujo con un cambio, para que se reconozca igual:
          -Progress 0..100 = el anillo, tenue entero y en blanco hasta ese % desde las 12 (sin
                             flecha); -Pulse le enciende la punta;
          -Spin            = la flecha girada esos grados;
          -Dot             = un punto verde en la esquina de abajo a la derecha.
    #>
    param(
        [int]$Size = 32,
        [int]$Progress = -1,
        [int]$Spin = 0,
        [bool]$Dot = $false,
        [bool]$Pulse = $false
    )
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
        $grosor = [float]($S * 0.108)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $grosor
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Flat
        if ($Progress -ge 0) {
            # AVANCE: el anillo entero tenue (lo que falta) y en blanco lo hecho, desde las 12 (-90
            # grados en GDI+) en el sentido de las agujas del reloj.
            $tenue = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(85, 255, 255, 255)), $grosor
            $g.DrawEllipse($tenue, ($cx - $r), ($cy - $r), $diam, $diam)
            $tenue.Dispose()
            $barrido = [float](3.6 * [Math]::Min(100, $Progress))
            if ($barrido -gt 0) {
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawArc($pen, ($cx - $r), ($cy - $r), $diam, $diam, -90, $barrido)
            }
            if ($Pulse) {
                # La PUNTA, encendida un fotograma si y otro no: es lo que se mueve mientras el %
                # tarda minutos en cambiar.
                $ang = (-90.0 + $barrido) * [Math]::PI / 180.0
                $pd = [float]($grosor * 1.6)
                $px = [float]($cx + $r * [Math]::Cos($ang) - $pd / 2)
                $py = [float]($cy + $r * [Math]::Sin($ang) - $pd / 2)
                $brPunta = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 235, 140))
                $g.FillEllipse($brPunta, $px, $py, $pd, $pd)
                $brPunta.Dispose()
            }
        } else {
            # OJO con los angulos: en GDI+ la Y crece HACIA ABAJO, asi que 0 grados es las 3 en punto y
            # el arco avanza en el sentido de las agujas del reloj. El arco va de 45 a 330 grados (hueco
            # a la derecha) y la punta va donde TERMINA -330-, no donde empieza: puesta al principio
            # apunta al reves y parece un gancho colgando (se vio al dibujarlo a 256 px). -Spin lo
            # gira entero, arco y punta.
            $g.DrawArc($pen, ($cx - $r), ($cy - $r), $diam, $diam, (45 + $Spin), 285)
            Add-CvGuiArcArrow -Graphics $g -Cx $cx -Cy $cy -Radius $r -Degrees (330 + $Spin) -Size ([float]($S * 0.125)) -Brush $blanco
        }
        $pen.Dispose()

        $t = [float]($S * $(if ($Size -ge 32) { 0.095 } else { 0.105 }))
        $pts = @(
            (New-Object System.Drawing.PointF([float]($cx - $t * 0.72), [float]($cy - $t)))
            (New-Object System.Drawing.PointF([float]($cx - $t * 0.72), [float]($cy + $t)))
            (New-Object System.Drawing.PointF([float]($cx + $t * 0.95), [float]$cy))
        )
        $g.FillPolygon($blanco, $pts)
        $blanco.Dispose()

        if ($Dot) {
            # El punto de 'trabajando', abajo a la derecha, con un borde oscuro para que se vea
            # tambien sobre el azul claro de la pastilla.
            $dd = [float]($S * 0.40)
            $dx = [float]($S - $dd - $m * 0.2)
            $dy = [float]($S - $dd - $m * 0.2)
            $brDot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, 204, 113))
            $g.FillEllipse($brDot, $dx, $dy, $dd, $dd)
            $brDot.Dispose()
            $penDot = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(10, 60, 30)), ([float]([Math]::Max(1, $S * 0.05)))
            $g.DrawEllipse($penDot, $dx, $dy, $dd, $dd)
            $penDot.Dispose()
        }
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
    param(
        [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256),
        # El fotograma del icono animado (ver New-CvGuiAppBitmap); sin nada, el icono de siempre.
        [int]$Progress = -1,
        [int]$Spin = 0,
        [bool]$Dot = $false,
        [bool]$Pulse = $false
    )
    [void](Initialize-CvGui)
    $tam = @($Sizes | Sort-Object)
    $marcos = @()
    foreach ($s in $tam) {
        $bmp = New-CvGuiAppBitmap -Size $s -Progress $Progress -Spin $Spin -Dot $Dot -Pulse $Pulse
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
    <#
        El icono de la aplicacion listo para una ventana. Se monta UNA vez y se reparte.

        Se lee de icon.ico (la raiz) si esta: es el MISMO dibujo, ya hecho (lo genera
        manual\generar-logo.ps1 con Get-CvGuiAppIconBytes, y un test comprueba que son identicos byte
        a byte). Dibujarlo con GDI+ costaba ~0,7 s al abrir la primera ventana de cada proceso -casi
        todo arrancar GDI+-; leer el fichero, nada. Sin el fichero, se dibuja como antes.
    #>
    if ($null -ne $script:CvGuiAppIcon) { return $script:CvGuiAppIcon }
    try {
        $fich = Join-Path (Split-Path -Parent $PSScriptRoot) 'icon.ico'
        if (Test-Path -LiteralPath $fich) {
            $script:CvGuiAppIcon = New-Object System.Drawing.Icon $fich
            return $script:CvGuiAppIcon
        }
    } catch { $script:CvGuiAppIcon = $null }
    try {
        $ms = New-Object System.IO.MemoryStream (, (Get-CvGuiAppIconBytes))
        $script:CvGuiAppIcon = New-Object System.Drawing.Icon $ms
        $ms.Dispose()
    } catch { $script:CvGuiAppIcon = $null }
    return $script:CvGuiAppIcon
}

function Get-CvGuiTrayFrameIcon {
    <#
        El icono de UN fotograma de la animacion del area de notificacion (-Frame, lo que devuelve
        Get-CvTrayAnimFrame). Se monta una vez por dibujo (su Key) y se guarda: la animacion pasa por
        los mismos pocos fotogramas una y otra vez, y montar un .ico cada medio segundo seria tirar
        CPU para nada. Solo los tamanos del area de notificacion (16 a 100%, 24 a 150%, 32 a 200%...).

        'static' (o sin -Frame) = el icono de la aplicacion. Nunca lanza: si algo falla, ese.
    #>
    param($Frame = $null)
    if ($null -eq $Frame -or "$($Frame.Key)" -eq '' -or "$($Frame.Key)" -eq 'static') { return (Get-CvGuiAppIconSmall) }
    $k = "$($Frame.Key)"
    if ($null -eq $script:CvGuiTrayIcons) { $script:CvGuiTrayIcons = @{} }
    if ($script:CvGuiTrayIcons.ContainsKey($k)) { return $script:CvGuiTrayIcons[$k] }
    $ico = $null
    try {
        $bytes = Get-CvGuiAppIconBytes -Sizes @(16, 20, 24, 32, 40, 48) -Progress ([int]$Frame.Progress) `
            -Spin ([int]$Frame.Spin) -Dot ([bool]$Frame.Dot) -Pulse ([bool]$Frame.Pulse)
        $ms = New-Object System.IO.MemoryStream (, $bytes)
        # Con el tamano PEQUENO del sistema: 'Icon(stream)' coge el de 32 px y la bandeja lo encoge a
        # 16, asi que los fotogramas dibujados a 16/20/24 no se usaban y el icono salia borroso.
        $ico = New-Object System.Drawing.Icon($ms, [System.Windows.Forms.SystemInformation]::SmallIconSize)
        $ms.Dispose()
    } catch { $ico = $null }
    if ($null -eq $ico) { return (Get-CvGuiAppIconSmall) }
    $script:CvGuiTrayIcons[$k] = $ico
    return $ico
}

function Get-CvGuiAppIconSmall {
    <#
        El icono del programa en el tamano PEQUENO del sistema (el de la bandeja). Uno solo, para toda
        la sesion. Si no se puede, el normal.
    #>
    if ($null -ne $script:CvGuiAppIconSmall) { return $script:CvGuiAppIconSmall }
    $grande = Get-CvGuiAppIcon
    if ($null -eq $grande) { return $null }
    try { $script:CvGuiAppIconSmall = New-Object System.Drawing.Icon($grande, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
    catch { return $grande }
    return $script:CvGuiAppIconSmall
}

function Clear-CvGuiTrayFrameIcons {
    <#
        Libera los iconos de la animacion del area de notificacion (Get-CvGuiTrayFrameIcon). Se guardan
        mientras la ventana vive -la animacion pasa por los mismos una y otra vez-; al cerrarla ya no
        hacen falta, y cada uno es un icono de Windows. Devuelve cuantos libero.
    #>
    $n = 0
    if ($null -eq $script:CvGuiTrayIcons) { return 0 }
    foreach ($ico in @($script:CvGuiTrayIcons.Values)) {
        try { $ico.Dispose(); $n++ } catch { }
    }
    $script:CvGuiTrayIcons = @{}
    return $n
}

function Get-CvGuiTaskbarStates {
    <# PURO. Estado del boton de la barra de tareas -> valor de TBPFLAG (ITaskbarList3::SetProgressState). #>
    @{
        none          = 0
        indeterminate = 1
        normal        = 2
        error         = 4
        paused        = 8
    }
}

function Set-CvGuiTaskbarProgress {
    <#
        Pinta el AVANCE en el boton de la ventana en la barra de tareas (la barra verde que pone
        Windows al copiar ficheros): -State 'none' / 'indeterminate' / 'normal' / 'error' / 'paused'
        (Get-CvGuiTaskbarStates) y -Percent 0..100.

        Es ITaskbarList3, una interfaz COM del shell: se declara en C# una vez por sesion. Solo vale
        con el boton ya creado -con la ventana escondida en el area de notificacion no hay boton y
        Windows lo ignora-, y al volver a mostrarla el boton es NUEVO y ha perdido la barra: quien
        llama tiene que volver a ponerla (la cola lo hace en cada refresco).

        Fail-soft: devuelve si se pudo, nunca lanza (sin la barra se vive igual).
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [string]$State = 'none',
        [int]$Percent = 0
    )
    try {
        if ($null -eq $Form -or -not $Form.IsHandleCreated) { return $false }
        $estados = Get-CvGuiTaskbarStates
        $v = $estados["$State".ToLower()]
        if ($null -eq $v) { $v = 0 }
        if (-not ('CvGui.Taskbar' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CvGui {
    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList3 {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
        void SetProgressState(IntPtr hwnd, int state);
    }
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
    public class TaskbarListCom { }
    public static class Taskbar {
        private static ITaskbarList3 lista;
        public static bool Set(IntPtr hwnd, int state, int percent) {
            try {
                if (lista == null) { lista = (ITaskbarList3)new TaskbarListCom(); lista.HrInit(); }
                lista.SetProgressState(hwnd, state);
                if (state == 2 || state == 4 || state == 8) {
                    lista.SetProgressValue(hwnd, (ulong)Math.Max(0, Math.Min(100, percent)), 100UL);
                }
                return true;
            } catch { return false; }
        }
    }
}
'@ -ErrorAction Stop
        }
        return [bool]([CvGui.Taskbar]::Set($Form.Handle, [int]$v, $Percent))
    } catch {
        return $false
    }
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
        tools   = @{ Code = 0xE90F; Color = @(69, 90, 100) }    # llave inglesa (herramientas)
        folder  = @{ Code = 0xED25; Color = @(198, 155, 40) }   # carpeta
        console = @{ Code = 0xE756; Color = @(69, 90, 100) }    # ventana de comandos
        theme   = @{ Code = 0xE706; Color = @(120, 120, 130) }  # brillo (cambiar claro/oscuro)
        # Los del menu del boton derecho de la cola (Set-CvGuiMenuIcons).
        log     = @{ Code = 0xE8A5; Color = @(69, 90, 100) }    # documento (ver el log)
        bulk    = @{ Code = 0xE762; Color = @(69, 90, 100) }    # lista con marcas (editar varios)
        job     = @{ Code = 0xE943; Color = @(69, 90, 100) }    # llaves { } (ver el job, JSON)
        video   = @{ Code = 0xE714; Color = @(21, 101, 192) }   # camara (reproducir el original)
        output  = @{ Code = 0xE8B2; Color = @(21, 101, 192) }   # fotogramas (reproducir el convertido)
        delete  = @{ Code = 0xE74D; Color = @(198, 40, 40) }    # papelera (borrar la salida a medias)
        unlock  = @{ Code = 0xE785; Color = @(199, 119, 0) }    # candado abierto (liberar el bloqueo)
        remove  = @{ Code = 0xECC9; Color = @(198, 40, 40) }    # circulo con menos (quitar de la cola)
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

function Set-CvGuiMenuIcons {
    <#
        Pone a cada opcion de un menu su icono (New-CvGuiIcon, la misma fuente de iconos de Windows
        que los botones de la barra). -Items: @{ Item = <opcion>; Kind = <icono> }. Los iconos llevan
        el color del tema (en oscuro se aclaran), asi que se rehacen si el tema ha cambiado desde la
        ultima vez: se llama al ABRIR el menu, y con el mismo tema no hace nada. -State guarda que
        paleta tienen puesta. Nunca lanza: una opcion sin icono sigue siendo una opcion.
    #>
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][hashtable]$State,
        [int]$Size = 16
    )
    $pal = Get-CvGuiCurrentPalette
    if ([object]::ReferenceEquals($State['MenuIconPal'], $pal)) { return }
    foreach ($par in @($Items)) {
        try {
            $viejo = $par.Item.Image
            $par.Item.Image = New-CvGuiIcon -Kind "$($par.Kind)" -Size $Size
            if ($null -ne $viejo) { $viejo.Dispose() }
        } catch { }
    }
    $State['MenuIconPal'] = $pal
}

function New-CvGuiIcon {
    <#
        Icono para la barra de botones. Se pinta el glifo que toca de 'Segoe MDL2 Assets' (la fuente
        de iconos que trae Windows 10/11): son los mismos simbolos que usa el sistema, asi que la
        ventana no parece de otra epoca, y al ser una fuente escalan nitidos a cualquier tamano y DPI.

        Si esa fuente NO esta (Windows viejo), se cae a los iconos DIBUJADOS a mano con GDI+ que habia
        antes: mas pobres, pero siempre disponibles. En ningun caso hay ficheros .png que instalar.

        -Kind: una clave de Get-CvGuiIconGlyphs (play, stop, cancel, edit, folder, delete...). Devuelve un Bitmap
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

        SE CONTESTA CON EL TECLADO: Escape cierra sin elegir -lo decia esta ayuda desde el principio
        y no lo hacia nadie: no habia CancelButton ni manejador, asi que un aviso abierto con una
        tecla solo se podia quitar con el raton-, el PRIMER boton arranca con el foco y es el que
        contesta a Intro, y con Tab se va a los demas. El primero es siempre la salida principal
        (en los avisos de cerrar, la menos destructiva).

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
    # WinForms puede no estar cargado aun: el arranque de la cola avisa de una herramienta que falta
    # ANTES de abrir su ventana, y solo funcionaba porque el splash ya lo habia cargado. Sin splash,
    # 'no se encuentra el tipo Form' y la cola (con la consola oculta) moria sin decir nada.
    if (-not (Initialize-CvGui)) { return '' }
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

    $primero = $null
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
            [void](Register-CvGuiDisposeWith -Control $b -Object $tt)
        }
        $val = "$($o.Value)"
        $b.Add_Click({ $pick.Value = $val; $f.Close() }.GetNewClosure())
        $flow.Controls.Add($b)
        if ($null -eq $primero) { $primero = $b }
    }
    if ($null -ne $primero) {
        $f.AcceptButton = $primero
        $f.ActiveControl = $primero
    }
    # Escape = cerrar sin elegir. Con KeyPreview lo ve el dialogo aunque el foco este en un boton.
    $f.KeyPreview = $true
    $f.Add_KeyDown({
        param($emisor, $tecla)
        if ($tecla.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $tecla.SuppressKeyPress = $true
            $emisor.Close()
        }
    })
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
    [DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(System.IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(System.IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr hwnd, System.IntPtr pid);
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint hiloA, uint hiloB, bool enganchar);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern System.IntPtr SendMessage(System.IntPtr hwnd, int msg, System.IntPtr wp, string lp);
'@ -ErrorAction SilentlyContinue

$script:CvGuiTheme   = ''     # tema RESUELTO de esta sesion ('light' / 'dark')
$script:CvGuiPalette = $null  # su paleta ya montada: la piden los Paint, no se rehace cada vez

# Test-CvWindowsDarkMode y Resolve-CvGuiTheme (que tema toca) viven en Config.psm1, junto al
# catalogo Get-CvGuiThemes: la pantalla de arranque de la cola tiene que decidirlo ANTES de cargar
# este modulo, que es lo que mas tarda en cargar.

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
        Marca un control con su ROL de mensaje y le pone el color que le toca AHORA. La marca va en la
        tabla de marcas del tema (Get-CvGuiRoleOf), y sirve para que al aplicar el tema no se le pise
        el color con el del texto normal: un aviso en rojo tiene que seguir en rojo en los dos temas.
        Antes iba en AccessibleDescription, que un lector de pantalla lee en voz alta.
    #>
    param(
        [Parameter(Mandatory)]$Control,
        [string]$Role = 'muted',
        $Palette = $null
    )
    $pal = $(if ($null -ne $Palette) { $Palette } else { Get-CvGuiCurrentPalette })
    (Get-CvGuiMarks -Control $Control)['role'] = "$Role".ToLower()
    $Control.ForeColor = Get-CvGuiRoleColor -Palette $pal -Role $Role
    return $Control
}

function Get-CvGuiRoleOf {
    <# El ROL de color que se le puso a un control con Set-CvGuiRole, o '' si no tiene. #>
    param([Parameter(Mandatory)]$Control)
    $h = $null
    if (-not $script:CvGuiMarks.TryGetValue($Control, [ref]$h)) { return '' }
    return "$($h['role'])"
}

function Set-CvGuiExplorerThemeTree {
    <#
        Recorre los controles y, en los que lo llevan (cuadros de texto, listas, arbol) y ya tienen
        handle, pone o quita el tema oscuro del explorador (Set-CvGuiExplorerTheme). Es lo unico del
        tema que hay que repetir al ENSENARSE la ventana: lo demas ya se aplico al montarla.
    #>
    param([Parameter(Mandatory)]$Control, [bool]$Dark = $false)
    $tipos = @(
        'TextBox'
        'RichTextBox'
        'ListBox'
        'ListView'
        'TreeView'
    )
    if ($tipos -contains $Control.GetType().Name -and $Control.IsHandleCreated) {
        try { Set-CvGuiExplorerTheme -Control $Control -Dark $Dark } catch { }
    }
    foreach ($c in $Control.Controls) { Set-CvGuiExplorerThemeTree -Control $c -Dark $Dark }
}

function Set-CvGuiExplorerTheme {
    <#
        Pone (o quita) el tema OSCURO del explorador a una lista, un arbol o un cuadro de texto ya con
        handle: es lo que oscurece sus barras de scroll y cabeceras. Al volver a CLARO se quita (tema
        por defecto), pero solo en los que se oscurecieron: antes se quedaba puesto y la lista salia con
        las barras oscuras en una ventana clara.
    #>
    param([Parameter(Mandatory)]$Control, [bool]$Dark = $false)
    if ($Dark) {
        [void][CvGui.Native]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null)
        Set-CvGuiMark -Control $Control -Mark 'explorer-dark'
    } elseif (Test-CvGuiMark -Control $Control -Mark 'explorer-dark') {
        [void][CvGui.Native]::SetWindowTheme($Control.Handle, $null, $null)
        Set-CvGuiMark -Control $Control -Mark 'explorer-dark' -On $false
    }
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
                if ($Control.IsHandleCreated) { Set-CvGuiExplorerTheme -Control $Control -Dark $oscuro }
            }
            'RichTextBox'    {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($Control.IsHandleCreated) { Set-CvGuiExplorerTheme -Control $Control -Dark $oscuro }
                # Un resumen pintado por bloques (Set-CvGuiSummaryText) lleva sus colores en el texto:
                # se repinta con los del tema nuevo, si lo que se ve sigue siendo ese resumen.
                $mk = Get-CvGuiMarks -Control $Control
                if ($mk.ContainsKey('SummaryLines')) {
                    $plan = Get-CvGuiSummaryRuns -Lines @($mk['SummaryLines'])
                    if ("$($Control.Text)" -eq $plan.Text) { [void](Set-CvGuiSummaryText -Box $Control -Lines @($mk['SummaryLines']) -Force) }
                }
            }
            'ListBox'        {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($Control.IsHandleCreated) { Set-CvGuiExplorerTheme -Control $Control -Dark $oscuro }
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
                    if (-not (Test-CvGuiMark -Control $Control -Mark 'grid-off') -and [bool]$Control.GridLines) { Set-CvGuiMark -Control $Control -Mark 'grid-off' }
                    $Control.GridLines = $false
                } else {
                    if (Test-CvGuiMark -Control $Control -Mark 'grid-off') { $Control.GridLines = $true }
                }
                # OJO: aqui NO se toca BorderStyle. Cambiarlo RECREA el control, y al recrearse se
                # pierde el tema oscuro del explorador: la cabecera de columnas volvia a salir
                # BLANCA (comprobado), y volver a pedir el tema despues ya no la recupera. El borde
                # de la lista es una linea fina; la rejilla era lo que llenaba la ventana de blanco.
                if ($oscuro -or (Test-CvGuiMark -Control $Control -Mark 'paint-always')) { [void](Set-CvGuiListDarkPaint -List $Control) }
                else { try { $Control.OwnerDraw = $false } catch { } }
                if ($Control.IsHandleCreated) { Set-CvGuiExplorerTheme -Control $Control -Dark $oscuro }
            }
            'TreeView'       {
                $Control.BackColor = $Palette.Panel
                $Control.ForeColor = $Palette.Fore
                $Control.LineColor = $Palette.Border
                $Control.BorderStyle = $(if ($oscuro) { 'None' } else { 'Fixed3D' })
                if ($Control.IsHandleCreated) { Set-CvGuiExplorerTheme -Control $Control -Dark $oscuro }
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
                $Control.BackColor = $(if (Test-CvGuiMark -Control $Control -Mark 'sep') { $Palette.Border } else { $Palette.Back })
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
        $marca = Get-CvGuiRoleOf -Control $Control
        if ($marca -ne '') {
            $Control.ForeColor = Get-CvGuiRoleColor -Palette $Palette -Role $marca
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
        la rayita gris). Va MARCADA ('sep', Set-CvGuiMark) para que el tema la pinte con el color de borde
        en vez de con el del fondo.
    #>
    param(
        [int]$Height = 20,
        [int]$MarginX = 12
    )
    $sep = New-Object System.Windows.Forms.Panel
    Set-CvGuiMark -Control $sep -Mark 'sep'
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
    if (Test-CvGuiMark -Control $Split -Mark 'grip') { return $Split }
    Set-CvGuiMark -Control $Split -Mark 'grip'
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
        [void](Register-CvGuiDisposeWith -Control $Split -Object $tip)
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

        La marca ('repaint', Set-CvGuiMark) evita engancharlo dos veces: el tema se aplica al montar la ventana
        y otra vez en 'Shown'.
    #>
    param([Parameter(Mandatory)]$Control)
    if (Test-CvGuiMark -Control $Control -Mark 'repaint') { return $Control }
    Set-CvGuiMark -Control $Control -Mark 'repaint'
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
    if (Test-CvGuiMark -Control $Button -Mark 'btn-off') { return $Button }   # ya tiene el pintor
    Set-CvGuiMark -Control $Button -Mark 'btn-off'
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

# Pinceles y banderas del pintor de listas oscuras, para la paleta EN CURSO (ver Set-CvGuiListDarkPaint).
$script:CvGuiListPaint = $null

function Get-CvGuiListPaintTools {
    <#
        Lo que necesita el pintor de listas oscuras, montado UNA vez por paleta: los pinceles (antes
        se creaba y tiraba uno por celda), los colores y las banderas de texto. Si cambia el tema, la
        paleta es otra y se rehace (soltando los de antes).
    #>
    $pal = Get-CvGuiCurrentPalette
    $viejo = $script:CvGuiListPaint
    if ($null -ne $viejo -and [object]::ReferenceEquals($viejo.Pal, $pal)) { return $viejo }
    $base = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    # Fondo SUAVE de una etiqueta: su color mezclado con el del panel (se lee en los dos temas).
    $suave = {
        param($C, [double]$F)
        [System.Drawing.Color]::FromArgb(
            [int]($pal.Panel.R + ($C.R - $pal.Panel.R) * $F),
            [int]($pal.Panel.G + ($C.G - $pal.Panel.G) * $F),
            [int]($pal.Panel.B + ($C.B - $pal.Panel.B) * $F))
    }
    $nuevo = @{
        Pal         = $pal
        Dark        = ("$($pal.Name)" -eq 'dark')
        Panel       = [System.Drawing.SolidBrush]::new($pal.Panel)
        Accent      = [System.Drawing.SolidBrush]::new($pal.Accent)
        Border      = [System.Drawing.Pen]::new($pal.Border)
        Track       = [System.Drawing.SolidBrush]::new($pal.Border)
        SelSoft     = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
        White       = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        Fore        = $pal.Fore
        Muted       = $pal.Muted
        # Etiquetas de estado: color del texto y su fondo suave, por tipo.
        Chip        = @{
            ok   = @{ Fore = $pal.Ok;     Back = [System.Drawing.SolidBrush]::new((& $suave $pal.Ok 0.16)) }
            run  = @{ Fore = $pal.Accent; Back = [System.Drawing.SolidBrush]::new((& $suave $pal.Accent 0.16)) }
            warn = @{ Fore = $pal.Warn;   Back = [System.Drawing.SolidBrush]::new((& $suave $pal.Warn 0.16)) }
            err  = @{ Fore = $pal.Error;  Back = [System.Drawing.SolidBrush]::new((& $suave $pal.Error 0.16)) }
            q    = @{ Fore = $pal.Fore;   Back = [System.Drawing.SolidBrush]::new((& $suave $pal.Muted 0.14)) }
        }
        FlagsLeft   = ($base -bor [System.Windows.Forms.TextFormatFlags]::Left)
        FlagsRight  = ($base -bor [System.Windows.Forms.TextFormatFlags]::Right)
        FlagsCenter = ($base -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter)
        # Sin el margen que TextRenderer pone a cada lado: el de la etiqueta se mide igual que se pinta.
        FlagsTight  = ($base -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
    }
    $script:CvGuiListPaint = $nuevo
    if ($null -ne $viejo) {
        foreach ($k in 'Panel', 'Accent', 'Border', 'Track', 'SelSoft', 'White') { try { $viejo[$k].Dispose() } catch { } }
        foreach ($c in @($viejo.Chip.Values)) { try { $c.Back.Dispose() } catch { } }
    }
    return $nuevo
}

function Set-CvGuiListCellPainter {
    <#
        Una lista que se pinta A MANO en los dos temas (no solo en oscuro), con un PINTOR propio para
        algunas celdas: -Painter recibe ($e, $herramientas, $rectangulo) y devuelve $true si ha pintado
        la celda (entonces no se escribe su texto). Lo usa la cola para la etiqueta de color del estado
        y la barra de progreso (Write-CvGuiCellChip / Write-CvGuiCellBar). El pintor corre en CADA
        repintado de su celda: que no cree objetos ni llame a nada caro.
    #>
    param([Parameter(Mandatory)]$List, [Parameter(Mandatory)][scriptblock]$Painter)
    $m = Get-CvGuiMarks -Control $List
    $m['paint-always'] = $true
    $m['CellPainter']  = $Painter
    [void](Set-CvGuiListDarkPaint -List $List)
    return $List
}

function Get-CvGuiSummaryRuns {
    <#
        PURO. Como se pinta un resumen por bloques: de las lineas con su tipo (Get-CvJobSummaryLines
        -WithKind) saca el TEXTO entero y, por linea, donde empieza, cuanto mide y su estilo. Antes de
        cada cabecera (VIDEO / AUDIO / SUBS) va una linea en blanco: eso es lo que separa los bloques.
        No quita ni cambia ninguna linea: solo anade esos huecos. Los saltos son '\n' porque es lo que
        guarda un RichTextBox (con '\r\n' las posiciones se descuadraban una por linea).
          Style: 'title' / 'head' / 'result' en negrita; Role: el rol de color (Get-CvGuiRoleColor),
          con 'head' = el azul de lo editado y 'result' = verde.
    #>
    param([object[]]$Lines = @())
    $estilo = @{
        title  = @{ Bold = $true;  Role = 'fore' }
        meta   = @{ Bold = $false; Role = 'muted' }
        head   = @{ Bold = $true;  Role = 'edited' }
        keep   = @{ Bold = $false; Role = 'fore' }
        drop   = @{ Bold = $false; Role = 'muted' }
        detail = @{ Bold = $false; Role = 'fore' }
        result = @{ Bold = $true;  Role = 'ok' }
    }
    $sb   = New-Object System.Text.StringBuilder
    $runs = @()
    foreach ($ln in @($Lines)) {
        if ($null -eq $ln) { continue }
        $txt  = "$($ln.Text)"
        $kind = "$($ln.Kind)"
        if (-not $estilo.ContainsKey($kind)) { $kind = 'keep' }
        if ($sb.Length -gt 0) {
            if ($kind -eq 'head') { [void]$sb.Append("`n") }
            [void]$sb.Append("`n")
        }
        $runs += [pscustomobject]@{
            Start = $sb.Length
            Length = $txt.Length
            Kind = $kind
            Bold = [bool]$estilo[$kind].Bold
            Role = $estilo[$kind].Role
        }
        [void]$sb.Append($txt)
    }
    return [pscustomobject]@{
        Text = $sb.ToString()
        Runs = $runs
    }
}

function Set-CvGuiSummaryText {
    <#
        Pinta en un RichTextBox un resumen por BLOQUES (Get-CvGuiSummaryRuns): el mismo texto, con las
        cabeceras destacadas, lo descartado atenuado y lo que QUEDA en verde. Solo repinta si cambia el
        texto o el tema. Guarda las lineas en las marcas del control: el tema las vuelve a pintar con
        sus colores al cambiar (Set-CvGuiThemeControl), si lo que se ve sigue siendo ese resumen.
    #>
    param([Parameter(Mandatory)]$Box, [object[]]$Lines = @(), [switch]$Force)
    $plan = Get-CvGuiSummaryRuns -Lines $Lines
    $pal  = Get-CvGuiCurrentPalette
    $mk   = Get-CvGuiMarks -Control $Box
    $mk['SummaryLines'] = @($Lines)
    if (-not $Force -and "$($Box.Text)" -eq $plan.Text -and "$($mk['SummaryTheme'])" -eq "$($pal.Name)") { return $Box }
    $mk['SummaryTheme'] = "$($pal.Name)"
    $base = $Box.Font
    $negrita = Get-CvGuiFont -Family $base.FontFamily.Name -Size $base.Size -Style ([System.Drawing.FontStyle]::Bold)
    $Box.SuspendLayout()
    try {
        $Box.Text = $plan.Text
        foreach ($r in @($plan.Runs)) {
            if ($r.Length -le 0) { continue }
            $Box.Select($r.Start, $r.Length)
            $Box.SelectionColor = (Get-CvGuiRoleColor -Palette $pal -Role $r.Role)
            $Box.SelectionFont  = $(if ($r.Bold) { $negrita } else { $base })
        }
        $Box.Select(0, 0)
    } finally {
        $Box.ResumeLayout()
    }
    return $Box
}

function Set-CvGuiPartsLabel {
    <#
        Una etiqueta de UNA linea con trozos de distinto color (Get-CvQueueSummaryParts: {Text; Role}).
        Su .Text es el texto entero, como siempre (lo leen el icono de la bandeja y los tests); lo que
        cambia es como se pinta: encima, trozo a trozo, con el color de su rol en el tema de ese
        momento. El pintor se engancha una sola vez; los trozos van en las marcas del control.
    #>
    param([Parameter(Mandatory)]$Label, [object[]]$Parts = @())
    $mk = Get-CvGuiMarks -Control $Label
    $mk['Parts'] = @($Parts)
    $txt = ((@($Parts) | ForEach-Object { "$($_.Text)" }) -join '')
    if ("$($Label.Text)" -cne $txt) { $Label.Text = $txt } else { $Label.Invalidate() }
    if (-not $mk.ContainsKey('parts-paint')) {
        $mk['parts-paint'] = $true
        $Label.Add_Paint({
            param($s, $e)
            try {
                $trozos = @((Get-CvGuiMarks -Control $s)['Parts'])
                if ($trozos.Count -eq 0) { return }
                $pal = Get-CvGuiCurrentPalette
                $e.Graphics.Clear($s.BackColor)
                $fl = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
                      [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left -bor
                      [System.Windows.Forms.TextFormatFlags]::NoPrefix
                $x = $s.Padding.Left + 3
                foreach ($t in $trozos) {
                    $tx = "$($t.Text)"
                    if ($tx -eq '' -or $x -ge $s.Width) { continue }
                    $w = [System.Windows.Forms.TextRenderer]::MeasureText($e.Graphics, $tx, $s.Font, [System.Drawing.Size]::Empty, $fl).Width
                    $r = New-Object System.Drawing.Rectangle($x, 0, ($s.Width - $x), $s.Height)
                    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $tx, $s.Font, $r, (Get-CvGuiRoleColor -Palette $pal -Role "$($t.Role)"), $fl)
                    $x += $w
                }
            } catch { }
        })
    }
    return $Label
}

function Show-CvGuiCellEditor {
    <#
        Editar UNA celda de una lista en su sitio (fase A6 del rediseno): un cuadro de texto encima de
        la celda, con lo que ponia. Intro o salir del cuadro confirma; Esc lo deja como estaba. Al
        acabar llama a -OnDone con (texto, confirmado) y se quita. No guarda nada por su cuenta: quien
        llama decide que hacer con el texto (en el editor del job, lo mismo que los campos de la barra).
        -OnDone tiene que ser un scriptblock SIN GetNewClosure si usa variables de la ventana.
    #>
    param(
        [Parameter(Mandatory)]$List,
        [Parameter(Mandatory)][int]$ItemIndex,
        [Parameter(Mandatory)][int]$SubIndex,
        [string]$Text = '',
        [Parameter(Mandatory)][scriptblock]$OnDone
    )
    if ($ItemIndex -lt 0 -or $ItemIndex -ge $List.Items.Count) { return $null }
    $it = $List.Items[$ItemIndex]
    if ($SubIndex -le 0 -or $SubIndex -ge $it.SubItems.Count) { return $null }
    $r = $it.SubItems[$SubIndex].Bounds
    $pal = Get-CvGuiCurrentPalette
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font        = $List.Font
    $tb.BackColor   = $pal.Panel
    $tb.ForeColor   = $pal.Fore
    $tb.Text        = $Text
    $tb.Name        = 'cvCellEditor'
    $tb.Bounds      = New-Object System.Drawing.Rectangle($r.X, ($r.Y - 1), [Math]::Max(40, $r.Width), ($r.Height + 2))
    $h = @{ Done = $false }
    $fin = {
        param([bool]$Ok)
        if ($h.Done) { return }
        $h.Done = $true
        $t = "$($tb.Text)"
        # Quitarlo DESPUES de este evento: deshacerse de un control dentro de su propio manejador
        # (Leave, KeyDown) deja a WinForms con un handle que ya no existe.
        try { [void]$List.BeginInvoke([System.Action]({ try { $List.Controls.Remove($tb); $tb.Dispose() } catch { } }.GetNewClosure())) } catch { }
        try { [void]$List.Focus() } catch { }
        & $OnDone $t $Ok
    }.GetNewClosure()
    $tb.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter)  { $_.SuppressKeyPress = $true; & $fin $true }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $_.SuppressKeyPress = $true; & $fin $false }
    }.GetNewClosure())
    $tb.Add_Leave({ & $fin $true }.GetNewClosure())
    $List.Controls.Add($tb)
    [void]$tb.Focus()
    $tb.SelectAll()
    return $tb
}

function Add-CvGuiButtonKey {
    <#
        Pone a la derecha de un boton su TECLA de atajo, en una cajita pequena y atenuada (como en los
        menus de Windows): el atajo se ve sin pasar el raton por encima. Se hace sitio ensanchando el
        relleno derecho del boton (con AutoSize, el boton crece solo) y se pinta en su Paint con los
        colores del tema de ese momento. -Key es el texto tal cual ('F9', 'Esc', 'Ctrl+T').
    #>
    param([Parameter(Mandatory)]$Button, [Parameter(Mandatory)][string]$Key)
    $font = Get-CvGuiFont -Family 'Segoe UI' -Size 7.5
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($Key, $font).Width + 2
    $p = $Button.Padding
    $Button.Padding = New-Object System.Windows.Forms.Padding($p.Left, $p.Top, ($p.Right + $w + 6), $p.Bottom)
    $Button.Add_Paint({
        param($s, $e)
        try {
            $pal = Get-CvGuiCurrentPalette
            $alto = 15
            $x = $s.Width - $w - 6
            $y = [int](($s.Height - $alto) / 2)
            $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $alto)
            $pen = New-Object System.Drawing.Pen $pal.Border
            $e.Graphics.DrawRectangle($pen, $rect)
            $pen.Dispose()
            $col = if ($s.Enabled) { $pal.Muted } else { $pal.Border }
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $Key, $font, $rect, $col,
                ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding))
        } catch { }
    }.GetNewClosure())
    return $Button
}

function Write-CvGuiCellChip {
    <#
        Pinta en una celda una ETIQUETA de estado: texto en su color sobre un fondo suave redondeado
        (-Kind: ok | run | warn | err | q, ver Get-CvGuiListPaintTools). En una fila marcada, en blanco
        sobre blanco translucido, para que se lea sobre el azul de la seleccion.
    #>
    param($Graphics, $Rect, [string]$Text, [string]$Kind = 'q', [bool]$Selected = $false, $Tools, $Font)
    if ("$Text" -eq '') { return }
    $c = $Tools.Chip[$Kind]
    if ($null -eq $c) { $c = $Tools.Chip['q'] }
    # Medido y pintado con las MISMAS banderas (sin margen): si no, el texto no cabia en su etiqueta.
    # Sin EndEllipsis al medir: con un tamano propuesto de cero, medir 'con puntos suspensivos' daba
    # casi nada y la etiqueta salia en 'H...'.
    $med = [System.Windows.Forms.TextRenderer]::MeasureText($Graphics, $Text, $Font, [System.Drawing.Size]::Empty, ([System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine))
    $alto = [Math]::Min($Rect.Height - 2, $med.Height + 4)
    $ancho = [Math]::Min($Rect.Width - 6, $med.Width + 16)
    if ($ancho -le 8 -or $alto -le 4) { return }
    $x = $Rect.X + 4
    $y = $Rect.Y + [int](($Rect.Height - $alto) / 2)
    $radio = [int]($alto / 2)
    $ruta = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ruta.AddArc($x, $y, $alto, $alto, 90, 180)
    $ruta.AddArc(($x + $ancho - $alto), $y, $alto, $alto, 270, 180)
    $ruta.CloseFigure()
    $modo = $Graphics.SmoothingMode
    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.FillPath($(if ($Selected) { $Tools.SelSoft } else { $c.Back }), $ruta)
    $Graphics.SmoothingMode = $modo
    $ruta.Dispose()
    $rt = [System.Drawing.Rectangle]::new(($x + 8), $y, ($ancho - 12), $alto)
    $col = if ($Selected) { [System.Drawing.Color]::White } else { $c.Fore }
    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Text, $Font, $rt, $col, $Tools.FlagsTight)
}

function Write-CvGuiCellBar {
    <#
        Pinta en una celda una BARRA de progreso de verdad (-Percent, 0-100) y a su derecha -Text. En
        una fila marcada, la barra en blanco. Antes era una barra hecha con caracteres dentro del texto.
    #>
    param($Graphics, $Rect, [int]$Percent = 0, [string]$Text = '', [bool]$Selected = $false, $Tools, $Font, [int]$Width = 110)
    $ancho = [Math]::Min($Width, [int]($Rect.Width / 2))
    $alto = 8
    $x = $Rect.X + 4
    $y = $Rect.Y + [int](($Rect.Height - $alto) / 2)
    if ($ancho -gt 10) {
        $Graphics.FillRectangle($(if ($Selected) { $Tools.SelSoft } else { $Tools.Track }), $x, $y, $ancho, $alto)
        $lleno = [int]($ancho * [Math]::Max(0, [Math]::Min(100, $Percent)) / 100)
        if ($lleno -gt 0) { $Graphics.FillRectangle($(if ($Selected) { $Tools.White } else { $Tools.Accent }), $x, $y, $lleno, $alto) }
    } else { $ancho = 0 }
    if ("$Text" -ne '') {
        $tx = $x + $ancho + 8
        $rt = [System.Drawing.Rectangle]::new($tx, $Rect.Y, [Math]::Max(0, $Rect.Right - $tx - 2), $Rect.Height)
        $col = if ($Selected) { [System.Drawing.Color]::White } else { $Tools.Fore }
        [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Text, $Font, $rt, $col, $Tools.FlagsLeft)
    }
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
    if (Test-CvGuiMark -Control $List -Mark 'list-dark') { $List.OwnerDraw = $true; return $List }
    Set-CvGuiMark -Control $List -Mark 'list-dark'
    $List.OwnerDraw = $true

    # Esto corre POR CELDA en cada repintado: medido, 30x10 celdas costaban ~410 ms en oscuro (86 en
    # claro). Por eso nada de New-Object ni de llamar a funciones aqui dentro: la paleta se mira por su
    # variable, los pinceles se guardan (Get-CvGuiListPaintTools, se rehacen si cambia el tema) y
    # los rectangulos se crean con ::new.
    $List.Add_DrawColumnHeader({
        param($s, $e)
        try {
            $h = $script:CvGuiListPaint
            if ($null -eq $h -or -not [object]::ReferenceEquals($h.Pal, $script:CvGuiPalette)) { $h = Get-CvGuiListPaintTools }
            $mk = $null
            [void]$script:CvGuiMarks.TryGetValue($s, [ref]$mk)
            if (-not $h.Dark -and -not ($null -ne $mk -and $mk['paint-always'])) { $e.DrawDefault = $true; return }
            $b = $e.Bounds
            $e.Graphics.FillRectangle($h.Panel, $b)
            # Separador de columna y linea inferior, para que se siga leyendo como una cabecera.
            $e.Graphics.DrawLine($h.Border, ($b.Right - 1), ($b.Top + 4), ($b.Right - 1), ($b.Bottom - 4))
            $e.Graphics.DrawLine($h.Border, $b.Left, ($b.Bottom - 1), $b.Right, ($b.Bottom - 1))
            # Margen de 2 px: con columnas estrechas (la de 'Bordes'), 4 se comian el texto.
            $r = [System.Drawing.Rectangle]::new(($b.X + 2), $b.Y, ($b.Width - 3), $b.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $e.Font, $r, $h.Fore, $h.FlagsLeft)
        } catch { $e.DrawDefault = $true }
    })

    # En vista 'Details' las filas se pintan por SUBITEM; DrawItem no pinta nada (si se deja en
    # DrawDefault vuelve el problema de las filas que desaparecen).
    $List.Add_DrawItem({ param($s, $e) })
    $List.Add_DrawSubItem({
        param($s, $e)
        try {
            $h = $script:CvGuiListPaint
            if ($null -eq $h -or -not [object]::ReferenceEquals($h.Pal, $script:CvGuiPalette)) { $h = Get-CvGuiListPaintTools }
            $mk = $null
            [void]$script:CvGuiMarks.TryGetValue($s, [ref]$mk)
            # En claro solo las listas que lo piden (Set-CvGuiListCellPainter); las demas, las pinta Windows.
            if (-not $h.Dark -and -not ($null -ne $mk -and $mk['paint-always'])) { $e.DrawDefault = $true; return }
            # La celda: para la primera columna, Bounds devuelve la FILA entera (es asi desde
            # siempre en WinForms), asi que se recorta al ancho de su columna.
            $r = $e.Bounds
            $item = $e.Item
            if ($e.ColumnIndex -eq 0) {
                $ib = $item.Bounds
                $r = [System.Drawing.Rectangle]::new($ib.X, $ib.Y, $s.Columns[0].Width, $ib.Height)
            }
            # El color de la FILA, no el del tema: si alguien le ha puesto uno (las filas de solo
            # lectura de la ventana de perfiles van en gris), aqui se respeta. Sin tocar nada,
            # Item.ForeColor ya devuelve el de la lista, que es el del tema.
            if ($item.Selected) {
                $e.Graphics.FillRectangle($h.Accent, $r)
                $texto = [System.Drawing.Color]::White
            } else {
                $e.Graphics.FillRectangle($h.Panel, $r)
                $texto = $item.ForeColor
            }
            # El pintor PROPIO de la lista (etiquetas, barras): si pinta la celda, no se escribe su texto.
            if ($null -ne $mk -and $null -ne $mk['CellPainter']) {
                if (& $mk['CellPainter'] $e $h $r) { return }
            }
            $al = $s.Columns[$e.ColumnIndex].TextAlign
            $flags = if ($al -eq [System.Windows.Forms.HorizontalAlignment]::Right) { $h.FlagsRight }
                     elseif ($al -eq [System.Windows.Forms.HorizontalAlignment]::Center) { $h.FlagsCenter }
                     else { $h.FlagsLeft }
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
            $ancho = $r.Width - $margen - 2
            if ($ancho -lt 0) { $ancho = 0 }
            $rt = [System.Drawing.Rectangle]::new(($r.X + $margen), $r.Y, $ancho, $r.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $rt, $texto, $flags)
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
    if (Test-CvGuiMark -Control $Box -Mark 'box-dark') { return $Box }
    Set-CvGuiMark -Control $Box -Mark 'box-dark'
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

function Get-CvGuiCenteredLocation {
    <#
        PURO. Donde poner una ventana de -Width x -Height para que quede CENTRADA en un area de
        trabajo (-Area, la de un monitor) sin salirse por arriba ni por la izquierda si es mas grande.
        Devuelve un System.Drawing.Point.
    #>
    param(
        [Parameter(Mandatory)]$Area,
        [int]$Width = 0,
        [int]$Height = 0
    )
    $x = [int]$Area.X + [int][Math]::Floor(([int]$Area.Width - $Width) / 2)
    $y = [int]$Area.Y + [int][Math]::Floor(([int]$Area.Height - $Height) / 2)
    return (New-Object System.Drawing.Point([Math]::Max([int]$Area.X, $x), [Math]::Max([int]$Area.Y, $y)))
}

function Set-CvGuiTestScreen {
    <#
        MODO PRUEBAS de las baterias de ventanas (test\gui-tests.ps1, gui-convert-tests.ps1): que sus
        ventanas no molesten a quien esta trabajando mientras corren. Se llama UNA vez al empezar,
        antes de abrir ninguna, y deja dos variables de entorno (las heredan la pantalla de arranque,
        que vive en otro hilo y no carga este modulo, y los procesos que lancen las pruebas):
          CV_GUI_TEST      = 1: ninguna ventana se pone delante a la fuerza (Set-CvGuiForeground) ni
                             se queda 'siempre encima' (la pantalla de arranque).
          CV_GUI_TEST_AREA = 'x,y,ancho,alto': la zona de trabajo del monitor elegido (-Mode, que sale de
                             gui.testScreen): 'other' = donde NO esta la ventana que tiene ahora el
                             primer plano (la de quien trabaja; con un solo monitor no se pone y las
                             ventanas salen donde siempre, pero sin el foco), 'mouse' = el del raton,
                             'number' = el monitor -Number (DISPLAYn). La eleccion: Select-CvGuiTestArea.
          CV_GUI_TEST_USER = la ventana que tenia el primer plano al empezar (la de quien trabaja):
                             si una ventana de las pruebas se lo lleva al abrirse, se lo devuelve
                             (Restore-CvGuiTestFocus).
        La app normal no lo usa nunca. Devuelve la zona elegida (o $null).
    #>
    param([string]$Mode = 'other', [int]$Number = 0)
    $env:CV_GUI_TEST = '1'
    $env:CV_GUI_TEST_AREA = ''
    try {
        # Lo unico que se le pregunta a Windows: que monitores hay y en cual esta la ventana que tiene
        # el primer plano (sin ninguna, el del raton). La ELECCION es pura: Select-CvGuiTestArea.
        $fg = [CvGui.Native]::GetForegroundWindow()
        # Quien trabaja: se apunta una vez (los procesos hijos lo heredan y no lo pisan).
        if ("$env:CV_GUI_TEST_USER" -eq '' -and $fg -ne [System.IntPtr]::Zero) { $env:CV_GUI_TEST_USER = "$($fg.ToInt64())" }
        $mio = if ($fg -ne [System.IntPtr]::Zero) { [System.Windows.Forms.Screen]::FromHandle($fg) } else { [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position) }
        $raton = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $a = Select-CvGuiTestArea -Screens @([System.Windows.Forms.Screen]::AllScreens) -Current "$($mio.DeviceName)" `
            -Mode $Mode -Number $Number -Mouse "$($raton.DeviceName)"
        if ($null -ne $a) {
            $env:CV_GUI_TEST_AREA = ("{0},{1},{2},{3}" -f $a.X, $a.Y, $a.Width, $a.Height)
        }
        return $a
    } catch { }
    return $null
}

function Get-CvGuiMonitorRows {
    <#
        PURO. Los monitores tal y como los cuenta 'Identificar monitores': su NUMERO (el de Windows,
        sacado del DeviceName: '\\.\DISPLAY2' -> 2; es el que se pone en gui.testScreenNumber), su
        resolucion, si es el principal y si es donde saldrian ahora las ventanas de las pruebas
        (-TestArea, la zona que da Select-CvGuiTestArea; $null = donde siempre, ninguno marcado).
        -Screens: lo que tenga DeviceName, Bounds, WorkingArea y Primary (como Screen.AllScreens).
    #>
    param($Screens = @(), $TestArea = $null)
    $filas = @()
    $orden = 0
    foreach ($s in @($Screens)) {
        if ($null -eq $s) { continue }
        $orden++
        $n = $orden
        if ("$($s.DeviceName)" -match '(\d+)\s*$') { $n = [int]$Matches[1] }
        $filas += [pscustomobject]@{
            Number  = $n
            Device  = "$($s.DeviceName)"
            Bounds  = $s.Bounds
            Primary = [bool]$s.Primary
            Tests   = ($null -ne $TestArea -and $s.WorkingArea -eq $TestArea)
        }
    }
    return $filas
}

function Show-CvGuiMonitorIds {
    <#
        'IDENTIFICAR MONITORES', como el de Windows: un recuadro con el NUMERO de cada monitor en el
        centro de cada pantalla durante -Seconds segundos (gui.identifyMonitorsSec). Debajo del numero,
        su resolucion, si es el principal y si es donde salen ahora las ventanas de las PRUEBAS (con lo
        que diga gui.testScreen, -Mode / -Number). Asi se sabe que numero poner en gui.testScreenNumber.
        No espera: los recuadros se cierran solos con su temporizador. Devuelve las filas pintadas.
    #>
    param([int]$Seconds = 3, [string]$Mode = 'other', [int]$Number = 0)
    [void](Initialize-CvGui)
    $pantallas = @([System.Windows.Forms.Screen]::AllScreens)
    # 'Donde trabajas' = el monitor de la ventana activa (la que ha pulsado el boton).
    $fg = [CvGui.Native]::GetForegroundWindow()
    $mio = if ($fg -ne [System.IntPtr]::Zero) { [System.Windows.Forms.Screen]::FromHandle($fg) } else { [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position) }
    $raton = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $zona = Select-CvGuiTestArea -Screens $pantallas -Current "$($mio.DeviceName)" -Mode $Mode -Number $Number -Mouse "$($raton.DeviceName)"
    $filas = @(Get-CvGuiMonitorRows -Screens $pantallas -TestArea $zona)
    $pal = Get-CvGuiCurrentPalette
    $grande = Get-CvGuiFont -Size 72 -Style Bold
    $chica  = Get-CvGuiFont -Size 11
    $formas = @()
    foreach ($f in $filas) {
        $w = New-Object System.Windows.Forms.Form
        $w.FormBorderStyle = 'None'
        $w.ShowInTaskbar   = $false
        $w.TopMost         = $true
        $w.StartPosition   = 'Manual'
        $w.Size            = New-Object System.Drawing.Size(320, 230)
        $w.Location        = New-Object System.Drawing.Point(($f.Bounds.X + [int](($f.Bounds.Width - 320) / 2)), ($f.Bounds.Y + [int](($f.Bounds.Height - 230) / 2)))
        $w.BackColor       = $(if ($f.Tests) { $pal.Accent } else { $pal.Panel })
        $w.Name            = ('cvMonitorId{0}' -f $f.Number)
        $num = New-Object System.Windows.Forms.Label
        $num.Text      = "$($f.Number)"
        $num.Font      = $grande
        $num.Dock      = 'Fill'
        $num.TextAlign = 'MiddleCenter'
        $num.ForeColor = $(if ($f.Tests) { [System.Drawing.Color]::White } else { $pal.Fore })
        $info = New-Object System.Windows.Forms.Label
        $notas = @((Get-CvText -Key 'mon.resolucion' -Values @($f.Bounds.Width, $f.Bounds.Height)))
        if ($f.Primary) { $notas += (Get-CvText -Key 'mon.principal') }
        if ($f.Tests)   { $notas += (Get-CvText -Key 'mon.pruebas') }
        $info.Text      = (Get-CvText -Key 'mon.info' -Values @($f.Number, ($notas -join ', ')))
        $info.Font      = $chica
        $info.Dock      = 'Bottom'
        $info.Height    = 48
        $info.TextAlign = 'MiddleCenter'
        $info.ForeColor = $num.ForeColor
        $w.Controls.Add($num)
        $w.Controls.Add($info)
        $w.Show()
        $formas += $w
    }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = [Math]::Max(1, $Seconds) * 1000
    $t.Add_Tick({
        $t.Stop()
        foreach ($w in $formas) { try { $w.Close(); $w.Dispose() } catch { } }
        $t.Dispose()
    }.GetNewClosure())
    $t.Start()
    return $filas
}

function Restore-CvGuiTestFocus {
    <#
        Modo pruebas: si una ventana de las pruebas se ha llevado el primer plano al ACTIVARSE, se lo
        devuelve a la ventana de quien trabaja (CV_GUI_TEST_USER). Windows deja que un proceso que lanza
        quien esta en primer plano active su primera ventana -por eso salian delante aunque nadie las
        trajera-; y como en ese momento el primer plano es nuestro, SI se puede ceder. Las pruebas no
        dependen del foco del sistema (pulsan con PerformClick y eventos), y las capturas pintan la
        ventana como activa sin necesitarlo (WM_NCACTIVATE). Fuera del modo pruebas no hace nada.
    #>
    param($Form = $null)
    try {
        if (-not (Test-CvGuiTestMode)) { return $false }
        $u = [int64]0
        if (-not [int64]::TryParse("$env:CV_GUI_TEST_USER", [ref]$u) -or $u -eq 0) { return $false }
        $fg = [CvGui.Native]::GetForegroundWindow()
        if ($null -ne $Form -and $Form.IsHandleCreated -and $fg -ne $Form.Handle) { return $false }
        return [bool][CvGui.Native]::SetForegroundWindow([System.IntPtr]$u)
    } catch { return $false }
}

function Select-CvGuiTestArea {
    <#
        PURO. De los monitores (-Screens: lo que tenga DeviceName y WorkingArea, como Screen.AllScreens),
        la zona de trabajo donde salen las ventanas de las pruebas, segun -Mode (gui.testScreen):
          other  - la del PRIMERO que no sea -Current (el monitor donde trabaja quien lanza las
                   pruebas). $null si no hay otro: con un solo monitor no hay a donde mandar las
                   ventanas y salen donde siempre. Sin saber cual es el de quien trabaja (-Current
                   vacio) tampoco se elige: mandarlas a uno cualquiera podria ser justo el suyo.
          mouse  - la del monitor del raton (-Mouse). Elegido a proposito, aunque sea el tuyo.
          number - la del monitor -Number, por el numero de su DeviceName ('\\.\DISPLAY2' = 2), que
                   es el que da Windows. Si no hay ninguno con ese numero, como 'other'.
    #>
    param($Screens = @(), [string]$Current = '', [string]$Mode = 'other', [int]$Number = 0, [string]$Mouse = '')
    if ("$Mode" -eq 'mouse' -and "$Mouse" -ne '') {
        foreach ($s in @($Screens)) { if ($null -ne $s -and "$($s.DeviceName)" -eq "$Mouse") { return $s.WorkingArea } }
    }
    if ("$Mode" -eq 'number' -and $Number -gt 0) {
        foreach ($s in @($Screens)) {
            if ($null -ne $s -and "$($s.DeviceName)" -match '(\d+)\s*$' -and [int]$Matches[1] -eq $Number) { return $s.WorkingArea }
        }
    }
    if ("$Current" -eq '') { return $null }
    foreach ($s in @($Screens)) {
        if ($null -eq $s) { continue }
        if ("$($s.DeviceName)" -eq "$Current") { continue }
        return $s.WorkingArea
    }
    return $null
}

function Test-CvGuiTestMode {
    <# $true si las ventanas corren en el MODO PRUEBAS (Set-CvGuiTestScreen). #>
    return ("$env:CV_GUI_TEST" -eq '1')
}

function Get-CvGuiTestArea {
    <# La zona del monitor libre del modo pruebas (Set-CvGuiTestScreen), o $null. #>
    $t = "$env:CV_GUI_TEST_AREA"
    if (-not (Test-CvGuiTestMode) -or $t -notmatch '^-?\d+,-?\d+,\d+,\d+$') { return $null }
    $n = @($t -split ',' | ForEach-Object { [int]$_ })
    return (New-Object System.Drawing.Rectangle($n[0], $n[1], $n[2], $n[3]))
}

function Set-CvGuiStartScreen {
    <#
        Que una ventana que se abre se CENTRE en el monitor donde esta la ventana PRINCIPAL (la
        primera abierta y a la vista), no donde este el raton. WinForms, con 'CenterScreen', usa el
        monitor del RATON: con dos pantallas, un dialogo de la cola salia en la otra.

        Solo toca las que iban a 'CenterScreen' (o a donde Windows quiera): las que se centran en su
        dueno o tienen sitio propio se quedan como estan. Sin principal a la vista (la primera ventana,
        o la principal escondida junto al reloj), tampoco. Las ventanas de OTRO hilo (la pantalla de
        arranque) no cuentan: no se pueden tocar desde aqui. Nunca lanza.
    #>
    param([Parameter(Mandatory)]$Form)
    try {
        # Modo pruebas: TODAS al monitor libre, se centren donde se centren (Set-CvGuiTestScreen).
        if (Test-CvGuiTestMode) {
            # Y si al abrirse se llevan el primer plano, se devuelve (Restore-CvGuiTestFocus).
            $Form.Add_Activated({ param($s, $e) [void](Restore-CvGuiTestFocus -Form $s) })
            $zona = Get-CvGuiTestArea
            if ($null -ne $zona) {
                $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
                $Form.Location = New-Object System.Drawing.Point(($zona.X + 40), ($zona.Y + 40))
                $Form.Add_Load({
                    try { $Form.Location = Get-CvGuiCenteredLocation -Area $zona -Width $Form.Width -Height $Form.Height } catch { }
                }.GetNewClosure())
            }
            return $Form
        }
        $pos = "$($Form.StartPosition)"
        if ($pos -ne 'CenterScreen' -and $pos -ne 'WindowsDefaultLocation') { return $Form }
        $ref = $null
        foreach ($o in @([System.Windows.Forms.Application]::OpenForms)) {
            if ($null -eq $o -or [object]::ReferenceEquals($o, $Form)) { continue }
            if ($o.InvokeRequired -or -not $o.Visible) { continue }
            if ($o.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { continue }
            $ref = $o
            break
        }
        if ($null -eq $ref) { return $Form }
        $area = ([System.Windows.Forms.Screen]::FromControl($ref)).WorkingArea
        $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        # La posicion se calcula al CARGAR, con el tamano ya definitivo (hay ventanas que se ponen el
        # suyo recordado despues de esta llamada).
        $Form.Add_Load({
            try { $Form.Location = Get-CvGuiCenteredLocation -Area $area -Width $Form.Width -Height $Form.Height } catch { }
        }.GetNewClosure())
    } catch { }
    return $Form
}

# Marcas PROPIAS del tema por control (ver Test-CvGuiMark). Tabla debil: cuando el control se va,
# su entrada tambien, sin tener que limpiar nada.
$script:CvGuiMarks = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,System.Collections.Hashtable]'

function Get-CvGuiMarks {
    <# Las marcas del tema de un control (se crean vacias la primera vez). #>
    param([Parameter(Mandatory)]$Control)
    $h = $null
    if (-not $script:CvGuiMarks.TryGetValue($Control, [ref]$h)) {
        $h = @{}
        $script:CvGuiMarks.Add($Control, $h)
    }
    return $h
}

function Test-CvGuiMark {
    <#
        Si el tema ya le hizo algo a un control ('btn-off': ya tiene su pintor de apagado; 'list-dark',
        'box-dark'; 'grid-off': se le quito la rejilla). Van en una tabla APARTE: antes iban en su
        AccessibleDescription -donde tambien va el ROL de color ('cv-role:...')- y en su Tag -que las
        ventanas usan para lo suyo-, asi que un boton o una lista con rol perdia su color, y ponerle
        rol a uno ya pintado le enganchaba un segundo pintor.
    #>
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][string]$Mark)
    return (Get-CvGuiMarks -Control $Control).ContainsKey($Mark)
}

function Set-CvGuiMark {
    <# Pone (o quita, con -On $false) una marca del tema en un control (ver Test-CvGuiMark). #>
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][string]$Mark, [bool]$On = $true)
    $h = Get-CvGuiMarks -Control $Control
    if ($On) { $h[$Mark] = $true } else { [void]$h.Remove($Mark) }
}

function Set-CvGuiTheme {
    <#
        Aplica el tema a una ventana ENTERA, justo antes de ensenarla: colores por control, barra de
        titulo oscura (DWM), las cabeceras de lista y barras de scroll en oscuro, el icono de la
        aplicacion y el monitor donde sale (que no dependen del tema, pero este es el sitio por el
        que pasan todas).

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
    # ventanas; no depende del tema (es el mismo en claro y en oscuro). Por lo mismo, aqui se decide
    # en que MONITOR sale: el de la ventana principal (Set-CvGuiStartScreen).
    [void](Set-CvGuiAppIcon -Form $Form)
    [void](Set-CvGuiStartScreen -Form $Form)
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
    }.GetNewClosure()   # sin esto, llamado luego desde HandleCreated/Shown, $Form y $oscuro llegaban vacios
    # Cuanto ANTES, mejor: en Windows 10 la barra de titulo oscura se aplica limpia si se pide antes
    # de que la ventana se dibuje. Si ya tiene handle se pide ahora (y el SetWindowPos de arriba
    # rehace el marco); si no, en cuanto lo tenga.
    if ($Form.IsHandleCreated) { & $poner }
    else { $Form.Add_HandleCreated({ & $poner }.GetNewClosure()) }
    $Form.Add_Shown({
        & $poner
        # Las listas y el arbol solo aceptan el tema del explorador cuando ya tienen handle. Solo eso:
        # antes se volvia a aplicar el tema ENTERO a todos los controles, y en el editor de config
        # (un arbol enorme) eso doblaba lo que cuesta abrirlo.
        Set-CvGuiExplorerThemeTree -Control $Form -Dark ("$($pal.Name)" -eq 'dark')
    }.GetNewClosure())
    return $pal
}

function Set-CvGuiCueBanner {
    <#
        El texto GRIS de ejemplo dentro de un campo vacio ('Buscar...'), el que se va al escribir. Es
        del propio Windows (EM_SETCUEBANNER), asi que sigue el tema del campo sin pintar nada. Con
        -Always tambien se ve con el foco puesto (si no, se va al entrar, que en un buscador es justo
        cuando hace falta). Necesita el control ya creado: se aplica en cuanto tenga ventana.
        Nunca lanza: sin el ejemplo el campo funciona igual.
    #>
    param(
        [Parameter(Mandatory)]$TextBox,
        [string]$Text = '',
        [bool]$Always = $true
    )
    $poner = {
        try { [void][CvGui.Native]::SendMessage($TextBox.Handle, 0x1501, [System.IntPtr]([int]$Always), "$Text") } catch { }
    }.GetNewClosure()
    try {
        if ($TextBox.IsHandleCreated) { & $poner } else { $TextBox.Add_HandleCreated($poner) }
    } catch { }
    return $TextBox
}

function Set-CvGuiForeground {
    <#
        Trae una ventana AL FRENTE y le da el foco DE VERDAD. Suena a una linea y no lo es: Windows
        no deja que un proceso que no esta en primer plano se ponga delante por las buenas -Activate
        y BringToFront se quedan en parpadear el boton de la barra de tareas-, y eso es justo lo que
        pasa al arrancar desde un acceso directo MINIMIZADO: el proceso nace sin derecho de primer
        plano y su ventana sale DETRAS de lo que estuvieras usando.

        Escalera, parando en cuanto la ventana ya esta delante:
          1) restaurarla si esta minimizada, Activate + BringToFront (basta si tenemos el derecho);
          2) engancharse a la cola de entrada del hilo que TIENE el primer plano (AttachThreadInput):
             mientras dura, SetForegroundWindow si funciona. Se suelta siempre, incluso si falla;
          3) TopMost un instante y quitarlo, que es lo unico que queda cuando lo demas no cuela.

        Fail-soft: nunca lanza (una ventana detras es un incordio, no un motivo para no abrirla) y
        devuelve si lo ha conseguido. Es para la ventana PRINCIPAL que abre un lanzador, no para los
        dialogos: uno modal ya sale sobre su padre.
    #>
    param([Parameter(Mandatory)]$Form)
    try {
        if ($null -eq $Form -or -not $Form.IsHandleCreated) { return $false }
        $h = $Form.Handle
        if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $Form.WindowState = 'Normal' }
        # Modo pruebas: nada de quitarle el primer plano a quien esta trabajando (Set-CvGuiTestScreen).
        if (Test-CvGuiTestMode) { return $false }
        $Form.Activate()
        $Form.BringToFront()
        if ([CvGui.Native]::GetForegroundWindow() -eq $h) { return $true }

        $fg = [CvGui.Native]::GetForegroundWindow()
        $hiloFg = 0
        if ($fg -ne [System.IntPtr]::Zero) { $hiloFg = [CvGui.Native]::GetWindowThreadProcessId($fg, [System.IntPtr]::Zero) }
        $mio = [CvGui.Native]::GetCurrentThreadId()
        $pegado = $false
        if ($hiloFg -ne 0 -and $hiloFg -ne $mio) { $pegado = [CvGui.Native]::AttachThreadInput($hiloFg, $mio, $true) }
        try {
            [void][CvGui.Native]::BringWindowToTop($h)
            [void][CvGui.Native]::SetForegroundWindow($h)
        } finally {
            if ($pegado) { [void][CvGui.Native]::AttachThreadInput($hiloFg, $mio, $false) }
        }
        if ([CvGui.Native]::GetForegroundWindow() -eq $h) { return $true }

        $Form.TopMost = $true
        [System.Windows.Forms.Application]::DoEvents()
        $Form.TopMost = $false
        $Form.Activate()
        return ([CvGui.Native]::GetForegroundWindow() -eq $h)
    } catch { return $false }
}

function Show-CvGuiFolderPicker {
    <#
        El dialogo de ELEGIR CARPETA de Windows. Devuelve la ruta elegida, o '' si se cancela (o si
        el dialogo no se puede abrir: esto nunca puede tumbar una ventana, se sigue pudiendo
        escribir la ruta a mano, que es para lo que esta el campo de al lado).

        -Initial es donde se abre: lo que ya haya escrito, si existe.
    #>
    param([string]$Initial = '', [string]$Title = '')
    try {
        [void](Initialize-CvGui)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "$Title"
        $dlg.ShowNewFolderButton = $true
        $ini = "$Initial".Trim()
        if ($ini -ne '' -and (Test-Path -LiteralPath $ini)) { $dlg.SelectedPath = $ini }
        $r = $dlg.ShowDialog()
        $sel = "$($dlg.SelectedPath)"
        $dlg.Dispose()
        if ($r -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
        return $sel
    } catch { return '' }
}

function Show-CvGuiFilePicker {
    <#
        El dialogo de ELEGIR FICHERO de Windows. Devuelve la ruta elegida o '' (cancelado o fallo).
        -Filter es el filtro de tipos en formato WinForms ('Programas|*.exe|Todos|*.*').
    #>
    param(
        [string]$Initial = '',
        [string]$Title = '',
        [string]$Filter = ''
    )
    try {
        [void](Initialize-CvGui)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "$Title"
        $dlg.CheckFileExists = $true
        if ("$Filter" -ne '') { $dlg.Filter = "$Filter" }
        $ini = "$Initial".Trim()
        if ($ini -ne '') {
            $dir = Split-Path -Parent $ini
            if ("$dir" -ne '' -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
            if (Test-Path -LiteralPath $ini) { $dlg.FileName = $ini }
        }
        $r = $dlg.ShowDialog()
        $sel = "$($dlg.FileName)"
        $dlg.Dispose()
        if ($r -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
        return $sel
    } catch { return '' }
}

function Set-CvGuiTrayText {
    <#
        El rotulo del icono del area de notificacion. Va aparte por un detalle que revienta:
        NotifyIcon.Text no admite mas de 63 caracteres y pasarse LANZA, asi que se recorta.
    #>
    param($Icon, [string]$Text = '')
    if ($null -eq $Icon) { return $Icon }
    try {
        $t = "$Text"
        if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
        $Icon.Text = $t
    } catch { }
    return $Icon
}

function Add-CvGuiTrayIcon {
    <#
        Al MINIMIZAR, la ventana se va al AREA DE NOTIFICACION (junto al reloj) en vez de quedarse en
        la barra de tareas: se queda minimizada pero SIN boton en la barra, y deja su icono. Vuelve
        con doble clic o con 'Abrir' en su menu, y vuelve DELANTE (Set-CvGuiForeground: una ventana
        restaurada detras no se ve).

        OJO: la ventana que lo use tiene que abrirse con Application.Run, NO con ShowDialog. Sobre
        un dialogo modal, tanto Hide() como tocar ShowInTaskbar TERMINAN su bucle: la ventana se
        cierra al minimizarla -medido con la cola de verdad, que por eso abre con Run-.

        -Enabled se consulta EN CADA minimizado, asi que la casilla que lo manda se puede cambiar sin
        volver a montar nada. -BalloonMs (0 = nunca) ensena UNA vez por sesion el aviso de donde se
        ha metido la ventana: sin el, la primera vez parece que se ha cerrado.

        Los manejadores se cierran sobre las variables de aqui con GetNewClosure() a proposito: esta
        funcion RETORNA y sus locales se irian, que es como pierde su temporizador quien lo crea
        dentro de un manejador (ver ref-gotchas.md).

        Devuelve el NotifyIcon: hace falta para ponerle el estado (Set-CvGuiTrayText) y, sobre todo,
        para apagarlo al cerrar -un NotifyIcon sin Dispose deja el icono FANTASMA en la barra hasta
        que pasas el raton por encima-, cosa que ya hace solo al cerrarse la ventana.
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [string]$Text = '',
        [scriptblock]$Enabled = $null,
        [int]$BalloonMs = 0
    )
    $ni = $null
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ico = Get-CvGuiAppIconSmall    # el de 16 (o lo que pida el sistema), no el de 32 encogido
        if ($null -ne $ico) { $ni.Icon = $ico }
        [void](Set-CvGuiTrayText -Icon $ni -Text $Text)

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miAbrir  = $menu.Items.Add((Get-CvText -Key 'comun.abrir'))
        $miCerrar = $menu.Items.Add((Get-CvText -Key 'comun.cerrar'))
        $ni.ContextMenuStrip = $menu
        [void](Set-CvGuiMenuTheme -Menu $menu -Palette (Get-CvGuiCurrentPalette))
        # Y cada vez que se abre, con el tema de AHORA: cuelga del icono y no de un control, asi que
        # el boton 'Tema' de la cola no lo alcanzaba y se quedaba con los colores de antes.
        $menu.Add_Opening({
            try { [void](Set-CvGuiMenuTheme -Menu $menu -Palette (Get-CvGuiCurrentPalette)) } catch { }
        }.GetNewClosure())

        # Ultimo = como estaba la ventana ANTES de minimizarla. Sin esto, volver la dejaba siempre
        # en 'Normal': una ventana maximizada volvia pequena, y ademas cerrar desde el icono habria
        # guardado en el layout que NO estaba maximizada.
        $est = @{
            Avisado = $false
            Ultimo  = [System.Windows.Forms.FormWindowState]::Normal
        }
        $volver = {
            try {
                $Form.Show()
                $Form.WindowState = $est.Ultimo
                $ni.Visible = $false
                [void](Set-CvGuiForeground -Form $Form)
            } catch { }
        }.GetNewClosure()
        $ni.Add_DoubleClick($volver)
        $miAbrir.Add_Click($volver)
        # Para que quien la tenga pueda sacarla de aqui sin pasar por el icono (la cola lo usa cuando
        # otro arranque le pide salir al frente, ver Request-CvQueueInstance).
        $ni.Tag = $volver
        # Cerrar desde el menu pasa por el cierre NORMAL de la ventana (con su confirmacion si hay
        # workers), no por un Dispose a traicion.
        $miCerrar.Add_Click({
            try {
                # Se devuelve a como estaba antes de cerrar: quien guarde su tamano al cerrarse
                # (la cola lo hace) apuntaria 'no maximizada' si se cerrara escondida.
                $Form.Show()
                $Form.WindowState = $est.Ultimo
                $Form.Close()
            } catch { }
        }.GetNewClosure())

        $Form.Add_Resize({
            try {
                if ($Form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
                    # Maximizada o normal: se apunta, que es a lo que hay que volver.
                    $est.Ultimo = $Form.WindowState
                    return
                }
                if ($null -ne $Enabled -and -not (& $Enabled)) { return }
                $ni.Visible = $true
                $Form.Hide()
                if ($BalloonMs -gt 0 -and -not $est.Avisado) {
                    $est.Avisado = $true
                    $ni.BalloonTipTitle = "$($ni.Text)"
                    $ni.BalloonTipText  = (Get-CvText -Key 'gui.tray.oculta')
                    $ni.ShowBalloonTip($BalloonMs)
                }
            } catch { }
        }.GetNewClosure())
        $Form.Add_FormClosed({
            # El menu tambien: NotifyIcon.Dispose no se lleva el suyo.
            try { $ni.Visible = $false; $ni.Dispose(); $menu.Dispose() } catch { }
        }.GetNewClosure())
    } catch { $ni = $null }
    return $ni
}

function New-CvGuiProgressPanel {
    <#
        Barra de progreso PINTADA a mano. La del sistema ignora los colores (la dibuja Windows), asi
        que en oscuro se queda como una franja clara; esta se pinta con el color de acento del tema y
        vale para los dos.

        Se maneja con Set-CvGuiProgressValue (0-100) o, con -Marquee, se mueve sola mientras se
        analiza algo. Ese temporizador se para SOLO cuando la barra se esconde y se tira cuando la
        barra se destruye (con su ventana): antes habia que acordarse de Stop-CvGuiProgress, nadie lo
        hacia, y cada editor de jobs abierto dejaba uno vivo para siempre repintando 16 veces por
        segundo una barra que ya no existia.
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
        # Escondida no se anima (se para el temporizador) y al volver a verse, sigue.
        $pb.Add_VisibleChanged({
            try {
                $e2 = $pb.Tag
                if ($null -eq $e2.Timer) { return }
                if ($pb.Visible -and [bool]$e2.Marquee) { $e2.Timer.Start() } else { $e2.Timer.Stop() }
            } catch { }
        }.GetNewClosure())
        # Con la ventana se va el temporizador: un Timer en marcha no lo recoge nadie (se queda
        # enganchado a si mismo) y seguiria saltando para siempre.
        $pb.Add_Disposed({
            try {
                $e2 = $pb.Tag
                if ($null -ne $e2.Timer) { $e2.Timer.Stop(); $e2.Timer.Dispose(); $e2.Timer = $null }
            } catch { }
        }.GetNewClosure())
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
    # Sin 'seguir' (se esta LEYENDO) y con algo ya en el panel, no se repinta: poner el texto nuevo
    # devolvia el cursor y el scroll al principio cada vez que el log crecia. La huella no se apunta,
    # asi que en cuanto se vuelva a marcar 'seguir' se repinta con lo ultimo.
    if (-not $Follow -and $TextBox.TextLength -gt 0) { return $false }
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
            Show-CvGuiInfo -Title $Title -Message (Get-CvText -Key 'gu.noabre' -Values @($Path, $_.Exception.Message))
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

        'flow' es una celda con VARIOS controles pequenos dentro (etiqueta + campo + etiqueta +
        campo...), en su campo Items y con el mismo formato: una celda de una rejilla solo admite un
        control, y partirla en columnas sueltas descuadraria las demas filas.
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
        'flow' {
            $c = New-Object System.Windows.Forms.FlowLayoutPanel
            $c.FlowDirection = 'LeftToRight'
            $c.WrapContents  = $false
            $c.AutoSize      = $true
            $c.Margin        = New-Object System.Windows.Forms.Padding($gap, 0, 3, 0)
            if ($fill) { $c.Dock = 'Fill' }
            foreach ($sub in @($Item.Items | Where-Object { $null -ne $_ })) { $c.Controls.Add((New-CvGuiCatalogControl -Item $sub -FontSize $FontSize)) }
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
        foreach ($sub in @($c.Controls)) { if ("$($sub.Name)" -ne '') { $out["$($sub.Name)"] = $sub } }
    }
    return $out
}

function Add-CvGuiFormRows {
    <#
        Las filas de un formulario (TableLayoutPanel) desde un CATALOGO: la columna 0 es la etiqueta
        y las demas, los controles de esa fila.

        Cada fila: @{ Label = 'Recorte:'; Cells = @(...) }, y cada celda una entrada de catalogo
        (ver New-CvGuiCatalogControl) con Span opcional. Las celdas se van colocando a partir de la
        columna 1, cada una detras de la anterior. Devuelve la tabla Nombre -> control, y los
        controles de dentro de una celda 'flow' salen en ella igual que los de primer nivel: la
        ventana los coge por su nombre sin saber que estan anidados.
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
            foreach ($sub in @($c.Controls)) { if ("$($sub.Name)" -ne '') { $out["$($sub.Name)"] = $sub } }
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
        if (-not (Initialize-CvGui)) { return $false }
        $form = New-Object System.Windows.Forms.Form
        $form.Text          = $Title
        $form.StartPosition = 'CenterScreen'
        $form.Size          = New-Object System.Drawing.Size(800, 600)
        $rtb = New-Object System.Windows.Forms.RichTextBox
        $rtb.Dock       = 'Fill'
        $rtb.ReadOnly   = $true
        $rtb.WordWrap   = $false
        $rtb.Font       = Get-CvGuiFont -Family 'Consolas' -Size 10
        $rtb.DetectUrls = $false
        $rtb.Text       = $Text
        $form.Controls.Add($rtb)
        # ESC cierra la ventana.
        $form.KeyPreview = $true
        $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
        # Como las demas ventanas: tema de la sesion, icono del programa y el monitor de la principal
        # (sin esto, en oscuro salia BLANCA y en el monitor del raton).
        [void](Set-CvGuiTheme -Form $form)
        [void]$form.ShowDialog()
        $form.Dispose()
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function *
