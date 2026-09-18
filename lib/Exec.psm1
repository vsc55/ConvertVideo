<#
    Exec.psm1 - Ejecucion de procesos externos (ffmpeg/ffprobe/ffplay/aacgain): captura de
    salida, ventana aparte y modo debug.
#>

# Helper nativo: lanza un proceso en una CONSOLA NUEVA MINIMIZADA SIN ROBAR EL FOCO
# (SW_SHOWMINNOACTIVE). El Start-Process con -WindowStyle Minimized usa SW_SHOWMINIMIZED,
# que activa la ventana y roba el foco aunque quede minimizada.
if (-not ('CvProc' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CvProc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    const uint CREATE_NEW_CONSOLE = 0x00000010; const int STARTF_USESHOWWINDOW = 0x00000001;
    const short SW_SHOWMINNOACTIVE = 7; const uint INFINITE = 0xFFFFFFFF;
    public static int RunMinimizedNoActivate(string exe, string args, string cwd) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_SHOWMINNOACTIVE;
        var cmd = new StringBuilder("\"" + exe + "\" " + args);
        PROCESS_INFORMATION pi;
        if (!CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, CREATE_NEW_CONSOLE, IntPtr.Zero, cwd, ref si, out pi))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        WaitForSingleObject(pi.hProcess, INFINITE);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return (int)code;
    }
}
'@
}

# Helper nativo: traer una ventana al PRIMER PLANO y darle el foco. Se usa para la ventana de
# previsualizacion (ffplay), que debe recibir el foco para poder cerrarla ('q'/ESC) y que las
# teclas vayan a ella y no a la consola (al contrario que las ventanas de codificacion, que van
# sin foco). Al reves que el no-foco de CvProc.
if (-not ('CvWin' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CvWin {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int nCmdShow);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    const int SW_SHOW = 5; const int SW_RESTORE = 9;
    // Windows bloquea SetForegroundWindow si el proceso que llama no es el de primer plano
    // (foreground lock): en ese caso la ventana solo parpadea en la barra de tareas y no se
    // activa. Truco estandar: adjuntar la cola de entrada del hilo de la ventana ACTUAL de primer
    // plano (y la del hilo destino) a la nuestra mientras hacemos el SetForegroundWindow; asi el SO
    // nos considera parte del hilo activo y permite el cambio de foco. Luego se desadjunta.
    public static void ToForeground(IntPtr h) {
        if (h == IntPtr.Zero) return;
        uint pid;
        uint cur = GetCurrentThreadId();
        uint fg  = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint tgt = GetWindowThreadProcessId(h, out pid);
        if (fg  != cur) AttachThreadInput(cur, fg,  true);
        if (tgt != cur && tgt != fg) AttachThreadInput(cur, tgt, true);
        ShowWindow(h, SW_RESTORE); ShowWindow(h, SW_SHOW);
        BringWindowToTop(h);
        for (int i = 0; i < 3 && !SetForegroundWindow(h); i++) { System.Threading.Thread.Sleep(30); }
        if (tgt != cur && tgt != fg) AttachThreadInput(cur, tgt, false);
        if (fg  != cur) AttachThreadInput(cur, fg,  false);
    }
}
'@
}

function Write-CvDebug {
    param([Parameter(Mandatory)]$Context, [string]$Message)
    if ($Context.Debug) { Write-Host ("[DEBUG] {0}" -f $Message) -ForegroundColor DarkGray }
}


function ConvertTo-ArgString {
    <#
        Cita un array de argumentos segun las reglas de CreateProcess de Windows.
        Compatible con PS5.1 (no usa ProcessStartInfo.ArgumentList, que solo existe en PS7).
    #>
    param([string[]]$Arguments = @())
    $parts = foreach ($a in $Arguments) {
        if ($null -eq $a) { $a = '' }
        if ($a.Length -gt 0 -and $a -notmatch '[ \t"]') {
            $a
        } else {
            # escapar backslashes previos a comilla y las comillas
            $s = $a -replace '(\\*)"', '$1$1\"'
            $s = $s -replace '(\\+)$', '$1$1'
            '"' + $s + '"'
        }
    }
    return ($parts -join ' ')
}


function Invoke-ToolCapture {
    <#
        Ejecuta un exe capturando stdout/stderr. Para salidas pequenas (ffprobe, cropdetect,
        volumedetect, aacgain). Si se pasa -Context y esta en modo debug, muestra el comando
        y espera confirmacion antes de ejecutar.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        $Context = $null
    )
    if ($null -ne $Context) {
        Write-CvDebug -Context $Context -Message ("RUN (analisis) => `"{0}`" {1}" -f $Exe, (ConvertTo-ArgString $Arguments))
        if ($Context.Debug -and $Context.DebugPausePerCommand) { Read-Host '  ...ENTER para ejecutar...' | Out-Null }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    # Leer stderr de forma asincrona para evitar bloqueos si el buffer se llena.
    $errTask = $p.StandardError.ReadToEndAsync()
    $out     = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result

    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $out
        StdErr   = $err
    }
}


function Invoke-ToolShow {
    <#
        Ejecuta un exe y espera a que termine. Devuelve el codigo de salida.
        Las CODIFICACIONES se lanzan en una ventana aparte minimizada para no ensuciar
        la consola principal. Con -Preview (previsualizacion de bordes con FFplay) se
        ejecuta en la consola principal, como antes. En modo debug o con el marcador
        'same_window' todo va a la consola principal.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)]$Context,
        [switch]$Preview
    )
    Write-CvDebug -Context $Context -Message ("RUN => `"{0}`" {1}" -f $Exe, (ConvertTo-ArgString $Arguments))
    if ($Context.Debug -and $Context.DebugPausePerCommand) { Read-Host '  ...ENTER para ejecutar...' | Out-Null }

    # La previsualizacion se queda en la consola principal; solo las codificaciones
    # se mueven a una ventana aparte minimizada.
    $separate = ($Context.SeparateWindow -and -not $Context.Debug -and -not $Preview)

    if ($separate) {
        # Ventana aparte MINIMIZADA sin robar el foco (SW_SHOWMINNOACTIVE via CreateProcess).
        $cwd = "$($Context.Root)"; if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }
        try {
            return [CvProc]::RunMinimizedNoActivate($Exe, (ConvertTo-ArgString $Arguments), $cwd)
        } catch {
            # Fallback: minimizada clasica (puede robar foco) si la API nativa fallara.
            Write-CvDebug -Context $Context -Message ("ventana sin foco no disponible ({0}); minimizada normal" -f $_.Exception.Message)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = $Exe
            $psi.Arguments       = ConvertTo-ArgString $Arguments
            $psi.UseShellExecute = $true
            $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Minimized
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            return $p.ExitCode
        }
    }

    # Consola actual (previsualizacion, debug o marcador same_window).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $Exe
    $psi.Arguments       = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Preview) {
        # La ventana de preview (ffplay) DEBE tener el foco: si no, las teclas ('q'/ESC para
        # cerrarla) irian a la consola. Windows no siempre le da el primer plano al abrirla, asi
        # que se espera a que cree su ventana (hasta ~2 s) y se trae al frente. Best-effort.
        try {
            for ($i = 0; $i -lt 40 -and $p.MainWindowHandle -eq [IntPtr]::Zero -and -not $p.HasExited; $i++) {
                Start-Sleep -Milliseconds 50; $p.Refresh()
            }
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [CvWin]::ToForeground($p.MainWindowHandle) }
        } catch {
            Write-CvDebug -Context $Context -Message ("no se pudo dar foco a la preview: {0}" -f $_.Exception.Message)
        }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

function Format-CvEta {
    <# Segundos -> 'mm:ss' o 'h:mm:ss' (compacto, sin ms). Negativo/no finito -> '--:--'. #>
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return '--:--' }
    $p = Get-CvTimeParts ([math]::Round($Seconds))   # redondeo a segundos (MS = 0)
    if ($p.H -ge 1) { return ('{0}:{1:00}:{2:00}' -f $p.H, $p.M, $p.S) }
    return ('{0:00}:{1:00}' -f $p.M, $p.S)
}

function Write-CvProgressLine {
    <#
        Pinta una linea de progreso que se reescribe en el sitio: vuelve al inicio (\r), escribe el
        texto, borra con espacios el sobrante de un render anterior mas largo ($PrevLen) y vuelve a
        colocar el cursor JUSTO tras el texto (segundo \r + texto). Devuelve la longitud del texto
        (para pasarla como -PrevLen en la siguiente llamada). Asi el cursor no queda flotando a la
        derecha entre espacios.

        Escribe con [Console]::Write y NO con Write-Host A PROPOSITO: el transcript de la sesion
        registra lo que pasa por el host, asi que con Write-Host acababa en el log CADA repintado (y
        ademas por duplicado, por el doble volcado del cursor). En un log real eran 4273 de 5181
        lineas -el 82%- y la carpeta logs\ se iba a decenas de MB. La consola se ve igual; lo que si
        queda registrado es el estado FINAL del paso, que el llamador escribe con Write-Host al
        cerrarlo. Fail-soft: sin consola (salida redirigida) cae a Write-Host.
    #>
    param([string]$Text, [int]$PrevLen = 0)
    $clear = if ($PrevLen -gt $Text.Length) { ' ' * ($PrevLen - $Text.Length) } else { '' }
    $out = ("`r{0}{1}`r{0}" -f $Text, $clear)
    try { [Console]::Write($out) } catch { Write-Host $out -NoNewline }
    return $Text.Length
}

function Resolve-CvProgressSeconds {
    <#
        PURO. Segundos de video YA producidos, para el % y la ETA de la linea de progreso.

        Fuente principal: el 'out_time' que da ffmpeg por '-progress' (-OutSeconds, con -HasOutTime
        $true en cuanto ffmpeg llega a darlo). Si NO lo da, se ESTIMA con los frames ya codificados y
        el fps de SALIDA: frames / fps. Esto pasa de verdad: ffmpeg calcula out_time como el MINIMO de
        todas las pistas de salida, asi que basta con que una este VACIA (p. ej. un subtitulo sin un
        solo cue, ver Test-CvSubtitleEmpty) para que emita 'out_time_us=N/A' durante TODA la ejecucion
        y la barra se quede congelada en 0%. Sin fps conocido (<= 0) no hay estimacion posible -> 0.
    #>
    param(
        [bool]$HasOutTime,
        [double]$OutSeconds = 0,
        [double]$Frames = 0,
        [double]$Fps = 0
    )
    if ($HasOutTime) { return [double]$OutSeconds }
    if ($Fps -gt 0 -and $Frames -gt 0) { return [double]($Frames / $Fps) }
    return 0.0
}

function Resolve-CvProgressSpeed {
    <#
        PURO. Velocidad de codificacion (x tiempo real) para la ETA: la que da ffmpeg ('speed=1.8x')
        o, si la da como 'N/A' (mismo caso que el out_time de Resolve-CvProgressSeconds), la MEDIA
        calculada con los segundos ya producidos y el reloj de pared (-Elapsed). Devuelve 0 si no se
        puede saber (el llamador omite entonces la ETA y la velocidad).
    #>
    param(
        [string]$Speed = '',
        [double]$Seconds = 0,
        [double]$Elapsed = 0
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $spd = 0.0
    if ([double]::TryParse(($Speed -replace '[^0-9.]', ''), [System.Globalization.NumberStyles]::Float, $inv, [ref]$spd) -and $spd -gt 0) { return $spd }
    if ($Seconds -gt 0 -and $Elapsed -gt 0) { return [double]($Seconds / $Elapsed) }
    return 0.0
}

function Invoke-ToolProgress {
    <#
        Ejecuta ffmpeg INLINE (sin ventana aparte) capturando su salida '-progress' y mostrando una
        linea de progreso VIVA que se actualiza en el sitio (\r):
            " - <Label>  42%  ETA 03:12  1.8x  1234.5kbits/s  q28"   (bitrate siempre; q solo con -ShowQ)
        Al terminar deja la linea en el estado "abierto" de Start-CvStep (" - <Label>", sin salto)
        para que el llamador la cierre con Stop-CvStep (OK/ERROR segun el codigo/validacion). Devuelve
        el codigo de salida. Inyecta '-nostats -progress pipe:1' (progreso legible por stdout; el resto
        del log de ffmpeg va a stderr, que se drena sin mostrar). TotalSeconds <= 0 -> no hay % ni ETA,
        solo tiempo transcurrido/velocidad. Pensada para los pasos largos (recodificacion de video/audio).

        -Fps (fps de SALIDA, Get-CvOutputFps) = red de seguridad: si ffmpeg no da 'out_time'/'speed'
        (los da como 'N/A'), el avance se estima con los frames codificados (Resolve-CvProgressSeconds)
        en vez de dejar la barra clavada en 0%.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)]$Context,
        [string]$Label = 'Procesando...',
        [double]$TotalSeconds = 0,
        [double]$Fps = 0,         # fps de salida: permite estimar el avance si ffmpeg no da out_time
        [switch]$ShowQ            # mostrar el cuantizador (q) del stream: util en video, no en audio
    )
    Write-CvDebug -Context $Context -Message ("RUN (progress) => `"{0}`" {1}" -f $Exe, (ConvertTo-ArgString $Arguments))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ConvertTo-ArgString (@('-nostats','-progress','pipe:1') + $Arguments)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p       = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()   # drenar stderr (errores) sin mostrarlo -> evita bloqueos
    $reader  = $p.StandardOutput

    $inv        = [System.Globalization.CultureInfo]::InvariantCulture
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $lastRender = -1000.0
    $lastPct    = -1
    $lastLen    = 0        # longitud del ultimo texto pintado (para borrar el sobrante del anterior)
    $speed      = ''
    $outSec     = 0.0
    $hasOut     = $false  # $true en cuanto ffmpeg da un out_time numerico (si no, se estima por frames)
    $frames     = 0.0     # 'frame=' del -progress (frames ya codificados)
    $bitrate    = ''      # 'bitrate=' del -progress (p. ej. '1234.5kbits/s' o 'N/A')
    $qv         = ''      # 'stream_X_X_q=' del -progress (cuantizador del stream; -1 si no aplica)

    while ($null -ne ($line = $reader.ReadLine())) {
        if     ($line.StartsWith('out_time_us=')) { $n = 0L; if ([long]::TryParse($line.Substring(12), [ref]$n) -and $n -ge 0) { $outSec = $n / 1000000.0; $hasOut = $true } }
        elseif ($line.StartsWith('frame='))         { $fr = 0L; if ([long]::TryParse($line.Substring(6).Trim(), [ref]$fr) -and $fr -ge 0) { $frames = [double]$fr } }
        elseif ($line.StartsWith('speed='))        { $speed = $line.Substring(6).Trim() }
        elseif ($line.StartsWith('bitrate='))       { $bitrate = $line.Substring(8).Trim() }
        elseif ($line -match '^stream_\d+_\d+_q=')  { $qv = ($line -split '=', 2)[1].Trim() }
        elseif ($line.StartsWith('progress=')) {
            # Fin de bloque de progreso: renderizar (limitado a cambio de % o cada 2 s, para no
            # inundar el transcript con cientos de lineas). Los segundos producidos y la velocidad
            # salen de ffmpeg o, si los da como 'N/A', se estiman (Resolve-CvProgressSeconds/Speed).
            $sec    = Resolve-CvProgressSeconds -HasOutTime $hasOut -OutSeconds $outSec -Frames $frames -Fps $Fps
            $curPct = if ($TotalSeconds -gt 0) { [int][math]::Floor($sec / $TotalSeconds * 100) } else { -1 }
            if (($curPct -ne $lastPct) -or (($sw.Elapsed.TotalSeconds - $lastRender) -ge 2)) {
                $pct = if ($TotalSeconds -gt 0) { [int][math]::Min(100, [math]::Max(0, $curPct)) } else { -1 }
                $spd = Resolve-CvProgressSpeed -Speed $speed -Seconds $sec -Elapsed $sw.Elapsed.TotalSeconds
                $hasSpd = ($spd -gt 0)
                $parts = " - $Label"
                if ($pct -ge 0) {
                    $bar = Get-CvProgressBar -Percent $pct   # '' si console.progressBarWidth = 0
                    if ($bar) { $parts += "  $bar" }
                    $parts += ('  {0,3}%' -f $pct)
                }
                # Resto acotado a >= 0: con el avance estimado por frames el total puede quedarse corto
                # por decimas y un resto negativo pintaria 'ETA --:--' justo al acabar.
                if ($pct -ge 0 -and $hasSpd) { $parts += ('  ETA {0}' -f (Format-CvEta ([math]::Max(0.0, [double]($TotalSeconds - $sec)) / $spd))) }
                if ($hasSpd)        { $parts += ('  {0}x' -f ([math]::Round($spd, 2)).ToString($inv)) }
                elseif ($pct -lt 0) { $parts += ('  {0}' -f (Format-CvEta $sec)) }   # sin total: tiempo transcurrido
                # Bitrate (audio y video) y cuantizador q (solo si -ShowQ, p. ej. video). Se omiten
                # mientras ffmpeg aun no da un valor util ('N/A' al arrancar; q negativo = no aplica).
                if ($bitrate -and $bitrate -notmatch '(?i)n/?a') { $parts += ('  {0}' -f $bitrate) }
                if ($ShowQ -and $qv) {
                    $qn = 0.0
                    if ([double]::TryParse(($qv -replace '[^0-9.\-]', ''), [System.Globalization.NumberStyles]::Float, $inv, [ref]$qn) -and $qn -ge 0) {
                        $parts += ('  q{0}' -f [int][math]::Round($qn))
                    }
                }
                $lastLen = Write-CvProgressLine -Text $parts -PrevLen $lastLen
                $lastPct = $curPct; $lastRender = $sw.Elapsed.TotalSeconds
            }
        }
    }
    $p.WaitForExit()
    # stderr completo de ffmpeg (oculto en modo progreso) en variable GLOBAL (cruza modulos): el
    # llamador lo vuelca a un log con Save-CvToolError si el proceso falla, para poder analizarlo.
    $global:CvLastToolError = $errTask.Result

    # Dejar la linea como la dejaria Start-CvStep (" - <Label>" sin salto, con el cursor JUSTO tras
    # el texto): se BORRA de la consola el ultimo render (que no pasa por el transcript) y se reescribe
    # ya con Write-Host, que SI queda en el log. Asi el log recibe UNA sola linea por paso -la que
    # Stop-CvStep cierra con OK/ERROR-, igual que en el pipeline por etapas.
    try { [Console]::Write("`r" + (' ' * [Math]::Max(0, $lastLen)) + "`r") } catch {}
    Write-Host (" - $Label") -NoNewline
    return $p.ExitCode
}

function Invoke-CvPreview {
    <#
        Nucleo comun de las previews con ffplay (bordes, pista de video/audio, subtitulo): reproduce
        con -autoexit (se cierra solo al acabar o antes con q/ESC) + los args de seleccion/filtro que
        aporta cada llamador (-vst/-ast/-sst/-vf/-nodisp). El INICIO sale de -Start (comando 'P N <seg>')
        o, si no se da, de preview.start (0 = desde el principio; se ajusta a la duracion real con
        Get-CvSafeStart). La DURACION sale de -Seconds si el llamador la fija (>= 0), o de
        preview.seconds: 0 = SIN limite (todo el video); > 0 = muestra de esos segundos (-t). -Start
        y -Seconds < 0 = usar la config (permiten un override por-llamada si en el futuro hace falta).
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [string[]]$ExtraArgs = @(), [string]$Label = 'PREVIEW',
        [int]$Start = -1, [int]$Seconds = -1, [double]$Duration = 0
    )
    $s   = if ($Start -ge 0) { $Start } else { [int]$Context.PreviewStart }
    $ss  = if ($s -gt 0) { @('-ss', "$(Get-CvSafeStart -Start $s -Duration $Duration -Window 1)") } else { @() }
    $sec = if ($Seconds -ge 0) { $Seconds } else { [int]$Context.PreviewSeconds }
    $t   = if ($sec -gt 0) { @('-t', "$sec") } else { @() }   # 0 = sin limite (reproduce todo)
    $a = @('-hide_banner','-loglevel','error','-autoexit') + $ss + $t + $ExtraArgs + @('-window_title',$Label,$File)
    Invoke-ToolShow -Exe $Context.FFplay -Arguments $a -Context $Context -Preview | Out-Null
}


Export-ModuleMember -Function *
