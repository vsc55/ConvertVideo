<#
    form\GuiPrepareWindow.psm1 - VENTANA de PREPARAR los pendientes, calcada al flujo de consola.

    Se elige el PERFIL una vez para todo el lote y despues se hace el AUTODISCOVER de cada archivo
    (Get-CvJobAutoPlan, lib\JobCore.psm1). Lo que la consola resolveria sola se guarda solo; solo se
    pregunta en los MISMOS casos en que preguntaria la consola (varias pistas de video, varias -o
    ninguna- del idioma preferido, subtitulos sin idioma preferido, bordes que hay que confirmar), y
    entonces se abre el editor (form\GuiJobWindow.psm1) ya relleno y diciendo por que.

    A diferencia de la consola, NO SE PARA mientras respondes: el analisis va en segundo plano
    (Start-CvPrepareAnalysis) y sigue con el resto; lo que se resuelve solo se guarda aunque tengas un
    editor abierto, y lo que pide revision espera su turno y se abre en cuanto cierras el anterior.
#>

function Show-CvPrepareWindow {
    <#
        PREPARAR PENDIENTES, como en consola: se elige el PERFIL una vez y se recorren los archivos
        haciendo el autodiscover. Lo que se resuelve solo se guarda solo; donde la consola
        preguntaria, se abre el editor ya relleno con el motivo escrito.

        -Files: @({ Name; Path }) de los archivos a preparar (los 'sin preparar' de la cola).
        Devuelve cuantos jobs han quedado escritos.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Files
    )
    if (-not (Initialize-CvGui)) { return 0 }
    $items = @($Files)
    if ($items.Count -eq 0) { return 0 }

    # Igual que al lanzar workers: sin ffmpeg/ffprobe no se puede analizar nada, y es mejor decirlo
    # una vez al principio que dejar una fila con una excepcion cruda por cada archivo.
    $ready = Test-CvConvertReady -Context $Context
    if (-not $ready.Ok) {
        Show-CvGuiInfo -Title (Get-CvText -Key 'prep.faltan.tit') -Message (Get-CvText -Key 'prep.faltan.msg' -Values @($ready.Reason))
        return 0
    }

    # 1) El perfil, UNA vez para todo el lote (igual que al empezar PREPARAR en consola).
    $prof = Show-CvJobProfileDialog -Context $Context -Info (Get-CvText -Key 'prep.perfil.info' -Values @($items.Count))
    if ($null -eq $prof) { return 0 }

    $st = @{
        Done    = 0
        Manual  = 0
        Skipped = 0
        Failed  = 0
        Handled = 0           # archivos ya RESUELTOS (preparados, omitidos o con error): la barra
        Cancel  = $false
        Running = $true
        CloseAt = $null       # cuando cerrarse sola (casilla 'Cerrar al terminar')
        Bg      = $null       # el analisis en segundo plano (Start-CvPrepareAnalysis)
        Ask     = (New-Object System.Collections.Queue)   # los que esperan su turno en el editor
        Asking  = $false      # hay un editor abierto: no se abre otro encima
        LogSeen = 0           # lineas del log del analisis ya volcadas al de la sesion
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = (Get-CvText -Key 'prep.tit')
    $form.StartPosition = 'CenterScreen'
    $form.Size          = New-Object System.Drawing.Size(900, 520)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 400)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 4
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    $form.Controls.Add($grid)

    $lblProf = New-Object System.Windows.Forms.Label
    $lblProf.Dock      = 'Fill'
    $lblProf.TextAlign = 'MiddleLeft'
    # En palabras (fase A4); la etiqueta compacta, en su ayuda emergente.
    $lblProf.Text      = (Get-CvText -Key 'prep.perfil' -Values @((Format-CvProfileWords -Prof $prof)))
    $lblProf.AutoEllipsis = $true
    $lblProf.Name      = 'cvPrepProfile'
    $grid.Controls.Add($lblProf, 0, 0)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.Font          = (New-CvGuiFont 9)
    $lv.Name          = 'cvPrepList'
    [void]$lv.Columns.Add((Get-CvText -Key 'prep.col.archivo'), 360)
    [void]$lv.Columns.Add((Get-CvText -Key 'prep.col.estado'), 130)
    # Bordes: en que archivos ha entrado el recorte y con que tamano quedan, sin tener que abrir nada.
    [void]$lv.Columns.Add((Get-CvText -Key 'prep.col.bordes'), 150)
    [void]$lv.Columns.Add((Get-CvText -Key 'prep.col.detalle'), 300)
    # 'Detalle' se queda con lo que SOBRE (y crece con la ventana). Con los cuatro anchos fijos
    # (940 px) no cabian en la lista de una ventana de 900 y salia la barra horizontal de entrada,
    # sin nada largo que ver. Como las demas listas: Set-CvGuiListFillColumn.
    [void](Set-CvGuiListFillColumn -List $lv -Index 3 -Min 160)
    [void](Set-CvGuiDoubleBuffered -Control $lv)
    foreach ($f in $items) {
        $it = New-Object System.Windows.Forms.ListViewItem("$($f.Name)")
        [void]$it.SubItems.Add((Get-CvText -Key 'prep.est.pendiente'))
        [void]$it.SubItems.Add('')
        [void]$it.SubItems.Add('')
        [void]$lv.Items.Add($it)
    }
    $grid.Controls.Add($lv, 0, 1)

    $lblSt = New-Object System.Windows.Forms.Label
    $lblSt.Dock      = 'Fill'
    $lblSt.TextAlign = 'MiddleLeft'
    $lblSt.Name      = 'cvPrepStatus'
    $grid.Controls.Add($lblSt, 0, 2)

    $foot = New-Object System.Windows.Forms.TableLayoutPanel
    $foot.Dock        = 'Fill'
    $foot.ColumnCount = 3
    $foot.RowCount    = 1
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    # La FILA tambien lleva estilo. Sin el, un TableLayoutPanel la da por AutoSize y la hace tan
    # alta como el mayor de sus controles (aqui salian 116 px dentro de un pie de 38): el boton se
    # estiraba por debajo de lo que se ve y su ROTULO, centrado en esa altura, quedaba FUERA. Por
    # eso la ventana parecia no tener boton -ni 'Cancelar' ni 'Cerrar'- y no avisaba de nada.
    [void]$foot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $grid.Controls.Add($foot, 0, 3)

    # Barra pintada, por lo mismo que la del editor: la del sistema no se puede oscurecer.
    $prog = New-CvGuiProgressPanel -Name 'cvPrepProgress'
    $prog.Dock   = 'Fill'
    $prog.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 8)
    $foot.Controls.Add($prog, 0, 0)

    # Cerrarse sola al acabar: arranca con lo que diga la configuracion (gui.prepareAutoClose) y
    # lo que se marque aqui se guarda alli, que es lo que se espera de una casilla que se ve cada
    # vez que preparas. Solo se cierra si ha ido todo bien (ver Get-CvPrepareEndState).
    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text     = (Get-CvText -Key 'prep.autocerrar')
    $chkAuto.AutoSize = $true
    $chkAuto.Anchor   = 'Left'
    $chkAuto.Margin   = New-Object System.Windows.Forms.Padding(3, 12, 3, 3)
    $chkAuto.Checked  = [bool]$Context.GuiPrepareAutoClose
    $chkAuto.Name     = 'cvPrepAutoClose'
    $foot.Controls.Add($chkAuto, 1, 0)
    $tip = New-Object System.Windows.Forms.ToolTip
    [void](Register-CvGuiDisposeWith -Control $form -Object $tip)
    $tip.SetToolTip($chkAuto, (Get-CvText -Key 'prep.autocerrar.tip'))

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text   = (Get-CvText -Key 'comun.cancelar')
    $btnClose.Dock   = 'Fill'
    $btnClose.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 7)
    $btnClose.Name   = 'cvPrepClose'
    $foot.Controls.Add($btnClose, 2, 0)

    $setRow = {
        param([int]$i, [string]$Estado, [string]$Detalle, [string]$Bordes = $null)
        if ($i -lt 0 -or $i -ge $lv.Items.Count) { return }
        $lv.Items[$i].SubItems[1].Text = $Estado
        # $null = no se toca (el estado cambia varias veces por archivo y los bordes solo una).
        if ($null -ne $Bordes) { $lv.Items[$i].SubItems[2].Text = $Bordes }
        $lv.Items[$i].SubItems[3].Text = $Detalle
        $lv.Items[$i].EnsureVisible()
    }
    # Que poner en la columna de bordes de un archivo ya analizado (texto puro: Format-CvJobBorderCell).
    $borderCell = {
        param($Draft, $Info)
        if ($null -eq $Draft -or $null -eq $Info) { return '' }
        if ([bool]$Draft.VideoSkip) { return '' }   # en copy no se toca la imagen
        $vs = @(Get-VideoStreams -Info $Info | Where-Object { [int]$_.index -eq [int]$Draft.VideoIndex })
        if ($vs.Count -eq 0) { return '' }
        $dbv = "$($Draft.Prof.DetectBorder)".ToLower()
        Format-CvJobBorderCell -Crop "$($Draft.Crop)" -Resize "$($Draft.Resize)" `
            -Width ([int]$vs[0].width) -Height ([int]$vs[0].height) `
            -Detect ($dbv -eq 'auto' -or $dbv -eq 'true')
    }

    $chkAuto.Add_CheckedChanged({
        # Al contexto vivo y al fichero, como hace la cola con sus opciones. Si no se puede escribir
        # se dice y ya esta: la casilla sigue valiendo para ESTA vuelta.
        try { $Context.GuiPrepareAutoClose = [bool]$chkAuto.Checked } catch { }
        $cfgPath = "$($Context.ConfigPath)"
        if ($cfgPath -ne '') {
            $r = Set-CvConfigValue -Path $cfgPath -Key 'gui/prepareAutoClose' -Value ([bool]$chkAuto.Checked)
            if (-not $r.Ok) {
                [void](Set-CvGuiRole -Control $lblSt -Role 'warn')
                $lblSt.Text = (Get-CvText -Key 'prep.autocerrar.no' -Values @($r.Error))
            }
        }
    })

    $btnClose.Add_Click({
        if ($st.Running) { $st.Cancel = $true; $lblSt.Text = (Get-CvText -Key 'prep.cancelando') }
        else { $form.Close() }
    })

    # La barra cuenta los archivos ya RESUELTOS (preparados, omitidos o con error), no los analizados:
    # uno que espera revision todavia no esta hecho.
    $updateProgress = {
        [void](Set-CvGuiProgressValue -Bar $prog -Percent $(if ($items.Count -gt 0) { [int](100 * [Math]::Min($items.Count, $st.Handled) / $items.Count) } else { 0 }))
    }

    # Lo que el analisis escribe (los pasos del escaneo de bordes, la sincronia...) va al log de la
    # SESION, que es donde iba cuando corria en el hilo de la ventana y donde se busca luego.
    $forwardLog = {
        $inf = $st.Bg.PowerShell.Streams.Information
        while ($st.LogSeen -lt $inf.Count) {
            $md = $inf[$st.LogSeen].MessageData
            $st.LogSeen++
            if ($md -is [System.Management.Automation.HostInformationMessage]) { Write-Host $md.Message -NoNewline:([bool]$md.NoNewLine) }
            else { Write-Host "$md" }
        }
    }

    # Un resultado del analisis. Lo que se resuelve solo se guarda YA, aunque haya un editor abierto
    # con otro archivo; lo que pide revision se pone a esperar su turno.
    $onResult = {
        param($r)
        $i = [int]$r.Index
        try {
            switch ("$($r.Kind)") {
                'noinfo' {
                    $st.Failed++
                    $st.Handled++
                    & $setRow $i (Get-CvText -Key 'prep.est.error') (Get-CvText -Key 'prep.det.noleido')
                }
                'error' {
                    $st.Failed++
                    $st.Handled++
                    & $setRow $i (Get-CvText -Key 'prep.est.error') "$($r.Error)"
                }
                default {
                    $plan = $r.Plan
                    if (-not $plan.Manual) {
                        [void](Save-CvJobDraft -Context $Context -Draft $plan.Draft -Info $r.Info)
                        $st.Done++
                        $st.Handled++
                        # 'Notes' = lo que se ha decidido solo y conviene contar (p. ej. el retardo de
                        # audio detectado); no obliga a revisar, pero tiene que verse.
                        $det = (Get-CvText -Key 'prep.det.auto')
                        if (@($plan.Notes).Count -gt 0) { $det = (Get-CvText -Key 'prep.det.auto.notas' -Values @((@($plan.Notes) -join ' | '))) }
                        & $setRow $i (Get-CvText -Key 'prep.est.preparado') $det (& $borderCell $plan.Draft $r.Info)
                    } else {
                        $st.Ask.Enqueue($r)
                        & $setRow $i (Get-CvText -Key 'prep.est.espera') (@($plan.Reasons) -join ' | ') (& $borderCell $plan.Draft $r.Info)
                    }
                }
            }
        } catch {
            $st.Failed++
            $st.Handled++
            & $setRow $i (Get-CvText -Key 'prep.est.error') "$($_.Exception.Message)"
        }
        & $updateProgress
    }

    # Lo que va contando el analisis de fondo: por donde va y lo que ya ha decidido.
    $drain = {
        $p = $null
        while ($st.Bg.Progress.TryDequeue([ref]$p)) {
            $i = [int]$p.Index
            $f = $items[$i]
            if ("$($p.Step)" -eq '') {
                & $setRow $i (Get-CvText -Key 'prep.est.analizando') ''
                $lblSt.Text = (Get-CvText -Key 'prep.paso.leer' -Values @(($i + 1), $items.Count, $f.Name))
            } else {
                $lblSt.Text = (Get-CvText -Key 'prep.paso' -Values @(($i + 1), $items.Count, $f.Name, "$($p.Step)"))
            }
        }
        $r = $null
        while ($st.Bg.Results.TryDequeue([ref]$r)) { & $onResult $r }
        & $forwardLog
    }

    # El siguiente que espera revision: su editor, ya relleno. Es MODAL, pero este temporizador sigue
    # vivo debajo -el bucle de mensajes del editor le despacha los tics-, asi que mientras respondes el
    # resto se sigue analizando y lo que no pide nada se va guardando.
    $askNext = {
        $r = $st.Ask.Dequeue()
        $i = [int]$r.Index
        $f = $items[$i]
        $plan = $r.Plan
        & $setRow $i (Get-CvText -Key 'prep.est.revisar') (@($plan.Reasons) -join ' | ')
        try {
            $saved = Show-CvJobWindow -Context $Context -Name $f.Name -File $f.Path -Draft $plan.Draft -Info $r.Info -Reasons $plan.Reasons -CropAsk ([bool]$plan.CropAsk) -CropPct ([int]$plan.CropPct)
            if ($saved) {
                $st.Done++
                $st.Manual++
                # Lo que se haya guardado MANDA sobre lo que proponia el borrador: en la ventana se
                # puede cambiar el recorte, quitarlo o poner otro escalado.
                $final = $plan.Draft
                try { $final = Read-CvJobDraft -Context $Context -Name $f.Name } catch { }
                & $setRow $i (Get-CvText -Key 'prep.est.preparado') (Get-CvText -Key 'prep.det.revisado') (& $borderCell $final $r.Info)
            } else {
                $st.Skipped++
                & $setRow $i (Get-CvText -Key 'prep.est.omitido') (@($plan.Reasons) -join ' | ')
            }
        } catch {
            $st.Failed++
            & $setRow $i (Get-CvText -Key 'prep.est.error') "$($_.Exception.Message)"
        }
        $st.Handled++
        & $updateProgress
    }

    # TERMINADO, y que se note: el resumen en verde (o en naranja si algo ha fallado o se ha
    # cancelado), el titulo lo dice -para verlo desde la barra de tareas sin traer la ventana
    # delante- y el boton pasa a 'Cerrar', que ademas responde a Intro.
    $finish = {
        $st.Running = $false
        if ($st.Cancel) {
            Stop-CvPrepareAnalysis -Handle $st.Bg
            # Lo que esperaba revision se queda sin preparar; lo que no se llego a analizar sigue
            # 'pendiente', que es lo que es.
            while ($st.Ask.Count -gt 0) {
                $r = $st.Ask.Dequeue()
                $st.Skipped++
                & $setRow ([int]$r.Index) (Get-CvText -Key 'prep.est.omitido') (@($r.Plan.Reasons) -join ' | ')
            }
        } else {
            Complete-CvPrepareAnalysis -Handle $st.Bg
        }
        $fin = Get-CvPrepareEndState -Done $st.Done -Manual $st.Manual -Skipped $st.Skipped -Failed $st.Failed `
            -Cancelled:([bool]$st.Cancel) -AutoClose:([bool]$chkAuto.Checked)
        $btnClose.Text = (Get-CvText -Key 'comun.cerrar')
        $form.AcceptButton = $btnClose
        $form.Text = (Get-CvText -Key 'prep.tit.hecho')
        [void](Set-CvGuiProgressValue -Bar $prog -Percent 100)
        $fatal = "$($st.Bg.Sync.Fatal)"
        if ($fatal -ne '') {
            # El analisis entero se cayo (p. ej. no pudo cargar un modulo): eso es lo que hay que contar.
            [void](Set-CvGuiRole -Control $lblSt -Role 'error')
            $lblSt.Text = (Get-CvText -Key 'prep.fallo' -Values @($fatal))
            return
        }
        [void](Set-CvGuiRole -Control $lblSt -Role "$($fin.Role)")
        # Con 'Cerrar al terminar' marcada y algo que mirar, se dice POR QUE se queda abierta.
        $lblSt.Text = $(if ("$($fin.Reason)" -ne '') { (Get-CvText -Key 'prep.hecho.motivo' -Values @("$($fin.Text)", "$($fin.Reason)")) } else { "$($fin.Text)" })
        if ($fin.Close) {
            # Un respiro antes de cerrar: si se cierra en el mismo tick no se llega a ver ni el 100% ni
            # el resumen. La espera la cuenta ESTE mismo temporizador: uno nuevo creado aqui dentro no
            # sirve -cuando salta, su manejador ya no ve la variable donde se guardo (ref-gotchas.md)-.
            $st.CloseAt = (Get-Date).AddMilliseconds([Math]::Max(0, [int]$Context.GuiPrepareAutoCloseMs))
        }
    }

    # UN temporizador que NO se para mientras hay un editor abierto. Su tic recoge lo del analisis y,
    # si no hay ya un editor, abre el del siguiente que espera. Un tic que llega con el editor abierto
    # (va ANIDADO, dentro del bucle de mensajes del editor) solo recoge y guarda: abrir otro encima
    # seria una pila de ventanas modales.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        # TODO el tick va dentro de un try. Una excepcion en el manejador de un Timer no la recoge
        # nadie: WinForms la saca como excepcion NO CONTROLADA -el dialogo de .NET con el volcado- y
        # la ventana se queda colgada, a cerrar a mano.
        try {
            if ($null -ne $st.CloseAt) {
                if ((Get-Date) -ge $st.CloseAt) { $timer.Stop(); $form.Close() }
                return
            }
            if (-not $st.Running -or $null -eq $st.Bg) { return }
            # 'Terminado' se lee ANTES de recoger: el analisis lo marca despues de dejar su ultimo
            # resultado, asi que si ya lo estaba, lo que se recoja ahora es todo lo que habia.
            $acabado = [bool]$st.Bg.Sync.Finished
            & $drain
            if ($st.Asking) {
                if ($acabado) { $lblSt.Text = (Get-CvText -Key 'prep.quedan' -Values @(($st.Ask.Count + 1))) }
                return
            }
            if ($st.Cancel) { & $finish; return }
            if ($st.Ask.Count -gt 0) {
                $st.Asking = $true
                $sig = [int]$st.Ask.Peek().Index
                $lblSt.Text = (Get-CvText -Key 'prep.paso.decision' -Values @(($sig + 1), $items.Count, $items[$sig].Name))
                try { & $askNext } finally { $st.Asking = $false }
                return
            }
            if ($acabado -and $st.Bg.Results.IsEmpty) { & $finish }
        } catch {
            $timer.Stop()
            $st.Running = $false
            $st.CloseAt = $null
            try { Stop-CvPrepareAnalysis -Handle $st.Bg } catch { }
            $btnClose.Text = (Get-CvText -Key 'comun.cerrar')
            try { [void](Set-CvGuiRole -Control $lblSt -Role 'error') } catch { }
            $lblSt.Text = (Get-CvText -Key 'prep.fallo' -Values @("$($_.Exception.Message)"))
        }
    })

    $form.Add_Shown({
        # El analisis arranca con la ventana YA visible: el runspace carga los modulos (unos segundos)
        # y mientras tanto se dice, en vez de una lista quieta.
        $lblSt.Text = (Get-CvText -Key 'prep.arranca')
        try {
            $st.Bg = Start-CvPrepareAnalysis -Context $Context -Prof $prof -Items $items
        } catch {
            $st.Running = $false
            $btnClose.Text = (Get-CvText -Key 'comun.cerrar')
            [void](Set-CvGuiRole -Control $lblSt -Role 'error')
            $lblSt.Text = (Get-CvText -Key 'prep.fallo' -Values @("$($_.Exception.Message)"))
            return
        }
        $timer.Start()
    })
    $form.Add_FormClosing({
        $timer.Stop()
        if ($st.Running) { Stop-CvPrepareAnalysis -Handle $st.Bg }
    })
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return [int]$st.Done
}

Export-ModuleMember -Function *
