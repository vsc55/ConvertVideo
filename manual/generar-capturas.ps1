<#
    generar-capturas.ps1 - Rehace las capturas del manual (manual\img\*.png).

    Abre las ventanas DE VERDAD sobre un ROOT TEMPORAL sembrado a mano (%TEMP%\cv_manual_*): no se
    toca nada del proyecto real, ni Original\, ni Proceso\, ni el config.json de al lado. Los videos
    son las fixtures de test\ copiadas con nombres inventados (Serie_1x01...), asi que en las
    capturas no aparece material de nadie.

    Cada ventana es MODAL, asi que no se puede "abrir y capturar" desde fuera: se arranca un
    temporizador ANTES de abrirla, y es ese temporizador el que la busca, la retrata y la cierra
    (el mismo truco que usan las baterias test\gui-*.ps1 para manejarlas sin raton).

    Uso:  powershell -ExecutionPolicy Bypass -Sta -File manual\generar-capturas.ps1
          ...  -Only cola,job        (solo esos grupos: cola, job, preparar, setup)
          ...  -Only gif             (el GIF de uso; ver abajo)
          ...  -Out C:\otra\carpeta  (por defecto manual\img)

    El grupo 'gif' NO entra en la tanda normal y hay que pedirlo: no retrata, GRABA una sesion de
    verdad (preparar + codificar tres archivos) y eso tarda minutos y gasta CPU. Sale
    manual\img\uso.gif, montado con el ffmpeg de tools\.

    Las capturas se le piden a CADA VENTANA (PrintWindow), no a la pantalla, asi que salen bien
    aunque se este trabajando en el equipo mientras corren. La UNICA excepcion es la del menu
    contextual desplegado -un menu es una ventana emergente aparte y solo se puede fotografiar de la
    pantalla-: para esa conviene no tocar nada, y si la ventana no esta delante se avisa.

    Necesita entorno grafico, -Sta y las herramientas instaladas (tools\, para el ffprobe de los
    resumenes y del editor). Sin eso, aborta diciendolo.
#>
[CmdletBinding()]
param(
    [string]$Out = '',
    [string[]]$Only = @(),
    # Tema de las ventanas para esta tanda. Por defecto CLARO y no 'system': si no, las capturas
    # saldrian de un color o de otro segun como tenga Windows la maquina donde se generen.
    # En oscuro los PNG se guardan con el sufijo '-oscuro', para no pisar los del manual.
    [ValidateSet('light', 'dark')][string]$Theme = 'light',
    # Idioma de las ventanas de ESTA tanda. Las del manual van en castellano pase lo que pase (con
    # 'auto' saldrian en el idioma de la maquina donde se generen); el parametro esta para poder
    # MIRAR como queda una traduccion sin tocar nada.
    [string]$Lang = 'es'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

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
    'GuiSetup'
    'GuiConfig'
    'GuiConvert'
    'GuiJob'
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
    'SetupCore'
    'ConfigEditor'
    # Las VENTANAS, una por formulario (lib\form\); la logica que se prueba sin abrir
    # ninguna se queda en los modulos de arriba.
    'form\GuiConvertWindow'
    'form\GuiWorkerLogWindow'
    'form\GuiJobWindow'
    'form\GuiJobBulkWindow'
    'form\GuiPrepareWindow'
    'form\GuiSetupWindow'
    'form\GuiConfigChooser'
    'form\GuiToolsWindow'
    'form\GuiLogsWindow'
    'form\GuiMaintenanceWindow'
    'form\GuiCleanWindow'
    'form\GuiConfigWindow'
    'form\GuiJobProfileDialog'
    'form\GuiProfileEditorWindow'
    'form\GuiProfilesWindow'
)
foreach ($m in $modules) {
    $p = Join-Path $Lib ("{0}.psm1" -f $m)
    if (Test-Path -LiteralPath $p) { Import-Module $p -Force }
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    Write-Host 'Hace falta -Sta (powershell -Sta -File manual\generar-capturas.ps1)' -ForegroundColor Red
    exit 1
}
if (-not (Initialize-CvGui)) {
    Write-Host 'Sin entorno grafico: no hay nada que capturar.' -ForegroundColor Red
    exit 1
}
if (-not $Out) { $Out = Join-Path $PSScriptRoot 'img' }
New-Item -ItemType Directory -Path $Out -Force | Out-Null

# ================================================================================================
#  Utilidades
# ================================================================================================

# Grupos pedidos con -Only. Se parten por comas a mano: al lanzar el script con -File (que es como
# se lanza siempre), PowerShell NO separa '-Only job,setup' en dos elementos, lo pasa como UNA
# cadena, y entonces no coincidia con ningun grupo y no se capturaba nada sin decir por que.
$script:groups = @(@($Only) | ForEach-Object { "$_" -split ',' } | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })

function Test-Group {
    <#
        Se pide este grupo de capturas? Sin -Only se hacen todos... menos 'gif': ese GRABA una
        sesion entera (minutos de CPU codificando de verdad), asi que hay que pedirlo por su nombre.
    #>
    param([string]$Name)
    if ($Name -eq 'gif') { return ($script:groups -contains 'gif') }
    return ($script:groups.Count -eq 0 -or $script:groups -contains $Name)
}

# El rectangulo de una ventana NO es Form.Bounds: desde Windows 10, alrededor hay unos pixeles de
# borde invisible (el area de redimensionar) que en la captura salen como un trozo del escritorio.
# Lo que se ve de verdad lo dice el propio gestor de ventanas: DWMWA_EXTENDED_FRAME_BOUNDS.
Add-Type -Namespace CvShot -Name Dwm -MemberDefinition @'
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(System.IntPtr hwnd, int attr, out RECT rect, int size);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(System.IntPtr hwnd, System.IntPtr hdc, uint flags);
    [DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@ -ErrorAction SilentlyContinue

function Get-WindowRect {
    <# Lo que ocupa la ventana EN PANTALLA, sin el borde invisible. #>
    param([Parameter(Mandatory)]$Form)
    try {
        $r = New-Object CvShot.Dwm+RECT
        $hr = [CvShot.Dwm]::DwmGetWindowAttribute($Form.Handle, 9, [ref]$r, 16)   # 9 = EXTENDED_FRAME_BOUNDS
        if ($hr -eq 0 -and ($r.Right - $r.Left) -gt 0) {
            return (New-Object System.Drawing.Rectangle($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)))
        }
    } catch { }
    return $Form.Bounds
}

function Get-TopForm {
    <# La ventana de mas arriba: la ULTIMA abierta, que con dialogos modales es la que manda. #>
    $fs = @([System.Windows.Forms.Application]::OpenForms)
    if ($fs.Count -eq 0) { return $null }
    return $fs[$fs.Count - 1]
}

function Get-WindowBitmap {
    <#
        Los pixeles de LA VENTANA, pedidos a la propia ventana (PrintWindow con
        PW_RENDERFULLCONTENT), no fotografiando la pantalla.

        Esto no es un capricho: fotografiar la pantalla captura lo que haya ENCIMA. Si mientras se
        generan las capturas otra aplicacion se pone delante -o simplemente se esta trabajando en el
        equipo-, en el PNG sale el escritorio de otro. Paso: una captura acabo con el editor de
        codigo de quien la genero. Con PrintWindow se retrata la ventana aunque este tapada.

        Devuelve el bitmap del RECTANGULO DE VENTANA (con su borde invisible; quien llama recorta),
        o $null si el pintado falla o sale en blanco (ventanas que no responden a PrintWindow).
    #>
    param([Parameter(Mandatory)]$Form)
    $wr = $Form.Bounds
    if ($wr.Width -le 0 -or $wr.Height -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($wr.Width, $wr.Height)
    try {
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $ok  = $false
        try { $ok = [CvShot.Dwm]::PrintWindow($Form.Handle, $hdc, 2) } catch { $ok = $false }   # 2 = PW_RENDERFULLCONTENT
        $g.ReleaseHdc($hdc)
        $g.Dispose()
        if (-not $ok) { $bmp.Dispose(); return $null }
        # Comprobacion de vida: algunas ventanas devuelven 'true' y un lienzo vacio. Si cuatro puntos
        # repartidos son el MISMO color, se da por fallida y se cae a la foto de pantalla.
        $c1 = $bmp.GetPixel(2, 2)
        $c2 = $bmp.GetPixel([int]($wr.Width / 2), 2)
        $c3 = $bmp.GetPixel(2, [int]($wr.Height / 2))
        $c4 = $bmp.GetPixel([int]($wr.Width / 2), [int]($wr.Height - 3))
        if ($c1 -eq $c2 -and $c2 -eq $c3 -and $c3 -eq $c4) { $bmp.Dispose(); return $null }
        return $bmp
    } catch {
        try { $bmp.Dispose() } catch { }
        return $null
    }
}

function Save-Shot {
    <#
        Retrata una ventana (o un trozo, con -Rect) y lo guarda como PNG.

        Por defecto se le piden los pixeles a la VENTANA (Get-WindowBitmap): sale bien aunque este
        tapada o no tenga el foco. Con -Screen se fotografia la PANTALLA, que es la unica forma de
        pillar lo que no pertenece a la ventana -un menu contextual desplegado vive en su propia
        ventana emergente-; en ese caso si hace falta que este delante, y se comprueba.
    #>
    param(
        [Parameter(Mandatory)]$Form,
        [Parameter(Mandatory)][string]$Name,
        $Rect = $null,
        # Sin tocar el foco: activar la ventana CIERRA un menu contextual desplegado.
        [switch]$NoFocus,
        # Fotografiar la pantalla (para menus desplegados y demas ventanas emergentes).
        [switch]$Screen
    )
    if (-not $NoFocus) {
        # Se intenta ponerla delante aunque se vaya a usar PrintWindow: una ventana sin foco se pinta
        # con la barra de titulo APAGADA, y en el manual queda como si estuviera deshabilitada.
        for ($i = 0; $i -lt 4; $i++) {
            try { $Form.TopMost = $true; $Form.Activate() } catch { }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
            $fg = [System.IntPtr]::Zero
            try { $fg = [CvShot.Dwm]::GetForegroundWindow() } catch { }
            if ($fg -eq $Form.Handle) { break }
        }
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.Application]::DoEvents()

    $frame = Get-WindowRect -Form $Form      # lo que se ve, sin el borde invisible
    $bmp   = $null
    # En OSCURO se fotografia la pantalla: la barra de titulo oscura la compone el gestor de ventanas
    # (DWM) y PrintWindow devuelve el marco claro por defecto, que en el manual pareceria un fallo.
    if ($Theme -eq 'dark') { $Screen = $true }
    if (-not $Screen) {
        $full = Get-WindowBitmap -Form $Form
        if ($null -ne $full) {
            $wr  = $Form.Bounds
            # El recorte pedido esta en coordenadas de PANTALLA: se pasa a coordenadas de la ventana.
            $src = $(if ($null -ne $Rect) { $Rect } else { $frame })
            $cut = New-Object System.Drawing.Rectangle(($src.X - $wr.X), ($src.Y - $wr.Y), $src.Width, $src.Height)
            $cut.Intersect((New-Object System.Drawing.Rectangle(0, 0, $full.Width, $full.Height)))
            if ($cut.Width -gt 0 -and $cut.Height -gt 0) {
                $bmp = $full.Clone($cut, $full.PixelFormat)
            }
            $full.Dispose()
        }
    }
    if ($null -eq $bmp) {
        # Foto de pantalla: o se ha pedido (-Screen) o PrintWindow no ha dado nada. Aqui SI importa
        # que la ventana este delante, asi que se insiste un poco y se avisa si no se consigue.
        $b = $(if ($null -ne $Rect) { $Rect } else { $frame })
        if (-not $NoFocus) {
            for ($i = 0; $i -lt 6; $i++) {
                $fg = [System.IntPtr]::Zero
                try { $fg = [CvShot.Dwm]::GetForegroundWindow() } catch { }
                if ($fg -eq $Form.Handle) { break }
                try { $Form.TopMost = $true; $Form.Activate() } catch { }
                # Windows NO deja que un proceso que no esta en primer plano se ponga delante por las
                # buenas (Activate no basta): minimizar y restaurar si lo consigue. Importa para el
                # tema OSCURO, porque la barra de titulo solo se pinta oscura en la ventana ACTIVA.
                if ($i -ge 1) {
                    try {
                        $Form.WindowState = 'Minimized'
                        [System.Windows.Forms.Application]::DoEvents()
                        $Form.WindowState = 'Normal'
                        $Form.Activate()
                    } catch { }
                }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 250
            }
            $fg2 = [System.IntPtr]::Zero
            try { $fg2 = [CvShot.Dwm]::GetForegroundWindow() } catch { }
            if ($fg2 -ne $Form.Handle) {
                Write-Host ("  [AVISO] {0}: la ventana no esta delante; la captura puede salir tapada" -f $Name) -ForegroundColor Yellow
            }
        }
        $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $g.Dispose()
    }
    $sufijo = $(if ($Theme -eq 'dark') { '-oscuro' } else { '' })
    $path = Join-Path $Out ("{0}{1}.png" -f $Name, $sufijo)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    try { $Form.TopMost = $false } catch { }
    Write-Host ("  [PNG]  {0}" -f $path) -ForegroundColor Green
}

function Get-ControlRect {
    <# Rectangulo EN PANTALLA de un control (para recortar una barra, una tabla...). #>
    param([Parameter(Mandatory)]$Control, [int]$Pad = 0)
    $p = $Control.PointToScreen([System.Drawing.Point]::Empty)
    return (New-Object System.Drawing.Rectangle(($p.X - $Pad), ($p.Y - $Pad), ($Control.Width + (2 * $Pad)), ($Control.Height + (2 * $Pad))))
}

# El temporizador que maneja cada ventana: se arranca ANTES de abrirla (que es modal) y ejecuta
# $script:body en cada tick. $script:step es el paso del guion de esa ventana.
$script:body     = $null
$script:step     = 0
$script:waits    = 0
$script:err      = ''
$script:busy     = $false
$script:deadline = [datetime]::UtcNow.AddYears(1)
$shotTimer = New-Object System.Windows.Forms.Timer
$shotTimer.Interval = 400
$shotTimer.Add_Tick({
    # RE-ENTRADA: capturar llama a DoEvents (para que la ventana se pinte antes del retrato) y eso
    # deja correr al propio temporizador, que volveria a entrar aqui con el paso todavia sin avanzar
    # -y se repetiria la misma captura sin fin, que es justo lo que paso al escribir esto-.
    if ($script:busy) { return }
    $script:busy = $true
    try {
        # CORTAFUEGOS: pase lo que pase, ninguna ventana se queda abierta esperando a nadie. Estas
        # ventanas son MODALES y se abren sin vigilancia: si un guion se atasca, el script se queda
        # colgado con una ventana encima de todo (y con TopMost, molestando).
        if ([datetime]::UtcNow -gt $script:deadline) {
            $script:err = 'se agoto el tiempo de esta ventana'
            $shotTimer.Stop()
            foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
            return
        }
        if ($null -ne $script:body) { & $script:body }
    } catch {
        $script:err = "$_"
        $shotTimer.Stop()
        foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
    } finally {
        $script:busy = $false
    }
})

function Start-Flow {
    <# Empieza el guion de una ventana. Justo despues se la abre (ShowDialog no vuelve hasta cerrar). #>
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [int]$Seconds = 120
    )
    $script:body     = $Body
    $script:step     = 0
    $script:waits    = 0
    $script:err      = ''
    $script:busy     = $false
    $script:deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    $shotTimer.Start()
}

function Stop-Flow {
    <# Cierra el guion y cuenta si algo se torcio (que no se vea solo como una captura que falta). #>
    $shotTimer.Stop()
    $script:body = $null
    if ($script:err) { Write-Host ("  [ERROR] {0}" -f $script:err) -ForegroundColor Red }
}

function Wait-Step {
    <# Un tick mas de espera; con -Max agotado se da por perdida la ventana y se cierra. #>
    param([int]$Max = 200)
    $script:waits++
    if ($script:waits -gt $Max) {
        $script:err = 'la ventana no llego a estar lista'
        $shotTimer.Stop()
        foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
    }
}

# ================================================================================================
#  El escenario: un ROOT temporal con videos de ejemplo
# ================================================================================================

$script:shotCfg = ''

function New-ShotRoot {
    <#
        Carpeta de trabajo de mentira: config propio, tools\ enlazado al del repo (para que haya
        ffprobe) y las carpetas Original/Proceso/Convertido/logs ya creadas. Devuelve el contexto.
    #>
    param([string]$Gui = '"rememberLayout": false, "queueWidth": 1280, "queueHeight": 740, "confirmCloseWithWorkers": false')
    # CV_SHOT_WIDTH: ancho de la ventana de la cola para esta tanda. Sirve para reproducir lo que se
    # ve en una pantalla grande (hubo un fallo del tema que SOLO aparecia con la ventana ancha).
    if ($env:CV_SHOT_WIDTH) { $Gui = $Gui -replace '"queueWidth": \d+', ('"queueWidth": ' + $env:CV_SHOT_WIDTH) }
    $Gui = ('"theme": "{0}", ' -f $Theme) + $Gui
    # AL LADO del proyecto y no en %TEMP%: la ruta SE VE en alguna captura (el estado de setup la
    # imprime), y la de %TEMP% lleva dentro el nombre de usuario de quien genero las imagenes.
    # Si ahi no se puede escribir, %TEMP% y listo.
    $base = Join-Path (Split-Path -Parent $Root) 'ConvertVideo-demo'
    try {
        if (Test-Path -LiteralPath $base) { Remove-ShotRoot -Path $base }
        New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null
        $tmp = $base
    } catch {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cv_manual_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    }
    $cfg = Join-Path $tmp 'config.json'
    $json = '{ "behavior": { "workers": 2 }, "gui": { ' + $Gui + ' } }'
    [void](Save-CvTextFile -Path $cfg -Text $json)
    try {
        New-Item -ItemType Junction -Path (Join-Path $tmp 'tools') -Target (Join-Path $Root 'tools') -ErrorAction Stop | Out-Null
    } catch {
        Write-Host '  [AVISO] no se pudo enlazar tools: los resumenes iran sin ffprobe' -ForegroundColor Yellow
    }
    $ctx = New-CvContext -Root $tmp -ConfigPath $cfg
    [void](Set-CvGuiThemeDefault -Theme "$($ctx.GuiTheme)")   # el tema de ESTA tanda, no el de la maquina
    [void](Set-CvLanguage -Lang $Lang)                       # y en el idioma de la tanda (por defecto, castellano)
    $script:shotCfg = $cfg
    return $ctx
}

function Remove-ShotRoot {
    <#
        Borra el root temporal. La union a tools\ se quita ANTES y con rmdir (que borra el enlace, no
        lo que apunta): un borrado recursivo sobre un enlace es la forma clasica de cargarse la
        carpeta de verdad que hay al otro lado.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $link = Join-Path $Path 'tools'
    if (Test-Path -LiteralPath $link) { & cmd.exe /c rmdir "$link" | Out-Null }
    Remove-Item -Recurse -Force -LiteralPath $Path -ErrorAction SilentlyContinue
}

function Add-ShotVideo {
    <# Copia una fixture de test\ en Original\ con un nombre inventado. #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Fixture)
    $src = Join-Path $Root ("test\{0}" -f $Fixture)
    $dst = Join-Path $Ctx.Original ("{0}.mkv" -f $Name)
    Copy-Item -LiteralPath $src -Destination $dst -Force
    return $dst
}

function Add-ShotJob {
    <#
        Deja preparado el .job.json de un archivo, como habria hecho PREPARAR. -Crop y -Sync se
        ponen a mano para que en las capturas se vean las columnas 'Bordes' y 'Audio' con algo
        (es lo mismo que se guarda si en el editor recortas o corriges la sincronia).
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Prof,
        [string]$Crop = '',
        [double]$Sync = 0
    )
    $file  = Join-Path $Ctx.Original ("{0}.mkv" -f $Name)
    $info  = Get-MediaInfo -Context $Ctx -File $file
    $draft = New-CvJobDraft -Context $Ctx -Prof $Prof -Info $info -File $file
    if ($Crop) { $draft.Crop = $Crop }
    if ($Sync -ne 0 -and @($draft.Audio).Count -gt 0) { $draft.Audio[0].Sync = $Sync }
    [void](Save-CvJobDraft -Context $Ctx -Draft $draft -Info $info)
}

function Get-ShotProfile {
    <# Un perfil del catalogo por lo que dice su etiqueta (para no fijar aqui ningun perfil concreto). #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Match)
    $opts = @(Get-CvJobProfileOptions -Context $Ctx)
    $hit  = @($opts | Where-Object { $_.Text -match $Match })
    if ($hit.Count -gt 0) { return $hit[0].Prof }
    return $opts[0].Prof
}

function Add-ShotLog {
    <# Un log de worker de mentira, para que la pestana Log y la ventana del proceso tengan algo. #>
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path $Ctx.Logs $Name
    $txt = @(
        '[GLOBAL] - ConvertVideo - inicio'
        '[GLOBAL] - Modo: WORKER (desatendido)'
        '[WORKER] - Buscando archivos preparados para codificar...'
        '================================================================'
        '[WORKER] - CODIFICANDO: Serie_1x02'
        '----------------------------------------------------------------'
        '   - ffmpeg 7.1.1   hevc_nvenc   CRF 22'
        '   - Origen : 1920x1080  h264  00:42:10'
        '   - Recorte: 1920:800:0:140   ->   1920x800'
        '   [AUDIO] - spa 5.1 -> aac 192k estereo (retardo +0,250 s)'
        '   [AUDIO] - OK (00:12)'
        '   [VIDEO] - Codificando...'
    ) -join [Environment]::NewLine
    [void](Save-CvTextFile -Path $path -Text $txt)
    return $path
}

# ================================================================================================
#  1) La cola de conversion (Convert-gui.cmd)
# ================================================================================================
if (Test-Group 'cola') {
    Write-Host "`nCola de conversion" -ForegroundColor Cyan
    $ctx  = New-ShotRoot
    $cfgQ = $script:shotCfg
    $prof = Get-ShotProfile -Ctx $ctx -Match 'x265|HEVC|h265'

    # Un archivo por estado, para que la captura ensene la tabla entera de estados.
    foreach ($n in @('Serie_1x01', 'Serie_1x02', 'Serie_1x03', 'Serie_1x04', 'Serie_1x05', 'Serie_1x06')) {
        [void](Add-ShotVideo -Ctx $ctx -Name $n -Fixture 'audio-y-subs-multiidioma.mkv')
    }
    Add-ShotJob -Ctx $ctx -Name 'Serie_1x02' -Prof $prof -Crop '1920:800:0:140' -Sync 0.25
    Add-ShotJob -Ctx $ctx -Name 'Serie_1x03' -Prof $prof -Crop '1920:800:0:140'
    Add-ShotJob -Ctx $ctx -Name 'Serie_1x05' -Prof $prof
    Add-ShotJob -Ctx $ctx -Name 'Serie_1x06' -Prof $prof
    # HECHO = salida escrita y job borrado; SIN TERMINAR = salida escrita pero el job sigue ahi.
    foreach ($n in @('Serie_1x01', 'Serie_1x05')) {
        $outFile = Join-Path $ctx.Convertido ("{0}_fix.{1}" -f $n, $ctx.OutExt)
        [System.IO.File]::WriteAllBytes($outFile, (New-Object byte[] (1150 * 1024)))
    }
    # El que se esta codificando ya tiene su salida A MEDIO ESCRIBIR (es lo que pasa de verdad
    # mientras ffmpeg trabaja): asi se ve la opcion de reproducir el convertido 'a medio hacer'.
    [System.IO.File]::WriteAllBytes((Join-Path $ctx.Convertido ("Serie_1x02_fix.{0}" -f $ctx.OutExt)), (New-Object byte[] (420 * 1024)))
    # CODIFICANDO: bloqueo de un worker VIVO (este mismo proceso) y su estado con el avance.
    $logShot = Add-ShotLog -Ctx $ctx -Name 'Convert_20260919_101500_4242.log'
    [void](Save-CvTextFile -Path (Join-Path $ctx.Proceso 'Serie_1x02.lock') -Text ("PID={0};HOST={1}" -f $PID, $env:COMPUTERNAME))
    Start-CvWorkerState -Context $ctx -Role 'worker' -LogPath $logShot
    Set-CvWorkerFile -Context $ctx -File 'Serie_1x02'
    Update-CvWorkerProgress -Context $ctx -Step 'Video' -Percent 47 -Eta '04:12' -Speed '1.8x'
    # BLOQUEO HUERFANO: un .lock de un worker que ya no existe.
    $deadPid = 0
    for ($i = 999999; $i -gt 100000; $i -= 7777) {
        if (-not (Get-Process -Id $i -ErrorAction SilentlyContinue)) { $deadPid = $i; break }
    }
    [void](Save-CvTextFile -Path (Join-Path $ctx.Proceso 'Serie_1x06.lock') -Text ("PID={0};HOST={1}" -f $deadPid, $env:COMPUTERNAME))

    Start-Flow {
        $f = Get-TopForm
        if ($null -eq $f) { Wait-Step; return }
        $lv = @($f.Controls.Find('cvQueue', $true))
        if ($lv.Count -eq 0 -or $lv[0].Items.Count -lt 6) { Wait-Step; return }
        $lv   = $lv[0]
        $tabs = $f.Controls.Find('cvTabs', $true)[0]
        $sum  = $f.Controls.Find('cvSummary', $true)[0]
        switch ($script:step) {
            0 {
                # Marcar el que se esta codificando: asi el resumen ensena lo que se le va a hacer.
                for ($i = 0; $i -lt $lv.Items.Count; $i++) {
                    if ("$($lv.Items[$i].Text)" -eq 'Serie_1x02') {
                        $lv.Items[$i].Selected = $true
                        $lv.Items[$i].Focused  = $true
                    }
                }
                $script:step = 1
            }
            1 {
                # El resumen hace un ffprobe la primera vez: se espera a que termine de montarse.
                if ("$($sum.Text)" -eq '' -or "$($sum.Text)" -match 'Leyendo') { Wait-Step; return }
                Save-Shot -Form $f -Name 'cola'
                $script:step = 2
            }
            2 {
                # Solo la barra de herramientas, para explicarla boton a boton.
                $b1 = $f.Controls.Find('cvStart', $true)[0]
                # El ultimo boton de la barra (el de tema es el que cierra el grupo de vista).
                $b2 = @($f.Controls.Find('cvTheme', $true))
                if ($b2.Count -eq 0) { $b2 = @($f.Controls.Find('cvRefresh', $true)) }
                $b2 = $b2[0]
                $bar = $b1.Parent
                $p   = $bar.PointToScreen([System.Drawing.Point]::Empty)
                $w   = [Math]::Min($bar.Width, ($b2.Right + 10))
                Save-Shot -Form $f -Name 'cola-barra' -Rect (New-Object System.Drawing.Rectangle($p.X, $p.Y, $w, $bar.Height))
                $script:step = 3
            }
            3 {
                # El menu contextual desplegado (activar la ventana lo cerraria: por eso -NoFocus).
                $lv.ContextMenuStrip.Show($lv, (New-Object System.Drawing.Point(160, 60)))
                [System.Windows.Forms.Application]::DoEvents()
                Save-Shot -Form $f -Name 'cola-menu' -NoFocus -Screen
                $lv.ContextMenuStrip.Close()
                $script:step = 4
            }
            4 {
                [void](Select-CvGuiTab -Tabs $tabs -Index 1)     # Log
                $script:step = 5
            }
            5 {
                Save-Shot -Form $f -Name 'cola-log'
                [void](Select-CvGuiTab -Tabs $tabs -Index 2)     # Opciones
                $script:step = 6
            }
            6 {
                Save-Shot -Form $f -Name 'cola-opciones'
                [void](Select-CvGuiTab -Tabs $tabs -Index 0)
                $script:step = 7
            }
            default {
                $shotTimer.Stop()
                $f.Close()
            }
        }
    }
    [void](Show-CvConvertWindow -Context $ctx -Root $ctx.Root -CfgPath $cfgQ -CfgName 'config.json')
    Stop-Flow

    # La ventana del proceso de un archivo (doble clic en su fila): el log en vivo de su worker.
    Start-Flow {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Name)" -ne 'cvWorkerLog') { Wait-Step; return }
        $txt = @($f.Controls.Find('cvWlText', $true))
        if ($txt.Count -eq 0 -or "$($txt[0].Text)" -eq '') { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'cola-proceso'
        $f.Close()
    }
    [void](Show-CvWorkerLogWindow -Context $ctx -WorkerPid $PID -LogPath $logShot -File 'Serie_1x02')
    Stop-Flow

    Remove-CvWorkerState -Context $ctx
    Remove-ShotRoot -Path $ctx.Root
}

# ================================================================================================
#  2) Elegir perfil y editar el job de un archivo
# ================================================================================================
if (Test-Group 'job') {
    Write-Host "`nPerfil y editor del job" -ForegroundColor Cyan
    $ctx  = New-ShotRoot
    $cfgJ = $script:shotCfg
    $file = Add-ShotVideo -Ctx $ctx -Name 'Serie_1x04' -Fixture 'audio-y-subs-multiidioma.mkv'
    # Un perfil PROPIO guardado, para que en el dialogo se vea la entrada [config] y el boton Borrar.
    [void](Save-CvConfigProfile -Path $cfgJ -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 21 -DetectBorder 'auto' -ChangeSize '1920:-2' -NoUpscale $true) -Label 'Series 1080p (CPU)')
    $ctx  = New-CvContext -Root $ctx.Root -ConfigPath $cfgJ

    # Un job NUEVO: primero el dialogo del perfil y luego el editor ya cargado. Dos capturas de un
    # solo recorrido, que es como se ve de verdad (lo uno lleva a lo otro).
    Start-Flow -Seconds 240 -Body {
        $f = Get-TopForm
        if ($null -eq $f) { Wait-Step; return }
        $pl = @($f.Controls.Find('cvProfList', $true))
        if ($pl.Count -gt 0) {
            if ($script:step -eq 0) {
                for ($i = 0; $i -lt $pl[0].Items.Count; $i++) {
                    if ("$($pl[0].Items[$i])" -match 'h265|x265') { $pl[0].SelectedIndex = $i; break }
                }
                Save-Shot -Form $f -Name 'job-perfil'
                $script:step = 1
                $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
            }
            return
        }
        # El editor se abre ANTES de analizar y va contando por donde va: hay que esperar a que la
        # tabla de audio tenga filas (si no, se retrata una ventana a medio llenar).
        $au = @($f.Controls.Find('cvJobAudio', $true))
        if ($au.Count -eq 0 -or $au[0].Items.Count -eq 0) { Wait-Step -Max 400; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'job-editor'
        $f.Close()          # se cierra SIN guardar: aqui solo se venia a retratar
    }
    [void](Show-CvJobWindow -Context $ctx -Name 'Serie_1x04' -File $file)
    Stop-Flow

    # 'Ajustar...': cambiar un valor del perfil solo para este job.
    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Text)" -notmatch 'Ajustar') { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'job-ajustar'
        $f.Close()
    }
    # Con -CfgPath, el editor ensena ademas la caja del nombre y 'Guardar como perfil'.
    [void](Show-CvProfileEditorWindow -Context $ctx -Prof (Get-ShotProfile -Ctx $ctx -Match 'h265|x265') -CfgPath $cfgJ)
    Stop-Flow

    # Editar VARIOS jobs a la vez: lo que se cambia de golpe y lo que se queda como esta en cada uno.
    # Los jobs se escriben a mano (no hace falta analizar nada: el dialogo solo lee los .job.json).
    foreach ($n in @('Serie_1x01', 'Serie_1x02', 'Serie_1x03', 'Serie_1x04')) {
        $recB = ConvertTo-CvJobRecord -Context $ctx -File $file `
            -Prof (Get-ShotProfile -Ctx $ctx -Match 'h265|x265') -VideoIndex 0 `
            -AudioTracks @([pscustomobject]@{ Index = 1; Is51 = $false; Sync = 0; Lang = 'spa'; Default = $true })
        Write-CvJob -Context $ctx -Name $n -Job $recB
    }
    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Name)" -ne 'cvJobBulk') { Wait-Step; return }
        $shotTimer.Stop()
        # Marcado el caso tipico: que todos copien el video en vez de recodificarlo.
        $f.Controls.Find('cvBulkVal_videoCopy', $true)[0].SelectedIndex = 1
        $f.Controls.Find('cvBulkChk_videoCopy', $true)[0].Checked = $true
        [System.Windows.Forms.Application]::DoEvents()
        Save-Shot -Form $f -Name 'job-bloque'
        $f.Controls.Find('cvBulkCancel', $true)[0].PerformClick()   # aqui solo se venia a retratar
    }
    [void](Show-CvJobBulkWindow -Context $ctx -Names @('Serie_1x01', 'Serie_1x02', 'Serie_1x03', 'Serie_1x04'))
    Stop-Flow

    Remove-ShotRoot -Path $ctx.Root
}

# ================================================================================================
#  3) Preparar pendientes (el recorrido de todo el lote)
# ================================================================================================
if (Test-Group 'preparar') {
    Write-Host "`nPreparar pendientes" -ForegroundColor Cyan
    $ctx   = New-ShotRoot
    $files = @()
    foreach ($n in @('Serie_2x01', 'Serie_2x02', 'Serie_2x03')) {
        $p = Add-ShotVideo -Ctx $ctx -Name $n -Fixture 'audio-y-subs-multiidioma.mkv'
        $files += @{
            Name = $n
            Path = $p
        }
    }
    Start-Flow -Seconds 600 -Body {
        $f = Get-TopForm
        if ($null -eq $f) { Wait-Step; return }
        $pl = @($f.Controls.Find('cvProfList', $true))
        if ($pl.Count -gt 0) {
            for ($i = 0; $i -lt $pl[0].Items.Count; $i++) {
                if ("$($pl[0].Items[$i])" -match 'AUTO-BORDE') { $pl[0].SelectedIndex = $i; break }
            }
            $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
            return
        }
        # Si el recorrido se para a preguntar algo, se abre el EDITOR encima: se retrata (es el caso
        # que hay que contar en el manual) y se cierra, que aqui no se viene a preparar nada.
        $au = @($f.Controls.Find('cvJobAudio', $true))
        if ($au.Count -gt 0) {
            if ($au[0].Items.Count -eq 0) { Wait-Step -Max 400; return }
            Save-Shot -Form $f -Name 'preparar-revision'
            $f.Close()
            return
        }
        $cl = @($f.Controls.Find('cvPrepClose', $true))
        if ($cl.Count -eq 0) { Wait-Step -Max 400; return }
        if ("$($cl[0].Text)" -ne 'Cerrar') { Wait-Step -Max 1000; return }   # todavia recorriendo
        # Un tick de cortesia antes de retratar: la barra de progreso de WinForms llega al 100% con
        # una animacion, y sin esperar se retrata a medio llenar con el recorrido ya terminado.
        if ($script:step -eq 0) { $script:step = 1; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'preparar'
        $cl[0].PerformClick()
    }
    [void](Show-CvPrepareWindow -Context $ctx -Files $files)
    Stop-Flow

    Remove-ShotRoot -Path $ctx.Root
}

# ================================================================================================
#  4) Setup en ventana (setup-gui.cmd)
# ================================================================================================
if (Test-Group 'setup') {
    Write-Host "`nSetup en ventana" -ForegroundColor Cyan
    $ctx  = New-ShotRoot
    $cfgS = $script:shotCfg
    # Un config alterno, para que el selector de configuracion tenga algo que elegir.
    [void](Save-CvTextFile -Path (Join-Path $ctx.Root 'config.debug.json') -Text '{ "debug": { "enabled": true } }')
    # Algo en Proceso\ y en logs\, para que la limpieza y el visor no salgan vacios.
    $prof = Get-ShotProfile -Ctx $ctx -Match 'h265|x265'
    [void](Add-ShotVideo -Ctx $ctx -Name 'Serie_1x01' -Fixture 'audio-y-subs-multiidioma.mkv')
    Add-ShotJob -Ctx $ctx -Name 'Serie_1x01' -Prof $prof
    [void](Save-CvTextFile -Path (Join-Path $ctx.Proceso 'Serie_1x01.lock') -Text ("PID={0};HOST={1}" -f $PID, $env:COMPUTERNAME))
    [void](Add-ShotLog -Ctx $ctx -Name 'Convert_20260919_101500_4242.log')
    [void](Add-ShotLog -Ctx $ctx -Name 'Convert_20260918_223000_3311.log')

    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Text)" -notmatch 'Setup') { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'setup'
        $f.Close()
    }
    [void](Show-CvSetupWindow -Context $ctx -Root $ctx.Root -CfgPath $cfgS -CfgName 'config.json')
    Stop-Flow

    # Editor de configuracion: se abre en una clave concreta, que un arbol cerrado no explica nada.
    $findNode = {
        param($Nodes, [string]$Path)
        foreach ($n in $Nodes) {
            if ("$($n.Tag)" -eq $Path) { return $n }
            $r = & $findNode $n.Nodes $Path
            if ($r) { return $r }
        }
        return $null
    }
    $script:findNode = $findNode
    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f) { Wait-Step; return }
        $tr = @($f.Controls.Find('cvTree', $true))
        if ($tr.Count -eq 0 -or $tr[0].Nodes.Count -eq 0) { Wait-Step; return }
        if ($script:step -eq 0) {
            $n = & $script:findNode $tr[0].Nodes 'encode/video/videoEncoder'
            if ($null -ne $n) { $tr[0].SelectedNode = $n; $n.EnsureVisible() }
            $script:step = 1
            return
        }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'setup-config'
        $f.Close()
    }
    [void](Show-CvConfigWindow -Root $ctx.Root -CfgPath $cfgS -CfgName 'config.json')
    Stop-Flow

    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or @($f.Controls.Find('cvToolUse', $true)).Count -eq 0) { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'setup-herramientas'
        $f.Close()
    }
    [void](Show-CvToolsWindow -Context $ctx -Root $ctx.Root -CfgPath $cfgS)
    Stop-Flow

    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Text)" -notmatch 'Logs') { Wait-Step; return }
        $ls = @($f.Controls.Find('cvLogList', $true))
        if ($ls.Count -eq 0 -or $ls[0].Items.Count -eq 0) { Wait-Step; return }
        if ($script:step -eq 0) { $ls[0].SelectedIndex = 0; $script:step = 1; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'setup-logs'
        $f.Close()
    }
    [void](Show-CvLogsWindow -Context $ctx)
    Stop-Flow

    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Text)" -notmatch 'Limpiar') { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'setup-limpieza'
        $f.Close()
    }
    Show-CvCleanWindow -Context $ctx
    Stop-Flow

    # Perfiles propios: la lista con lo que se puede hacer con ellos.
    [void](Save-CvConfigProfile -Path $cfgS -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 21 -DetectBorder 'auto' -ChangeSize '1920:-2' -NoUpscale $true) -Label 'Series 1080p (CPU)')
    [void](Save-CvConfigProfile -Path $cfgS -Prof (New-CvProfile -VideoEncoder 'hevc_nvenc' -VideoProfile 'main10' -VideoLevel '5' -Qmin 1 -Qmax 20 -AudioCodec 'ac3' -AudioBitrate '448k') -Label 'Peliculas GPU (audio AC3)')
    [void](Save-CvConfigProfile -Path $cfgS -Prof (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy') -Label 'Solo arreglar el contenedor')
    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or "$($f.Name)" -ne 'cvProfiles') { Wait-Step; return }
        $lp = @($f.Controls.Find('cvProfilesList', $true))
        if ($lp.Count -eq 0 -or $lp[0].Items.Count -eq 0) { Wait-Step; return }
        $shotTimer.Stop()
        $lp[0].Items[0].Selected = $true
        Save-Shot -Form $f -Name 'setup-perfiles'
        $f.Close()
    }
    [void](Show-CvProfilesWindow -Context $ctx -CfgPath $cfgS)
    Stop-Flow

    Start-Flow -Body {
        $f = Get-TopForm
        if ($null -eq $f -or @($f.Controls.Find('cvCfgList', $true)).Count -eq 0) { Wait-Step; return }
        $shotTimer.Stop()
        Save-Shot -Form $f -Name 'selector-config'
        $f.Close()
    }
    [void](Show-CvSetupConfigChooser -Root $ctx.Root)
    Stop-Flow

    Remove-ShotRoot -Path $ctx.Root
}

# ================================================================================================
#  5) GIF de uso: la cola de principio a fin (preparar -> codificar -> hecho)
# ================================================================================================
if (Test-Group 'gif') {
    Write-Host "`nGIF de uso (se graba una sesion DE VERDAD: tarda)" -ForegroundColor Cyan
    # La ventana de preparar se cierra sola al terminar (gui.prepareAutoClose): asi el guion no
    # tiene que pelearse con ella mientras esta bloqueado en el clic de 'Preparar pendientes'.
    $ctx = New-ShotRoot -Gui '"rememberLayout": false, "queueWidth": 1280, "queueHeight": 720, "confirmCloseWithWorkers": false, "prepareAutoClose": true, "prepareAutoCloseMs": 700, "bringToFront": false'
    foreach ($n in @('Serie_1x01', 'Serie_1x02', 'Serie_1x03')) {
        # Una fixture que el autodiscover resuelve SOLO: si se para a preguntar, el recorrido abre
        # el editor del job y el guion se queda bloqueado ahi (paso: tres editores abiertos que
        # hubo que cerrar a mano). Aun asi, el guion de los fotogramas sabe cerrarlo por si acaso.
        [void](Add-ShotVideo -Ctx $ctx -Name $n -Fixture 'audio-y-subs-multiidioma.mkv')
    }
    # Aqui se CODIFICA de verdad, y los workers son procesos aparte que abren '<root>\Convert.ps1':
    # el root de demo necesita el script y sus modulos. Sin esto los workers se mueren al nacer y la
    # lista se queda en 'En cola' para siempre (paso: el GIF salio con la cola parada).
    New-Item -ItemType Directory -Path (Join-Path $ctx.Root 'bin') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'bin\Convert.ps1') -Destination (Join-Path $ctx.Root 'bin\Convert.ps1') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $ctx.Root 'lib'))) {
        New-Item -ItemType Junction -Path (Join-Path $ctx.Root 'lib') -Target (Join-Path $Root 'lib') | Out-Null
    }

    $frames = Join-Path ([System.IO.Path]::GetTempPath()) ('cv_gif_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $frames -Force | Out-Null
    # El LIENZO es fijo y con sitio de sobra: todos los fotogramas tienen que medir lo mismo, y una
    # ventana mas alta que el lienzo saldria CORTADA (paso con el editor del job). Lo que no quepa
    # se reduce manteniendo la proporcion. Abajo, una franja con el ROTULO de lo que se esta viendo.
    $gifW   = 1320
    $gifH   = 920
    $rotuloH = 54
    $script:gifN      = 0
    $script:gifPerf   = $false   # ya se contesto al dialogo del perfil
    $script:gifTexto  = 'La cola de conversion: tres archivos recien dejados en Original\'
    $script:gifCada   = 1        # 1 = todos los fotogramas; 3 = uno de cada tres (ver la codificacion)
    $script:gifTick   = 0
    $script:gifJobT   = 0        # ticks dentro del editor del job (su escena va por pasos, abajo)

    # Los rotulos van en castellano y a pelo aqui: son texto DEL GIF del manual (que es en
    # castellano), no de la aplicacion; no pasan por lang\ a proposito.
    $fuenteRot = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Regular)
    $brochaRot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(236, 236, 236))
    $brochaFon = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(32, 32, 32))
    $brochaBor = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 120, 215))

    function Add-GifFrame {
        <# Guarda el lienzo como fotograma; -Veces lo repite (asi se PARA el GIF donde hay que leer). #>
        param($Img, [int]$Veces = 1)
        if ($null -eq $Img) { return }
        for ($i = 0; $i -lt [Math]::Max(1, $Veces); $i++) {
            $script:gifN++
            $Img.Save((Join-Path $frames ('f_{0:d5}.png' -f $script:gifN)), [System.Drawing.Imaging.ImageFormat]::Png)
        }
    }
    function Wait-Gif {
        <#
            Pausa del GIF: repite el ULTIMO fotograma, para que de tiempo a leer lo que hay.

            Se copia el PNG ya escrito en vez de volver a guardar el mismo objeto Bitmap: guardarlo
            otra vez desde otro temporizador acababa en 'Error generico en GDI+' -y con el error, el
            guion cerraba la ventana y no habia GIF-. Copiar un fichero no tiene ese problema.

            Y OJO con el nombre del parametro: llamandolo '-Frames' pisaba a $frames -la carpeta de
            los fotogramas-, porque en PowerShell las variables NO distinguen mayusculas. El
            Join-Path se hacia contra un numero, Test-Path decia que no, y la pausa se iba EN
            SILENCIO: el GIF salia sin una sola. Es la trampa apuntada en ref-gotchas.md.
        #>
        param([int]$Veces = 16)
        if ($script:gifN -le 0) { return }
        $ult = Join-Path $frames ('f_{0:d5}.png' -f $script:gifN)
        if (-not (Test-Path -LiteralPath $ult)) { return }
        for ($i = 0; $i -lt $Veces; $i++) {
            $script:gifN++
            Copy-Item -LiteralPath $ult -Destination (Join-Path $frames ('f_{0:d5}.png' -f $script:gifN)) -Force
        }
        # Se cuenta cada escena: asi se ve de un vistazo si una pausa no ha entrado (paso).
        Write-Host ("  escena: +{0} fotogramas (total {1})  {2}" -f $Veces, $script:gifN, $script:gifTexto) -ForegroundColor DarkGray
    }

    # Temporizador APARTE para los fotogramas. Hace falta que sea otro: mientras el guion esta
    # dentro del clic de 'Preparar pendientes' (que abre una ventana MODAL y no vuelve hasta que se
    # cierra), su propio tick esta bloqueado; este sigue corriendo y ademas contesta al dialogo del
    # perfil, que es lo unico que hay que pulsar ahi dentro.
    $gifTimer = New-Object System.Windows.Forms.Timer
    $gifTimer.Interval = 250
    $gifTimer.Add_Tick({
        try {
            $f = Get-TopForm
            if ($null -eq $f) { return }
            # Si saliera el aviso de "solo los marcados o todos", se contesta TODOS: sin esto la
            # grabacion se queda parada esperando un clic (paso).
            if ("$($f.Name)" -eq 'cvStartAsk') {
                $bAll = @($f.Controls.Find('cvStartAsk_all', $true))
                if ($bAll.Count -gt 0) { $bAll[0].PerformClick(); return }
            }
            $pl = @($f.Controls.Find('cvProfList', $true))
            if ($pl.Count -gt 0 -and -not $script:gifPerf) {
                for ($i = 0; $i -lt $pl[0].Items.Count; $i++) {
                    if ("$($pl[0].Items[$i])" -match 'AUTO-BORDE') { $pl[0].SelectedIndex = $i; break }
                }
                $script:gifPerf = $true
                $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
                return
            }
            # EL EDITOR DEL JOB es una escena con su propio guion: se ensena lo que se puede tocar
            # a mano y se cierra SIN guardar. Va aqui y no en el guion principal porque, mientras el
            # editor esta abierto (modal), el tick de aquel esta bloqueado en el clic que lo abrio.
            # Y de paso sirve de red: si el recorrido de preparar se parase a preguntar, esta misma
            # cuenta lo acabaria cerrando en vez de dejar la ventana esperando a una persona.
            if (@($f.Controls.Find('cvJobSave', $true)).Count -gt 0) {
                $lvA = @($f.Controls.Find('cvJobAudio', $true))
                if ($lvA.Count -eq 0 -or $lvA[0].Items.Count -eq 0) {
                    $script:gifTexto = 'Editar job: primero se analiza el archivo (pistas, bordes, sincronia)'
                } else {
                    $script:gifJobT++
                    switch ($script:gifJobT) {
                        8  { $script:gifTexto = 'El editor del job: video, recorte y escalado, ya propuestos' }
                        20 {
                            $lvA[0].Items[0].Selected = $true
                            $script:gifTexto = 'Audio: que pistas se conservan, su idioma y su retardo'
                        }
                        34 {
                            $lvS = @($f.Controls.Find('cvJobSubs', $true))
                            if ($lvS.Count -gt 0 -and $lvS[0].Items.Count -gt 0) { $lvS[0].Items[0].Selected = $true }
                            $script:gifTexto = 'Subtitulos: cuales se conservan, forzados y predeterminado'
                        }
                        48 { $script:gifTexto = 'Lo que se decida aqui se congela en su .job.json' }
                        58 { $f.Controls.Find('cvJobCancel', $true)[0].PerformClick() }
                    }
                }
            }

            # Ritmo: en la parte larga (codificando) no hace falta un fotograma cada 250 ms, y sin
            # esto esa fase sola dura mas que todo lo demas junto.
            $script:gifTick++
            if (($script:gifTick % [Math]::Max(1, $script:gifCada)) -ne 0) { return }
            $img = Get-WindowBitmap -Form $f
            if ($null -eq $img) { return }
            $lienzo = New-Object System.Drawing.Bitmap($gifW, $gifH)
            $g = [System.Drawing.Graphics]::FromImage($lienzo)
            $g.Clear([System.Drawing.Color]::FromArgb(58, 58, 58))
            $g.InterpolationMode = 'HighQualityBicubic'
            # La ventana, centrada en la zona de arriba; si no cabe, se reduce (nunca se corta).
            $libreH = $gifH - $rotuloH
            $esc = [Math]::Min(1.0, [Math]::Min($gifW / [double]$img.Width, $libreH / [double]$img.Height))
            $w = [int]($img.Width * $esc)
            $h = [int]($img.Height * $esc)
            $g.DrawImage($img, [int](($gifW - $w) / 2), [int](($libreH - $h) / 2), $w, $h)
            $img.Dispose()
            # La franja del rotulo, con su filo de color y el texto de lo que se esta viendo.
            $g.FillRectangle($brochaFon, 0, ($gifH - $rotuloH), $gifW, $rotuloH)
            $g.FillRectangle($brochaBor, 0, ($gifH - $rotuloH), $gifW, 3)
            $g.DrawString("$($script:gifTexto)", $fuenteRot, $brochaRot, 24, ($gifH - $rotuloH + 14))
            $g.Dispose()
            Add-GifFrame -Img $lienzo
            $lienzo.Dispose()
        } catch { }
    })

    # Plazo corto a proposito: si algo se tuerce, la ventana se cierra sola y no se queda ahi
    # esperando a que la cierre quien estuviera trabajando en el equipo (paso, con 900 s).
    Start-Flow -Seconds 300 -Body {
        $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Controls.Find('cvQueue', $true).Count -gt 0 }) | Select-Object -First 1
        if ($null -eq $f) { Wait-Step; return }
        $lv = $f.Controls.Find('cvQueue', $true)[0]
        if ($lv.Items.Count -lt 3) { Wait-Step -Max 400; return }
        switch ($script:step) {
            0 {
                # Que se VEA la lista antes de tocar nada: era lo que mas fallaba del primer intento.
                # Ojo: en los primeros ticks aun no hay NINGUN fotograma que repetir (el otro
                # temporizador todavia no ha capturado), y la pausa se perdia entera.
                if ($script:gifN -le 0) { return }
                Wait-Gif -Veces 18
                $script:step = 1
            }
            1 {
                $script:gifTexto = 'Preparar pendientes: decide por ti y solo se para donde lo haria la consola'
                Wait-Gif -Veces 12
                $f.Controls.Find('cvPrepareAll', $true)[0].PerformClick()   # bloquea hasta que acabe
                $script:step = 2
            }
            2 {
                $script:gifTexto = 'Listos: cada archivo con su job congelado, en cola'
                Wait-Gif -Veces 18
                $script:step = 3
            }
            3 {
                # Antes de arrancar: abrir el editor de UNO a mano, que es lo que no se veia.
                $script:gifTexto = 'Y si quieres decidir tu: marca un archivo y Editar job'
                $lv.Items[0].Selected = $true
                Wait-Gif -Veces 12
                $f.Controls.Find('cvPrepareGui', $true)[0].PerformClick()   # modal: bloquea aqui
                $script:step = 31
                return
            }
            31 {
                $script:gifTexto = 'Sin guardar: el job se queda como lo dejo el recorrido'
                Wait-Gif -Veces 12
                $script:step = 32
                return
            }
            32 {
                # Sin marcas: con una fila marcada, 'Iniciar' pregunta si van solo esas (y con
                # razon), pero aqui esa pregunta corta la grabacion.
                foreach ($it in @($lv.Items)) { $it.Selected = $false }
                $script:gifTexto = 'Iniciar: los workers son procesos aparte y van a lo suyo'
                Wait-Gif -Veces 10
                $f.Controls.Find('cvStart', $true)[0].PerformClick()
                $script:gifTexto = 'Codificando: paso, porcentaje, velocidad y ETA en vivo'
                $script:gifCada  = 5
                $script:step = 4
            }
            4 {
                $hechos = @($lv.Items | Where-Object { "$($_.SubItems[2].Text)" -match 'Hecho' }).Count
                $script:waits++
                if ($hechos -ge 3 -or $script:waits -gt 400) { $script:step = 5 }
                return
            }
            5 {
                $script:gifCada  = 1
                $script:gifTexto = 'Hecho: cada salida en Convertido\, con lo que ha adelgazado'
                Wait-Gif -Veces 24
                $script:step = 6
            }
            default { $shotTimer.Stop(); $f.Close() }
        }
    }
    $gifTimer.Start()
    [void](Show-CvConvertWindow -Context $ctx -Root $ctx.Root -CfgPath $script:shotCfg -CfgName 'config.json' -CurrentLog '')
    $gifTimer.Stop()
    Stop-Flow
    foreach ($o in @($fuenteRot, $brochaRot, $brochaFon, $brochaBor)) { try { $o.Dispose() } catch { } }

    # Y a GIF con el ffmpeg de tools\: palette propia (los 256 colores por defecto destrozan el
    # texto de una ventana) y a 8 fps, que es lo que hace que se pueda leer lo que pasa.
    $gifOut = Join-Path $Out 'uso.gif'
    if ($script:gifN -lt 10) {
        Write-Host "  [ERROR] no se han grabado fotogramas suficientes ($script:gifN)" -ForegroundColor Red
    } else {
        $filtro = 'fps=6,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle'
        # $args NO: es variable automatica de PowerShell y aqui dentro es otra cosa.
        $ffArgs = @('-y', '-loglevel', 'error', '-framerate', '6', '-i', (Join-Path $frames 'f_%05d.png'),
                    '-filter_complex', $filtro, '-loop', '0', $gifOut)
        & "$($ctx.FFmpeg)" @ffArgs
        if (Test-Path -LiteralPath $gifOut) {
            $mb = [math]::Round((Get-Item -LiteralPath $gifOut).Length / 1MB, 2)
            Write-Host ("  [GIF]  {0}  ({1} fotogramas, {2} MB)" -f $gifOut, $script:gifN, $mb) -ForegroundColor Green
        } else {
            Write-Host '  [ERROR] ffmpeg no genero el GIF' -ForegroundColor Red
        }
    }
    Remove-Item -Recurse -Force -LiteralPath $frames -ErrorAction SilentlyContinue
    Remove-ShotRoot -Path $ctx.Root
}

Write-Host "`nCapturas en: $Out" -ForegroundColor Cyan
