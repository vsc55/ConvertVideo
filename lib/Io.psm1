<#
    Io.psm1 - Lectura y escritura de FICHEROS, en un solo sitio.

    Todo el programa guarda cosas en disco -el job, el estado de cada worker, config.json, el tamano
    en que quedo una ventana- y todas esas escrituras hacian lo MISMO copiado en cada modulo: montar
    el JSON, escribir con UTF-8 SIN BOM (con BOM, ffmpeg y media herramienta se atragantan) y, cuando
    el fichero lo puede estar leyendo otro proceso, hacerlo ATOMICO: escribir un '.tmp' al lado y
    renombrarlo, para que nadie llegue a ver medio fichero.

    Se usan las llamadas de .NET con rutas LITERALES a proposito: los nombres de video llevan
    corchetes con frecuencia y PowerShell los interpretaria como comodines en -Path.

    Leer es la otra cara: un .json puede no existir, estar a medio escribir o venir de otra version.
    Read-CvJsonFile -Quiet devuelve $null en vez de lanzar, que es lo que quiere quien pinta una
    ventana (una excepcion en un manejador tumba la aplicacion) o quien solo esta mirando el estado.
#>

function Move-CvFileOver {
    <#
        Pone -Source en el sitio de -Target, que puede existir ya, SIN que haya un momento en que no
        este ninguno de los dos: si el destino existe se usa File.Replace (el ReplaceFile de Windows,
        que cambia uno por otro de golpe) y si no, un Move normal. Lo usan el guardado atomico y el
        nombre final de las salidas.

        Antes se hacia 'borrar el destino y mover': si el Move fallaba (el antivirus, un lector), el
        destino ya no estaba y, al limpiar, tampoco el nuevo -medio job, o la salida buena, perdidos-.
        Ahora, si falla, el destino sigue intacto y -Source sigue donde estaba. Lanza si falla.
        Los dos en el MISMO volumen (es un renombrado, no una copia).
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    if ([System.IO.File]::Exists($Target)) {
        [System.IO.File]::Replace($Source, $Target, [NullString]::Value)
    } else {
        [System.IO.File]::Move($Source, $Target)
    }
    return $Target
}

function Save-CvTextFile {
    <#
        Escribe texto en UTF-8 SIN BOM. Con -Atomic pasa por un '.tmp' y renombra, para que otro
        proceso que este leyendo no vea el fichero a medias. Lanza si no se puede escribir.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Atomic
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    if (-not $Atomic) {
        [System.IO.File]::WriteAllText($Path, $Text, $enc)
        return $Path
    }
    # El temporal lleva el PID: con un nombre fijo, dos procesos que guardaban el mismo fichero a la vez
    # (varios workers dejando la cache de la GPU en config.json) chocaban en el .tmp o publicaban lo
    # del otro. Get-CvProcesoPatterns y Remove-CvTemps conocen este nombre.
    $tmp = "{0}.{1}.tmp" -f $Path, $PID
    [System.IO.File]::WriteAllText($tmp, $Text, $enc)
    # REINTENTOS: el fichero destino puede estar abierto un instante por quien lo lee (la ventana de
    # la cola relee los estados de los workers, y tambien pasa el antivirus o el propio explorador),
    # y entonces el Delete/Move falla con 'lo esta usando otro proceso'. Son colisiones de
    # milisegundos: con tres reintentos cortos desaparecen. Medido con un lector a saco: 10,7% de
    # escrituras perdidas -> 0%.
    $intentos = 4
    for ($i = 1; $i -le $intentos; $i++) {
        try {
            # Sin borrar antes el destino (Move-CvFileOver): si falla, el fichero de antes sigue entero.
            [void](Move-CvFileOver -Source $tmp -Target $Path)
            return $Path
        } catch {
            if ($i -eq $intentos) {
                # El destino sigue como estaba: el .tmp sobra.
                try { [System.IO.File]::Delete($tmp) } catch { }
                throw
            }
            Start-Sleep -Milliseconds (15 * $i)
        }
    }
    return $Path
}

function Save-CvJsonFile {
    <#
        Serializa un objeto a JSON y lo guarda (UTF-8 sin BOM). Por defecto de forma ATOMICA, porque
        estos ficheros -el job, el estado del worker- los lee otro proceso mientras se escriben.
        Con -Quiet no lanza y devuelve $false si algo falla: para telemetria (el estado del worker)
        que jamas debe tumbar una conversion.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 8,
        [switch]$NoAtomic,
        [switch]$Quiet
    )
    try {
        $json = $Object | ConvertTo-Json -Depth $Depth
        [void](Save-CvTextFile -Path $Path -Text $json -Atomic:(-not $NoAtomic))
        return $true
    } catch {
        if ($Quiet) { return $false }
        throw
    }
}

function Get-CvFileStamp {
    <#
        HUELLA de un fichero: 'ruta|tamano|fecha'. Sirve para saber si HA CAMBIADO sin leerlo, que es
        lo que evita repintar un panel (o re-parsear un .json) cada segundo para nada.

        Si el fichero no se puede mirar devuelve 'ruta|?': una huella valida y distinta de la de un
        fichero legible, asi que quien la compara reintenta en la siguiente vuelta en vez de dar por
        bueno lo que tuviera pintado.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ("$Path" -eq '') { return '' }
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ("{0}|{1}|{2}" -f $Path, $fi.Length, $fi.LastWriteTimeUtc.Ticks)
    } catch {
        return ("{0}|?" -f $Path)
    }
}

function Test-CvFileInUse {
    <#
        $true si algun proceso tiene el fichero ABIERTO (se prueba a abrirlo sin compartir nada). Para
        no contar como borrable el log de otra sesion o de un worker, que Start-Transcript tiene
        abierto: se contaba, se intentaba borrar y salia como error.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $fs.Dispose()
        return $false
    } catch [System.IO.FileNotFoundException] {
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        return $false
    }
}

function Read-CvTextFileShared {
    <#
        Lee un fichero de texto SIN bloquear a quien lo escribe: se abre con FileShare
        ReadWrite+Delete, asi que el escritor puede borrarlo/reemplazarlo mientras leemos (que es
        justo lo que hace la escritura atomica). Con el Get-Content de toda la vida -o ReadAllText-
        el lector impide el Delete y el escritor se lleva un 'lo esta usando otro proceso'.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $fs = New-Object System.IO.FileStream($Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
}

function Read-CvJsonFile {
    <#
        Lee un .json y lo devuelve como objeto. Con -Quiet devuelve $null si el fichero no existe, no
        se puede leer o no es JSON valido (a medio escribir, de otra version, tocado a mano); sin
        -Quiet se comporta como siempre y LANZA, que es lo que esperan quienes ya lo capturan.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Quiet
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Quiet) { return $null }
        throw [System.IO.FileNotFoundException]::new(("No existe el fichero: {0}" -f $Path), $Path)
    }
    try {
        return ((Read-CvTextFileShared -Path $Path) | ConvertFrom-Json)
    } catch {
        if ($Quiet) { return $null }
        throw
    }
}

Export-ModuleMember -Function *
