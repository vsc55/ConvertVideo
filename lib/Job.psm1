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
    $jobs  = @(
        '*.job.json'
        '*.job.json.tmp'
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
        '*.job.json.tmp'
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
    )
    foreach ($p in $tmpFiles) {
        if (Test-Path -LiteralPath $p) { Remove-Item -Force -LiteralPath $p -ErrorAction SilentlyContinue }
    }
    # Temporales POR-PISTA de la multipista (<name>_aN.m4a/.mka/_aN_concat.wav). Regex ESTRICTA (solo
    # digitos tras '_a') para no tocar temporales de otro archivo con prefijo parecido ("Peli" vs
    # "Peli 2" o "Peli_a"). Enumeracion .NET con nombre exacto (los corchetes del nombre no son globs).
    $rx = [regex]("^" + [regex]::Escape($Name) + "_a\d+(_concat\.wav|\.m4a|\.mka)$")
    if (Test-Path -LiteralPath $Context.Proceso) {
        foreach ($f in [System.IO.Directory]::GetFiles($Context.Proceso)) {
            if ($rx.IsMatch([System.IO.Path]::GetFileName($f))) { try { [System.IO.File]::Delete($f) } catch {} }
        }
    }
}


function Test-CvLockStale {
    <#
        Un lock esta caducado si su worker dueño ya no existe. En el lock se guarda
        "PID=<pid>;HOST=<equipo>". Solo se considera caducado si es de ESTE equipo y el
        proceso con ese PID ya no corre (en otra maquina no se puede verificar -> no se roba).
    #>
    param([string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    try { $txt = [System.IO.File]::ReadAllText($LockPath) } catch { return $false }
    $m = [regex]::Match("$txt", 'PID=(\d+);HOST=(.+)')
    if (-not $m.Success) { return $false }
    if ($m.Groups[2].Value.Trim() -ne $env:COMPUTERNAME) { return $false }
    $lockPid = [int]$m.Groups[1].Value
    return (-not (Test-CvProcessAlive -ProcessId $lockPid))
}

function Enter-Lock {
    <#
        Reclama el archivo creando un fichero-lock con modo CreateNew (atomico: falla si ya
        existe). Guarda PID+equipo para poder detectar y robar locks caducados (worker
        muerto). Ruta literal (los nombres pueden llevar corchetes). Devuelve $true si lo consigue.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $lock = Join-Path $Context.Proceso ("{0}.lock" -f $Name)
    # Si hay un lock de un worker que ya no existe, robarlo.
    if (Test-CvLockStale $lock) {
        try { [System.IO.File]::Delete($lock) } catch {}
    }
    try {
        $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(("PID={0};HOST={1}" -f $PID, $env:COMPUTERNAME))
            $fs.Write($bytes, 0, $bytes.Length)
        } finally { $fs.Close() }
        return $true
    } catch {
        return $false
    }
}


function Exit-Lock {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $lock = Join-Path $Context.Proceso ("{0}.lock" -f $Name)
    try { [System.IO.File]::Delete($lock) } catch {}
}


function Get-OutputPath {
    param($Context, [string]$Name)
    Join-Path $Context.Convertido ("{0}_fix.{1}" -f $Name, $Context.OutExt)
}


Export-ModuleMember -Function *
