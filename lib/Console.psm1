<#
    Console.psm1 - Consola: apariencia, control nativo de la ventana (P/Invoke), menus
    (Show-Menu / Select-FromList) y prompts (Read-*).
#>

# Ancho de los separadores de seccion (=== / ---). Lo fija Set-CvSepWidth desde config
# (console.sepWidth) al arrancar; 0 = aun no fijado -> se toma el default de config. Asi el numero
# no se hardcodea aqui: la fuente unica es Get-CvConfigDefaults (console.sepWidth).
$script:CvSepWidth = 0
function Set-CvSepWidth { param([int]$Width) $script:CvSepWidth = [Math]::Max(1, $Width) }

# Auto-timeout de los prompts: $true (por defecto) = al teclear algo se desactiva el auto y solo ENTER
# envia; $false = clasico (al expirar envia lo tecleado). Lo fija Start-CvSession desde config
# (behavior.promptTimeoutStopOnType). Lo usa Read-CvLine.
$script:CvPromptStopOnType = $true
function Set-CvPromptStopOnType { param([bool]$Value) $script:CvPromptStopOnType = $Value }
function Resolve-CvSepWidth {
    <# Ancho a usar: -Width explicito (>0) | el fijado por Set-CvSepWidth | el default de config. #>
    param([int]$Width = 0)
    if ($Width -gt 0)             { return $Width }
    if ($script:CvSepWidth -gt 0) { return $script:CvSepWidth }
    return [Math]::Max(1, [int](Get-CvConfigDefaults).console.sepWidth)
}
function Get-CvLine {
    <#
        Linea de separacion de un caracter arbitrario, del ancho de la UI (o el -Width que se pase).
        Base de Get-CvSepLine/Get-CvDashLine/Get-CvStarLine. Se stringifica el char antes de repetir
        (`[char] * [int]` haria aritmetica de enteros, no repeticion de texto).
    #>
    param([Parameter(Mandatory)][char]$Char, [int]$Width = 0)
    ([string]$Char) * (Resolve-CvSepWidth $Width)
}
function Get-CvSepLine  { param([int]$Width = 0) Get-CvLine -Char '=' -Width $Width }   # separador grueso ===
function Get-CvDashLine { param([int]$Width = 0) Get-CvLine -Char '-' -Width $Width }   # separador fino ---
function Get-CvStarLine { param([int]$Width = 0) Get-CvLine -Char '*' -Width $Width }   # separador de asteriscos ***

# Ancho de la barra visual de progreso (worker). Lo fija Set-CvProgressBarWidth desde config
# (console.progressBarWidth) al arrancar; <0 = aun no fijado -> se toma el default de config. 0 = sin
# barra. Misma logica de fuente unica que $script:CvSepWidth.
$script:CvProgressBarWidth = -1
function Format-CvSize {
    <#
        PURO. Tamano LEGIBLE: '48 KB' / '812 MB' / '2,4 GB' (vacio si no hay tamano). Se pasa -Bytes
        o -Kb, lo que se tenga a mano (un `.Length` o lo que devuelve Get-CvQueueStatus).

        Por debajo de 1 MB se dice en KB: un punado de logs de 20 KB salia como '0 MB', que no
        informa de nada.

        Vive aqui, con el resto de helpers de presentacion compartidos (Get-CvProgressBar, los
        separadores): lo usa la ventana de la cola y sirve igual para la consola. El resumen de
        conversion NO lo usa a proposito: ahi el tamano va SIEMPRE en MB a los dos lados
        (origen -> destino) para poder compararlos de un vistazo.
    #>
    param(
        [long]$Bytes = 0,
        [long]$Kb    = 0
    )
    $k = if ($Kb -gt 0) { $Kb } else { [long][math]::Round($Bytes / 1024.0) }
    if ($k -le 0) { return '' }
    $mb = $k / 1024.0
    if ($mb -ge 1024) { return ('{0:N1} GB' -f ($mb / 1024.0)) }
    if ($mb -lt 1)    { return ('{0:N0} KB' -f $k) }
    return ('{0:N0} MB' -f $mb)
}

function Format-CvMb {
    <#
        PURO. Tamano en MB con un decimal ('812,4'), SIN unidad ni auto-escala. Es el formato del
        resumen de conversion y de los logs del pipeline: ahi se comparan dos tamanos (origen ->
        destino, o el MB que acaba de escribir un paso), y pasar uno a GB y el otro no haria la
        comparacion ilegible. Para mostrar un tamano suelto, Format-CvSize.
    #>
    param([long]$Bytes)
    if ($Bytes -le 0) { return '0' }
    return ('{0}' -f [math]::Round($Bytes / 1MB, 1))
}

function Set-CvProgressBarWidth { param([int]$Width) $script:CvProgressBarWidth = [Math]::Max(0, $Width) }
function Resolve-CvProgressBarWidth {
    <# Ancho a usar: -Width explicito (>=0) | el fijado por Set-CvProgressBarWidth | el default de config. #>
    param([int]$Width = -1)
    if ($Width -ge 0)              { return $Width }
    if ($script:CvProgressBarWidth -ge 0) { return $script:CvProgressBarWidth }
    return [Math]::Max(0, [int](Get-CvConfigDefaults).console.progressBarWidth)
}
function Get-CvProgressBar {
    <#
        Barra de progreso visual para un porcentaje 0-100, p. ej. '████████░░░░░░░░░░░░'. El ancho sale
        de -Width (>=0) o del default de config (console.progressBarWidth); 0 = cadena vacia (sin barra).
        Usa bloques Unicode que Cascadia Code pinta bien (U+2588 lleno, U+2591 vacio). El porcentaje se
        recorta a [0,100]. Se stringifican los caracteres antes de repetir (igual que Get-CvLine).
    #>
    param([Parameter(Mandatory)][int]$Percent, [int]$Width = -1)
    $w = Resolve-CvProgressBarWidth $Width
    if ($w -le 0) { return '' }
    $p    = [Math]::Min(100, [Math]::Max(0, $Percent))
    $fill = [int][math]::Round($w * $p / 100.0)
    if ($fill -gt $w) { $fill = $w }
    $ch = Get-CvProgressBarChars
    ($ch.Full) * $fill + ($ch.Empty) * ($w - $fill)
}

function Get-CvProgressBarChars {
    <#
        FUENTE UNICA de los dos caracteres de la barra: U+2588 (lleno) y U+2591 (vacio). Se construyen
        con [char]0xNNNN y NO se escriben literales en el fichero A PROPOSITO: los .psm1 van en UTF-8
        SIN BOM y PowerShell 5.1 los lee como ANSI, asi que un glifo literal se corrompe (y segun los
        bytes, hasta rompe el parseo). Mismo motivo que Get-CvMark (ver Log.psm1).
        Lo usan Get-CvProgressBar al pintar y Test-CvLogProgressLine al reconocer un repintado en un log.
    #>
    @{
        Full  = [string]([char]0x2588)
        Empty = [string]([char]0x2591)
    }
}

function Set-CvWindowSize {
    <#
        Ajusta el tamano de la ventana de consola (columnas x lineas) desde config.json.
        Mantiene un buffer alto para conservar scroll hacia atras. 0 = no cambiar.
    #>
    param([int]$Cols, [int]$Lines)
    if ($Cols -le 0 -or $Lines -le 0) { return }
    try {
        $rui = $Host.UI.RawUI
        $maxW = $rui.MaxPhysicalWindowSize.Width
        $maxH = $rui.MaxPhysicalWindowSize.Height
        $wCols = [Math]::Min($Cols, $maxW)
        $wLines = [Math]::Min($Lines, $maxH)

        # 1) Encoger la ventana para poder redimensionar el buffer sin conflicto.
        $cur = $rui.WindowSize
        $rui.WindowSize = New-Object System.Management.Automation.Host.Size ([Math]::Min($cur.Width, $wCols)), ([Math]::Min($cur.Height, $wLines))
        # 2) Buffer: ancho = ventana; alto grande para scrollback.
        $rui.BufferSize = New-Object System.Management.Automation.Host.Size $wCols, ([Math]::Max($wLines, 3000))
        # 3) Ventana al tamano deseado.
        $rui.WindowSize = New-Object System.Management.Automation.Host.Size $wCols, $wLines
    } catch {}
}


function Set-CvAppearance {
    <#
        Aplica fuente, tamano de ventana, colores y titulo de la consola (config.json).
        Equivale al 'color 1e' + 'title' + 'mode con' del script batch antiguo.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Title = (Get-CvAppName))
    try { $Host.UI.RawUI.WindowTitle = $Title } catch {}

    # Fuente de la consola (Consolas por defecto; nombre vacio = no cambiar).
    Set-CvConsoleFont -Name $Context.ConsoleFont -Size $Context.ConsoleFontSize

    # Tamano de la ventana.
    Set-CvWindowSize -Cols $Context.WindowWidth -Lines $Context.WindowHeight

    $colors = [enum]::GetNames([System.ConsoleColor])
    if ($Context.ConsoleBackground -in $colors -and $Context.ConsoleForeground -in $colors) {
        try {
            [Console]::BackgroundColor = [System.ConsoleColor]$Context.ConsoleBackground
            [Console]::ForegroundColor = [System.ConsoleColor]$Context.ConsoleForeground
            Clear-Host   # repinta toda la ventana con el nuevo fondo
        } catch {}
    } elseif ($Context.ConsoleBackground -or $Context.ConsoleForeground) {
        Write-Host ("AVISO: color de consola no valido. Validos: {0}" -f ($colors -join ', ')) -ForegroundColor Yellow
    }
}


function Initialize-CvNative {
    <# Compila una sola vez las llamadas nativas (boton X + fuente de consola). #>
    if ('CvNative.Win' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CvNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    public static class Win {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]   public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
        [DllImport("user32.dll")]   public static extern bool EnableMenuItem(IntPtr hMenu, uint uIDEnableItem, uint uEnable);
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);
    }
}
'@ -ErrorAction Stop
}


function Set-CvCloseButton {
    <#
        Activa/desactiva el boton X (cerrar) de la ventana de consola, para evitar
        cerrarla por error a mitad de una conversion. Equivale al antiguo controls.exe.
        IMPORTANTE: reactivarlo siempre al terminar (se hace en un finally/trap).
    #>
    param([Parameter(Mandatory)][bool]$Enabled)
    try { Initialize-CvNative } catch { return }
    try {
        $hwnd = [CvNative.Win]::GetConsoleWindow()
        if ($hwnd -eq [System.IntPtr]::Zero) { return }
        $menu = [CvNative.Win]::GetSystemMenu($hwnd, $false)
        $SC_CLOSE   = [uint32]0xF060
        $MF_ENABLED = [uint32]0x0
        $MF_GRAYED  = [uint32]0x1
        $flag = if ($Enabled) { $MF_ENABLED } else { $MF_GRAYED }
        [void][CvNative.Win]::EnableMenuItem($menu, $SC_CLOSE, $flag)
    } catch {}
}


function Set-CvConsoleFont {
    <# Fija la fuente y el tamano de la consola (ej Consolas, 18). Nombre vacio = no cambia. #>
    param([string]$Name, [int]$Size = 18)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Size -le 0) { return }
    try { Initialize-CvNative } catch { return }
    try {
        $STD_OUTPUT = -11
        $h = [CvNative.Win]::GetStdHandle($STD_OUTPUT)
        if ($h -eq [System.IntPtr]::Zero -or $h -eq ([System.IntPtr](-1))) { return }
        $info = New-Object CvNative.CONSOLE_FONT_INFOEX
        $info.cbSize     = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type][CvNative.CONSOLE_FONT_INFOEX])
        $info.FontFamily = 0
        $info.FontWeight = 400
        $info.FaceName   = $Name
        $coord = New-Object CvNative.COORD
        $coord.X = [int16]0
        $coord.Y = [int16]$Size
        $info.dwFontSize = $coord
        [void][CvNative.Win]::SetCurrentConsoleFontEx($h, $false, [ref]$info)
    } catch {}
}


function ConvertFrom-CvPlayCommand {
    <#
        Parsea el comando de reproduccion de los menus de seleccion de pista:
        'P N [seg]' (video + pista) y, con -AllowAudioOnly, tambien 'A N [seg]' (solo audio).
        Devuelve @{ AudioOnly; Index; Start } (Start = -1 si no se indico) o $null si el texto
        no es un comando de reproduccion.
    #>
    param([string]$Text, [switch]$AllowAudioOnly)
    $pat = if ($AllowAudioOnly) { '^([PpAa])\s*(\d+)(?:\s+(\d+))?$' } else { '^([Pp])\s*(\d+)(?:\s+(\d+))?$' }
    $m = [regex]::Match("$Text", $pat)
    if (-not $m.Success) { return $null }
    [pscustomobject]@{
        AudioOnly = ($m.Groups[1].Value -match '^[Aa]$')
        Index     = [int]$m.Groups[2].Value
        Start     = $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { -1 })
    }
}

function Read-CvLine {
    <#
        Lee una linea del teclado con soporte de la tecla ESC. Devuelve el texto; con
        -AllowCancel, pulsar ESC lanza CV_CANCEL. Maneja Enter y Retroceso. Si la entrada
        esta redirigida (sin consola interactiva), cae a Read-Host (sin ESC).
    #>
    param([string]$Prompt = '', [switch]$AllowCancel, [int]$TimeoutSec = 0, [string]$TimeoutDefault = '')
    $interactive = $true
    try { $null = [Console]::KeyAvailable } catch { $interactive = $false }
    if (-not $interactive) { return (Read-Host $Prompt) }   # stdin redirigido (tests): sin timeout

    # Con timeout, se avisa en el prompt ("[auto Ns]") y se espera SIN teclear. Al expirar (sin haber
    # tecleado nada) se devuelve -TimeoutDefault ('' = como pulsar ENTER = valor por defecto; se puede
    # fijar otra respuesta, p. ej. 'n'/'0'). Comportamiento al TECLEAR: configurable (Set-CvPromptStopOnType,
    # de behavior.promptTimeoutStopOnType): $true (por defecto) desactiva el auto en cuanto escribes (solo
    # ENTER envia); $false = clasico (al expirar envia lo tecleado). Sin timeout (0), lectura bloqueante.
    $timed = ($TimeoutSec -gt 0)
    $dhint = if ($timed -and $TimeoutDefault -ne '') { "->{0}" -f $TimeoutDefault } else { '' }
    $ptxt  = if ($timed) { "{0} [auto {1}s{2}]: " -f $Prompt, $TimeoutSec, $dhint } else { "{0}: " -f $Prompt }
    Write-Host $ptxt -NoNewline
    $sb = New-Object System.Text.StringBuilder
    $sw = if ($timed) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }
    while ($true) {
        if ($timed) {
            while (-not [Console]::KeyAvailable) {
                # Contador de INACTIVIDAD (cada tecla lo reinicia). Con CvPromptStopOnType=$true (por
                # defecto) el auto SOLO actua mientras no se haya tecleado nada: al escribir algo se
                # DESACTIVA y solo ENTER envia. Con $false = modo clasico: al expirar envia lo tecleado
                # (si hay) o el TimeoutDefault (si no hay nada).
                $canAuto = ($sb.Length -eq 0) -or (-not $script:CvPromptStopOnType)
                if ($canAuto -and $sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                    Write-Host ''
                    if ($sb.Length -gt 0) { return $sb.ToString() }
                    return $TimeoutDefault
                }
                Start-Sleep -Milliseconds 100
            }
            $sw.Restart()   # se pulso una tecla: reinicia el contador de inactividad
        }
        $key = [Console]::ReadKey($true)   # $true = no eco automatico
        if ($key.Key -eq 'Enter')     { Write-Host ''; return $sb.ToString() }
        if ($key.Key -eq 'Escape')    { if ($AllowCancel) { Write-Host ''; throw 'CV_CANCEL' } ; continue }
        if ($key.Key -eq 'Backspace') { if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1); Write-Host "`b `b" -NoNewline } ; continue }
        $ch = $key.KeyChar
        if ($ch -and -not [char]::IsControl($ch)) { [void]$sb.Append($ch); Write-Host $ch -NoNewline }
    }
}


function Read-CvMenuLine {
    <#
        Lectura de una linea de menu con timeout OPCIONAL de inactividad. Si TimeoutSec > 0 usa
        Read-CvLine (que al expirar devuelve '' = como ENTER = opcion por defecto del menu); si es 0
        cae a Read-Host (comportamiento clasico, sin timeout). Pensada para los menus de PREPARAR con
        bucle propio (seleccion de pista/subtitulos, que aceptan 'P N' para reproducir).
    #>
    param([string]$Prompt, [int]$TimeoutSec = 0)
    if ($TimeoutSec -gt 0) { return (Read-CvLine -Prompt $Prompt -TimeoutSec $TimeoutSec) }
    return (Read-Host $Prompt)
}

function Get-CvPromptTimeout {
    <#
        Resuelve el timeout (segundos, entero >=0) de una pregunta a partir del mapa
        $Context.PromptTimeouts: usa el valor del tipo pedido; si es negativo o no existe, cae al
        generico 'default'. 0 = desactivado. Uso: Read-CvLine ... -TimeoutSec (Get-CvPromptTimeout $Context 'sync').
    #>
    param($Context, [string]$Kind)
    $map = $Context.PromptTimeouts
    if ($null -eq $map) { return 0 }
    $v = if ($map.Contains($Kind)) { [int]$map[$Kind] } else { -1 }
    if ($v -lt 0) { $v = if ($map.Contains('default')) { [int]$map['default'] } else { 0 } }
    return [Math]::Max(0, $v)
}

function Read-IntOrDefault {
    <#
        Lee un entero por teclado; si se deja vacio o no es valido, devuelve el valor por defecto.
        Con -TimeoutSec > 0 usa el lector con timeout de inactividad (al expirar = vacio = el default).
    #>
    param([string]$Prompt, [int]$Default, [int]$TimeoutSec = 0)
    $pr = "{0} [{1}]" -f $Prompt, $Default
    $v  = (& { if ($TimeoutSec -gt 0) { Read-CvLine -Prompt $pr -TimeoutSec $TimeoutSec } else { Read-Host $pr } }).Trim()
    if ($v -eq '') { return $Default }
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return $n }
    return $Default
}


function Read-QOrNull {
    <#
        Lee un cuantizador/CRF. Vacio => valor por defecto; negativo => $null (desactivado/auto).
        -Max (>0): valor maximo aceptado; por encima se re-pregunta (p. ej. 51 para el QP de
        H.264/HEVC y el CRF de x264/x265). Con -AllowCancel, 'C'/ESC lanza CV_CANCEL.
    #>
    param([string]$Prompt, [object]$Default, [int]$Max = 0, [switch]$AllowCancel)
    $dtxt = if ($null -eq $Default) { '-' } else { "$Default" }
    $hint = if ($AllowCancel) { '-1 = desactivar, C/ESC = cancelar' } else { '-1 = desactivar' }
    $pr   = "{0} [{1}] ({2})" -f $Prompt, $dtxt, $hint
    while ($true) {
        $v = (& { if ($AllowCancel) { Read-CvLine -Prompt $pr -AllowCancel } else { Read-Host $pr } }).Trim()
        if ($AllowCancel -and $v -match '^[Cc]$') { throw 'CV_CANCEL' }
        if ($v -eq '') { return $Default }
        $n = 0
        if ([int]::TryParse($v, [ref]$n)) {
            if ($n -lt 0) { return $null }                                    # negativo = desactivar/auto
            if ($Max -gt 0 -and $n -gt $Max) { Write-Host ("   Fuera de rango (0-{0})." -f $Max) -ForegroundColor Yellow; continue }
            return $n
        }
        Write-Host '   Valor no valido (numero entero).' -ForegroundColor Yellow
    }
}


function Read-YesNo {
    <#
        Pregunta si/no. Devuelve $true/$false. La tecla ESC: con -AllowCancel CANCELA ('C'/ESC lanzan
        CV_CANCEL); SIN -AllowCancel equivale a NO (devuelve $false), para poder descartar rapido.
        (Con stdin redirigido -tests- no hay ESC: cae a Read-Host.)
    #>
    param([string]$Prompt, [bool]$Default = $true, [switch]$AllowCancel)
    $d = if ($Default) { 'S' } else { 'N' }
    $opts = if ($AllowCancel) { 's/n, ESC=cancelar' } else { 's/n, ESC=no' }
    $pr = "{0} ({1}) [{2}]" -f $Prompt, $opts, $d
    $a = ''
    try { $a = (Read-CvLine -Prompt $pr -AllowCancel).Trim() }
    catch {
        if ($_.Exception.Message -eq 'CV_CANCEL') { if ($AllowCancel) { throw } else { return $false } }  # ESC: cancela / = no
        throw
    }
    if ($AllowCancel -and $a -match '^[Cc]$') { throw 'CV_CANCEL' }
    if ($a -eq '') { return $Default }
    return ($a -match '^[SsYy]')
}

function Read-CvInt {
    <#
        Lee un ENTERO por teclado y RE-PREGUNTA si lo tecleado no es un numero (no aborta). Con
        -AllowEmpty, ENTER (vacio) devuelve $null (opcional). Reutiliza Read-CvLine (con soporte de ESC/
        timeout). Util para asistentes que piden numeros (nº de cue, indices, etc.).
    #>
    param([string]$Prompt, [switch]$AllowEmpty)
    while ($true) {
        $s = (Read-CvLine -Prompt $Prompt).Trim()
        if ($s -eq '' -and $AllowEmpty) { return $null }
        if ($s -match '^\d+$') { return [int]$s }
        Write-Host '  Numero no valido.' -ForegroundColor Yellow
    }
}


function Show-CvHeader {
    <# Cabecera al arrancar: nombre de la app + version (y subtitulo opcional). #>
    param([Parameter(Mandatory)]$Context, [string]$Subtitle = '')
    $name = '{0} {1}' -f $Context.AppName, $Context.Version
    if ($Subtitle) { $name = "$name - $Subtitle" }
    $sep = Get-CvSepLine
    Write-Host ''
    Write-Host $sep  -ForegroundColor Cyan
    Write-Host ("  {0}" -f $name) -ForegroundColor Cyan
    Write-Host $sep  -ForegroundColor Cyan
}

function Show-Menu {
    <#
        Muestra un bloque de menu: el $Title va como ENCABEZADO (sin enmarcar con guiones, para no
        duplicar el marco de la cabecera), las opciones debajo y una linea de guiones al FINAL que
        cierra el bloque antes del prompt. $Lines = opciones (cadena vacia = linea en blanco). No
        trunca: las lineas largas se imprimen enteras.
    #>
    param([string]$Title, [string[]]$Lines = @(), [int]$Indent = 0)
    $pad = ' ' * $Indent
    $sep = $pad + (Get-CvDashLine)
    Write-Host ''
    # El titulo va como encabezado con una linea DEBAJO (subrayado, lo separa de la lista); NO se pone
    # linea encima (asi no duplica el marco de la cabecera === cuando el menu va justo debajo). Sin
    # titulo (p. ej. el menu principal, que ya tiene cabecera) no hay subrayado, solo la lista.
    if ($Title) { Write-Host ($pad + ("  {0}" -f $Title)); Write-Host $sep }
    foreach ($l in $Lines) {
        if ($l -eq '') { Write-Host ''; continue }
        $line = $pad + ("    {0}" -f $l)
        # Resaltar el marcador '[NO SOPORTADO]' dentro de una opcion (p. ej. un encoder por GPU que
        # esta GPU no admite). Se pinta como BADGE amarillo (mismo helper que los avisos): resalta
        # aunque el texto de la consola ya sea amarillo (console.foreground) y sus caps evitan que el
        # fondo se "estire" hasta el margen al redimensionar la ventana.
        $mk = '[NO SOPORTADO]'
        $at = $line.IndexOf($mk)
        if ($at -ge 0) {
            Write-Host $line.Substring(0, $at) -NoNewline
            Write-CvBadge -Text ($mk.Trim('[]'))
            Write-Host $line.Substring($at + $mk.Length)
        } else {
            Write-Host $line
        }
    }
    Write-Host $sep
}

function Write-CvOptionUnsupported {
    <#
        Aviso ESTANDAR y REUTILIZABLE (badge amarillo [AVISO]) para cuando la opcion elegida en un
        menu no es valida/soportada en este equipo, y hay que volver a elegir. Sirve para CUALQUIER
        opcion (no solo encoders): el llamador pasa que se eligio, el motivo y una sugerencia opcional.
          -Option: valor elegido (p. ej. 'av1_nvenc').
          -Reason: por que no se puede (p. ej. 'tu GPU no lo soporta').
          -Hint:   sugerencia opcional de que elegir en su lugar.
    #>
    param([Parameter(Mandatory)][string]$Option, [Parameter(Mandatory)][string]$Reason, [string]$Hint = '')
    $msg = "[AVISO] - '{0}' no disponible en este equipo: {1}." -f $Option, $Reason
    if ($Hint) { $msg = "$msg $Hint" }
    Write-CvLog 'GLOBAL' $msg
}

function Show-CvBox {
    <#
        Dibuja un CUADRO de doble linea alrededor del contenido. Pensado para mensajes
        destacados (avisos, errores, resumenes...). -Color aplica color a todo el cuadro.
        Usa codigos [char] para los bordes (no depende de la codificacion del fichero).
    #>
    param([string]$Title, [string[]]$Lines = @(), [System.ConsoleColor]$Color)
    $inner = 62
    $H  = [char]0x2550
    $V  = [char]0x2551
    $TL = [char]0x2554; $TR = [char]0x2557
    $BL = [char]0x255A; $BR = [char]0x255D
    $hbar = [string]$H * $inner

    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add(("{0}{1}{2}" -f $TL, $hbar, $TR))
    $add = {
        param($txt)
        if ($txt.Length -gt $inner) { $txt = $txt.Substring(0, $inner) }
        $rows.Add(("{0}{1}{0}" -f $V, $txt.PadRight($inner)))
    }
    & $add ''
    if ($Title) { & $add ("   {0}" -f $Title); & $add '' }
    foreach ($l in $Lines) {
        if ($l -eq '') { & $add '' } else { & $add ("   {0}" -f $l) }
    }
    & $add ''
    $rows.Add(("{0}{1}{2}" -f $BL, $hbar, $BR))

    $col = @{}
    if ($PSBoundParameters.ContainsKey('Color')) { $col.ForegroundColor = $Color }
    Write-Host ''
    foreach ($r in $rows) { Write-Host $r @col }
}


function Get-CvMenuNumWidth {
    <#
        Fuente unica del ANCHO (en digitos) para alinear a la derecha los indices de un listado
        numerado, de modo que TODAS las etiquetas empiecen en la misma columna aunque haya indices
        de 1 y de 2+ cifras (' 1.' … '10.'). Se le pasa el nº de opciones o el mayor indice mostrado.
        Lo usan Select-FromList, Select-Profile (perfiles) y el menu de grupos de bordes (Video).
    #>
    param([int]$Count)
    ("$([math]::Max(1, $Count))").Length
}

function Select-FromList {
    <#
        Muestra una lista numerada de opciones (enmarcada) y devuelve el valor elegido.
        Cada opcion puede ser una CADENA o un objeto @{ Value; Text } (Value = lo que se devuelve;
        Text = descripcion que se muestra tras el nombre). Asi los catalogos Get-Cv* (que usan ese
        formato) se pasan tal cual. La opcion 0 devuelve $NoneValue. ENTER = opcion por defecto
        ($DefaultIndex, 1-based; 0 = ninguno). $Headers: { <indice0> = 'Titulo' } inserta un titulo.
    #>
    param(
        [string]$Title,
        [Parameter(Mandatory)][object[]]$Options,   # cadenas o @{ Value; Text; Position }
        [string]$NoneLabel = 'ninguno',
        [string]$NoneValue = '',
        [int]$DefaultIndex = 0,
        [string]$DefaultValue = '',       # si se da, ENTER devuelve este valor (aunque no este en la lista)
        [string]$NoneKey = '',            # letra alternativa para la opcion 0 (p.ej. 'S' = salir)
        [string[]]$Descriptions = @(),    # descripcion por opcion (si la opcion no es objeto con Text)
        [string]$NoneDescription = '',    # descripcion opcional de la opcion 0
        [string]$CancelLabel = '',        # texto de la linea de cancelar (si -AllowCancel)
        [hashtable]$Headers = $null,
        [switch]$NoNone,                  # oculta la opcion 0 (salvo que haya una opcion Position='first')
        [switch]$AllowCancel
    )
    # Normalizar cada opcion a registro { Val; Txt; Pos }. Acepta cadenas o @{ Value; Text; Position }
    # (o PSObject con esas propiedades). Position: 'first' -> opcion 0 (None); 'end' -> al final.
    $recs = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        if ($o -is [System.Collections.IDictionary]) {
            $recs += @{
                Val = "$($o['Value'])"
                Txt = "$($o['Text'])"
                Pos = "$($o['Position'])"
            }
        } elseif ($o -is [psobject] -and $o.PSObject.Properties['Value']) {
            $recs += @{
                Val = "$($o.Value)"
                Txt = "$($o.Text)"
                Pos = "$(if ($o.PSObject.Properties['Position']) { $o.Position })"
            }
        } else {
            $recs += @{
                Val = "$o"
                Txt = $(if ($i -lt $Descriptions.Count) { $Descriptions[$i] } else { '' })
                Pos = ''
            }
        }
    }
    # Reparto por posicion: numeradas = mids (sin Position) + ends; la opcion 0 = 'first' si existe.
    $numbered = @($recs | Where-Object { $_.Pos -ne 'first' -and $_.Pos -ne 'end' }) + @($recs | Where-Object { $_.Pos -eq 'end' })
    $first    = @($recs | Where-Object { $_.Pos -eq 'first' })[0]
    $hasNone  = $true; $noneVal = $NoneValue; $noneLbl = $NoneLabel; $noneDsc = $NoneDescription
    if ($first) { $noneVal = $first.Val; $noneLbl = $first.Val; $noneDsc = $first.Txt }
    elseif ($NoNone) { $hasNone = $false }

    # Default: por valor (prioridad, puede ser libre) o por indice.
    $defIdx = $DefaultIndex; $defRet = $null
    if ($DefaultValue) {
        $defRet = $DefaultValue
        $mi = [array]::IndexOf(@($numbered | ForEach-Object { $_.Val }), "$DefaultValue")
        if ($mi -ge 0) { $defIdx = $mi + 1 } elseif ($hasNone -and $noneVal -eq $DefaultValue) { $defIdx = 0 } else { $defIdx = -1 }
    }
    $defShown = if ($null -ne $defRet) { $defRet } else { "$defIdx" }

    $mark    = '  <= por defecto'
    # La opcion 0 (none) tambien se elige con ESC (salvo -AllowCancel, donde ESC cancela). Se anota.
    $noneEsc = if ($AllowCancel) { '' } else { ' / ESC' }
    $noneNum = if ($NoneKey) { '0 / {0}{1}' -f $NoneKey.ToUpper(), $noneEsc } else { '0{0}' -f $noneEsc }
    # Ancho del NUMERO (dígitos del mayor: 13 -> 2), para alinear a la derecha los indices de 1 y 2
    # cifras y que TODAS las etiquetas empiecen en la misma columna ('1.' vs '10.'). Fuente unica.
    $numW    = Get-CvMenuNumWidth $numbered.Count
    $leftNum = @(); $descNum = @()
    for ($i = 0; $i -lt $numbered.Count; $i++) { $leftNum += ('{0}. {1}' -f (("$($i + 1)").PadLeft($numW)), $numbered[$i].Val); $descNum += $numbered[$i].Txt }
    $leftNone = if ($hasNone) { '{0}. {1}' -f $noneNum.PadLeft($numW), $noneLbl } else { '' }
    $anyDesc  = (@($descNum | Where-Object { $_ }).Count -gt 0) -or [bool]$noneDsc
    $allLeft  = @($leftNum); if ($hasNone) { $allLeft += $leftNone }
    $w        = if ($anyDesc -and $allLeft.Count) { ($allLeft | Measure-Object -Property Length -Maximum).Maximum } else { 0 }

    # Cuerpo de cada fila (izquierda alineada a $w + su descripcion), SIN la marca de defecto.
    $bodyNum = @()
    for ($i = 0; $i -lt $numbered.Count; $i++) {
        $bodyNum += $(if ($descNum[$i]) { $leftNum[$i].PadRight($w) + '  - ' + $descNum[$i] } else { $leftNum[$i] })
    }
    $bodyNone = ''
    if ($hasNone) { $bodyNone = $(if ($noneDsc) { $leftNone.PadRight($w) + '  - ' + $noneDsc } else { $leftNone }) }
    # Ancho comun para alinear "<= por defecto" en columna, tras el cuerpo (texto) mas largo.
    $allBody = @($bodyNum); if ($hasNone) { $allBody += $bodyNone }
    $bodyW   = if ($allBody.Count) { ($allBody | Measure-Object -Property Length -Maximum).Maximum } else { 0 }

    $lines = @()
    for ($i = 0; $i -lt $numbered.Count; $i++) {
        if ($Headers -and $Headers.Contains($i)) {
            if ($i -gt 0) { $lines += '' }                 # separacion antes del bloque
            $lines += ("-- {0} --" -f $Headers[$i])
        }
        $lines += $(if (($i + 1) -eq $defIdx) { $bodyNum[$i].PadRight($bodyW) + $mark } else { $bodyNum[$i] })
    }
    if ($hasNone) {
        $lines += ''
        $lines += $(if ($defIdx -eq 0) { $bodyNone.PadRight($bodyW) + $mark } else { $bodyNone })
    }
    if ($AllowCancel) {
        $lines += ''                                       # separacion antes de la linea de cancelar
        $lines += $(if ($CancelLabel) { $CancelLabel } else { 'C / ESC. Cancelar' })
    }
    Show-Menu -Title $Title -Lines $lines
    # ESC captura si hay -AllowCancel (cancela) o si hay opcion 0 (vuelve = elige none). Si no hay
    # ninguna de las dos (menu obligatorio -NoNone), ESC se ignora (lectura clasica con Read-Host).
    $escBack = $hasNone -and -not $AllowCancel
    $useLine = $AllowCancel -or $escBack
    while ($true) {
        $pr = "   Opcion [{0}]" -f $defShown
        $k = $null
        try { $k = (& { if ($useLine) { Read-CvLine -Prompt $pr -AllowCancel } else { Read-Host $pr } }).Trim() }
        catch {
            if ($_.Exception.Message -eq 'CV_CANCEL') {
                if ($AllowCancel) { throw }        # cancelar de verdad (propaga)
                return $noneVal                     # ESC = opcion 0 (volver / salir / none)
            }
            throw
        }
        if ($AllowCancel -and $k -match '^[Cc]$') { throw 'CV_CANCEL' }
        if ($hasNone -and $NoneKey -and $k -ieq $NoneKey) { return $noneVal }   # letra alternativa de la opcion 0
        if ($k -eq '') {
            if ($null -ne $defRet) { return $defRet }      # default por valor (incluido valor libre)
            $k = "$defIdx"
        }
        $n = 0
        if ([int]::TryParse($k, [ref]$n)) {
            if ($n -eq 0 -and $hasNone) { return $noneVal }
            if ($n -ge 1 -and $n -le $numbered.Count) { return $numbered[$n - 1].Val }
        }
        Write-Host '   Opcion no valida.' -ForegroundColor Yellow
    }
}


Export-ModuleMember -Function *
