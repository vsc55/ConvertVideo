<#
    Log.psm1 - Registro: log de consola (Write-CvLog) y transcript de la ejecucion a logs\.
    Sin dependencias de otros modulos.
#>

# Estilo de las marcas/avisos: $true => ASCII puro ([OK]/[ERROR], corchetes []); $false =>
# simbolos y badge de medio bloque. Lo fija el arranque desde config (console.asciiMarks) via
# Set-CvMarkStyle, util en consolas/fuentes que no tengan los glifos (se verian como cuadros).
$script:CvAsciiMarks = $false
function Set-CvMarkStyle { param([bool]$Ascii) $script:CvAsciiMarks = [bool]$Ascii }

function Get-CvMark {
    <#
        Marca de estado (check/cruz). Con console.asciiMarks -> texto ASCII ([OK]/[ERROR]); si no,
        simbolos U+2713 (check) y U+00D7 (cruz x) via ConvertFromUtf32 (no depende de la codificacion
        del fichero ni de que la fuente tenga la cruz Dingbats U+2717).
    #>
    param([bool]$Ok)
    if ($script:CvAsciiMarks) { if ($Ok) { return '[OK]' } else { return '[ERROR]' } }
    # Check U+2713 (Dingbats) y cruz U+00D7 (signo de multiplicacion, Latin-1). Se usa 00D7 y NO la
    # cruz U+2717 (Dingbats) porque algunas fuentes de consola (p. ej. Cascadia Code) pintan el check
    # pero NO esa cruz (sale un cuadro/tofu); 00D7 esta en cualquier fuente que ya dibuje el check.
    if ($Ok) { return [char]::ConvertFromUtf32(0x2713) }   # check monocromo
    else     { return [char]::ConvertFromUtf32(0x00D7) }   # cruz monocroma (x, universal)
}

function Write-CvBadge {
    <#
        Escribe INLINE (sin salto de linea) una etiqueta resaltada tipo badge: interior con fondo de
        color y unos CAPS a los lados cuyo fondo es el POR DEFECTO, de modo que la celda del borde NO
        lleva fondo -> evita el bug de la consola de Windows de "estirar" el fondo hasta el margen al
        redimensionar. Con console.asciiMarks usa corchetes '[ ]'; si no, medios bloques (▐ ▌). El
        llamador decide el salto de linea y lo que va antes/despues. Reutilizado por Write-CvLog
        (avisos/errores) y por los menus (marcador 'NO SOPORTADO' de una opcion no disponible).
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [System.ConsoleColor]$Fg = [System.ConsoleColor]::Black,
        [System.ConsoleColor]$Bg = [System.ConsoleColor]::Yellow
    )
    $dbg = $Host.UI.RawUI.BackgroundColor
    $dfg = $Host.UI.RawUI.ForegroundColor
    if ($script:CvAsciiMarks) {
        $lb = '['; $rb = ']'
    } else {
        $lb = [char]0x2590; $rb = [char]0x258C
    }
    # ASCII: corchetes en color normal. Simbolos: medios bloques coloreados como el fondo (se ven
    # solidos). En ambos casos el cap va con el FONDO POR DEFECTO (la ultima celda no lleva color).
    $capFg = if ($script:CvAsciiMarks) { $dfg } else { $Bg }
    Write-Host $lb -NoNewline -ForegroundColor $capFg -BackgroundColor $dbg
    Write-Host (' ' + $Text + ' ') -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
    Write-Host $rb -NoNewline -ForegroundColor $capFg -BackgroundColor $dbg
}

function Write-CvLog {
    <#
        Log de consola. Las lineas de error/aviso se resaltan con fondo de color y se envuelven
        en "[ ... ]" con los CORCHETES en color normal: asi la ultima celda de la linea NO lleva
        fondo, evitando el bug de la consola de Windows de que el fondo se "estira" hasta el borde
        al redimensionar la ventana. El texto interior va resaltado ([ERR] -> rojo; [AVISO]/[WARN]/
        [NO SOPORTADO] -> amarillo). Ademas se quita la redundancia del [TAG] y de los corchetes
        del token: "[AUDIO] [AVISO] - x" se muestra como "[ AVISO - x ]".
    #>
    param([string]$Tag = 'GLOBAL', [string]$Message = '', [int]$Indent = 0)
    $pad = ' ' * $Indent
    if ($Message -match '\[(ERR|AVISO|WARN|NO SOPORTADO)\]') {
        # Quitar los corchetes de TODOS los tokens iniciales, no solo del primero: "[AVISO] - x"
        # -> "AVISO - x", y tambien "[FFMPEG] - [ERR] - x" -> "FFMPEG - ERR - x" (el nivel puede
        # no ser el primer token). El padding del bloque lo aportan los espacios de abajo.
        $inner = $Message.Trim()
        $mTok = [regex]::Match($inner, '^(?:\[[^\]]+\]\s*-\s*)+')
        if ($mTok.Success) { $inner = ($mTok.Value -replace '[\[\]]', '') + $inner.Substring($mTok.Value.Length) }
        # Badge reutilizable (caps sin fondo para no "estirar" el color al redimensionar). ERR = rojo,
        # el resto (AVISO/WARN/NO SOPORTADO) = amarillo. El pad va antes; el salto de linea, despues.
        if ($Message -match '\[ERR\]') { $bg = [System.ConsoleColor]::Red; $fg = [System.ConsoleColor]::White }
        else                           { $bg = [System.ConsoleColor]::Yellow; $fg = [System.ConsoleColor]::Black }
        if ($pad) { Write-Host $pad -NoNewline }
        Write-CvBadge -Text $inner -Fg $fg -Bg $bg
        Write-Host ''
    }
    else {
        Write-Host (('{0}[{1}] ' -f $pad, $Tag) + $Message)
    }
}

function Start-CvStep {
    <#
        Inicia una linea de "paso" del worker. En uso normal imprime " - <msg>" SIN salto
        (se cierra con Stop-CvStep, que anade OK/ERROR en la misma linea). En modo debug
        imprime el log detallado normal ("[TAG] <msg>") para no romper el volcado de comandos.
    #>
    param($Context, [string]$Tag, [string]$Message)
    if ($Context.Debug) { Write-CvLog $Tag $Message }
    else { Write-Host (" - {0}" -f $Message) -NoNewline }
}

function Stop-CvStep {
    <# Cierra el paso iniciado con Start-CvStep. Normal: " [extra] OK|ERROR" en la misma linea.
       Debug: escribe OkMsg (si OK) o FailMsg (si falla) como log normal. #>
    param($Context, [string]$Tag, [bool]$Ok = $true, [string]$Extra = '', [string]$OkMsg = '', [string]$FailMsg = '')
    if ($Context.Debug) {
        if ($Ok) { if (-not [string]::IsNullOrEmpty($OkMsg)) { Write-CvLog $Tag $OkMsg } }
        else     { if (-not [string]::IsNullOrEmpty($FailMsg)) { Write-CvLog $Tag $FailMsg } }
    } else {
        if ($Extra) { Write-Host (" {0}" -f $Extra) -NoNewline }
        if ($Ok) { Write-Host (' {0}' -f (Get-CvMark $true)) -ForegroundColor Green } else { Write-Host (' {0}' -f (Get-CvMark $false)) -ForegroundColor Red }
    }
}

function Write-CvInfoStep {
    <# Linea de paso informativa (sin OK/ERROR). Normal: " - <msg>". Debug: "[TAG] <msg>". #>
    param($Context, [string]$Tag, [string]$Message)
    if ($Context.Debug) { Write-CvLog $Tag $Message }
    else { Write-Host (" - {0}" -f $Message) }
}

function Save-CvToolError {
    <#
        Guarda en logs\ la salida de error de una herramienta cuando falla, para poder diagnosticarla
        despues (util en modo progreso, donde ffmpeg corre oculto sin ventana). Escribe un fichero
        'error_<tool>_<nombre>_<fecha>_<pid>.log' con DOS secciones: (1) los AJUSTES DEL JOB (perfil +
        decisiones de video/audio/subtitulos, para reproducir el caso) y (2) el ERROR completo (stderr).
        Devuelve la ruta, o '' si no habia error que guardar o no se pudo escribir. Se guarda siempre que
        haya fallo (diagnostico puntual), independientemente de behavior.log.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Name = '', [string]$Tool = 'ffmpeg', [string]$StdErr = '', $Job = $null)
    if ([string]::IsNullOrWhiteSpace($StdErr)) { return '' }
    try {
        $dir = $Context.Logs
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = ($Name -replace '[^\w\.\-]', '_'); if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
        $file = Join-Path $dir ("error_{0}_{1}_{2}_{3}.log" -f $Tool, $safe, (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
        $jobTxt = if ($null -ne $Job) {
            try { $Job | ConvertTo-Json -Depth 12 } catch { "(no se pudo serializar el job: {0})" -f $_.Exception.Message }
        } else { '(no disponible)' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('======== ERROR AL CONVERTIR ========')
        [void]$sb.AppendLine(("Archivo    : {0}" -f $Name))
        [void]$sb.AppendLine(("Herramienta: {0}" -f $Tool))
        [void]$sb.AppendLine(("Fecha      : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('======== AJUSTES DEL JOB ========')
        [void]$sb.AppendLine($jobTxt)
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(("======== ERROR (stderr de {0}) ========" -f $Tool))
        [void]$sb.AppendLine("$StdErr")
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        return $file
    } catch { return '' }
}

function Show-CvToolError {
    <#
        Si hay stderr de ffmpeg capturado (fallo en modo progreso, donde corre oculto), lo guarda en
        logs\ (Save-CvToolError), muestra las ULTIMAS lineas (donde suele estar el error) y la ruta del
        log completo, y limpia el buffer global. Sin nada capturado (p. ej. modo ventana aparte), no
        hace nada. Llamar tras Stop-CvStep en la rama de fallo.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Category = 'WORKER', [string]$Name = '', [string]$Tool = 'ffmpeg', $Job = $null)
    $err = "$($global:CvLastToolError)"
    $global:CvLastToolError = $null
    if ([string]::IsNullOrWhiteSpace($err)) { return }
    # El job para la seccion 'AJUSTES DEL JOB' del log: el explicito o el que el worker adjunta al contexto.
    if ($null -eq $Job -and $Context.PSObject.Properties['CurrentJob']) { $Job = $Context.CurrentJob }
    $tail = @($err -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 8)
    if ($tail.Count -gt 0) {
        Write-CvLog $Category '[ERR] - Ultimas lineas de ffmpeg:'
        foreach ($l in $tail) { Write-Host ('     ' + $l) -ForegroundColor DarkGray }
    }
    $path = Save-CvToolError -Context $Context -Name $Name -Tool $Tool -StdErr $err -Job $Job
    if ($path) { Write-CvLog $Category ("[ERR] - Detalle (ajustes del job + error) guardado en: {0}" -f $path) }
}

function Start-CvLog {
    <#
        Inicia el transcript de la ejecucion en logs\<Prefix>_<fecha>_<PID>.log si el
        contexto tiene Log activo. Devuelve la ruta del log (o '' si no se inicia).
        Cada ventana/worker genera su propio fichero (el PID lo hace unico).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Prefix)
    if (-not $Context.Log) { return '' }
    $path = Join-Path $Context.Logs ("{0}_{1}_{2}.log" -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)
    try { Start-Transcript -LiteralPath $path -Append -ErrorAction Stop | Out-Null; return $path }
    catch { return '' }
}

function Stop-CvLog {
    <# Detiene el transcript si hay uno activo (seguro de llamar aunque no haya). #>
    try { Stop-Transcript | Out-Null } catch {}
}

function Get-CvLogFiles {
    <#
        Ficheros de log (*.log) de la carpeta logs\, excluyendo opcionalmente ExceptPath
        (por ejemplo el log de la sesion actual, que esta en uso).
    #>
    param([Parameter(Mandatory)]$Context, [string]$ExceptPath = '')
    $dir = $Context.Logs
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne "$ExceptPath" })
}

function Remove-CvLogFiles {
    <# Borra los ficheros de log indicados. Devuelve cuantos habia. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Files)
    $Files | Remove-Item -Force -ErrorAction SilentlyContinue
    return @($Files).Count
}

Export-ModuleMember -Function *
