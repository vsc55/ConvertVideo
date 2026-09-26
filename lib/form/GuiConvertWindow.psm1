<#
    form\GuiConvertWindow.psm1 - VENTANA de la cola de conversion.

    El panel de mando de lo que antes eran varias consolas negras: una sola ventana con todos los
    archivos de Original\, en que estado esta cada uno, que worker lo esta codificando y por donde
    va, mas el log en vivo. Desde aqui se arrancan y se paran los workers, se preparan los jobs y se
    editan (de uno en uno o en bloque).

    La ventana NO codifica: WinForms es de un solo hilo y se quedaria congelada durante horas. Cada
    worker es un proceso aparte (Convert.ps1 -WorkerOnly -Unattended, ver Start-CvConvertWorker),
    igual que setup-gui lanza 'setup.ps1 -Task ...'. Aqui solo se MIRA y se manda.

    Los DATOS salen de lib\WorkerCore.psm1 y lo que se puede decidir sin pintar nada -las filas, el
    refresco, el seguimiento del archivo en curso, que botones se encienden- de lib\GuiConvert.psm1,
    que se prueba sin abrir ventana. La barra de progreso es la MISMA que pinta la consola
    (Get-CvProgressBar), asi que las dos caras se ven igual.

    Requiere hilo STA, lo normal en powershell.exe. Fail-soft: sin GUI devuelve $false y el llamador
    remite a Convert.cmd (la consola de siempre hace lo mismo).
#>

function Show-CvConvertWindow {
    <#
        Ventana de la cola. Devuelve $true si llego a abrirse, $false si no hay GUI/STA.

        Lo que hace cada boton:
          Iniciar        - comprueba que se puede trabajar desatendido (Test-CvConvertReady: lo unico
                           que Convert.ps1 pregunta al arrancar es la descarga de ffmpeg) y abre N
                           workers, sin pasar de los archivos que hay en cola.
          Parar          - parada ORDENADA (Set-CvWorkerStop): cada worker termina el archivo que
                           tenga y no coge mas. Es la forma buena de parar.
          Cancelar ahora - corta en seco los workers (y su ffmpeg). Deja bloqueo y temporales, que se
                           limpian solos/desde setup; por eso pide confirmacion.
          Preparar       - abre Convert.cmd en consola: las preguntas de PREPARAR siguen siendo cosa
                           de la consola (esta ventana es la fase de CODIFICAR).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Root,
        [string]$CfgPath = '',
        [string]$CfgName = 'config.json',
        [string]$CurrentLog = ''
    )
    if (-not (Initialize-CvGui)) { return $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("{0} {1} - Cola de conversion ({2})" -f $Context.AppName, $Context.Version, $CfgName)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize   = New-Object System.Drawing.Size(860, 560)

    # Como quedo la ultima vez (config gui.rememberLayout): tamano, maximizada, reparto del divisor y
    # anchos de columna. Sin nada apuntado -o con gui.rememberLayout en false- manda la config.
    $lay = $null
    if ([bool]$Context.GuiRemember) { $lay = Get-CvGuiLayout -Context $Context -Key 'cola' }
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $sz  = Resolve-CvGuiWindowSize -Layout $lay `
        -DefaultWidth ([int]$Context.GuiQueueWidth) -DefaultHeight ([int]$Context.GuiQueueHeight) `
        -MinWidth $form.MinimumSize.Width -MinHeight $form.MinimumSize.Height `
        -MaxWidth $scr.Width -MaxHeight $scr.Height
    $form.Size = New-Object System.Drawing.Size([int]$sz.Width, [int]$sz.Height)
    if ([bool]$sz.Maximized) { $form.WindowState = 'Maximized' }

    # Rejilla: barra de botones / lista / resumen / log. Con posiciones absolutas o Dock los controles
    # se salen al redimensionar (ya paso en el editor de configuracion): aqui todo va en la rejilla.
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    # Menos margen ARRIBA que a los lados: la barra no necesita aire por encima (el borde de la
    # ventana ya separa) y cada pixel de ahi es alto que se le quita a la lista.
    $grid.Padding     = New-Object System.Windows.Forms.Padding(8, 3, 8, 8)
    $grid.ColumnCount = 1
    $grid.RowCount    = 2
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($grid)

    # Divisor ARRASTRABLE: arriba la cola (+ el resumen de una linea), abajo las pestanas. Asi cada
    # uno reparte el alto como quiera -un resumen largo pide sitio, y mirar la cola entera tambien-.
    # OJO: SplitterDistance y los minimos se fijan en Shown, no aqui: antes de que el control tenga
    # tamano real, asignarlos lanza excepcion o se recalculan solos (ya paso en el editor de config).
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock        = 'Fill'
    $split.Orientation = 'Horizontal'
    $split.Name        = 'cvSplit'
    # El agarre del divisor (sin el no se descubre que se puede arrastrar), en Gui.psm1 porque lo
    # usan las dos ventanas que reparten sitio.
    [void](Set-CvGuiSplitGrip -Split $split -Tooltip 'Arrastra esta linea para repartir el alto entre la cola y el resumen')
    $grid.Controls.Add($split, 0, 1)

    # Arriba: la lista y, pegada debajo, la linea de totales.
    $topGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $topGrid.Dock        = 'Fill'
    $topGrid.ColumnCount = 1
    $topGrid.RowCount    = 2
    [void]$topGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$topGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$topGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    $split.Panel1.Controls.Add($topGrid)

    # ---- Barra superior ----
    # Barra de herramientas: botones PLANOS con icono (New-CvGuiIcon los dibuja, no hay ficheros) y
    # con tooltip, agrupados por lo que hacen: marcha / preparacion / vista.
    # La barra es SOLO acciones, en grupos separados por una linea. Los ajustes de ejecucion
    # (workers, ver consolas) NO estan aqui: viven en la pestana 'Opciones' de abajo, con el resumen
    # y el log. En la barra se salian de la ventana y ademas no son acciones.
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 0)

    $tipBar = New-Object System.Windows.Forms.ToolTip
    $tipBar.AutoPopDelay = 10000

    # Separador vertical entre grupos de botones (lo que en una barra de verdad es la linea gris).
    $mkSep = { $bar.Controls.Add((New-CvGuiSeparator)) }

    $numW = New-Object System.Windows.Forms.NumericUpDown
    $numW.Minimum = 1
    $numW.Maximum = 16
    $numW.Width   = 50
    $numW.Name    = 'cvWorkers'
    # Por defecto, los que diga la configuracion (behavior.workers), igual que la pregunta de consola.
    $defW = [int]$Context.Workers
    $numW.Value   = [Math]::Min(16, [Math]::Max(1, $(if ($defW -gt 0) { $defW } else { 1 })))

    $mkBtn = {
        param([string]$Text, [int]$Width, [string]$Name, [string]$Icon = '', [string]$Tip = '', [int]$Gap = 3)
        $b = New-Object System.Windows.Forms.Button
        $b.Text   = $Text
        # AUTO-TAMANO, no un ancho fijo: con el icono delante y otra fuente o DPI, un ancho a ojo
        # corta el texto (paso con el boton de contar lineas) y ademas empuja fuera de la barra lo
        # que va al final. -Width queda como suelo para que los botones no bailen de tamano.
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.MinimumSize  = New-Object System.Drawing.Size($Width, 28)
        $b.Height = 28
        $b.Margin = New-Object System.Windows.Forms.Padding($Gap, 2, 3, 2)
        # Plano y sin borde: barra de herramientas, no formulario. El realce al pasar por encima lo
        # pone Windows, asi que se sigue viendo que son botones.
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.TextImageRelation = 'ImageBeforeText'
        $b.ImageAlign        = 'MiddleLeft'
        $b.TextAlign         = 'MiddleLeft'
        $b.Padding           = New-Object System.Windows.Forms.Padding(4, 0, 6, 0)
        if ($Icon) {
            $img = New-CvGuiIcon -Kind $Icon
            if ($null -ne $img) { $b.Image = $img }
        }
        if ($Name) { $b.Name = $Name }
        if ($Tip)  { $tipBar.SetToolTip($b, $Tip) }
        $bar.Controls.Add($b)
        return $b
    }
    # GRUPO 1 - la marcha de las conversiones.
    $btnStart   = & $mkBtn 'Iniciar'              90 'cvStart'      'play'    'Abre los workers y empieza a codificar' 8
    $btnStop    = & $mkBtn 'Parar'                80 'cvStop'       'stop'    'Parada ordenada: cada worker termina su archivo y no coge mas'
    $btnKill    = & $mkBtn 'Cancelar ahora'      120 'cvKill'       'cancel'  'Corta los workers y su ffmpeg: se pierde el archivo en curso'
    & $mkSep
    # GRUPO 2 - preparar (decidir que se le hace a cada archivo).
    $btnPrepAll = & $mkBtn 'Preparar pendientes' 160 'cvPrepareAll' 'prepare' 'Recorre los archivos sin preparar: pregunta el perfil una vez y decide lo que puede'
    $btnEdit    = & $mkBtn 'Editar job'          110 'cvPrepareGui' 'edit'    'Abre el editor del archivo elegido (o del primero sin preparar)'
    & $mkSep
    # GRUPO 3 - las carpetas de trabajo (a donde se mira cuando algo no cuadra).
    $btnDirIn  = & $mkBtn 'Original'    100 'cvDirOriginal'   'folder' 'Abre la carpeta de entrada (Original)'
    $btnDirOut = & $mkBtn 'Convertido'  115 'cvDirConvertido' 'folder' 'Abre la carpeta de salida (Convertido)'
    & $mkSep
    # GRUPO 4 - la vista.
    $btnRefresh = & $mkBtn 'Actualizar'          105 'cvRefresh'    'refresh' 'Refresca ya (la lista se refresca sola cada segundo)'
    $btnTheme   = & $mkBtn 'Tema'                 75 'cvTheme'      'theme'   'Cambia entre claro y oscuro (se guarda en la configuracion)'

    $chkCon = New-Object System.Windows.Forms.CheckBox
    $chkCon.Text     = 'Ver las consolas de los workers'
    $chkCon.AutoSize = $true
    $chkCon.Margin   = New-Object System.Windows.Forms.Padding(0, 4, 0, 2)
    $chkCon.Name     = 'cvShowConsoles'

    # (Los ajustes -workers y ver consolas- se colocan mas abajo, en la pestana 'Opciones'.)

    # ---- Lista de la cola ----
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.HideSelection = $false
    $lv.MultiSelect   = $true    # acciones en bloque: quitar varios jobs, liberar varios bloqueos...
    $lv.Font          = (New-CvGuiFont 9)   # monoespaciada: la barra de progreso se pinta con bloques
    $lv.Name          = 'cvQueue'
    # La de PROGRESO se estira con la ventana (ver $fitCols); las demas tienen ancho fijo.
    # 'Bordes' y 'Audio' salen del job (sin ffprobe): de un vistazo se ve a cuales les ha entrado el
    # recorte y cuales llevan algo de audio que conviene revisar DESPUES de codificar (una sincronia
    # aplicada, varias pistas, una 5.1 mezclada a estereo).
    $cols = @(
        @{ Text = 'Archivo';  Width = 300 }
        @{ Text = 'Tamano';   Width = 85  }
        @{ Text = 'Estado';   Width = 120 }
        @{ Text = 'Bordes';   Width = 55  }
        @{ Text = 'Audio';    Width = 150 }
        @{ Text = 'Worker';   Width = 70  }
        @{ Text = 'Progreso'; Width = 300 }
        @{ Text = 'ETA';      Width = 80  }
    )
    $iProg = 6
    foreach ($c in $cols) { [void]$lv.Columns.Add($c.Text, $c.Width) }
    [void](Set-CvGuiDoubleBuffered -Control $lv)   # sin esto, el refresco de cada segundo parpadea
    $topGrid.Controls.Add($lv, 0, 0)

    $lblTot = New-Object System.Windows.Forms.Label
    $lblTot.Dock      = 'Fill'
    $lblTot.TextAlign = 'MiddleLeft'
    $lblTot.Name      = 'cvTotals'
    $topGrid.Controls.Add($lblTot, 0, 1)

    # ---- Zona de abajo: pestanas (log del worker / resumen del archivo elegido) ----
    # Pestanas PROPIAS (New-CvGuiTabs): el TabControl de WinForms pinta su tira y su marco en claro
    # pase lo que pase, y en oscuro eso era un recuadro blanco alrededor del contenido.
    $tabs = New-CvGuiTabs -Name 'cvTabs'
    $split.Panel2.Controls.Add($tabs)

    # El RESUMEN va primero y es el que sale al abrir: al marcar un archivo, lo primero que se quiere
    # saber es que se le va a hacer. El log queda detras, para cuando ya esta codificando.
    $tabSum = Add-CvGuiTab -Tabs $tabs -Text 'Resumen del archivo' -Padding 4
    $tabLog = Add-CvGuiTab -Tabs $tabs -Text 'Log' -Padding 4
    # Ajustes de ESTA sesion: no son acciones, asi que no van en la barra. Aqui abajo estan a mano
    # (y no se salen de la ventana, que es lo que pasaba con el desplegable de la barra).
    $tabOpt = Add-CvGuiTab -Tabs $tabs -Text 'Opciones' -Padding 10

    $optFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $optFlow.Dock          = 'Fill'
    $optFlow.FlowDirection = 'TopDown'
    $optFlow.WrapContents  = $false
    $tabOpt.Controls.Add($optFlow)

    $rowW = New-Object System.Windows.Forms.FlowLayoutPanel
    $rowW.FlowDirection = 'LeftToRight'
    $rowW.WrapContents  = $false
    $rowW.AutoSize      = $true
    $rowW.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    $optFlow.Controls.Add($rowW)

    $lblW = New-Object System.Windows.Forms.Label
    $lblW.Text     = 'Workers en paralelo:'
    $lblW.AutoSize = $true
    $lblW.Margin   = New-Object System.Windows.Forms.Padding(0, 6, 8, 3)
    $rowW.Controls.Add($lblW)
    $rowW.Controls.Add($numW)

    $lblWHelp = New-Object System.Windows.Forms.Label
    $lblWHelp.Text      = 'Cuantas conversiones a la vez al pulsar Iniciar. Arranca con el valor de behavior.workers del config; lo que pongas aqui vale para esta sesion.'
    $lblWHelp.Name      = 'cvWorkersHelp'
    $lblWHelp.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblWHelp.Margin    = New-Object System.Windows.Forms.Padding(2, 0, 0, 12)
    $optFlow.Controls.Add($lblWHelp)
    [void](Set-CvGuiWrapLabel -Label $lblWHelp -Container $optFlow)

    $optFlow.Controls.Add($chkCon)

    $lblCHelp = New-Object System.Windows.Forms.Label
    $lblCHelp.Text      = 'Marcado, cada worker abre su ventana de consola. Desmarcado van ocultos y se siguen por la pestana Log.'
    $lblCHelp.Name      = 'cvConsolesHelp'
    $lblCHelp.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblCHelp.Margin    = New-Object System.Windows.Forms.Padding(2, 0, 0, 12)
    $optFlow.Controls.Add($lblCHelp)
    [void](Set-CvGuiWrapLabel -Label $lblCHelp -Container $optFlow)

    # Recodificar no siempre compensa. Esto es el valor de PARTIDA: cada archivo se lo lleva
    # congelado en su job (y ahi se puede cambiar, uno a uno o en bloque).
    $chkKeep = New-Object System.Windows.Forms.CheckBox
    $chkKeep.Text     = 'Si el video recodificado engorda, quedarse con el original'
    $chkKeep.AutoSize = $true
    $chkKeep.Checked  = [bool]$Context.KeepOriginal
    $chkKeep.Name     = 'cvKeepOriginal'
    $optFlow.Controls.Add($chkKeep)

    $lblKHelp = New-Object System.Windows.Forms.Label
    $lblKHelp.Text      = 'Al terminar de codificar el video se compara con la pista original: si ha salido mas grande y la imagen no se toca (sin recorte, escalado, tone-mapping ni cambio de fps), se tira lo codificado y se usa la original. El audio y los subtitulos ya hechos se conservan. Se guarda en la configuracion y es el valor de partida de los jobs NUEVOS; cada archivo lo lleva en su job y se puede cambiar en su editor (o en varios a la vez).'
    $lblKHelp.Name      = 'cvKeepHelp'
    $lblKHelp.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblKHelp.Margin    = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
    $optFlow.Controls.Add($lblKHelp)
    [void](Set-CvGuiWrapLabel -Label $lblKHelp -Container $optFlow)

    $chkKeep.Add_CheckedChanged({
        # Al config (para los jobs que se preparen despues) y al contexto vivo de esta ventana, que
        # es el que usa el editor de jobs que se abra desde aqui.
        try { $Context.KeepOriginal = [bool]$chkKeep.Checked } catch { }
        if ("$CfgPath" -ne '') {
            $r = Set-CvConfigValue -Path $CfgPath -Key 'encode/video/keepOriginalIfBigger' -Value ([bool]$chkKeep.Checked)
            if (-not $r.Ok) { Show-CvGuiInfo -Title 'Opciones' -Message ("No se pudo guardar en {0}:`n`n{1}" -f $CfgName, $r.Error) }
        }
    })

    [void](Select-CvGuiTab -Tabs $tabs -Page $tabSum)

    # Que se le va a hacer al archivo marcado (sale del job, ver Get-CvJobSummaryLines).
    $sumGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $sumGrid.Dock        = 'Fill'
    $sumGrid.ColumnCount = 1
    $sumGrid.RowCount    = 2
    [void]$sumGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$sumGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$sumGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
    $tabSum.Controls.Add($sumGrid)

    $txtSum = New-Object System.Windows.Forms.TextBox
    $txtSum.Dock       = 'Fill'
    $txtSum.Multiline  = $true
    $txtSum.ReadOnly   = $true
    $txtSum.ScrollBars = 'Both'
    $txtSum.WordWrap   = $false
    $txtSum.Font       = (New-CvGuiFont 9)
    $txtSum.Name       = 'cvSummary'
    $sumGrid.Controls.Add($txtSum, 0, 0)

    # Contar las lineas de los subtitulos es LENTO cuando el MKV no trae el tag NUMBER_OF_FRAMES:
    # hay que demultiplexar el fichero entero por cada pista. Por eso no se hace solo: se pide.
    # Va en el BOTON DERECHO sobre el resumen y no en un boton: el texto es largo, y un boton con
    # texto largo acaba cortado segun la fuente y el DPI del equipo (ver ref-gotchas.md). En el menu
    # cabe entero y ademas deja sitio para copiar el resumen. La linea de abajo lo anuncia, que si no
    # un menu contextual no lo encuentra nadie (lo mismo que pasaba con el divisor).
    $sumMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $txtSum.ContextMenuStrip = $sumMenu

    $miCount = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCount.Text        = 'Contar las lineas de los subtitulos'
    $miCount.ToolTipText = 'Solo si el archivo no las trae ya: hay que leerlo entero y puede tardar.'
    $miCount.Name        = 'cvSumCount'
    [void]$sumMenu.Items.Add($miCount)
    [void]$sumMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miCopy = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCopy.Text = 'Copiar el resumen'
    $miCopy.Name = 'cvSumCopy'
    [void]$sumMenu.Items.Add($miCopy)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Dock      = 'Fill'
    $lblCount.TextAlign = 'MiddleLeft'
    $lblCount.Text      = 'Boton derecho sobre el resumen: contar las lineas de los subtitulos (hay que leer el archivo entero: puede tardar) o copiarlo.'
    $lblCount.AutoSize  = $false
    $lblCount.AutoEllipsis = $true
    $lblCount.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblCount.Name      = 'cvSumHint'
    $sumGrid.Controls.Add($lblCount, 0, 1)

    # ---- Panel del log ----
    $logGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $logGrid.Dock        = 'Fill'
    $logGrid.ColumnCount = 1
    $logGrid.RowCount    = 2
    [void]$logGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$logGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$logGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $tabLog.Controls.Add($logGrid)

    $logBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $logBar.Dock          = 'Fill'
    $logBar.FlowDirection = 'LeftToRight'
    $logBar.WrapContents  = $false
    $logGrid.Controls.Add($logBar, 0, 0)

    $lblL = New-Object System.Windows.Forms.Label
    $lblL.Text     = 'Log:'
    $lblL.AutoSize = $true
    $lblL.Margin   = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $logBar.Controls.Add($lblL)

    $cmbLog = New-Object System.Windows.Forms.ComboBox
    $cmbLog.DropDownStyle = 'DropDownList'
    $cmbLog.Width         = 620
    $cmbLog.Font          = (New-CvGuiFont 9)
    $cmbLog.Name          = 'cvLogPick'
    $logBar.Controls.Add($cmbLog)

    $chkFollow = New-Object System.Windows.Forms.CheckBox
    $chkFollow.Text     = 'Seguir'
    $chkFollow.Checked  = $true
    $chkFollow.AutoSize = $true
    $chkFollow.Margin   = New-Object System.Windows.Forms.Padding(12, 7, 3, 3)
    $chkFollow.Name     = 'cvFollow'
    $logBar.Controls.Add($chkFollow)

    $btnLogOpen = New-Object System.Windows.Forms.Button
    $btnLogOpen.Text   = 'Abrir fuera'
    $btnLogOpen.Width  = 110
    $btnLogOpen.Height = 26
    $btnLogOpen.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 3)
    $btnLogOpen.Name   = 'cvLogOpen'
    $logBar.Controls.Add($btnLogOpen)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Dock       = 'Fill'
    $txtLog.Multiline  = $true
    $txtLog.ReadOnly   = $true
    $txtLog.ScrollBars = 'Both'
    $txtLog.WordWrap   = $false
    $txtLog.Font       = (New-CvGuiFont 9)
    $txtLog.Name       = 'cvLogText'
    $logGrid.Controls.Add($txtLog, 0, 1)

    # Estado mutable de la ventana en un hashtable: asignar dentro de un manejador crea la variable en
    # SU ambito y se perderia (misma trampa que en GuiSetup / Format-CvLogText).
    # El temporizador se crea aqui -antes que $refresh- porque el propio refresco ajusta su ritmo.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000

    $st = @{
        Rows     = @()
        Names    = ''
        LogPath  = ''
        LogStamp = ''      # ruta + tamano + fecha del log ya volcado: si no cambia, no se toca el panel
        Stopping = $false  # hay parada pedida: lo mira el menu contextual
        Running  = $false  # hay workers vivos: idem (con workers en marcha no se abren mas)
        StartedAt = 0      # ticks del ultimo 'Iniciar': el boton se apaga ya, sin esperar al refresco
        Workers  = @()     # ultimo estado de los workers (lo usa la ventana de log de un worker)
        SumName  = ''      # archivo cuyo resumen esta pintado
        SumStamp = ''      # huella de lo pintado (archivo + pestana + fecha del job + si hay cues)
        SumBusy  = $false  # se esta montando un resumen: no re-entrar desde el temporizador
        Infos    = @{}     # ffprobe ya hecho, por archivo: no se repite al volver a marcarlo
        Cues     = @{}     # lineas de subtitulo ya contadas, por archivo (lo lento; solo a peticion)
        Busy     = $false
        Vacios   = 0       # veces SEGUIDAS que Original\ se ha listado vacia teniendo archivos
        LiveSig  = ''      # huella de los workers vivos (pid+archivo+estado): si cambia, algo paso
        Live     = 0       # workers vivos en la ultima vuelta (lo miran los botones)
        Follow   = $true   # la lista persigue al archivo en curso (se suelta si te vas tu a otra parte)
        FollowKey = ''     # archivo(s) en curso que ya se dieron por vistos (solo se mueve si cambian)
        Touch    = 0       # ticks de la ultima vez que tocaste la lista (no se mueve mientras eliges)
        LastTop  = -1      # primera fila visible en el refresco anterior (-1: sin dato)
    }

    # ---- Menu contextual de la lista ----
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $lv.ContextMenuStrip = $menu
    $miStart = $menu.Items.Add('Codificar solo este')
    $miKill  = $menu.Items.Add('Cortar la codificacion de este')
    $miWorkerLog = $menu.Items.Add('Ver el proceso (log)')
    [void]$menu.Items.Add('-')
    $miEdit  = $menu.Items.Add('Preparar / editar el job (ventana)')
    $miBulk  = $menu.Items.Add('Editar varios jobs a la vez...')
    $miJob   = $menu.Items.Add('Ver el job (que se decidio en PREPARAR)')
    $miPlayIn  = $menu.Items.Add('Reproducir el ORIGINAL')
    $miPlayOut = $menu.Items.Add('Reproducir el CONVERTIDO')
    $miOut   = $menu.Items.Add('Abrir la carpeta del archivo')
    $miPurge = $menu.Items.Add('Eliminar la salida a medias (se rehace)')
    $miFree  = $menu.Items.Add('Liberar el bloqueo huerfano')
    $miDrop  = $menu.Items.Add('Quitar de la cola (borrar su job)')

    $current = {
        if ($lv.SelectedIndices.Count -eq 0) { return $null }
        $i = $lv.SelectedIndices[0]
        if ($i -lt 0 -or $i -ge @($st.Rows).Count) { return $null }
        return @($st.Rows)[$i]
    }
    # TODAS las filas marcadas, para las acciones en bloque. Lo que es por-archivo (editar el job, ver
    # el job, abrir la carpeta) sigue usando $current = la primera.
    $selected = {
        $out = @()
        foreach ($i in @($lv.SelectedIndices)) {
            if ($i -ge 0 -and $i -lt @($st.Rows).Count) { $out += @($st.Rows)[$i] }
        }
        return @($out)
    }
    # Fila cuyo job se puede editar: la SELECCIONADA si su estado lo permite y, si no hay seleccion
    # (o no vale), el primer archivo SIN PREPARAR. Asi el boton hace lo obvio nada mas abrir la
    # ventana, sin obligar a seleccionar antes. No se edita el de un archivo que se esta codificando:
    # el worker ya trabaja con la copia que leyo.
    $editable = {
        $r = & $current
        if ($null -ne $r -and $r.State -in @('pending', 'queued', 'stale')) { return $r }
        $pend = @(@($st.Rows) | Where-Object { $_.State -eq 'pending' })
        if ($pend.Count -gt 0) { return $pend[0] }
        return $null
    }

    # Resumen de lo que se le va a hacer al archivo marcado. Sale del JOB, asi que es instantaneo y
    # es lo que de verdad hara el worker. Los canales y el numero de lineas de cada subtitulo NO estan
    # en el job: eso pide un ffprobe, asi que solo se hace si la pestana esta a la vista (no mientras
    # se mira el log) y se guarda por archivo para no repetirlo.
    # OJO: esto lo llama un manejador de evento de WinForms. Una excepcion que se escape de aqui NO
    # es un error de PowerShell que se vea en el log: es una excepcion no controlada que TUMBA la
    # aplicacion con el cuadro de volcado de Windows. Por eso va todo dentro de un try y el fallo se
    # cuenta en el propio panel.
    $updateSummary = {
        param([bool]$Force)
        # RE-ENTRADA: dentro se llama a DoEvents (para que se vea el 'leyendo el archivo...') y eso
        # deja correr el temporizador, que volveria a entrar aqui con el ffprobe anterior a medias.
        # Pasaba de verdad: durante una codificacion, cambiar de fila dejaba la lista sin responder
        # porque se encadenaban analisis del mismo archivo.
        if ($st.SumBusy) { return }
        $st.SumBusy = $true
        try {
            $r = & $current
            if ($null -eq $r) {
                $st.SumName  = ''
                $st.SumStamp = ''
                if ($txtSum.Text -ne '') { $txtSum.Text = '' }
                return
            }
            # Huella de lo que se esta pintando: archivo + pestana + fecha de su job. Si no cambia, no
            # hay nada que rehacer, y el refresco de cada segundo no cuesta nada (antes rehacia el
            # resumen SIEMPRE, con su ffprobe, aunque no hubiera cambiado ni la seleccion).
            $jobTicks = 0
            try {
                $jp = Get-CvJobPath $Context $r.Name
                if (Test-Path -LiteralPath $jp) { $jobTicks = (Get-Item -LiteralPath $jp).LastWriteTimeUtc.Ticks }
            } catch { }
            $stamp = "{0}|{1}|{2}|{3}" -f $r.Name, $jobTicks, $(if ((Get-CvGuiTabPage -Tabs $tabs) -eq $tabSum) { 'sum' } else { 'log' }), $(if ($st.Cues.ContainsKey($r.Name)) { 'c' } else { '-' })
            if (-not $Force -and $st.SumStamp -eq $stamp) { return }
            $st.SumName  = $r.Name
            $st.SumStamp = $stamp
            $info = $null
            if ((Get-CvGuiTabPage -Tabs $tabs) -eq $tabSum) {
                if ($st.Infos.ContainsKey($r.Name)) {
                    $info = $st.Infos[$r.Name]
                } elseif ($r.HasJob) {
                    # Primero el resumen SIN ffprobe, que se vea ya; luego se enriquece.
                    $txtSum.Text = ((@(Get-CvJobSummaryLines -Context $Context -Name $r.Name) + @('', 'Leyendo el archivo para los canales y las lineas...')) -join [Environment]::NewLine)
                    [System.Windows.Forms.Application]::DoEvents()
                    try { $info = Get-MediaInfo -Context $Context -File $r.Path } catch { $info = $null }
                    $st.Infos[$r.Name] = $info
                }
            }
            $cues = $null
            if ($st.Cues.ContainsKey($r.Name)) { $cues = $st.Cues[$r.Name] }
            $txt = ((@(Get-CvJobSummaryLines -Context $Context -Name $r.Name -Info $info -CueCounts $cues)) -join [Environment]::NewLine)
            if ($txt -ne $txtSum.Text) { $txtSum.Text = $txt }
            $miCount.Enabled = ($r.HasJob -and -not $st.Cues.ContainsKey($r.Name))
        } catch {
            $txtSum.Text = ("No se pudo montar el resumen: {0}" -f $_.Exception.Message)
        } finally {
            $st.SumBusy = $false
        }
    }
    $miCopy.Add_Click({
        try { if ("$($txtSum.Text)" -ne '') { [System.Windows.Forms.Clipboard]::SetText($txtSum.Text) } } catch { }
    })
    # Contar las lineas del archivo marcado: lo LENTO, a peticion y una sola vez por archivo.
    $miCount.Add_Click({
        try {
            $r = & $current
            if ($null -eq $r) { return }
            $miCount.Enabled = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                if (-not $st.Infos.ContainsKey($r.Name)) {
                    $txtSum.Text = 'Leyendo el archivo...'
                    [System.Windows.Forms.Application]::DoEvents()
                    $st.Infos[$r.Name] = Get-MediaInfo -Context $Context -File $r.Path
                }
                $info = $st.Infos[$r.Name]
                if ($null -eq $info) { $txtSum.Text = 'No se pudo leer el archivo (ffprobe).'; return }
                $map = @{}
                $subs = @(Get-SubtitleStreams -Info $info)
                for ($i = 0; $i -lt $subs.Count; $i++) {
                    $sub = $subs[$i]
                    $txtSum.Text = ("Contando lineas del subtitulo {0} de {1} (pista {2})..." -f ($i + 1), $subs.Count, $sub.index)
                    [System.Windows.Forms.Application]::DoEvents()
                    $map[[int]$sub.index] = [int](Get-CvSubtitleCueCount -Context $Context -File $r.Path -Index ([int]$sub.index) -Stream $sub)
                }
                $st.Cues[$r.Name] = $map
                & $updateSummary $true
            } finally {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } catch {
            $txtSum.Text = ("No se pudieron contar las lineas: {0}" -f $_.Exception.Message)
        }
    })
    # 'La estas usando': con el raton APRETADO (un Mayus+clic o un arrastre a medias) o durante unos
    # segundos despues de tocarla (gui.queueFollowHoldSec). Mientras, la lista no se mueve sola.
    $tocando = {
        if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None) { return $true }
        if ([double]$st.Touch -le 0) { return $false }
        return (((([datetime]::UtcNow.Ticks - $st.Touch) / 10000000)) -lt [int]$Context.GuiQueueFollowHold)
    }
    $toque = { $st.Touch = [datetime]::UtcNow.Ticks }
    $lv.Add_MouseDown($toque)
    $lv.Add_MouseUp($toque)
    $lv.Add_KeyDown($toque)

    # 'Arrancando': entre que se pulsa Iniciar y el worker publica su estado pasan unos segundos.
    $arrancando = {
        if ([double]$st.StartedAt -le 0) { return $false }
        return (((([datetime]::UtcNow.Ticks - $st.StartedAt) / 10000000)) -lt [int]$Context.GuiQueueStartGrace)
    }

    # ---- Botones: lo que depende de la SELECCION y del estado ya conocido ----
    # No lee el disco: sale de las filas de la ultima vuelta ($st.Rows) y de lo que haya marcado. Va
    # aparte del refresco a proposito -antes estaba dentro, y al dejar la ventana de refrescarse
    # sola el texto de 'Iniciar' no se enteraba de lo que marcabas hasta pulsar Actualizar-.
    $updateButtons = {
        $filas  = @($st.Rows)
        $totals = Get-CvQueueTotals -Rows $filas
        # 'Iniciar' trabaja con lo SELECCIONADO si hay algo en cola marcado; si no, con toda la cola.
        # El texto del boton lo dice, para que no haya sorpresas.
        $selQAll = @(& $selected)
        $selQ = @($selQAll | Where-Object { $_.State -eq 'queued' })
        $btnStart.Text = $(if ($selQ.Count -gt 0) { 'Iniciar ({0} elegidos)' -f $selQ.Count } else { 'Iniciar' })
        # Cuando se puede arrancar (y por que no), en una funcion pura: Get-CvQueueStartState.
        $ss = Get-CvQueueStartState -Queued ([int]$totals.Queued) -Live ([int]$st.Live) `
                                    -Stopping ([bool]$st.Stopping) -JustStarted ([bool](& $arrancando))
        $btnStart.Enabled = [bool]$ss.Enabled
        $tipBar.SetToolTip($btnStart, "$($ss.Tip)")
        $btnStop.Enabled  = ([int]$st.Live -gt 0) -and (-not [bool]$st.Stopping)
        $btnKill.Enabled  = ([int]$st.Live -gt 0)
        # 'Editar job': con una fila elegida vale la suya; sin elegir nada, el primero que este sin
        # preparar. Solo se apaga si no hay ninguno de los dos casos.
        $lote = @((Get-CvQueueBulkActions -Rows $selQAll).Edit)
        $btnEdit.Text     = $(if ($lote.Count -gt 1) { 'Editar los {0} jobs' -f $lote.Count } else { 'Editar job' })
        $btnEdit.Enabled  = (($lote.Count -gt 1) -or ($null -ne (& $editable)))
        # 'Preparar pendientes' lleva el recuento: es el flujo normal cuando llega material nuevo.
        $btnPrepAll.Text    = $(if ([int]$totals.Pending -gt 0) { 'Preparar pendientes ({0})' -f $totals.Pending } else { 'Preparar pendientes' })
        $btnPrepAll.Enabled = ([int]$totals.Pending -gt 0)
    }
    $lv.Add_SelectedIndexChanged({ $st.Touch = [datetime]::UtcNow.Ticks; & $updateSummary $false; & $updateButtons })
    # Al cambiar de pestana se rehace: si se viene del log, ahora si toca el ffprobe.
    [void](Add-CvGuiTabChanged -Tabs $tabs -Action ({ & $updateSummary $true }.GetNewClosure()))

    # Ritmo del temporizador: mientras hay workers -o mientras se espera a los que se acaban de
    # abrir-, el del progreso (gui.queueRefreshMs); sin nada en marcha, lo que diga
    # gui.queueIdleRefreshMs, y con 0 se PARA del todo -la lista se actualiza cuando la pides-.
    # La decision, en una funcion pura: Get-CvQueueTickPlan.
    $ritmo = {
        $plan = Get-CvQueueTickPlan -Live @($st.Workers | Where-Object { $_.Alive }).Count `
                                    -Starting ([bool](& $arrancando)) `
                                    -RefreshMs ([int]$Context.GuiQueueRefreshMs) -IdleMs ([int]$Context.GuiQueueIdleMs)
        if (-not [bool]$plan.Enabled) { $timer.Stop(); return }
        $timer.Interval = [int]$plan.Interval
        if (-not $timer.Enabled) { $timer.Start() }
    }

    # ---- Seguir con la lista al archivo que se esta codificando ----
    # Si la fila en curso se sale de la zona visible, la lista se mueve para dejarla a la vista; si
    # te has ido tu a mirar otra parte, se calla (Get-CvQueueFollowPlan). Cuantas filas caben se
    # MIDE de la propia lista: el alto de fila y el de la cabecera cambian con la fuente y el DPI.
    $followRow = {
        # El resumen de la fila marcada llama a DoEvents mientras lee el archivo, y el temporizador
        # entra AHI. Mover la lista en ese momento es moverla a mitad de tu clic: ni tocarla.
        if ($st.SumBusy) { return }
        if ($lv.Items.Count -eq 0) { $st.LastTop = -1; return }
        $rango = Get-CvQueueWorkingRange -Rows @($st.Rows)
        $idx   = [int]$rango.First
        $top   = -1
        try { if ($null -ne $lv.TopItem) { $top = [int]$lv.TopItem.Index } } catch { $top = -1 }
        if ($top -lt 0 -or $top -ge $lv.Items.Count) { $st.LastTop = -1; return }
        # Que la fila en curso SE VEA se mira en su rectangulo de verdad (el de la cabecera marca
        # donde empieza la zona util). Sin medidas todavia -la ventana aun colocandose- no se decide
        # nada: se vuelve a mirar en la proxima vuelta, que es mejor que apuntar una mentira.
        $b    = $lv.Items[$top].Bounds
        if ([int]$b.Height -le 0) { return }
        $seVe = $false
        if ($idx -ge 0 -and $idx -lt $lv.Items.Count) {
            $rb = $lv.Items[$idx].Bounds
            $seVe = ([int]$rb.Height -gt 0 -and [int]$rb.Top -ge [int]$b.Top -and [int]$rb.Bottom -le [int]$lv.ClientSize.Height)
        }
        $plan = Get-CvQueueFollowPlan -HasRow ($idx -ge 0) -Visible $seVe -Moved ([int]$st.LastTop -ge 0 -and $top -ne [int]$st.LastTop) `
                                      -Following ([bool]$st.Follow) -Changed ("$($rango.Key)" -ne "$($st.FollowKey)") `
                                      -Busy ([bool](& $tocando)) -Enabled ([bool]$Context.GuiQueueFollow)
        if ([bool]$plan.Hold) { return }   # la estas usando: se vuelve a mirar cuando la sueltes
        $st.Follow    = [bool]$plan.Follow
        $st.FollowKey = "$($rango.Key)"
        if ([bool]$plan.Scroll -and $idx -ge 0 -and $idx -lt $lv.Items.Count) {
            # Primero la ULTIMA en curso y luego la primera: con varios workers se ve el bloque
            # entero si cabe, y si no cabe manda la primera (que es la que lleva mas rato).
            $fin = [int]$rango.Last
            if ($fin -ge 0 -and $fin -lt $lv.Items.Count) { $lv.Items[$fin].EnsureVisible() }
            $lv.Items[$idx].EnsureVisible()
        }
        try { $st.LastTop = $(if ($null -ne $lv.TopItem) { [int]$lv.TopItem.Index } else { -1 }) } catch { $st.LastTop = -1 }
    }

    # ---- Refresco (lo dispara el temporizador y el boton Actualizar) ----
    $refresh = {
        # Deducir los bordes de un archivo ya convertido cuesta dos ffprobe (~300 ms medidos), asi que
        # solo se hace con la cola PARADA: mientras hay workers el refresco tiene que seguir siendo
        # barato -la lista dejaba de responder por mucho menos- y ademas el disco esta ocupado. Se
        # mira el recuento de la vuelta ANTERIOR, que para esto vale y no cuesta nada.
        $probe = Get-CvQueueDoneProbeBudget -Configured $Context.GuiQueueDoneProbe -LiveWorkers @($st.Workers | Where-Object { $_.Alive }).Count
        $rows    = @(Get-CvQueueStatus -Context $Context -DoneProbe $probe -DoneTolerance $Context.GuiQueueDoneTol)
        $workers = @(Get-CvWorkerStates -Context $Context)
        $live    = @($workers | Where-Object { $_.Alive })
        # Un listado de Original\ que sale VACIO teniendo archivos a la vista es casi siempre un
        # tropiezo, no una carpeta vacia (ver Test-CvQueueKeepRows): se mira la carpeta de otra forma
        # -sin filtros ni FileInfo- y, si sigue habiendo ficheros, se deja la ventana como estaba.
        if (@($rows).Count -eq 0 -and $lv.Items.Count -gt 0) {
            $existe = $false
            $reales = 0
            try {
                $dirOrig = "$($Context.Original)"
                $existe = [System.IO.Directory]::Exists($dirOrig)
                if ($existe) { $reales = @([System.IO.Directory]::EnumerateFiles($dirOrig)).Count }
            } catch { $existe = $true; $reales = 1 }   # si ni eso se puede mirar, mejor no tocar nada
            if (Test-CvQueueKeepRows -Rows 0 -Items $lv.Items.Count -DirExists $existe -RealFiles $reales) {
                $st.Vacios++
                Write-CvLog 'COLA' ("[AVISO] - Original se ha listado vacia teniendo {0} fichero(s); se conserva lo que hay y se reintenta ({1} vez/veces seguidas)." -f $reales, $st.Vacios)
                return
            }
            $st.Vacios = 0
        } else {
            $st.Vacios = 0
        }
        $st.Rows    = $rows
        $st.Workers = $workers

        # Reconstruir la lista SOLO si cambio el conjunto de archivos; si no, actualizar las celdas en
        # su sitio (si no, la lista parpadea y se pierde la seleccion cada segundo).
        $names = (@($rows | ForEach-Object { $_.Name }) -join '|')
        $lv.BeginUpdate()
        try {
            if ($names -ne $st.Names) {
                # Se montan TODAS las filas primero y solo despues se toca la lista: si el formateo de
                # una fila falla, la lista se queda como estaba en vez de vaciarse. Antes se limpiaba
                # y se iban anadiendo, asi que un fallo a mitad dejaba la tabla EN BLANCO -y como el
                # nombre de la tanda no llegaba a apuntarse, el refresco siguiente repetia el destrozo.
                $nuevos = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
                foreach ($r in $rows) {
                    $cells = @(Format-CvQueueRow -Row $r)
                    if (@($cells).Count -eq 0) { $cells = @("$($r.Name)") }
                    $it = New-Object System.Windows.Forms.ListViewItem("$($cells[0])")
                    for ($i = 1; $i -lt $cells.Count; $i++) { [void]$it.SubItems.Add("$($cells[$i])") }
                    $nuevos.Add($it)
                }
                $lv.Items.Clear()
                $lv.Items.AddRange($nuevos.ToArray())
                $st.Names = $names
                $st.LastTop = -1   # la lista vuelve arriba sola: no cuenta como scroll tuyo
            } else {
                for ($k = 0; $k -lt $rows.Count -and $k -lt $lv.Items.Count; $k++) {
                    $cells = @(Format-CvQueueRow -Row $rows[$k])
                    $it = $lv.Items[$k]
                    for ($i = 0; $i -lt $cells.Count; $i++) {
                        if ($it.SubItems[$i].Text -ne $cells[$i]) { $it.SubItems[$i].Text = $cells[$i] }
                    }
                }
            }
        } finally { $lv.EndUpdate() }

        # El resumen se rehace SOLO si ha cambiado algo (su huella): recien preparado, editado o
        # terminado. Forzarlo en cada refresco disparaba un ffprobe por segundo sobre el archivo
        # marcado y dejaba la ventana sin responder mientras se codificaba.
        & $updateSummary $false

        $stopping = Test-CvWorkerStop -Context $Context
        $st.Stopping = $stopping
        $st.Running  = ($live.Count -gt 0)
        $st.Live     = $live.Count
        # La bandera de parada la retira la ventana cuando ya no queda ningun worker: asi no se queda
        # puesta y mata la siguiente ejecucion sin que se sepa por que.
        if ($stopping -and $live.Count -eq 0) { Clear-CvWorkerStop -Context $Context; $stopping = $false; $st.Stopping = $false }
        $lblTot.Text = Get-CvQueueSummaryLine -Totals (Get-CvQueueTotals -Rows $rows) -Workers $live.Count -Stopping $stopping

        # El plazo de gracia del arranque se acaba en cuanto se ve el primer worker.
        if ($live.Count -gt 0) { $st.StartedAt = 0 }
        & $updateButtons

        # Selector de logs: se rehace solo si cambio la lista (mantiene la eleccion del usuario).
        $choices = @(Get-CvConvertLogChoices -Context $Context -Workers $workers)
        $txts    = @($choices | ForEach-Object { $_.Text })
        if ((@($cmbLog.Items) -join '|') -ne ($txts -join '|')) {
            $keep = "$($st.LogPath)"
            $cmbLog.Items.Clear()
            foreach ($t in $txts) { [void]$cmbLog.Items.Add($t) }
            $idx = 0
            for ($i = 0; $i -lt $choices.Count; $i++) { if ($choices[$i].Path -eq $keep) { $idx = $i } }
            if ($cmbLog.Items.Count -gt 0) { $cmbLog.SelectedIndex = $idx }
        }
        $sel = $cmbLog.SelectedIndex
        if ($sel -ge 0 -and $sel -lt $choices.Count) { $st.LogPath = $choices[$sel].Path }

        if ($chkFollow.Checked -and $st.LogPath) {
            [void](Update-CvGuiLogView -TextBox $txtLog -State $st -Path "$($st.LogPath)")
        }

        $st.LiveSig = Get-CvWorkerSignature -Workers $live
        & $followRow
        & $ritmo
    }

    # ---- Refresco LIGERO: lo unico que se mueve solo ----
    # Releer las tres carpetas cada segundo no tiene sentido -la lista de archivos no cambia sola- y
    # ademas se hace justo cuando el disco esta ocupado codificando. Asi que mientras hay workers
    # solo se lee lo que ELLOS publican (Proceso\*.worker.json) y se repintan sus filas. La lista se
    # relee cuando cambia algo de verdad: un worker coge otro archivo, termina o se muere (la huella
    # cambia), o cuando lo pides tu (Actualizar), o al volver a la ventana.
    $refreshLive = {
        $workers = @(Get-CvWorkerStates -Context $Context)
        $live    = @($workers | Where-Object { $_.Alive })
        $sig     = Get-CvWorkerSignature -Workers $live
        if ($sig -ne $st.LiveSig) { & $refresh; return }   # algo cambio de estado: relectura completa
        $st.Workers = $workers
        $st.Live    = $live.Count
        & $updateButtons
        # Solo las filas que estan codificando: se les mete el avance publicado y se repintan.
        $porArchivo = @{}
        foreach ($w in $live) { if ("$($w.File)" -ne '') { $porArchivo["$($w.File)"] = $w } }
        $lv.BeginUpdate()
        try {
            for ($k = 0; $k -lt @($st.Rows).Count -and $k -lt $lv.Items.Count; $k++) {
                $r = @($st.Rows)[$k]
                $w = $porArchivo["$($r.Name)"]
                if ($null -eq $w) { continue }
                $r.WorkerPid = [int]$w.Pid
                $r.Step      = "$($w.Step)"
                $r.Percent   = [int]$w.Percent
                $r.Eta       = "$($w.Eta)"
                $r.Speed     = "$($w.Speed)"
                $cells = @(Format-CvQueueRow -Row $r)
                $it = $lv.Items[$k]
                for ($i = 0; $i -lt $cells.Count; $i++) {
                    if ($it.SubItems[$i].Text -ne $cells[$i]) { $it.SubItems[$i].Text = $cells[$i] }
                }
            }
        } finally { $lv.EndUpdate() }
        # El log que se sigue si se va escribiendo (eso tambien se mueve solo).
        if ($chkFollow.Checked -and $st.LogPath) {
            [void](Update-CvGuiLogView -TextBox $txtLog -State $st -Path "$($st.LogPath)")
        }
        & $followRow
        & $ritmo
    }

    # ---- Acciones ----
    # Abre los workers. -Only vacio = toda la cola; con nombres, SOLO esos (van como -Only). Lo usan
    # el boton 'Iniciar' y la opcion 'Codificar solo estos' del menu contextual: una sola rutina.
    $startWorkers = {
        param($Only)
        $only = @($Only)
        $ready = Test-CvConvertReady -Context $Context
        if (-not $ready.Ok) {
            Show-CvGuiInfo -Title 'No se puede empezar' -Message ("No se pueden lanzar workers: {0}" -f $ready.Reason)
            return
        }
        $rows = @(Get-CvQueueStatus -Context $Context)
        $pend = $(if ($only.Count -gt 0) { $only.Count } else { @($rows | Where-Object { $_.State -eq 'queued' }).Count })
        if ($pend -le 0) {
            Show-CvGuiInfo -Title 'Nada que codificar' -Message 'No hay archivos preparados. Usa "Preparar pendientes" para contestar las preguntas de los que faltan.'
            return
        }
        # Los elegidos viajan en la LINEA DE COMANDOS del worker, y lo que no cabe se pierde sin
        # avisar (Windows corta en 32767): mejor decirlo antes de abrir nada.
        $cabe = Test-CvWorkerOnlyFits -Argv (Get-CvConvertWorkerArgs -Root $Root -CfgPath $CfgPath -Only $only)
        if (-not [bool]$cabe.Ok) {
            Show-CvGuiInfo -Title 'Demasiados a la vez' -Message ("Has elegido {0} archivo(s) y sus nombres no caben en la orden con la que se abre un worker ({1} caracteres, el limite es {2}). Hazlo en dos tandas, o usa 'toda la cola' (sin elegir nada)." -f $only.Count, $cabe.Length, $cabe.Max)
            return
        }
        Clear-CvWorkerStop -Context $Context
        # Ni un worker mas que archivos por codificar: ventanas de sobra solo se abren para cerrarse.
        $n = [Math]::Min([int]$numW.Value, $pend)
        # El boton se apaga AQUI, no en el proximo refresco: entre que el worker nace y publica su
        # estado pasan unos segundos, y es justo cuando es facil volver a pulsar sin querer.
        $st.StartedAt = [datetime]::UtcNow.Ticks
        $btnStart.Enabled = $false
        for ($i = 0; $i -lt $n; $i++) {
            [void](Start-CvConvertWorker -Root $Root -CfgPath $CfgPath -Only $only -ShowConsole:$chkCon.Checked)
        }
        if ($only.Count -gt 0) {
            Write-CvLog 'COLA' ("[WORKER] - Abiertos {0} worker(s) SOLO para {1} archivo(s) elegido(s): {2}" -f $n, $only.Count, (($only | Select-Object -First 8) -join ', '))
        } else {
            Write-CvLog 'COLA' ("[WORKER] - Abiertos {0} worker(s) para {1} archivo(s) en cola." -f $n, $pend)
        }
        & $refresh
    }

    $btnStart.Add_Click({
        # Con filas EN COLA marcadas el boton codifica SOLO esas... pero marcar una fila es tambien
        # como se lee su resumen, asi que antes se pregunta (Get-CvQueueStartScope) en vez de dar por
        # hecho que la seleccion era una orden.
        $sel = @(@(& $selected) | Where-Object { $_.State -eq 'queued' } | ForEach-Object { $_.Name })
        $tot = @(@($st.Rows) | Where-Object { $_.State -eq 'queued' }).Count
        $sc  = Get-CvQueueStartScope -Selected $sel.Count -Total $tot
        if ([bool]$sc.Ask) {
            $pick = Show-CvGuiChoice -Title 'Iniciar' -Name 'cvStartAsk' -Message "$($sc.Message)" -Options $sc.Options
            switch ("$pick") {
                'sel'   { & $startWorkers $sel }
                'all'   { & $startWorkers @() }
                default { }   # 'cancel' o cerrar con la X: no se arranca nada
            }
            return
        }
        & $startWorkers $sel
    })

    $btnStop.Add_Click({
        [void](Set-CvWorkerStop -Context $Context)
        Write-CvLog 'COLA' '[STOP] - Parada pedida: cada worker terminara el archivo que tenga y no cogera mas.'
        & $refresh
    })

    $btnKill.Add_Click({
        $live = @(Get-CvWorkerStates -Context $Context | Where-Object { $_.Alive })
        if ($live.Count -eq 0) { return }
        $msg = "Cortar en seco {0} worker(s)?`n`nSe pierde lo que lleven del archivo en curso y quedaran temporales y un bloqueo caducado (se limpian desde setup).`n`nPara parar SIN perder nada, usa 'Parar'." -f $live.Count
        if (-not (Show-CvGuiConfirm -Title 'Cancelar ahora' -Message $msg)) { return }
        foreach ($w in $live) { [void](Stop-CvConvertWorker -ProcessId ([int]$w.Pid)) }
        Write-CvLog 'COLA' ("[KILL] - Cortados {0} worker(s) a peticion del usuario." -f $live.Count)
        & $refresh
    })

    # Las carpetas de trabajo, tal cual estan configuradas (paths.* del config): se abren en el
    # explorador. Utiles cuando hay que mirar algo a mano -una salida a medias, un archivo nuevo-.
    $btnDirIn.Add_Click({  [void](Open-CvGuiPath -Path "$($Context.Original)"   -Folder -Create -Title 'Carpeta') })
    $btnDirOut.Add_Click({ [void](Open-CvGuiPath -Path "$($Context.Convertido)" -Folder -Create -Title 'Carpeta') })

    # Cambiar de claro a oscuro y al reves sin salir del programa. Se aplica a la ventana abierta y
    # se GUARDA en el config (gui.theme), asi que la proxima vez arranca como lo dejaste; el resto de
    # ventanas lo cogen al abrirse. Si no se puede escribir el config, se avisa pero el cambio se ve.
    $btnTheme.Add_Click({
        $nuevo = $(if ((Get-CvGuiThemeName) -eq 'dark') { 'light' } else { 'dark' })
        [void](Set-CvGuiTheme -Form $form -Theme $nuevo)
        $form.Refresh()
        if ("$CfgPath" -ne '') {
            $r = Set-CvConfigValue -Path $CfgPath -Key 'gui/theme' -Value $nuevo
            if (-not $r.Ok) { Show-CvGuiInfo -Title 'Tema' -Message ("Se ha cambiado el tema, pero no se pudo guardar en {0}:`n`n{1}" -f $CfgName, $r.Error) }
        }
    })

    $btnRefresh.Add_Click($refresh)
    # Al volver a la ventana se releen las carpetas: recoge lo que hayas dejado en Original\ mientras
    # estabas en otra cosa (gui.queueRefreshOnActivate). Sin workers el temporizador esta parado, asi
    # que este es el momento natural para mirar.
    $form.Add_Activated({
        if (-not [bool]$Context.GuiQueueOnActivate) { return }
        if ($st.Busy) { return }
        $st.Busy = $true
        try { & $refresh } catch { Write-CvLog 'COLA' ("[ERROR] - Refresco al volver: {0}" -f $_) } finally { $st.Busy = $false }
    })
    $cmbLog.Add_SelectedIndexChanged({ $txtLog.Text = ''; $st.LogStamp = '' })   # el refresco lo recarga
    $btnLogOpen.Add_Click({ [void](Open-CvGuiPath -Path "$($st.LogPath)" -Title 'Log') })

    $menu.Add_Opening({
        $r   = & $current
        $sel = @(& $selected)
        # El job se puede editar mientras NADIE lo este codificando: a mitad de conversion el worker
        # ya trabaja con la copia que leyo, y cambiarlo solo confundiria. Editar/ver/abrir son de UNO
        # (van sobre el primero marcado); liberar y quitar van sobre TODOS los marcados que apliquen.
        $miEdit.Enabled = ($null -ne $r -and $r.State -in @('pending', 'queued', 'stale'))
        $miJob.Enabled  = ($null -ne $r -and $r.HasJob)
        $miOut.Enabled  = ($null -ne $r)
        # Reproducir: el original siempre esta; el convertido, solo cuando ya hay algo escrito
        # (tambien si quedo a medias o se esta codificando: mirar como va saliendo es justo para lo
        # que sirve). Se mira el fichero de verdad, no solo el estado.
        $hayOut = ($null -ne $r -and (Test-Path -LiteralPath "$($r.OutPath)"))
        $miPlayIn.Enabled  = ($null -ne $r)
        $miPlayOut.Enabled = $hayOut
        # El aviso de 'a medio hacer' solo cuando de verdad hay algo escrito y se sigue escribiendo:
        # si no, seria una promesa de algo que todavia no existe.
        $miPlayOut.Text    = $(if ($hayOut -and $r.State -in @('working', 'partial')) { 'Reproducir el CONVERTIDO (a medio hacer)' } else { 'Reproducir el CONVERTIDO' })
        $bulk = Get-CvQueueBulkActions -Rows $sel
        # 'Codificar solo estos' no aparece durante una parada pedida: nadie va a coger nada.
        # Misma regla que el boton: con workers en marcha no se abren mas (ellos cogeran lo que haya).
        $miStart.Enabled = ((@($bulk.Start).Count -gt 0) -and (-not $st.Stopping) -and (-not $st.Running))
        # Cortar SOLO lo elegido: mata el worker de ese archivo y deja los demas trabajando.
        $miKill.Enabled  = (@($bulk.Kill).Count -gt 0)
        $miKill.Text     = $bulk.KillText
        # Una sola entrada que se adapta: en marcha ensena el log VIVO de su worker; ya terminado
        # (o a medias), el trozo de log donde se convirtio. En lo demas no hay nada que ensenar.
        $miWorkerLog.Enabled = ($null -ne $r -and ([int]$r.WorkerPid -gt 0 -or $r.State -in @('done', 'partial')))
        $miWorkerLog.Text    = $(if ($null -ne $r -and [int]$r.WorkerPid -gt 0) { 'Ver lo que esta haciendo (log del worker)' } else { 'Ver el proceso de este archivo (log)' })
        $miStart.Text    = $bulk.StartText
        $miFree.Enabled  = (@($bulk.Free).Count  -gt 0)
        $miDrop.Enabled  = (@($bulk.Drop).Count  -gt 0)
        $miPurge.Enabled = (@($bulk.Purge).Count -gt 0)
        $miFree.Text     = $bulk.FreeText
        $miDrop.Text     = $bulk.DropText
        $miPurge.Text    = $bulk.PurgeText
        # Editar en bloque: cambia lo MISMO en varios jobs y deja intacto lo que es de cada archivo.
        $miBulk.Enabled  = (@($bulk.Edit).Count -gt 0)
        $miBulk.Text     = $bulk.EditText
    })
    # Editor del job en ventana (GuiJob): crea el job de un archivo sin preparar o retoca el que ya
    # tiene. Al volver se refresca: un 'sin preparar' pasa a 'en cola' sin tener que tocar nada mas.
    $openEditor = {
        # Con varias filas marcadas que tengan job, se editan TODAS a la vez (solo lo que marques en
        # el dialogo); con una, el editor de siempre.
        $lote = @((Get-CvQueueBulkActions -Rows (& $selected)).Edit)
        if ($lote.Count -gt 1) {
            $cambio = Show-CvJobBulkWindow -Context $Context -Names @($lote | ForEach-Object { $_.Name })
            if ($cambio) { $st.Infos = @{} }   # el resumen se rehace: el job ya no dice lo mismo
            & $refresh
            return
        }
        $r = & $editable
        if ($null -eq $r) { return }
        [void](Show-CvJobWindow -Context $Context -Name $r.Name -File $r.Path)
        & $refresh
    }
    $miBulk.Add_Click({
        $lote = @((Get-CvQueueBulkActions -Rows (& $selected)).Edit)
        if ($lote.Count -le 1) { return }
        $cambio = Show-CvJobBulkWindow -Context $Context -Names @($lote | ForEach-Object { $_.Name })
        if ($cambio) { $st.Infos = @{} }
        & $refresh
    })
    $miStart.Add_Click({
        $rows = @((Get-CvQueueBulkActions -Rows (& $selected)).Start)
        if ($rows.Count -eq 0) { return }
        & $startWorkers @($rows | ForEach-Object { $_.Name })
    })
    # Ver lo que esta haciendo un worker, BAJO PETICION: doble clic en una fila que se este
    # codificando (en las demas, el doble clic sigue abriendo el editor del job) o el menu contextual.
    $openWorkerLog = {
        $r = & $current
        if ($null -eq $r) { return }
        if ([int]$r.WorkerPid -gt 0) {
            # EN MARCHA: el log vivo de su worker.
            $wpid = [int]$r.WorkerPid
            $w = @(@($st.Workers) | Where-Object { [int]$_.Pid -eq $wpid })
            $lp = $(if ($w.Count -gt 0) { "$($w[0].Log)" } else { '' })
            [void](Show-CvWorkerLogWindow -Context $Context -WorkerPid $wpid -LogPath $lp -File "$($r.Name)")
            & $refresh
            return
        }
        if ($r.State -notin @('done', 'partial')) { return }
        # YA TERMINADO: se busca en los logs el trozo de ESE archivo (buscar puede tardar un poco si
        # hay logs grandes, asi que se avisa con el cursor).
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $hit = $null
        try { $hit = Find-CvFileLog -Context $Context -Name "$($r.Name)" } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        [void](Show-CvWorkerLogWindow -Context $Context -File "$($r.Name)" `
            -LogPath $(if ($null -ne $hit) { "$($hit.Path)" } else { '' }) `
            -Text $(if ($null -ne $hit -and [bool]$hit.Found) { "$($hit.Text)" } else { ' ' }))
    }
    $miWorkerLog.Add_Click($openWorkerLog)
    $miEdit.Add_Click($openEditor)
    $btnEdit.Add_Click($openEditor)
    # En una fila que se esta codificando, el doble clic ensena lo que hace su worker; en el resto,
    # abre el editor del job (que es lo que se quiere hacer con un archivo que no esta en marcha).
    $lv.Add_DoubleClick({
        $r = & $current
        if ($null -ne $r -and ([int]$r.WorkerPid -gt 0 -or $r.State -in @('done', 'partial'))) { & $openWorkerLog }
        else { & $openEditor }
    })

    # Preparar TODOS los pendientes de una tacada, como la consola: pregunta el perfil una vez y va
    # archivo por archivo; solo se para donde la consola tambien se pararia.
    $btnPrepAll.Add_Click({
        $pend = @(@($st.Rows) | Where-Object { $_.State -eq 'pending' } | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Path = $_.Path
            }
        })
        if ($pend.Count -eq 0) { return }
        [void](Show-CvPrepareWindow -Context $Context -Files $pend)
        & $refresh
    })
    $miJob.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        $p = Get-CvJobPath $Context $r.Name
        $txt = try { Get-Content -Raw -LiteralPath $p } catch { "(no se pudo leer el job: $_)" }
        [void](Show-CvTextWindow -Title ("Job de {0}" -f $r.Name) -Text "$txt")
    })
    # Ver el archivo: con lo que diga preview.player (por defecto, el reproductor asociado de
    # Windows). NO se espera a que se cierre -si no, la cola se quedaria congelada mientras se ve una
    # pelicula-, asi que la ventana sigue refrescandose con el reproductor abierto al lado.
    $play = {
        param([string]$Path, [string]$Que)
        if ("$Path" -eq '') { return }
        $res = Start-CvVideoPlayer -Context $Context -File $Path
        if (-not $res.Ok) {
            Show-CvGuiInfo -Title 'Reproducir' -Message ("No se pudo abrir el {0}:`n`n{1}`n`n{2}" -f $Que, $Path, $res.Error)
        }
    }
    $miPlayIn.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        & $play "$($r.Path)" 'original'
    })
    $miPlayOut.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        & $play "$($r.OutPath)" 'convertido'
    })
    $miOut.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        $sel = if ($r.Done) { $r.OutPath } else { $r.Path }
        [void](Open-CvGuiPath -Path $sel -Select -Title 'Carpeta')
    })
    $miKill.Add_Click({
        # Corta la codificacion de UN archivo (o de los que se hayan marcado): se mata SU worker -y
        # con el su ffmpeg-, no todos. El resto de workers sigue a lo suyo. Lo que queda es lo mismo
        # que con 'Cancelar ahora': la salida a medias y un bloqueo caducado, que se limpian desde
        # aqui mismo ('Eliminar la salida a medias' / 'Liberar el bloqueo').
        $rows = @((Get-CvQueueBulkActions -Rows (& $selected)).Kill)
        if ($rows.Count -eq 0) { return }
        $msg = "Cortar la codificacion de {0} archivo(s)?`n`n{1}`n`nSe pierde lo que lleven (queda la salida a medias y un bloqueo caducado). Los demas workers siguen." -f `
            $rows.Count, ((@($rows | Select-Object -First 12 | ForEach-Object { $_.Name }) -join "`n") + $(if ($rows.Count -gt 12) { "`n..." } else { '' }))
        if (-not (Show-CvGuiConfirm -Title 'Cortar la codificacion' -Message $msg)) { return }
        $n = 0
        foreach ($r in $rows) {
            if (Stop-CvConvertWorker -ProcessId ([int]$r.WorkerPid)) { $n++ }
            Write-CvLog 'COLA' ("[KILL] - Cortada la codificacion de {0} (worker #{1})." -f $r.Name, $r.WorkerPid)
        }
        & $refresh
    })
    $miPurge.Add_Click({
        # Borra el fichero de salida a medias para que el worker vuelva a hacerlo: mientras este ahi,
        # lo salta (da por hecho que ya esta convertido).
        $rows = @((Get-CvQueueBulkActions -Rows (& $selected)).Purge)
        if ($rows.Count -eq 0) { return }
        $msg = "Eliminar la salida a medias de {0} archivo(s)?`n`n{1}`n`nSon conversiones que no terminaron. Al borrarlas vuelven a la cola y se rehacen." -f `
            $rows.Count, ((@($rows | Select-Object -First 12 | ForEach-Object { $_.Name }) -join "`n") + $(if ($rows.Count -gt 12) { "`n..." } else { '' }))
        if (-not (Show-CvGuiConfirm -Title 'Eliminar salida a medias' -Message $msg)) { return }
        $n = Remove-CvQueueOutput -Context $Context -Names @($rows | ForEach-Object { $_.Name })
        Write-CvLog 'COLA' ("[SALIDA] - Eliminada(s) {0} salida(s) a medias; vuelven a la cola." -f $n)
        & $refresh
    })
    $miFree.Add_Click({
        $rows = @((Get-CvQueueBulkActions -Rows (& $selected)).Free)
        if ($rows.Count -eq 0) { return }
        foreach ($r in $rows) {
            Exit-Lock -Context $Context -Name $r.Name
            Write-CvLog 'COLA' ("[LOCK] - Liberado el bloqueo huerfano de {0}." -f $r.Name)
        }
        & $refresh
    })
    $miDrop.Add_Click({
        $rows = @((Get-CvQueueBulkActions -Rows (& $selected)).Drop)
        if ($rows.Count -eq 0) { return }
        $msg = if ($rows.Count -eq 1) {
            "Borrar el job de {0}?`n`nDeja de estar en cola y habra que volver a prepararlo." -f $rows[0].Name
        } else {
            "Borrar los jobs de {0} archivos?`n`n{1}`n`nDejan de estar en cola y habra que volver a prepararlos." -f `
                $rows.Count, ((@($rows | Select-Object -First 12 | ForEach-Object { $_.Name }) -join "`n") + $(if ($rows.Count -gt 12) { "`n..." } else { '' }))
        }
        if (-not (Show-CvGuiConfirm -Title 'Quitar de la cola' -Message $msg)) { return }
        foreach ($r in $rows) { Remove-CvJob -Context $Context -Name $r.Name }
        Write-CvLog 'COLA' ("[JOB] - Quitados {0} job(s) de la cola." -f $rows.Count)
        & $refresh
    })

    # Un segundo mientras hay trabajo es suficiente para que se note vivo y no cuesta nada (los datos
    # salen de ficheros pequenos, sin ffprobe); parado baja a 3 s. -Busy evita solaparse si un
    # refresco tarda mas de un tick.
    $timer.Add_Tick({
        if ($st.Busy) { return }
        $st.Busy = $true
        # Si el refresco falla, se apunta en el log: tragarselo en silencio deja la ventana a medias
        # (la lista de una vuelta y los totales de otra) sin nada que mirar despues.
        # El temporizador hace el refresco LIGERO; ese decide si hace falta el completo.
        try { & $refreshLive } catch { Write-CvLog 'COLA' ("[ERROR] - Refresco: {0}" -f $_) } finally { $st.Busy = $false }
    })

    # La columna de progreso ocupa lo que sobre: al abrir, al redimensionar la ventana y al cambiar
    # el ancho de otra columna a mano.
    $fitCols = {
        if ($lv.Columns.Count -le $iProg) { return }
        $others = 0
        for ($i = 0; $i -lt $lv.Columns.Count; $i++) { if ($i -ne $iProg) { $others += $lv.Columns[$i].Width } }
        $w = Get-CvQueueProgressWidth -ClientWidth $lv.ClientSize.Width -OtherWidths $others
        if ($lv.Columns[$iProg].Width -ne $w) { $lv.Columns[$iProg].Width = $w }
    }
    $lv.Add_Resize($fitCols)

    $form.Add_Shown({
        # Lo ya deducido en otras sesiones (bordes de los archivos convertidos): asi la columna sale
        # rellena de entrada en vez de volver a sondear lo mismo cada vez que se abre la ventana.
        if ([int]$Context.GuiQueueDoneProbe -gt 0) { [void](Import-CvDoneBorderCache -Context $Context) }

        # Fantasmas: ficheros de estado de workers que ya no existen. No estorban para nada salvo
        # que se releen en CADA refresco (y ahi si: diez fantasmas eran casi medio segundo por
        # vuelta). Se barren al abrir, que es cuando no molesta.
        try {
            $muertos = @(Get-CvWorkerStates -Context $Context | Where-Object { -not $_.Alive })
            if ($muertos.Count -gt 0) {
                $n = Remove-CvWorkerStates -States $muertos
                if ($n -gt 0) { Write-CvLog 'COLA' ("[LIMPIEZA] - Retirados {0} estado(s) de workers que ya no existen." -f $n) }
            }
        } catch { }

        # Reparto del alto: donde se dejo el divisor la ultima vez y, si no hay nada apuntado, el
        # gui.queueSplitPercent de la config (algo mas de la mitad para la cola). Va aqui y no al
        # crear el control: SplitterDistance necesita que la ventana tenga ya su tamano real.
        try {
            $split.Panel1MinSize = 120
            $split.Panel2MinSize = 140
            $split.SplitterDistance = Resolve-CvGuiSplitDistance -Height $split.Height `
                -Percent ([int]$Context.GuiQueueSplit) `
                -Saved ([int](Get-CvGuiLayoutValue -Layout $lay -Name 'split' -Default 0)) `
                -Min1 $split.Panel1MinSize -Min2 $split.Panel2MinSize -SplitterWidth $split.SplitterWidth
        } catch {}
        # Anchos de columna recordados (la de progreso no: se estira sola, ver $fitCols).
        try {
            $cw = @(Get-CvGuiLayoutValue -Layout $lay -Name 'cols' -Default @())
            if ($cw.Count -eq $lv.Columns.Count) {
                for ($i = 0; $i -lt $cw.Count; $i++) {
                    $n = 0
                    if ($i -ne $iProg -and [int]::TryParse("$($cw[$i])", [ref]$n) -and $n -ge 20 -and $n -le 2000) {
                        $lv.Columns[$i].Width = $n
                    }
                }
            }
        } catch {}
        & $refresh
        & $fitCols
        $timer.Start()
    })
    $form.Add_FormClosing({
        param($sender, $e)
        # Cerrar la ventana NO para nada: los workers son procesos aparte (Start-Process) y siguen
        # codificando, ocultos, aunque aqui ya no haya nada. Con gui.confirmCloseWithWorkers se
        # pregunta que hacer; es el equivalente de behavior.lockCloseButton en consola. Cualquier
        # fallo aqui NO puede impedir cerrar: se traga y se cierra.
        try {
            if ([bool]$Context.GuiConfirmClose) {
                $liveW = @(Get-CvWorkerStates -Context $Context | Where-Object { $_.Alive })
                if ($liveW.Count -gt 0) {
                    $pick = Show-CvGuiChoice -Title 'Cerrar la cola' -Name 'cvCloseAsk' `
                        -Message (Get-CvQueueCloseMessage -Workers $liveW.Count) `
                        -Options (Get-CvQueueCloseActions)
                    switch ($pick) {
                        'background' {
                            Write-CvLog 'COLA' ("[CERRAR] - Ventana cerrada con {0} worker(s) siguiendo en segundo plano." -f $liveW.Count)
                        }
                        'stop' {
                            [void](Set-CvWorkerStop -Context $Context)
                            Write-CvLog 'COLA' ("[CERRAR] - Parada pedida al cerrar: {0} worker(s) terminaran su archivo y saldran." -f $liveW.Count)
                        }
                        'kill' {
                            foreach ($w in $liveW) { [void](Stop-CvConvertWorker -ProcessId ([int]$w.Pid)) }
                            Write-CvLog 'COLA' ("[CERRAR] - Cortados {0} worker(s) al cerrar la ventana." -f $liveW.Count)
                        }
                        default {
                            # 'cancel' o cerrar el aviso con la X: no se cierra (lo seguro).
                            $e.Cancel = $true
                        }
                    }
                }
            }
        } catch { }
        if ($e.Cancel) { return }
        $timer.Stop()
        # Se apunta como queda para abrirla igual la proxima vez (config gui.rememberLayout). Si esta
        # maximizada o minimizada, el tamano bueno es el de RestoreBounds, no el de la ventana.
        if ([bool]$Context.GuiRemember) {
            try {
                $max = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
                $rb  = if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) { $form.Bounds } else { $form.RestoreBounds }
                $cw  = @()
                foreach ($c in $lv.Columns) { $cw += [int]$c.Width }
                [void](Save-CvGuiLayout -Context $Context -Key 'cola' -Layout ([ordered]@{
                    width     = [int]$rb.Width
                    height    = [int]$rb.Height
                    maximized = $max
                    split     = [int]$split.SplitterDistance
                    cols      = $cw
                }))
            } catch { }
        }
        # Y lo deducido de los bordes, para no volver a sondear lo mismo la proxima vez. Al guardarlo
        # se tiran las entradas de archivos que ya no estan (borrados, renombrados o movidos).
        if ([int]$Context.GuiQueueDoneProbe -gt 0) { [void](Save-CvDoneBorderCache -Context $Context) }
    })

    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
