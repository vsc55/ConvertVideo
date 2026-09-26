<#
    GuiConvert.psm1 - La logica de la COLA que se puede probar SIN ventana.

    Aqui vive lo que decide QUE se ve y QUE se puede hacer: como queda cada fila (Format-CvQueueRow),
    el resumen, cuando toca releer las carpetas (Test-CvQueueKeepRows, Get-CvQueueTickPlan), cuando
    la lista debe seguir al archivo en curso (Get-CvQueueWorkingRange, Get-CvQueueFollowPlan), que
    botones se encienden con lo que hay seleccionado (Get-CvQueueBulkActions, Get-CvQueueStartState,
    Get-CvQueueStartScope) y que hacer al cerrar con workers vivos (Get-CvQueueCloseActions).

    Son funciones PURAS: entran datos, salen datos. Ninguna toca un control, y por eso la bateria
    test\gui-convert-tests.ps1 las prueba a cientos sin abrir nada. Los DATOS de la cola salen de
    lib\WorkerCore.psm1; la ventana que pinta todo esto es form\GuiConvertWindow.psm1.
#>

function Format-CvQueueRow {
    <#
        PURO. Las celdas de una fila de la cola, en orden: archivo, tamano, estado, worker, progreso
        y ETA. Separado de la ventana para poder probarlo sin abrir nada (y para que la consola
        pudiera pintar lo mismo el dia que haga falta).

        - 'Codificando': paso + barra + % + velocidad, exactamente lo que publica el worker.
        - 'Hecho': tamano de la salida y cuanto ha quedado respecto al original (el dato que de
          verdad se mira al acabar).
    #>
    param($Row, [int]$BarWidth = 12)
    $prog = ''
    $eta  = ''
    if ($Row.State -eq 'working') {
        $p    = [int]$Row.Percent
        $bits = @()
        # El paso viene del mismo texto que la consola pinta tras " - " y suele acabar en puntos
        # suspensivos ('Una sola pasada (video+audio)...'); en una columna quedan de sobra.
        $step = "$($Row.Step)".TrimEnd('.', ' ')
        if ($step) { $bits += $step }
        if ($p -ge 0) {
            # Entre corchetes: a 9pt el tramo VACIO de la barra casi no se ve y sin el borde no se
            # sabe sobre que total avanza. El relleno es el mismo de la consola (Get-CvProgressBar).
            $bar = Get-CvProgressBar -Percent $p -Width $BarWidth
            if ($bar) { $bits += ('[{0}]' -f $bar) }
            $bits += ('{0,3}%' -f $p)
        }
        if ("$($Row.Speed)") { $bits += "$($Row.Speed)" }
        $prog = ($bits -join '  ')
        $eta  = "$($Row.Eta)"
    }
    elseif ($Row.State -eq 'done') {
        $prog = Format-CvSize -Kb $Row.OutSizeKb
        if ($Row.SizeKb -gt 0 -and $Row.OutSizeKb -gt 0) {
            $prog += (' ({0:N0}% del original)' -f (100.0 * $Row.OutSizeKb / $Row.SizeKb))
        }
        # Si la salida lleva el video ORIGINAL (recodificar lo engordaba), se dice: es justo lo que
        # no se ve mirando el tamano. Sin marca no se pinta nada, que es el caso normal -y en una
        # salida anterior a esta opcion no se puede saber-.
        if ("$($Row.VideoGuess)" -eq 'original') { $prog += '   [video ORIGINAL]' }
    }
    elseif ($Row.State -eq 'partial') {
        $prog = ("{0} a medias: borra la salida para rehacerlo" -f (Format-CvSize -Kb $Row.OutSizeKb))
    }
    elseif ($Row.State -eq 'stale') {
        $prog = 'su worker ya no existe'
    }
    elseif ($Row.State -eq 'pending') {
        $prog = 'falta PREPARAR'
    }
    return @(
        "$($Row.Name)"
        (Format-CvSize -Kb $Row.SizeKb)
        "$($Row.StateText)"
        # Salen del JOB; sin job (sin preparar, o ya hecho y borrado) no hay nada que decir -y 'sin
        # audio' ahi seria mentira: es que no se sabe-. En los ya CONVERTIDOS, los bordes se deducen
        # comparando proporciones (BorderGuess, ver Get-CvBorderFromSizes), que es lo unico que se
        # puede saber cuando el job ya no esta.
        $(if ([bool]$Row.HasJob) { Format-CvJobBorderCell -Crop "$($Row.Crop)" -Detect ([bool]$Row.Detect) -Short } else { "$($Row.BorderGuess)" })
        $(if ([bool]$Row.HasJob) { Format-CvJobAudioCell -Tracks @($Row.AudioTracks) -Skip ([bool]$Row.AudioSkip) } else { '' })
        $(if ([int]$Row.WorkerPid -gt 0) { '#{0}' -f $Row.WorkerPid } else { '' })
        $prog
        $eta
    )
}

function Get-CvQueueSummaryLine {
    <# PURO. Resumen de una linea bajo la lista (lo mismo que el recuento de Get-CvQueueTotals). #>
    param($Totals, [int]$Workers = 0, [bool]$Stopping = $false)
    $p = @()
    $p += ("{0} archivo(s)" -f [int]$Totals.Total)
    if ([int]$Totals.Working -gt 0) { $p += ("{0} codificando" -f $Totals.Working) }
    if ([int]$Totals.Queued  -gt 0) { $p += ("{0} en cola"     -f $Totals.Queued) }
    if ([int]$Totals.Pending -gt 0) { $p += ("{0} sin preparar" -f $Totals.Pending) }
    if ([int]$Totals.Done    -gt 0) { $p += ("{0} hecho(s)"    -f $Totals.Done) }
    if ([int]$Totals.Partial -gt 0) { $p += ("{0} sin terminar" -f $Totals.Partial) }
    if ([int]$Totals.Stale   -gt 0) { $p += ("{0} bloqueo(s) huerfano(s)" -f $Totals.Stale) }
    $p += ("{0} worker(s) activo(s)" -f $Workers)
    $txt = ($p -join '  -  ')
    if ($Stopping) { $txt += '   [PARADA PEDIDA: terminan el archivo en curso y no cogen mas]' }
    return $txt
}

function Test-CvQueueKeepRows {
    <#
        PURO. $true si hay que CONSERVAR las filas que ya se ven porque el listado que acaba de
        llegar vacio huele a tropiezo y no a carpeta vacia.

        Pasa de verdad: Get-CvFiles se traga los errores del disco (-ErrorAction SilentlyContinue) y
        devuelve @(), asi que un momento malo -dos ffmpeg machacando el disco, el antivirus, una
        unidad de red- vaciaba la ventana entera. La diferencia entre las dos cosas se ve mirando la
        carpeta: si sigue ahi y con ficheros dentro, el listado mintio.
    #>
    param(
        [int]$Rows       = 0,
        [int]$Items      = 0,
        [bool]$DirExists = $true,
        [int]$RealFiles  = 0
    )
    if ($Rows -gt 0)    { return $false }   # hay filas: no hay nada que conservar
    if ($Items -le 0)   { return $false }   # la lista ya estaba vacia
    if (-not $DirExists) { return $false }  # la carpeta ya no esta: vaciar es lo correcto
    return ($RealFiles -gt 0)               # hay ficheros pero el listado no los vio: tropiezo
}

function Get-CvQueueDoneProbeBudget {
    <#
        PURO. Cuantos archivos ya convertidos se pueden analizar en ESTE refresco para deducirles los
        bordes: ninguno mientras haya workers vivos -la sonda son dos ffprobe por archivo (~300 ms
        medidos) y el refresco tiene que seguir siendo barato mientras se codifica-, y lo que diga la
        config cuando la cola esta parada.
    #>
    param([int]$Configured = 0, [int]$LiveWorkers = 0)
    if ($LiveWorkers -gt 0) { return 0 }
    return [Math]::Max(0, $Configured)
}

function Get-CvQueueWorkingRange {
    <#
        PURO. Primera y ultima fila que se estan CODIFICANDO (-1 las dos si ninguna). Con varios
        workers hay varias filas en curso y lo que interesa es el bloque entero, no una sola.
    #>
    param($Rows)
    $first = -1
    $last  = -1
    $k = 0
    $nombres = @()
    foreach ($r in @($Rows)) {
        if ("$($r.State)" -eq 'working') {
            if ($first -lt 0) { $first = $k }
            $last = $k
            $nombres += "$($r.Name)"
        }
        $k++
    }
    return @{
        First = $first
        Last  = $last
        # Clave por NOMBRE, no por posicion: es lo que dice si se esta codificando OTRA cosa (que es
        # cuando hay que moverse). Que la fila cambie de sitio al aparecer un archivo nuevo no lo es.
        Key   = ($nombres -join '|')
    }
}

function Get-CvQueueFollowPlan {
    <#
        PURO. Si la lista tiene que moverse sola para no perder de vista la fila que se esta
        codificando, y si sigue enganchada a ella.

        La regla es la del que mira: la lista PERSIGUE al worker mientras no te hayas ido tu a otra
        parte. Lo uno se distingue de lo otro por el SCROLL: si se ha movido y no ha sido la ventana
        (-Moved), has sido tu, y entonces se sigue solo si has dejado la fila en curso a la vista.
        Volver a tenerla delante vuelve a engancharla.

        La lista se mueve POCO a proposito, solo cuando hay un motivo nuevo:
        - -Changed: se esta codificando OTRO archivo (o el primero). Que la fila se salga de la vista
          por cualquier otro motivo no mueve nada: mover la lista por su cuenta mientras la usas es
          peor que no seguir a nadie.
        - -Busy: la estas tocando ahora mismo (raton apretado, o acabas de marcar filas). Entonces no
          se mueve NADA y tampoco se da por visto el archivo: se vuelve a mirar cuando la sueltes.
          Pasaba de verdad: el resumen de la fila marcada llama a DoEvents, el temporizador entraba
          ahi mismo y la lista daba un salto a mitad de un Ctrl/Mayus+clic -seleccionando lo que no
          era-.

        Los HECHOS los mide la ventana y se pasan ya masticados, que aqui no hay controles: -HasRow
        (hay algo codificandose), -Visible (esa fila se ve ENTERA ahora mismo) y -Moved (el scroll
        esta en otro sitio que en la vuelta anterior). Se mide lo que se ve y no cuantas filas caben
        porque esa cuenta miente justo al abrir, mientras la ventana se esta colocando: dio por
        visible una fila que no lo era y la lista se quedaba sin ir a por ella.
    #>
    param(
        [bool]$HasRow    = $false,
        [bool]$Visible   = $false,
        [bool]$Moved     = $false,
        [bool]$Following = $true,
        [bool]$Changed   = $true,
        [bool]$Busy      = $false,
        [bool]$Enabled   = $true
    )
    if (-not $Enabled) {
        return @{
            Follow = $false
            Scroll = $false
            Hold   = $false
        }
    }
    if ($Busy) {
        return @{
            Follow = $Following
            Scroll = $false
            Hold   = $true      # ni se mueve ni se apunta nada: se decide cuando sueltes
        }
    }
    $follow = $Following
    if ($HasRow -and $Moved) { $follow = $Visible }
    return @{
        Follow = $follow
        Scroll = ($follow -and $HasRow -and (-not $Visible) -and $Changed)
        Hold   = $false
    }
}

function Get-CvQueueTickPlan {
    <#
        PURO. Si el temporizador tiene que estar en marcha y a que ritmo.

        - Con workers vivos: el ritmo del progreso (-RefreshMs).
        - ARRANCANDO: se acaba de pulsar Iniciar y ningun worker ha publicado su estado todavia. En
          ese hueco no hay nadie vivo pero SI hay algo que esperar; sin esto el temporizador se
          paraba justo despues de arrancar y la fila no pasaba a 'Codificando' hasta que se pulsaba
          Actualizar a mano.
        - Sin nada de lo anterior: lo que diga -IdleMs, y con 0 se PARA (la lista se actualiza a
          peticion, ver Get-CvWorkerSignature).
    #>
    param(
        [int]$Live      = 0,
        [bool]$Starting = $false,
        [int]$RefreshMs = 1000,
        [int]$IdleMs    = 0
    )
    if ($Live -gt 0 -or $Starting) {
        return @{
            Enabled  = $true
            Interval = $RefreshMs
        }
    }
    if ($IdleMs -le 0) {
        return @{
            Enabled  = $false
            Interval = $RefreshMs
        }
    }
    return @{
        Enabled  = $true
        Interval = $IdleMs
    }
}

function Get-CvQueueProgressWidth {
    <#
        PURO. Ancho de la columna de PROGRESO: se queda con todo el espacio que sobra a la derecha
        (es la columna que mas informacion lleva -paso, barra, %, velocidad- y la que peor sienta
        recortar). -ClientWidth es el ancho UTIL de la lista (sin la barra de scroll) y -OtherWidths
        la suma de las demas columnas. Nunca baja de -Min: con la ventana muy estrecha es preferible
        que aparezca scroll horizontal a que la barra de progreso quede en dos caracteres.
    #>
    param([int]$ClientWidth, [int]$OtherWidths, [int]$Min = 220)
    return (Get-CvGuiFillColumnWidth -ClientWidth $ClientWidth -OtherWidths $OtherWidths -Min $Min)
}

function Get-CvQueueBulkActions {
    <#
        PURO. Que acciones EN BLOQUE aplican a las filas seleccionadas, a cuantas, y con que etiqueta.
        Separado de la ventana para poder probarlo sin abrirla (y sin sacar el dialogo de confirmar).

        - Liberar bloqueo: las que tengan un bloqueo CADUCADO (su worker ya no existe).
        - Quitar de la cola: las que TENGAN job y no las este codificando nadie. Quitarle el job a un
          archivo en curso no lo parara -el worker ya lo leyo- y solo dejaria la cola inconsistente.
        - Cortar: las que se esten codificando AHORA (se mata SU worker, no todos).
        - Editar en bloque: las que TENGAN job y nadie este codificando, y solo a partir de DOS (con
          una sola, lo suyo es el editor de siempre, que ensena el archivo entero).
    #>
    param($Rows)
    $sel   = @($Rows)
    # Codificar SOLO los elegidos: los que estan en cola (lo demas no se puede lanzar).
    $start = @($sel | Where-Object { $_.State -eq 'queued' })
    # Cortar la codificacion de UNO: las que tienen un worker trabajandolas ahora mismo.
    $kill  = @($sel | Where-Object { $_.State -eq 'working' -and [int]$_.WorkerPid -gt 0 })
    $free  = @($sel | Where-Object { $_.Stale })
    $drop  = @($sel | Where-Object { $_.HasJob -and $_.State -in @('queued', 'stale', 'partial') })
    # Salidas A MEDIAS: las de los cancelados. Mientras esten, el worker salta el archivo.
    $purge = @($sel | Where-Object { $_.State -eq 'partial' })
    # Editar VARIOS jobs a la vez: los mismos que se pueden quitar de la cola (tienen job y nadie los
    # esta codificando). Con uno solo no es una accion en bloque: se queda vacia.
    $edit  = @($(if ($drop.Count -gt 1) { $drop } else { @() }))
    [pscustomobject]@{
        Start     = @($start)
        Kill      = @($kill)
        Free      = @($free)
        Drop      = @($drop)
        Purge     = @($purge)
        Edit      = @($edit)
        StartText = $(if ($start.Count -gt 1) { 'Codificar solo estos {0}' -f $start.Count } else { 'Codificar solo este' })
        KillText  = $(if ($kill.Count  -gt 1) { 'Cortar la codificacion de estos {0}' -f $kill.Count } else { 'Cortar la codificacion de este' })
        FreeText  = $(if ($free.Count  -gt 1) { 'Liberar los {0} bloqueos huerfanos' -f $free.Count } else { 'Liberar el bloqueo huerfano' })
        DropText  = $(if ($drop.Count  -gt 1) { 'Quitar de la cola los {0} seleccionados (borrar sus jobs)' -f $drop.Count } else { 'Quitar de la cola (borrar su job)' })
        PurgeText = $(if ($purge.Count -gt 1) { 'Eliminar las {0} salidas a medias (se rehacen)' -f $purge.Count } else { 'Eliminar la salida a medias (se rehace)' })
        EditText  = $(if ($edit.Count  -gt 1) { 'Editar los {0} jobs elegidos a la vez...' -f $edit.Count } else { 'Editar varios jobs a la vez...' })
    }
}

function Get-CvQueueStartState {
    <#
        PURO. Si 'Iniciar' se puede pulsar, y por que no cuando no. Se apaga con workers YA en
        marcha: volver a pulsarlo abriria OTRO grupo entero de workers sobre la misma cola -es facil
        hacerlo sin querer y no se nota hasta que hay el doble de procesos comiendo GPU-. Para
        cambiar cuantos hay: parar y volver a arrancar.

        Devuelve @{ Enabled; Tip }.
    #>
    param(
        [int]$Queued   = 0,
        [int]$Live     = 0,
        [bool]$Stopping = $false,
        # Se acaba de pulsar: los workers tardan unos segundos en publicar su estado, y hasta
        # entonces -Live sigue a 0. Sin esto, el boton se queda encendido justo en la ventana de
        # tiempo en la que es mas facil volver a pulsarlo.
        [bool]$JustStarted = $false
    )
    if ($Stopping) {
        return @{ Enabled = $false; Tip = 'Hay una parada pedida: espera a que los workers terminen' }
    }
    if ($JustStarted -and $Live -le 0) {
        return @{ Enabled = $false; Tip = 'Los workers estan arrancando...' }
    }
    if ($Live -gt 0) {
        return @{ Enabled = $false; Tip = ("Ya hay {0} worker(s) en marcha: para antes de volver a arrancar" -f $Live) }
    }
    if ($Queued -le 0) {
        return @{ Enabled = $false; Tip = 'No hay ningun archivo en cola' }
    }
    return @{ Enabled = $true; Tip = 'Abre los workers y empieza a codificar' }
}

function Get-CvQueueStartScope {
    <#
        PURO. Que hace 'Iniciar' cuando hay filas EN COLA seleccionadas. Es una trampa facil de
        pisar: se marca una fila para leer su resumen y, sin querer, el boton pasa a codificar SOLO
        esa -paso de verdad: un worker, empezando por el archivo 15 de la lista, y desde fuera
        parecia que el reparto estaba roto-. Asi que cuando lo elegido es solo una PARTE de la cola
        se pregunta antes, en vez de decidir por el usuario.

        Devuelve @{ Ask; Message; Options } (Options con Value 'sel'|'all'|'cancel').
    #>
    param(
        [int]$Selected = 0,
        [int]$Total    = 0
    )
    if ($Selected -le 0 -or $Selected -ge $Total) {
        return @{ Ask = $false; Message = ''; Options = @() }
    }
    return @{
        Ask     = $true
        Message = ("Tienes {0} archivo(s) marcados de los {1} que hay en cola.`n`nQue codifico?" -f $Selected, $Total)
        Options = @(
            @{
                Value = 'sel'
                Text  = ("Solo los {0} marcados" -f $Selected)
                Hint  = 'Los workers ignoran el resto de la cola (-Only)'
            }
            @{
                Value = 'all'
                Text  = 'Toda la cola'
                Hint  = ("Los {0} archivos en cola, en orden" -f $Total)
            }
            @{
                Value = 'cancel'
                Text  = 'No arrancar'
                Hint  = 'Volver a la cola'
            }
        )
    }
}

function Get-CvQueueCloseActions {
    <#
        PURO. Las salidas del aviso de CERRAR con workers codificando, en orden de izquierda a
        derecha. Catalogo (@{ Value; Text; Hint }) como los del resto del proyecto: la ventana solo
        lo pinta. 'cancel' (y cerrar el aviso con la X) significa NO cerrar, que es lo seguro.
    #>
    @(
        @{
            Value = 'background'
            Text  = 'Dejarlos en segundo plano'
            Hint  = 'Siguen codificando sin ventana; al volver a abrir la cola se ven otra vez.'
        }
        @{
            Value = 'stop'
            Text  = 'Parada ordenada'
            Hint  = 'Terminan el archivo que tengan y no cogen mas. No se pierde nada.'
        }
        @{
            Value = 'kill'
            Text  = 'Cancelar ahora'
            Hint  = 'Corta los workers y su ffmpeg: se pierde el archivo en curso.'
        }
        @{
            Value = 'cancel'
            Text  = 'No cerrar'
            Hint  = 'Volver a la cola.'
        }
    )
}

function Get-CvQueueCloseMessage {
    <# PURO. El texto del aviso de cierre: lo primero, que cerrar NO para nada. #>
    param([int]$Workers = 0)
    $q = if ($Workers -eq 1) { 'Hay 1 worker codificando' } else { ("Hay {0} workers codificando" -f $Workers) }
    return ("{0}.`n`nCada worker es un proceso aparte: cerrar esta ventana NO lo para, seguira codificando sin nada a la vista (su consola va oculta).`n`nQue hago?" -f $q)
}

function Get-CvConvertLogChoices {
    <#
        Logs que puede ensenar la ventana: los transcripts de Convert (logs\Convert_*.log), el mas
        reciente primero, marcando los que son de un worker VIVO. Reutiliza Get-CvSetupLogFiles
        (SetupCore) para no tener dos formas de listar logs.
    #>
    param([Parameter(Mandatory)]$Context, $Workers = @())
    $live = @{}
    foreach ($w in @($Workers)) { if ($w.Alive -and "$($w.Log)") { $live["$($w.Log)".ToLower()] = [int]$w.Pid } }
    $out = @()
    foreach ($l in @(Get-CvSetupLogFiles -Context $Context)) {
        if ($l.Name -notlike 'Convert_*') { continue }
        $wpid = 0
        if ($live.ContainsKey($l.Path.ToLower())) { $wpid = [int]$live[$l.Path.ToLower()] }
        $out += [pscustomobject]@{
            Name      = $l.Name
            Path      = $l.Path
            Date      = $l.Date
            SizeKb    = $l.SizeKb
            WorkerPid = $wpid
            Text      = ("{0:dd/MM HH:mm}  {1,6} KB  {2}{3}" -f $l.Date, $l.SizeKb, $l.Name, $(if ($wpid) { '   <- en curso' } else { '' }))
        }
    }
    return @($out)
}

Export-ModuleMember -Function *
