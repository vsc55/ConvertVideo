<#
    GuiSplashWindow.psm1 - La PANTALLA DE ARRANQUE de la cola: sale nada mas lanzar Convert-gui.cmd
    y dice que se esta haciendo mientras carga lo demas.

    Por que hace falta: entre el doble clic y la ventana pasaban 8-12 s sin nada a la vista
    (medido: ~2,5 s cargando modulos, ~2 s de sesion y comprobaciones y ~6 s montando la ventana),
    y no se sabia si el programa estaba haciendo algo o se habia quedado colgado.

    Como funciona: la pantalla vive en su PROPIO hilo (un runspace STA con su propio bucle de
    WinForms), porque el hilo principal esta ocupado justo en lo que tarda -cargar modulos, montar
    la cola- y una ventana suya no se repintaria ni se moveria hasta que acabase. Los dos hilos solo
    comparten un hashtable sincronizado: el principal escribe el texto del paso (Set-CvSplashText) o
    pide cerrarla (Stop-CvSplashWindow) y el de la pantalla lo mira en su temporizador.

    Se carga ANTES que Gui.psm1 (es lo que mas tarda en cargar), asi que no puede pedirle la paleta:
    con tema CLARO lleva los colores de la pastilla del icono de la aplicacion (New-CvGuiAppBitmap),
    y con OSCURO los de la paleta oscura de Get-CvGuiPalette (los tests comprueban que coinciden).
    El tema lo decide quien la llama, con la misma Resolve-CvGuiTheme que el resto de ventanas. Los
    textos tambien los pone quien la llama (Get-CvText): aqui no hay ninguno.
#>

function Get-CvSplashColors {
    <#
        PURO. Los colores de la pantalla de arranque, como RGB. No salen de Get-CvGuiPalette porque
        esta pantalla sale ANTES de cargar Gui.psm1, que es justo lo que tarda; por eso los tests
        comparan los del tema oscuro con los de esa paleta, para que no se separen.

          - Claro: el azul del degradado de la pastilla del icono (New-CvGuiAppBitmap), con letra y
            barra blancas. Strip vacio: el fondo ya es el color de la marca.
          - Oscuro (-Dark): el fondo, el texto, el texto secundario, las lineas y el acento de la
            paleta oscura (Back / Fore / Muted / Border / Accent), y una franja arriba en el acento
            para que se reconozca el programa.
    #>
    param([bool]$Dark = $false)
    if ($Dark) {
        return @{
            Top    = @(32, 32, 32)
            Bottom = @(32, 32, 32)
            Text   = @(228, 228, 228)
            Soft   = @(150, 150, 150)
            Track  = @(80, 80, 85)
            Bar    = @(0, 120, 215)
            Strip  = @(0, 120, 215)
        }
    }
    return @{
        Top    = @(56, 160, 245)
        Bottom = @(10, 92, 176)
        Text   = @(255, 255, 255)
        Soft   = @(200, 225, 250)
        Track  = @(30, 110, 190)
        Bar    = @(255, 255, 255)
        Strip  = @()
    }
}

function Start-CvSplashWindow {
    <#
        Abre la pantalla de arranque en su propio hilo y vuelve AL MOMENTO (no espera a que se vea).
        -Title (nombre y version) y -Text (lo que se esta haciendo). -TimeoutSec la cierra sola pase
        lo que pase: si quien la abrio se muere sin cerrarla, no se queda para siempre en pantalla.
        -Dark, con los colores del tema oscuro (Get-CvSplashColors).

        Devuelve el objeto que piden Set-CvSplashText / Stop-CvSplashWindow, o $null si no se pudo
        (sin GUI, sin runspace...): una pantalla de arranque nunca puede impedir arrancar.
    #>
    param(
        [string]$Title = '',
        [string]$Text = '',
        [int]$TimeoutSec = 120,
        [int]$FrameMs = 40,
        [bool]$Dark = $false
    )
    try {
        $estado = [hashtable]::Synchronized(@{
            Title   = "$Title"
            Text    = "$Text"
            Close   = $false
            Shown   = $false
            Timeout = [Math]::Max(5, $TimeoutSec)
            FrameMs = [Math]::Max(15, $FrameMs)
            Colors  = (Get-CvSplashColors -Dark $Dark)
        })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('estado', $estado)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            [System.Windows.Forms.Application]::EnableVisualStyles()
            $c = $estado.Colors
            $col = { param($v) [System.Drawing.Color]::FromArgb([int]$v[0], [int]$v[1], [int]$v[2]) }

            $f = New-Object System.Windows.Forms.Form
            $f.FormBorderStyle = 'None'
            $f.StartPosition   = 'CenterScreen'
            $f.ShowInTaskbar   = $true
            # SIEMPRE ENCIMA mientras dura. Lanzada desde un acceso directo MINIMIZADO, el proceso nace
            # sin derecho de primer plano y Windows la dejaba DETRAS de lo que estuvieras usando (el
            # explorador desde el que se abrio): Activate() no basta. TopMost es orden de apilado, no
            # foco, y eso Windows si lo deja. No molesta: se quita en cuanto la cola tiene la lista
            # pintada (y antes de cualquier pregunta o aviso), y como mucho a los TimeoutSec.
            $f.TopMost         = $true
            $f.Text            = "$($estado.Title)"
            $f.Size            = New-Object System.Drawing.Size(440, 150)
            $f.BackColor       = (& $col $c.Bottom)
            # Doble bufer: la barra se repinta cada pocos ms y sin el parpadea.
            $p = $f.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
            $p.SetValue($f, $true, $null)

            $titulo = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
            $letra  = New-Object System.Drawing.Font('Segoe UI', 10)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $f.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $r = $s.ClientRectangle
                $fondo = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, (& $col $c.Top), (& $col $c.Bottom), 90)
                $g.FillRectangle($fondo, $r)
                $fondo.Dispose()
                if (@($c.Strip).Count -eq 3) {
                    $bStrip = New-Object System.Drawing.SolidBrush (& $col $c.Strip)
                    $g.FillRectangle($bStrip, 0, 0, $r.Width, 4)
                    $bStrip.Dispose()
                }
                $bT = New-Object System.Drawing.SolidBrush (& $col $c.Text)
                $bS = New-Object System.Drawing.SolidBrush (& $col $c.Soft)
                $g.DrawString("$($estado.Title)", $titulo, $bT, [float]24, [float]22)
                $g.DrawString("$($estado.Text)", $letra, $bS, (New-Object System.Drawing.RectangleF([float]26, [float]66, [float]($r.Width - 52), [float]36)))
                $bT.Dispose()
                $bS.Dispose()
                # La barra que va y viene: un tramo claro que recorre la pista una y otra vez.
                $x0 = 26
                $w  = $r.Width - 52
                $y  = $r.Height - 30
                $bPista = New-Object System.Drawing.SolidBrush (& $col $c.Track)
                $g.FillRectangle($bPista, $x0, $y, $w, 6)
                $bPista.Dispose()
                $tramo = [int]($w * 0.28)
                $fase = (($sw.ElapsedMilliseconds % 1600) / 1600.0)
                $xi = [int]($x0 - $tramo + ($w + $tramo) * $fase)
                $a = [Math]::Max($x0, $xi)
                $b = [Math]::Min($x0 + $w, $xi + $tramo)
                if ($b -gt $a) {
                    $bBar = New-Object System.Drawing.SolidBrush (& $col $c.Bar)
                    $g.FillRectangle($bBar, $a, $y, ($b - $a), 6)
                    $bBar.Dispose()
                }
            })
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = [int]$estado.FrameMs
            $t.Add_Tick({
                if ([bool]$estado.Close -or $sw.Elapsed.TotalSeconds -gt [int]$estado.Timeout) {
                    $t.Stop()
                    $f.Close()
                    return
                }
                if ($f.Text -ne "$($estado.Title)") { $f.Text = "$($estado.Title)" }
                # Desde un acceso directo MINIMIZADO, Windows aplica ese 'minimizada' a la PRIMERA
                # ventana del proceso, que es esta: se veria solo en la barra de tareas (medido).
                if ($f.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) {
                    $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                    $f.TopMost = $true
                }
                $f.Invalidate()
            })
            $f.Add_Shown({ $estado.Shown = $true; $f.Activate() })
            $t.Start()
            [System.Windows.Forms.Application]::Run($f)
            $t.Dispose()
            $f.Dispose()
        })
        $h = $ps.BeginInvoke()
        return @{
            State      = $estado
            PowerShell = $ps
            Runspace   = $rs
            Handle     = $h
        }
    } catch {
        return $null
    }
}

function Set-CvSplashText {
    <# Cambia el texto del paso en curso. Sin pantalla ($null), no hace nada. #>
    param($Splash, [string]$Text = '')
    if ($null -eq $Splash -or $null -eq $Splash.State) { return }
    $Splash.State.Text = "$Text"
}

function Stop-CvSplashWindow {
    <#
        Cierra la pantalla de arranque y suelta su hilo. Espera como mucho -WaitMs a que se cierre (lo
        hace en el siguiente fotograma), y si no, la deja ir: la cierra su propio plazo. Nunca lanza.
    #>
    param($Splash, [int]$WaitMs = 1500)
    if ($null -eq $Splash -or $null -eq $Splash.State) { return }
    try {
        $Splash.State.Close = $true
        if ($null -ne $Splash.Handle -and $Splash.Handle.AsyncWaitHandle.WaitOne([Math]::Max(0, $WaitMs))) {
            try { [void]$Splash.PowerShell.EndInvoke($Splash.Handle) } catch { }
            try { $Splash.PowerShell.Dispose() } catch { }
            try { $Splash.Runspace.Dispose() } catch { }
        }
    } catch { }
}

Export-ModuleMember -Function *
