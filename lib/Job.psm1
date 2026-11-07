<#
    Job.psm1 - Cola de trabajo: jobs JSON (*-CvJob), lock atomico (Enter/Exit-Lock),
    ficheros temporales (Get-CvTempPaths/Remove-CvTemps) y ruta de salida (Get-OutputPath).
#>

function Get-CvJobPath { param($Context,[string]$Name) Join-Path $Context.Proceso ("{0}.job.json" -f $Name) }


function Test-CvJob    { param($Context,[string]$Name) Test-Path -LiteralPath (Get-CvJobPath $Context $Name) }


function Write-CvJob {
    <# Guarda el job de forma ATOMICA (.tmp + renombrado, UTF-8 sin BOM): ver Save-CvJsonFile. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Job)
    [void](Save-CvJsonFile -Path (Get-CvJobPath $Context $Name) -Object $Job -Depth 8)
}


function Read-CvJob {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    Read-CvJsonFile -Path (Get-CvJobPath $Context $Name)
}


function Remove-CvJob {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $f = Get-CvJobPath $Context $Name
    if (Test-Path -LiteralPath $f) { Remove-Item -Force -LiteralPath $f -ErrorAction SilentlyContinue }
}

function Get-CvJobAudioTracks {
    <#
        Lista NORMALIZADA de pistas de audio de un job, con compatibilidad hacia atras:
        - Formato nuevo (multipista): job.audio.tracks = [ {index,is51,sync,lang,default} ].
        - Formato antiguo (monopista): job.audio.index/is51/sync/lang -> lista de 1 (default=$true).
        Devuelve @() si no hay pistas. Cada elemento: {Index,Is51,Sync,Lang,Default}. La DEFAULT
        va primero (asi se congelo en PREPARAR); si ninguna lo es, se marca la primera.
    #>
    param($Audio)
    if ($null -eq $Audio) { return @() }
    $out = @()
    if ($Audio.PSObject.Properties['tracks'] -and $null -ne $Audio.tracks) {
        foreach ($t in @($Audio.tracks)) {
            $out += [pscustomobject]@{
                Index   = [int]$t.index
                Is51    = [bool]$t.is51
                Sync    = [double]$t.sync
                Lang    = $(if ($t.lang) { "$($t.lang)" } else { 'und' })
                Default = [bool]$t.default
            }
        }
    }
    elseif ($Audio.PSObject.Properties['index'] -and $null -ne $Audio.index) {
        # Job antiguo monopista.
        $out += [pscustomobject]@{
            Index   = [int]$Audio.index
            Is51    = [bool]$Audio.is51
            Sync    = [double]$Audio.sync
            Lang    = $(if ($Audio.lang) { "$($Audio.lang)" } else { 'und' })
            Default = $true
        }
    }
    $out = @($out)
    if ($out.Count -gt 0 -and -not ($out | Where-Object { $_.Default })) { $out[0].Default = $true }
    return $out
}


function Get-CvTempPaths {
    <#
        UNICA FUENTE de los nombres de los ficheros temporales de un archivo en Proceso.
        La usan los que los crean (Video/Audio/Multiplex) y el que los limpia (Remove-CvTemps).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    [pscustomobject]@{
        Video    = Join-Path $Context.Proceso ("{0}.mkv" -f $Name)           # video recodificado temporal
        Audio    = Join-Path $Context.Proceso ("{0}.m4a" -f $Name)           # audio recodificado temporal (AAC)
        AudioMka = Join-Path $Context.Proceso ("{0}.mka" -f $Name)           # audio recodificado temporal (no-AAC: ac3/eac3/mp3/flac/opus)
        SyncWav  = Join-Path $Context.Proceso ("{0}_concat.wav" -f $Name)    # wav de sincronizacion (silencio + audio)
        JobTmp   = Join-Path $Context.Proceso ("{0}.job.json.tmp" -f $Name)  # job a medio escribir (si quedo colgado)
    }
}


function Get-CvAudioTempPath {
    <#
        Rutas del temporal de audio de la pista en POSICION $Pos (0-based) de un archivo: <name>_aN.m4a
        (AAC) / <name>_aN.mka (resto de codecs) y su WAV de sincronia <name>_aN_concat.wav. FUENTE UNICA
        de los nombres por-pista de la multipista de audio (los usa Invoke-AudioRun y los limpia
        Remove-CvTemps). El sufijo _aN permite varias pistas sin pisarse (pos 0 = predeterminada).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [int]$Pos = 0)
    [pscustomobject]@{
        M4a     = Join-Path $Context.Proceso ("{0}_a{1}.m4a" -f $Name, $Pos)
        Mka     = Join-Path $Context.Proceso ("{0}_a{1}.mka" -f $Name, $Pos)
        SyncWav = Join-Path $Context.Proceso ("{0}_a{1}_concat.wav" -f $Name, $Pos)
    }
}


function Get-CvProcesoPatterns {
    <#
        Patrones GLOB de los ficheros que el pipeline deja en Proceso\, por categoria. FUENTE UNICA de
        esas convenciones (derivadas de Get-CvJobPath = *.job.json, Get-CvTempPaths = *.mkv/*.m4a/*.mka/
        *_concat.wav/*.job.json.tmp, y el *.lock de Enter/Exit-Lock). La consume setup.ps1 para limpiar
        la carpeta sin re-teclear las extensiones: si aqui cambia una convencion, la limpieza sigue
        sincronizada. -What: jobs | locks | temps | all.
    #>
    param([ValidateSet('jobs','locks','temps','all')][string]$What = 'all')
    # Los temporales de la escritura atomica: '<fichero>.<pid>.tmp' (Save-CvTextFile) y el de antes,
    # '<fichero>.tmp'. '*.json*.tmp' casa con los dos (job y estado de worker).
    $jobs  = @(
        '*.job.json'
        '*.job.json*.tmp'
    )
    # 'locks' = ficheros de CONTROL de los workers: el reclamo de cada archivo (*.lock), el estado que
    # cada worker publica para la ventana de la cola (<pid>.worker.json, WorkerCore) y la bandera de
    # parada ordenada (stop.flag). Ninguno es dato: si sobra alguno de un worker muerto, se borra.
    $locks = @(
        '*.lock'
        '*.worker.json'
        'stop.flag'
    )
    $temps = @(
        '*.mkv'
        '*.m4a'
        '*.mka'
        '*_concat.wav'
        '*.json*.tmp'
    )
    switch ($What) {
        'jobs'  { $jobs }
        'locks' { $locks }
        'temps' { $temps }
        default { @($jobs + $locks + $temps | Select-Object -Unique) }
    }
}


function Remove-CvTemps {
    <#
        Borra los ficheros temporales de un archivo en Proceso.
        Usa rutas EXACTAS (no comodines) para no tocar temporales de otro archivo
        cuyo nombre empiece igual (ej "Peli" vs "Peli 2").
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $tmp = Get-CvTempPaths -Context $Context -Name $Name
    $tmpFiles = @(
        $tmp.Video
        $tmp.Audio
        $tmp.AudioMka
        $tmp.SyncWav
        $tmp.JobTmp
        # La salida a medio escribir (Convertido\<name>_fix.mkv.part) de un intento que fallo o de un
        # worker muerto: no vale para nada y eran varios GB que nadie borraba. Quien llama tiene el lock.
        (Get-CvPartialPath (Get-OutputPath $Context $Name))
    )
    foreach ($p in $tmpFiles) {
        if (Test-Path -LiteralPath $p) { Remove-Item -Force -LiteralPath $p -ErrorAction SilentlyContinue }
    }
    # Temporales POR-PISTA de la multipista (<name>_aN.m4a/.mka/_aN_concat.wav). Regex ESTRICTA (solo
    # digitos tras '_a') para no tocar temporales de otro archivo con prefijo parecido ("Peli" vs
    # "Peli 2" o "Peli_a"). Enumeracion .NET con nombre exacto (los corchetes del nombre no son globs).
    $rx = [regex]("^" + [regex]::Escape($Name) + "(_a\d+(_concat\.wav|\.m4a|\.mka)|\.job\.json\.\d+\.tmp)$")
    if (Test-Path -LiteralPath $Context.Proceso) {
        foreach ($f in [System.IO.Directory]::GetFiles($Context.Proceso)) {
            if ($rx.IsMatch([System.IO.Path]::GetFileName($f))) { try { [System.IO.File]::Delete($f) } catch {} }
        }
    }
}


# Bloqueos que tiene ESTE proceso, con su fichero ABIERTO (ver Enter-Lock).
$script:CvLockHandles = @{}

function Test-CvLockStale {
    <#
        Un lock esta caducado si su worker dueno ya no existe. En el lock se guarda
        "PID=<pid>;HOST=<equipo>". Solo se considera caducado si es de ESTE equipo y el
        proceso con ese PID ya no corre (en otra maquina no se puede verificar -> no se roba).

        Tambien cuenta como caducado si ese PID existe pero NO es un PowerShell: Windows reutiliza
        los PID, y un worker muerto cuyo numero le ha tocado a otro programa dejaba su archivo
        bloqueado para siempre. Robarlo por error no es peligroso: el dueno de verdad tiene el
        fichero ABIERTO y Windows no deja borrarlo (ver Enter-Lock).

        Se lee compartido (Read-CvTextFileShared): leerlo con ReadAllText impedia al worker borrar su
        lock en ese mismo instante.

        Lo que DECIDE ya no es el PID sino si alguien tiene el fichero ABIERTO (Test-CvLockHeld): el
        dueno vivo lo tiene abierto sin dejar escribir a nadie. Mirando el PID, uno muerto cuyo numero
        le tocaba a OTRO PowerShell (la cola, otro worker, una consola) contaba como vivo y el archivo
        se quedaba bloqueado para siempre; igual con un lock vacio (el worker murio al crearlo) o uno
        que no se pudo borrar al soltarlo.

        -Processes se acepta por compatibilidad; ya no hace falta (abrir el fichero es lo barato).
    #>
    param([string]$LockPath, $Processes = $null)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    # De OTRO equipo (carpeta compartida) no se roba: ni su PID ni sus ficheros abiertos son de aqui.
    try { $txt = Read-CvTextFileShared -Path $LockPath } catch { $txt = '' }
    $m = [regex]::Match("$txt", 'PID=(\d+);HOST=(.+)')
    if ($m.Success -and $m.Groups[2].Value.Trim() -ne $env:COMPUTERNAME) { return $false }
    if ($script:CvLockHandles.ContainsKey($LockPath)) { return $false }   # es nuestro y lo tenemos
    $held = Test-CvLockHeld -LockPath $LockPath
    if ($null -ne $held) { return (-not $held) }
    # No se pudo saber (permisos): como antes, por el PID.
    if (-not $m.Success) { return $false }
    $lockPid = [int]$m.Groups[1].Value
    if (-not (Test-CvProcessAlive -ProcessId $lockPid)) { return $true }
    try {
        $p = Get-Process -Id $lockPid -ErrorAction Stop
        return (@('powershell', 'pwsh') -notcontains "$($p.ProcessName)".ToLower())
    } catch { return $true }
}

function Test-CvLockHeld {
    <#
        $true si el lock esta ABIERTO por su dueno (Enter-Lock lo deja abierto sin compartir la
        escritura), $false si nadie lo tiene, $null si no se puede saber. Se prueba a abrirlo para
        escribir compartiendo todo: un lector de paso (la cola, Read-CvTextFileShared) no lo estorba.
    #>
    param([Parameter(Mandatory)][string]$LockPath)
    try {
        $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $fs.Dispose()
        return $false
    } catch [System.IO.FileNotFoundException] {
        return $false
    } catch [System.IO.IOException] {
        return $true    # violacion de uso compartido: alguien lo tiene abierto
    } catch {
        return $null
    }
}

function Get-CvProcessNames {
    <#
        Los procesos de este equipo AHORA, como tabla PID -> nombre, en una sola consulta. Para mirar
        muchos locks de golpe (Test-CvLockStale -Processes) sin un Get-Process por cada uno.
    #>
    $t = @{}
    try { foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $t[[int]$p.Id] = "$($p.ProcessName)" } } catch { }
    return $t
}

function Enter-Lock {
    <#
        Reclama el archivo creando un fichero-lock con modo CreateNew (atomico: falla si ya
        existe). Guarda PID+equipo para poder detectar y robar locks caducados (worker
        muerto). Ruta literal (los nombres pueden llevar corchetes). Devuelve $true si lo consigue.

        El fichero se queda ABIERTO mientras dura el trabajo (hasta Exit-Lock, o hasta que el proceso
        muere y Windows lo cierra), y abierto SIN permiso de borrado para los demas. Asi robar un lock
        es seguro aunque dos workers lo intenten a la vez: antes, 'esta caducado -> borrar -> crear'
        dejaba que el segundo borrase el lock RECIEN creado por el primero, y los dos codificaban el
        mismo archivo. Ahora el borrado de un lock con dueno vivo FALLA, lo diga quien lo diga.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $lock = Join-Path $Context.Proceso ("{0}.lock" -f $Name)
    # Si hay un lock de un worker que ya no existe, robarlo (si su dueno vive, el borrado falla).
    if (Test-CvLockStale $lock) {
        try { [System.IO.File]::Delete($lock) } catch {}
    }
    try {
        # Lectura compartida (la cola lo lee para saber quien lo tiene); borrado, no.
        $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    } catch {
        return $false
    }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(("PID={0};HOST={1}" -f $PID, $env:COMPUTERNAME))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } catch {
        try { $fs.Dispose() } catch {}
        try { [System.IO.File]::Delete($lock) } catch {}
        return $false
    }
    $script:CvLockHandles[$lock] = $fs
    return $true
}

function Exit-Lock {
    <#
        Suelta el lock que tiene ESTE proceso (lo cierra y lo borra). Uno que no es suyo no se toca:
        antes se borraba sin mirar, y un worker que acababa podia soltar el archivo que tenia OTRO.
        Para quitar el de un worker muerto esta Remove-CvStaleLock.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $lock = Join-Path $Context.Proceso ("{0}.lock" -f $Name)
    $fs = $script:CvLockHandles[$lock]
    if ($null -eq $fs) { return }
    $script:CvLockHandles.Remove($lock)
    try { $fs.Dispose() } catch {}
    # Un lector (la cola) puede tenerlo abierto un instante: unos reintentos cortos.
    for ($i = 1; $i -le 4; $i++) {
        try { [System.IO.File]::Delete($lock); return } catch { Start-Sleep -Milliseconds (15 * $i) }
    }
}

function Remove-CvStaleLock {
    <#
        Quita el lock de un archivo si esta CADUCADO (su worker ya no existe). Es lo que hace
        'Liberar bloqueo' en la cola. Con el dueno vivo no hace nada (y aunque se intentara, Windows no
        dejaria: lo tiene abierto). Devuelve $true si lo quito.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $lock = Join-Path $Context.Proceso ("{0}.lock" -f $Name)
    if (-not (Test-CvLockStale $lock)) { return $false }
    try { [System.IO.File]::Delete($lock); return $true } catch { return $false }
}


function Get-OutputPath {
    param($Context, [string]$Name)
    Join-Path $Context.Convertido ("{0}_fix.{1}" -f $Name, $Context.OutExt)
}

function Get-CvPartialPath {
    <#
        Donde se ESCRIBE una salida mientras no esta terminada: <salida>.part, en la MISMA carpeta.

        La salida con su nombre final tiene que existir SOLO cuando esta completa, porque el worker
        da por hecho un archivo en cuanto ve su _fix.mkv (y no vuelve a mirarlo). Escribiendo
        directamente con el nombre final, una codificacion cortada -el boton Cortar de la cola mata
        el worker, o se cierra la consola, o se va la luz- dejaba un fichero a medias que parecia
        terminado y bloqueaba el reintento. Con la una-pasada activada de serie, ese fichero se
        escribe durante TODA la codificacion, no solo durante el multiplexado.

        En la misma carpeta y no en Proceso\: renombrar dentro de un disco es instantaneo, pero
        Proceso\ y Convertido\ pueden estar en discos distintos (paths.*), y entonces 'mover' seria
        COPIAR el fichero entero con su nombre final, que es justo el problema. A ffmpeg la extension
        le da igual (los emisores fuerzan -f matroska) y a mkvpropedit tambien (comprobado).
    #>
    param([Parameter(Mandatory)][string]$Path)
    return ($Path + '.part')
}


Export-ModuleMember -Function *
