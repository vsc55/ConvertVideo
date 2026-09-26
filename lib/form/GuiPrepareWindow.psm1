<#
    form\GuiPrepareWindow.psm1 - VENTANA de PREPARAR los pendientes, calcada al flujo de consola.

    Se elige el PERFIL una vez para todo el lote y despues se recorre archivo por archivo haciendo el
    AUTODISCOVER (Get-CvJobAutoPlan, lib\JobCore.psm1). Lo que la consola resolveria sola se guarda
    solo; solo se para a preguntar en los MISMOS casos en que preguntaria la consola (varias pistas
    de video, varias -o ninguna- del idioma preferido, subtitulos sin idioma preferido, bordes que
    hay que confirmar), y entonces abre el editor (form\GuiJobWindow.psm1) ya relleno y diciendo por
    que se ha parado.
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
        Index   = 0
        Done    = 0
        Manual  = 0
        Skipped = 0
        Failed  = 0
        Cancel  = $false
        Running = $true
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
    $lblProf.Text      = (Get-CvText -Key 'prep.perfil' -Values @((Format-CvProfileLabel -Prof $prof)))
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
    $foot.ColumnCount = 2
    $foot.RowCount    = 1
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    $grid.Controls.Add($foot, 0, 3)

    # Barra pintada, por lo mismo que la del editor: la del sistema no se puede oscurecer.
    $prog = New-CvGuiProgressPanel -Name 'cvPrepProgress'
    $prog.Dock   = 'Fill'
    $prog.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 8)
    $foot.Controls.Add($prog, 0, 0)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text   = (Get-CvText -Key 'comun.cancelar')
    $btnClose.Height = 30
    $btnClose.Dock   = 'Fill'
    $btnClose.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 7)
    $btnClose.Name   = 'cvPrepClose'
    $foot.Controls.Add($btnClose, 1, 0)

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
    $say = {
        param([string]$Text)
        $lblSt.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnClose.Add_Click({
        if ($st.Running) { $st.Cancel = $true; $lblSt.Text = (Get-CvText -Key 'prep.cancelando') }
        else { $form.Close() }
    })

    # Un archivo por tick: asi la ventana se pinta y responde entre archivos, y el bucle no bloquea
    # WinForms de principio a fin. Dentro de un archivo el analisis SI bloquea (ffprobe/ffmpeg), por
    # eso cada fase escribe antes lo que va a hacer (DoEvents en $say).
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60
    $timer.Add_Tick({
        $timer.Stop()
        if ($st.Cancel -or $st.Index -ge $items.Count) {
            $st.Running = $false
            $btnClose.Text = (Get-CvText -Key 'comun.cerrar')
            [void](Set-CvGuiProgressValue -Bar $prog -Percent 100)
            $lblSt.Text = (Get-CvText -Key 'prep.hecho' -Values @(
                $st.Done, $st.Manual, $st.Skipped, $st.Failed, $(if ($st.Cancel) { (Get-CvText -Key 'prep.cancelado') } else { '' })))
            return
        }

        $i = $st.Index
        $f = $items[$i]
        & $setRow $i (Get-CvText -Key 'prep.est.analizando') ''
        & $say (Get-CvText -Key 'prep.paso.leer' -Values @(($i + 1), $items.Count, $f.Name))

        try {
            $info = Get-MediaInfo -Context $Context -File $f.Path
            if ($null -eq $info) {
                $st.Failed++
                & $setRow $i (Get-CvText -Key 'prep.est.error') (Get-CvText -Key 'prep.det.noleido')
            } else {
                # Regla del prefijo '_': fuerza la deteccion de bordes, igual que en consola.
                $force = "$($f.Name)".StartsWith('_')
                $plan = Get-CvJobAutoPlan -Context $Context -Prof $prof -Info $info -File $f.Path -ForceBorder $force -OnStep {
                    param($t)
                    & $say (Get-CvText -Key 'prep.paso' -Values @(($i + 1), $items.Count, $f.Name, $t))
                }
                if (-not $plan.Manual) {
                    [void](Save-CvJobDraft -Context $Context -Draft $plan.Draft -Info $info)
                    $st.Done++
                    # 'Notes' = lo que se ha decidido solo y conviene contar (p. ej. el retardo de
                    # audio detectado); no obliga a revisar, pero tiene que verse.
                    $det = (Get-CvText -Key 'prep.det.auto')
                    if (@($plan.Notes).Count -gt 0) { $det = (Get-CvText -Key 'prep.det.auto.notas' -Values @((@($plan.Notes) -join ' | '))) }
                    & $setRow $i (Get-CvText -Key 'prep.est.preparado') $det (& $borderCell $plan.Draft $info)
                } else {
                    & $setRow $i (Get-CvText -Key 'prep.est.revisar') (@($plan.Reasons) -join ' | ') (& $borderCell $plan.Draft $info)
                    & $say (Get-CvText -Key 'prep.paso.decision' -Values @(($i + 1), $items.Count, $f.Name))
                    $saved = Show-CvJobWindow -Context $Context -Name $f.Name -File $f.Path -Draft $plan.Draft -Info $info -Reasons $plan.Reasons
                    if ($saved) {
                        $st.Done++; $st.Manual++
                        # Lo que se haya guardado MANDA sobre lo que proponia el borrador: en la
                        # ventana se puede cambiar el recorte, quitarlo o poner otro escalado.
                        $final = $plan.Draft
                        try { $final = Read-CvJobDraft -Context $Context -Name $f.Name } catch { }
                        & $setRow $i (Get-CvText -Key 'prep.est.preparado') (Get-CvText -Key 'prep.det.revisado') (& $borderCell $final $info)
                    } else {
                        $st.Skipped++
                        & $setRow $i (Get-CvText -Key 'prep.est.omitido') (@($plan.Reasons) -join ' | ')
                    }
                }
            }
        } catch {
            $st.Failed++
            & $setRow $i (Get-CvText -Key 'prep.est.error') "$($_.Exception.Message)"
        }

        $st.Index++
        [void](Set-CvGuiProgressValue -Bar $prog -Percent $(if ($items.Count -gt 0) { [int](100 * [Math]::Min($items.Count, $st.Index) / $items.Count) } else { 0 }))
        $timer.Start()
    })

    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosing({ $timer.Stop() })
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return [int]$st.Done
}

Export-ModuleMember -Function *
