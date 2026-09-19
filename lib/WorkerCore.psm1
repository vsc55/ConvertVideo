<#
    WorkerCore.psm1 - DATOS de la COLA de conversion (sin interfaz).

    Misma idea que SetupCore.psm1: aqui vive "que hay y que esta pasando", en OBJETOS, y cada
    interfaz decide como pintarlo (la consola con sus lineas, la ventana Convert-gui con su lista).
    Aqui NO se escribe en pantalla ni se pregunta nada.

    Dos mitades:

      LECTURA  - Get-CvQueueStatus cruza lo que YA esta en disco para saber el estado de cada
                 archivo: el job (Proceso\<n>.job.json), el bloqueo (<n>.lock, que guarda el PID del
                 worker) y la salida (Convertido\<n>_fix.<ext>). No hace falta ffprobe ni hablar con
                 los workers: el estado de la cola es el propio sistema de ficheros.

      ESCRITURA- Lo unico que NO esta en disco es el avance DENTRO de un archivo (%, ETA, paso), asi
                 que cada worker lo publica en Proceso\<pid>.worker.json (Start/Set/Update/Remove-
                 CvWorkerState). Es un fichero pequeno que se reescribe de forma atomica y best-
                 effort: si falla, el worker sigue codificando como si nada.

    Ademas la parada ordenada: Set-CvWorkerStop deja una bandera en Proceso\ que los workers miran
    ENTRE archivos (nunca a mitad de una codificacion), asi que parar no deja temporales a medias.
#>

# Estado publicado por ESTE proceso (solo lo usa el worker que escribe, no el que lee).
$script:CvWorkerState = $null

function Get-CvWorkerStatePath {
    <# Fichero donde un worker publica su estado: Proceso\<pid>.worker.json. #>
    param([Parameter(Mandatory)]$Context, [int]$ProcessId = $PID)
    Join-Path $Context.Proceso ("{0}.worker.json" -f $ProcessId)
}

function Get-CvWorkerStopPath {
    <# Bandera de parada ordenada (la crea la UI, la miran los workers entre archivos). #>
    param([Parameter(Mandatory)]$Context)
    Join-Path $Context.Proceso 'stop.flag'
}

function Save-CvWorkerState {
    <#
        Vuelca el estado en curso a su fichero (.tmp + renombrado, como Write-CvJob). BEST-EFFORT: si
        la carpeta no existe o el disco falla NO se lanza nada, porque esto es telemetria para la
        ventana y jamas debe tumbar una conversion.
    #>
    param([Parameter(Mandatory)]$Context)
    if ($null -eq $script:CvWorkerState) { return }
    try {
        $script:CvWorkerState.updated = (Get-Date).ToString('o')
        [void](Save-CvJsonFile -Path (Get-CvWorkerStatePath -Context $Context) `
            -Object ([pscustomobject]$script:CvWorkerState) -Depth 4 -Quiet)
    } catch {}
}

function Start-CvWorkerState {
    <#
        Empieza a publicar el estado de este proceso (al arrancar Convert.ps1). -Role distingue la
        ventana de PREPARAR de un worker que codifica; -LogPath deja apuntado su propio transcript
        para que la UI pueda ensenar EL log de ese worker sin adivinarlo por el nombre.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Role = 'worker',
        [string]$LogPath = ''
    )
    $script:CvWorkerState = [ordered]@{
        pid      = $PID
        host     = $env:COMPUTERNAME
        role     = $Role
        log      = "$LogPath"
        status   = 'idle'
        file     = ''
        step     = ''
        percent  = -1
        eta      = ''
        speed    = ''
        reason   = ''
        started  = (Get-Date).ToString('o')
        updated  = ''
    }
    Save-CvWorkerState -Context $Context
}

function Set-CvWorkerFile {
    <# El worker ha reclamado un archivo: pasa a 'working' y se reinicia el progreso. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File)
    if ($null -eq $script:CvWorkerState) { return }
    $script:CvWorkerState.status  = 'working'
    $script:CvWorkerState.file    = $File
    $script:CvWorkerState.step    = ''
    $script:CvWorkerState.percent = -1
    $script:CvWorkerState.eta     = ''
    $script:CvWorkerState.speed   = ''
    $script:CvWorkerState.reason  = ''
    Save-CvWorkerState -Context $Context
}

function Update-CvWorkerProgress {
    <#
        Avance dentro del archivo en curso. La llama Invoke-ToolProgress (Exec.psm1) con los MISMOS
        numeros que pinta en la consola, asi que la ventana ve exactamente lo que se ve ahi.

        Si este proceso no esta publicando estado (una ejecucion normal en consola sin -WorkerOnly,
        o los tests) no hace nada: por eso no hay ningun 'if' en el llamador.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Step = '',
        [int]$Percent = -1,
        [string]$Eta = '',
        [string]$Speed = ''
    )
    if ($null -eq $script:CvWorkerState) { return }
    $script:CvWorkerState.status  = 'working'
    $script:CvWorkerState.step    = $Step
    $script:CvWorkerState.percent = $Percent
    $script:CvWorkerState.eta     = $Eta
    $script:CvWorkerState.speed   = $Speed
    Save-CvWorkerState -Context $Context
}

function Complete-CvWorkerFile {
    <# Fin del archivo en curso: 'ok' o 'error' (con motivo) y a la espera del siguiente. #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Status = 'ok',
        [string]$Reason = ''
    )
    if ($null -eq $script:CvWorkerState) { return }
    $script:CvWorkerState.status  = $Status
    $script:CvWorkerState.step    = ''
    $script:CvWorkerState.percent = -1
    $script:CvWorkerState.eta     = ''
    $script:CvWorkerState.speed   = ''
    $script:CvWorkerState.reason  = $Reason
    Save-CvWorkerState -Context $Context
}

function Remove-CvWorkerState {
    <# Deja de publicar y borra el fichero (al terminar el worker). Best-effort. #>
    param([Parameter(Mandatory)]$Context)
    $p = Get-CvWorkerStatePath -Context $Context
    $script:CvWorkerState = $null
    try { if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) } } catch {}
}

function Get-CvLiveProcessIds {
    <#
        Los PID que existen AHORA en este equipo, en una sola consulta. Preguntar uno a uno con
        'Get-Process -Id' cuesta ~40 ms cada vez: con diez ficheros de estado en Proceso\ eran 400 ms
        por refresco -y la ventana refresca cada segundo-. Devuelve un HashSet para mirar en O(1);
        vacio si algo falla (entonces se da por vivo, que es lo prudente).
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { [void]$set.Add([int]$p.Id) }
    } catch { }
    return $set
}

function Get-CvWorkerStates {
    <#
        Workers que estan publicando estado en Proceso\. 'Alive' = el proceso sigue vivo EN ESTE
        equipo (misma regla que Test-CvLockStale: en otra maquina no se puede comprobar, asi que se
        da por vivo). Un fichero de un worker muerto queda huerfano: se devuelve con Alive=$false
        para que la UI lo ensene y ofrezca limpiarlo.

        Se llama en CADA refresco de la cola, asi que esta escrita para ser barata: la lista de
        procesos se pide UNA vez (no un Get-Process por fichero) y el .json solo se re-parsea si ha
        cambiado de fecha o tamano.
    #>
    param([Parameter(Mandatory)]$Context)
    $dir = $Context.Proceso
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $vivos = Get-CvLiveProcessIds
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.worker.json' -File -ErrorAction SilentlyContinue)) {
        $stamp = "{0}|{1}" -f $f.LastWriteTimeUtc.Ticks, $f.Length
        $hit   = $script:CvWorkerPeek[$f.FullName]
        if ($null -ne $hit -and "$($hit.Stamp)" -eq $stamp) {
            $s = $hit.Data
        } else {
            $s = Read-CvJsonFile -Path $f.FullName -Quiet
            if ($null -eq $s) { continue }   # a medio escribir o tocado a mano: ese worker se ignora
            $script:CvWorkerPeek[$f.FullName] = @{ Stamp = $stamp; Data = $s }
        }
        $wpid  = [int]$s.pid
        $mine  = ("$($s.host)" -eq $env:COMPUTERNAME)
        $alive = if ($mine) { ($vivos.Count -eq 0) -or $vivos.Contains($wpid) } else { $true }
        $out += [pscustomobject]@{
            Pid     = $wpid
            Host    = "$($s.host)"
            Role    = "$($s.role)"
            Log     = "$($s.log)"
            Status  = "$($s.status)"
            File    = "$($s.file)"
            Step    = "$($s.step)"
            Percent = [int]$s.percent
            Eta     = "$($s.eta)"
            Speed   = "$($s.speed)"
            Reason  = "$($s.reason)"
            Updated = $f.LastWriteTime
            Alive   = $alive
            Path    = $f.FullName
        }
    }
    return @($out | Sort-Object Pid)
}

function Remove-CvWorkerStates {
    <# Borra los ficheros de estado indicados (los huerfanos de workers muertos). Devuelve cuantos. #>
    param($States)
    $s = @($States)
    if ($s.Count -eq 0) { return 0 }
    foreach ($w in $s) { try { [System.IO.File]::Delete($w.Path) } catch {} }
    return $s.Count
}

function Set-CvWorkerStop {
    <#
        Pide a los workers que paren ORDENADAMENTE: dejan el archivo que tengan a medias terminado y
        no reclaman ninguno mas. Matarlos a mitad dejaria temporales y un bloqueo por limpiar, asi
        que esta es la parada por defecto de la UI.
    #>
    param([Parameter(Mandatory)]$Context)
    $p = Get-CvWorkerStopPath -Context $Context
    try {
        [void](Save-CvTextFile -Path $p -Text ((Get-Date).ToString('o')))
        return $true
    } catch { return $false }
}

function Clear-CvWorkerStop {
    <# Quita la bandera de parada (al volver a arrancar). #>
    param([Parameter(Mandatory)]$Context)
    $p = Get-CvWorkerStopPath -Context $Context
    try { if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) } } catch {}
}

function Test-CvWorkerStop {
    <# $true si hay parada pedida. Lo miran los workers ENTRE archivos, nunca a mitad de uno. #>
    param([Parameter(Mandatory)]$Context)
    return (Test-Path -LiteralPath (Get-CvWorkerStopPath -Context $Context))
}

function Get-CvQueueStates {
    <#
        Catalogo de estados de un archivo en la cola (@{Value;Text}, como el resto de catalogos del
        repo): fuente unica del texto que ensenan consola y ventana.
    #>
    @(
        @{
            Value = 'pending'
            Text  = 'Sin preparar'
        }
        @{
            Value = 'queued'
            Text  = 'En cola'
        }
        @{
            Value = 'working'
            Text  = 'Codificando'
        }
        @{
            Value = 'stale'
            Text  = 'Bloqueo huerfano'
        }
        @{
            Value = 'partial'
            Text  = 'Sin terminar'
        }
        @{
            Value = 'done'
            Text  = 'Hecho'
        }
    )
}

function Resolve-CvQueueState {
    <#
        PURO. Estado de un archivo a partir de los hechos que hay en disco. El ORDEN importa, y no es
        el obvio: quien lo esta TRABAJANDO manda sobre que exista la salida.

          - -Claimed = un worker VIVO dice estar codificandolo ahora mismo (su fichero de estado).
            Va primero: entre reclamar el archivo y verse su .lock hay un instante, y ensenar 'en
            cola' un archivo que va por el 42% seria mentira.
          - Bloqueo de un worker vivo: tambien antes que la salida. El fichero de salida EXISTE
            mientras se esta escribiendo (la ruta de una sola pasada escribe directamente en
            Convertido\), asi que mirar la salida primero marcaba 'Hecho' a los pocos segundos de
            empezar, con el worker todavia codificando.
          - Salida escrita PERO el job sigue ahi y nadie trabaja: la conversion NO termino (el worker
            borra el job solo cuando acaba bien, ver Remove-CvJob en Convert.ps1), asi que lo que hay
            en Convertido\ es un fichero A MEDIAS: 'partial'. Importa porque el worker SALTA los
            archivos que ya tienen salida, asi que ese resto bloquea el reintento hasta que se borra.
          - Con la salida ya escrita, sin job y nadie trabajando: 'done'.
          - Bloqueo CADUCADO (Test-CvLockStale, su worker ya no existe) y sin salida: nadie lo esta
            tocando y hay que liberarlo para que otro worker lo coja.
          - Sin bloqueo: 'queued' si tiene job (listo para codificar) o 'pending' si aun no se ha
            preparado (a eso hay que contestar las preguntas de PREPARAR).
    #>
    param(
        [bool]$Done = $false,
        [bool]$Locked = $false,
        [bool]$Stale = $false,
        [bool]$HasJob = $false,
        [bool]$Claimed = $false
    )
    if ($Claimed)                 { return 'working' }
    if ($Locked -and -not $Stale) { return 'working' }
    if ($Done -and $HasJob)       { return 'partial' }
    if ($Done)                    { return 'done' }
    if ($Locked)                  { return 'stale' }
    if ($HasJob)                  { return 'queued' }
    return 'pending'
}

function Get-CvQueueStateText {
    <# PURO. Texto de un estado (catalogo Get-CvQueueStates); la clave tal cual si no esta. #>
    param([string]$State)
    $s = Get-CvQueueStates | Where-Object { $_.Value -eq "$State" } | Select-Object -First 1
    if ($s) { return "$($s.Text)" }
    return "$State"
}

$script:CvJobPeek    = @{}
$script:CvWorkerPeek = @{}

function Get-CvJobPeek {
    <#
        Lo que la COLA necesita saber del job de un archivo -si lleva recorte y que pasa con el
        audio- SIN releer el fichero en cada refresco: se cachea por fecha+tamano, igual que el panel
        del log. La lista se repinta cada segundo y hay un job por archivo; parsear 30 JSON por
        segundo para nada seria justo lo que este modulo evita.

        Devuelve @{ Crop; Detect; Tracks; AudioSkip } o $null si no hay job (o no se puede leer: un
        job a medio escribir no puede tumbar la ventana).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        # FileInfo del .job.json si quien llama ya ha listado la carpeta: se ahorra un stat por fila.
        $Info = $null
    )
    $p = Get-CvJobPath $Context $Name
    $fi = $Info
    if ($null -eq $fi) {
        try { $fi = Get-Item -LiteralPath $p -ErrorAction Stop } catch { return $null }
    }
    $stamp = "{0}|{1}" -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    $hit = $script:CvJobPeek[$p]
    if ($null -ne $hit -and "$($hit.Stamp)" -eq $stamp) { return $hit.Data }
    $job = Read-CvJsonFile -Path $p -Quiet
    if ($null -eq $job) { return $null }
    $dbv = "$($job.profile.DetectBorder)".ToLower()
    $data = @{
        Crop      = "$($job.video.crop)"
        Detect    = ($dbv -eq 'auto' -or $dbv -eq 'true')
        Tracks    = @(Get-CvJobAudioTracks $job.audio)
        AudioSkip = [bool]$job.audio.skip
    }
    $script:CvJobPeek[$p] = @{ Stamp = $stamp; Data = $data }
    return $data
}

function Get-CvLogSection {
    <#
        PURO. Saca de un log el TROZO que corresponde a un archivo: desde su linea 'CODIFICANDO:
        <nombre>' hasta la del siguiente archivo (o el final). Un worker encadena varios archivos en
        el mismo log, asi que ensenar el log entero para mirar UNO es ruido.

        Si el archivo aparece varias veces (reintentos), se coge la ULTIMA: es la que cuenta como
        quedo la cosa. Devuelve '' si no aparece.
    #>
    param(
        $Lines,
        [Parameter(Mandatory)][string]$Name
    )
    $ls = @($Lines)
    if ($ls.Count -eq 0 -or "$Name" -eq '') { return '' }
    $marca = 'CODIFICANDO:'
    $ini = -1
    for ($i = 0; $i -lt $ls.Count; $i++) {
        $l = "$($ls[$i])"
        if ($l -like ("*{0}*{1}*" -f $marca, $Name)) { $ini = $i }
    }
    if ($ini -lt 0) { return '' }
    $fin = $ls.Count - 1
    for ($i = $ini + 1; $i -lt $ls.Count; $i++) {
        if ("$($ls[$i])" -like ("*{0}*" -f $marca)) { $fin = $i - 1; break }
    }
    return (($ls[$ini..$fin]) -join [Environment]::NewLine)
}

function Find-CvFileLog {
    <#
        Busca en logs\ el trozo de log donde se convirtio UN archivo (el que ya esta hecho, o el que
        se quedo a medias). Se miran los logs de mas nuevo a mas viejo y se para en el primero que lo
        tenga; de cada uno solo se lee la COLA (-MaxKb), que es donde esta lo reciente y evita
        tragarse logs de decenas de MB.

        Devuelve @{ Found; Path; Text }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaxLogs = 20,
        [int]$MaxKb   = 1024
    )
    $r = @{ Found = $false; Path = ''; Text = '' }
    try {
        $logs = @(Get-ChildItem -LiteralPath $Context.Logs -Filter 'Convert_*.log' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First $MaxLogs)
        foreach ($l in $logs) {
            $txt = Get-CvSetupLogText -Path $l.FullName -MaxKb $MaxKb
            if ("$txt" -eq '') { continue }
            $sec = Get-CvLogSection -Lines ($txt -split "`r?`n") -Name $Name
            if ("$sec" -ne '') {
                $r.Found = $true
                $r.Path  = $l.FullName
                $r.Text  = $sec
                break
            }
        }
    } catch { }
    return $r
}

function Get-CvQueueStatus {
    <#
        La COLA entera: una fila por video de Original\, con su estado, el worker que lo esta
        codificando (si lo hay) y el avance que ese worker publica.

        No lanza ffprobe: los tamanos salen del sistema de ficheros y la duracion/ETA de lo que
        publica el worker. Asi la ventana puede refrescar cada segundo sin coste.
    #>
    param([Parameter(Mandatory)]$Context)
    $workers = @(Get-CvWorkerStates -Context $Context | Where-Object { $_.Alive })
    # Las carpetas se listan UNA vez y se decide en memoria. Preguntando fichero a fichero
    # (Test-Path de la salida, del lock, del job...) eran ~90 consultas al disco por refresco y ~0,5 s;
    # los tres listados juntos cuestan menos de 60 ms. Con la ventana refrescando cada segundo -y el
    # disco ocupado codificando- esa diferencia es que la lista responda o no.
    $salidas = @{}
    foreach ($o in @(Get-ChildItem -LiteralPath $Context.Convertido -File -ErrorAction SilentlyContinue)) {
        $salidas[$o.BaseName] = $o
    }
    $proceso = @{}
    foreach ($p in @(Get-ChildItem -LiteralPath $Context.Proceso -File -ErrorAction SilentlyContinue)) {
        $proceso[$p.Name] = $p
    }
    $outExt = "$($Context.OutExt)"
    if ($outExt -and -not $outExt.StartsWith('.')) { $outExt = '.' + $outExt }
    $out = @()
    foreach ($f in @(Get-CvFiles -Dir $Context.Original -Filters $Context.Extensions -Exact)) {
        $name   = $f.BaseName
        $outPath = Get-OutputPath $Context $name
        $oInfo  = $salidas[[System.IO.Path]::GetFileNameWithoutExtension($outPath)]
        $done   = ($null -ne $oInfo)
        $lock   = Join-Path $Context.Proceso ("{0}.lock" -f $name)
        $lInfo  = $proceso[("{0}.lock" -f $name)]
        $locked = ($null -ne $lInfo)
        $stale  = $locked -and (Test-CvLockStale $lock)
        $jInfo  = $proceso[("{0}.job.json" -f $name)]
        $hasJob = ($null -ne $jInfo)
        $w      = $workers | Where-Object { $_.File -eq $name -and $_.Status -eq 'working' } | Select-Object -First 1
        $state  = Resolve-CvQueueState -Done $done -Locked $locked -Stale $stale -HasJob $hasJob -Claimed ($null -ne $w)
        $outKb = 0L
        if ($done) { $outKb = [long]($oInfo.Length / 1024) }
        # 'Hecho' de verdad = hay salida y NO queda job (el worker lo borra al acabar bien).


        # Del job, lo justo para las columnas de un vistazo (cacheado: no se relee si no cambia). Se
        # le pasa el FileInfo del listado para que no vuelva a preguntarle al disco por la fecha.
        $peek = $null
        if ($hasJob) { $peek = Get-CvJobPeek -Context $Context -Name $name -Info $jInfo }

        $out += [pscustomobject]@{
            Name      = $name
            Path      = $f.FullName
            SizeKb    = [long]($f.Length / 1024)
            Crop      = $(if ($null -ne $peek) { "$($peek.Crop)" } else { '' })
            Detect    = $(if ($null -ne $peek) { [bool]$peek.Detect } else { $false })
            AudioTracks = $(if ($null -ne $peek) { @($peek.Tracks) } else { @() })
            AudioSkip = $(if ($null -ne $peek) { [bool]$peek.AudioSkip } else { $false })
            OutPath   = $outPath
            OutSizeKb = $outKb
            HasJob    = $hasJob
            Locked    = $locked
            Stale     = $stale
            Done      = $done
            State     = $state
            StateText = (Get-CvQueueStateText -State $state)
            WorkerPid = $(if ($w) { [int]$w.Pid } else { 0 })
            Step      = $(if ($w) { "$($w.Step)" } else { '' })
            Percent   = $(if ($w) { [int]$w.Percent } elseif ($done) { 100 } else { -1 })
            Eta       = $(if ($w) { "$($w.Eta)" } else { '' })
            Speed     = $(if ($w) { "$($w.Speed)" } else { '' })
        }
    }
    return @($out)
}

function Get-CvQueueTotals {
    <# PURO. Recuento por estado de las filas de Get-CvQueueStatus (para el resumen de la UI). #>
    param($Rows)
    $r = @($Rows)
    [pscustomobject]@{
        Total   = $r.Count
        Pending = @($r | Where-Object { $_.State -eq 'pending' }).Count
        Queued  = @($r | Where-Object { $_.State -eq 'queued'  }).Count
        Working = @($r | Where-Object { $_.State -eq 'working' }).Count
        Stale   = @($r | Where-Object { $_.State -eq 'stale'   }).Count
        Partial = @($r | Where-Object { $_.State -eq 'partial' }).Count
        Done    = @($r | Where-Object { $_.State -eq 'done'    }).Count
    }
}

function Remove-CvQueueOutput {
    <#
        Borra el fichero de SALIDA de los archivos dados (Convertido\<nombre>_fix.<ext>). Se usa con
        las conversiones que quedaron A MEDIAS: mientras ese resto este ahi, el worker salta el
        archivo -da por hecho que ya esta convertido- y no lo rehace nunca.

        Devuelve cuantos borro. Quien llama confirma primero: esto borra de verdad.
    #>
    param([Parameter(Mandatory)]$Context, $Names)
    $n = 0
    foreach ($name in @($Names)) {
        $p = Get-OutputPath $Context "$name"
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -Force -LiteralPath $p -ErrorAction Stop; $n++ } catch {}
        }
    }
    return $n
}

function Test-CvConvertReady {
    <#
        Esta el entorno listo para trabajar? Comprueba que exista la version de ffmpeg CONFIGURADA
        (downloads.ffmpeg.selected). Lo usan tanto el arranque de workers -uno desatendido que tenga
        que preguntar algo se queda colgado para siempre- como PREPARAR, que necesita ffprobe y
        ffmpeg para analizar: sin esto, lo que salia era la excepcion cruda de Process.Start ("el
        sistema no puede encontrar el archivo especificado"), que no dice nada.

        Ok/Reason = lo que IMPIDE trabajar (ffmpeg). 'Warnings' = herramientas OPCIONALES que esta
        configuracion SI va a usar y no estan: no bloquean, pero conviene decirlo antes de empezar y
        no cuando ya se esta codificando. El motivo incluye las versiones que SI estan instaladas, que
        es justo lo que hace falta saber para arreglarlo. Devuelve @{ Ok; Reason; Warnings }.
    #>
    param([Parameter(Mandatory)]$Context)
    $ver = "$($Context.FFmpegVersion)"
    if (-not (Test-CvToolSupported -Context $Context -Name 'ffmpeg')) {
        return [pscustomobject]@{
            Ok       = $false
            Reason   = ("ffmpeg no tiene build para la plataforma de este equipo ({0})." -f $Context.Platform)
            Warnings = @()
        }
    }
    if (-not (Test-CvToolInstalled -Context $Context -Name 'ffmpeg' -Version $ver)) {
        $inst = @(Get-CvInstalledVersions -Context $Context -Name 'ffmpeg')
        $hay  = if ($inst.Count -gt 0) { "instalada(s): {0}" -f ($inst -join ', ') } else { 'no hay ninguna instalada' }
        return [pscustomobject]@{
            Ok       = $false
            Reason   = ("falta la version {0} de ffmpeg, que es la fijada en la configuracion ({1}).`n`nInstalala desde setup (setup-gui.cmd), o cambia downloads.ffmpeg.selected a una de las que ya tienes." -f $ver, $hay)
            Warnings = @()
        }
    }

    # Opcionales: solo se avisa de las que ESTA configuracion va a usar de verdad.
    $warn = @()
    if ("$($Context.VolumeMethod)".ToLower() -eq 'aacgain' -and
        -not (Test-CvToolInstalled -Context $Context -Name 'aacgain' -Version "$($Context.AacGainVersion)")) {
        $warn += ("falta aacgain {0} y el metodo de volumen configurado es 'aacgain': el ajuste de volumen se omitira." -f $Context.AacGainVersion)
    }
    if ($Context.StripTags -and [string]::IsNullOrWhiteSpace("$($Context.MkvPropEditOverride)")) {
        $mk = Get-CvAppDescriptor -Context $Context -Name 'mkvtoolnix'
        $mkv = if ($mk) { "$($mk.selected)" } else { '' }
        if ($mkv -and (Test-CvToolSupported -Context $Context -Name 'mkvtoolnix') -and
            -not (Test-CvToolInstalled -Context $Context -Name 'mkvtoolnix' -Version $mkv)) {
            $warn += ("falta mkvtoolnix {0} y la limpieza de etiquetas esta activada: el MKV final conservara las etiquetas DURATION (se descargara al codificar)." -f $mkv)
        }
    }
    return [pscustomobject]@{
        Ok       = $true
        Reason   = ''
        Warnings = @($warn)
    }
}

function Get-CvConvertWorkerArgs {
    <#
        PURO. Linea de argumentos con la que se abre un worker: Convert.ps1 en modo -WorkerOnly
        -Unattended, con el -Config si lo hay y con -Only cuando se han elegido archivos concretos.
        Separado de Start-CvConvertWorker para poder comprobarlo sin abrir procesos.

        -Only se pasa entrecomillado y separado por comas (asi lo entiende el parser de PowerShell
        como lista); los nombres van LITERALES porque 'powershell -File' no expande los argumentos.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$CfgPath = '',
        [string[]]$Only = @()
    )
    $script = Join-Path $Root 'Convert.ps1'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script), '-WorkerOnly', '-Unattended')
    if (-not [string]::IsNullOrWhiteSpace($CfgPath)) { $argv += @('-Config', ('"{0}"' -f $CfgPath)) }
    $names = @(@($Only) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($names.Count -gt 0) {
        $argv += @('-Only', ((@($names | ForEach-Object { '"{0}"' -f $_ }) -join ',')))
    }
    return @($argv)
}

function Start-CvConvertWorker {
    <#
        Abre un worker (Convert.ps1 -WorkerOnly -Unattended) como proceso aparte y devuelve sin
        esperar. La ventana NO codifica: WinForms es de un solo hilo y se quedaria congelada horas
        (mismo motivo por el que setup-gui lanza 'setup.ps1 -Task ...').

        -Unattended es lo que hace que sea seguro tenerlo sin consola a la vista: el worker no
        pregunta nada ni se queda en la pausa final. -ShowConsole abre su ventana para verlo en vivo.
        -Only limita ese worker a los archivos indicados (los elegidos en la lista).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$CfgPath = '',
        [string[]]$Only = @(),
        [switch]$ShowConsole
    )
    $argv  = @(Get-CvConvertWorkerArgs -Root $Root -CfgPath $CfgPath -Only $Only)
    $style = if ($ShowConsole) { 'Normal' } else { 'Hidden' }
    return (Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -WorkingDirectory $Root -WindowStyle $style -PassThru)
}

function Stop-CvConvertWorker {
    <#
        Corta un worker EN SECO (el boton de cancelar). Se mata primero a sus hijos (el ffmpeg que
        esta codificando) y luego al propio worker: al reves, ffmpeg se quedaria huerfano comiendo
        CPU. Lo que deje a medias -el bloqueo y los temporales- no se toca aqui: el bloqueo queda
        CADUCADO (su PID ya no existe) y el siguiente worker lo roba solo; los temporales se limpian
        desde setup. Devuelve $true si el proceso ya no esta.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        foreach ($c in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
    return (-not (Test-CvProcessAlive -ProcessId $ProcessId))
}

Export-ModuleMember -Function *
