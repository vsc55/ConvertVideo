<#
    form\GuiMaintenanceWindow.psm1 - VENTANA de mantenimiento: lo que ocupa sitio y lo que estorba.

    Bloqueos de workers que ya no existen, jobs huerfanos, temporales a medias y la cache de las
    ventanas. Los DATOS y las acciones salen de lib\SetupCore.psm1; borrar de verdad se confirma
    antes y se hace desde form\GuiCleanWindow.psm1.
#>

function Show-CvMaintenanceWindow {
    <#
        MANTENIMIENTO en un solo sitio: lo de la carpeta Proceso (jobs, bloqueos, temporales), los
        logs viejos y lo cacheado por las ventanas. Antes cada cosa estaba en su boton y habia que ir
        a buscarlas por separado -y una de ellas, la cache de archivos analizados, no se veia por
        ningun lado hasta que salia el dialogo-.

        Se marca lo que se quiere tirar y se limpia de una vez. Las filas y el borrado salen de
        SetupCore (los mismos que usa la consola); aqui solo se ensena y se confirma.

        Devuelve cuantos elementos se han borrado.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$CurrentLog = ''
    )
    if (-not (Initialize-CvGui)) { return 0 }
    $borrados = 0

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = (Get-CvText -Key 'mant.tit')
    $form.StartPosition = 'CenterParent'
    # Ancha a proposito: la columna de 'que se pierde' son frases, y a 720 se cortaban todas.
    $form.Size          = New-Object System.Drawing.Size(900, 560)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 440)
    $form.Name          = 'cvMaint'

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 4
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    $form.Controls.Add($grid)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = (Get-CvText -Key 'mant.marca')
    $lbl.Dock     = 'Fill'
    $lbl.AutoSize = $false
    $grid.Controls.Add($lbl, 0, 0)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.CheckBoxes    = $true
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.MultiSelect   = $false
    $lv.Font          = (New-CvGuiFont 9)
    $lv.Name          = 'cvMaintList'
    [void]$lv.Columns.Add((Get-CvText -Key 'mant.col.que'), 300)
    [void]$lv.Columns.Add((Get-CvText -Key 'mant.col.cuantos'), 70, 'Right')
    [void]$lv.Columns.Add((Get-CvText -Key 'mant.col.pierde'), 300)
    [void](Set-CvGuiListFillColumn -List $lv -Index 2 -Min 240)
    [void](Set-CvGuiDoubleBuffered -Control $lv)
    $grid.Controls.Add($lv, 0, 1)

    $lblSel = New-Object System.Windows.Forms.Label
    $lblSel.Dock      = 'Fill'
    $lblSel.AutoSize  = $false
    $lblSel.Name      = 'cvMaintHint'
    $grid.Controls.Add($lblSel, 0, 2)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 3)

    $mkBtn = {
        param([string]$Text, [string]$Name)
        $b = New-Object System.Windows.Forms.Button
        $b.Text         = $Text
        $b.Height       = 30
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.MinimumSize  = New-Object System.Drawing.Size(150, 30)
        $b.Margin       = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
        $b.Name         = $Name
        $bar.Controls.Add($b)
        return $b
    }
    $btnDo    = & $mkBtn (Get-CvText -Key 'mant.btn.limpiar') 'cvMaintRun'
    $btnClose = & $mkBtn (Get-CvText -Key 'comun.cerrar')      'cvMaintClose'

    $st = @{ Items = @() }
    $recargar = {
        $st.Items = @(Get-CvSetupMaintenanceItems -Context $Context -CurrentLog $CurrentLog)
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            foreach ($i in $st.Items) {
                $it = New-Object System.Windows.Forms.ListViewItem("$($i.Text)")
                [void]$it.SubItems.Add("$($i.Count)")
                [void]$it.SubItems.Add("$($i.Detail)")
                # Lo que no tiene nada que borrar se ensena apagado: se ve que no hay, sin quitarlo.
                if ([int]$i.Count -le 0) { $it.ForeColor = (Get-CvGuiCurrentPalette).Muted }
                [void]$lv.Items.Add($it)
            }
        } finally { $lv.EndUpdate() }
    }
    $marcados = {
        $ks = @()
        for ($i = 0; $i -lt $lv.Items.Count -and $i -lt @($st.Items).Count; $i++) {
            if ($lv.Items[$i].Checked) { $ks += "$(@($st.Items)[$i].Key)" }
        }
        return @($ks)
    }
    $refrescarPie = {
        $ks = @(& $marcados)
        $n = 0
        $avisa = $false
        foreach ($i in @($st.Items)) {
            if ($ks -contains "$($i.Key)") { $n += [int]$i.Count; if ([bool]$i.Warn) { $avisa = $true } }
        }
        $btnDo.Enabled = ($ks.Count -gt 0 -and $n -gt 0)
        $lblSel.Text = $(if ($ks.Count -eq 0) {
            (Get-CvText -Key 'mant.nada')
        } elseif ($avisa) {
            (Get-CvText -Key 'mant.borrar.ojo' -Values @($n))
        } else {
            (Get-CvText -Key 'mant.borrar.n' -Values @($n))
        })
        [void](Set-CvGuiRole -Control $lblSel -Role $(if ($avisa) { 'warn' } else { 'muted' }))
    }
    $lv.Add_ItemChecked({ & $refrescarPie })

    $btnDo.Add_Click({
        $ks = @(& $marcados)
        if ($ks.Count -eq 0) { return }
        $detalle = @()
        foreach ($i in @($st.Items)) {
            if ($ks -contains "$($i.Key)") { $detalle += ("  {0}  ({1})" -f $i.Text, $i.Count) }
        }
        $msg = Get-CvText -Key 'mant.confirm' -Values @(($detalle -join "`n"))
        if (-not (Show-CvGuiConfirm -Title (Get-CvText -Key 'mant.tit') -Message $msg)) { return }
        $r = @(Invoke-CvSetupMaintenance -Context $Context -Keys $ks -CurrentLog $CurrentLog)
        foreach ($x in $r) { $script:borrados += [int]$x.Removed }
        $malos = @($r | Where-Object { -not $_.Ok })
        if ($malos.Count -gt 0) {
            Show-CvGuiInfo -Title (Get-CvText -Key 'mant.tit') -Message (Get-CvText -Key 'mant.error' -Values @(((@($malos | ForEach-Object { "{0}: {1}" -f $_.Text, $_.Error })) -join "`n")))
        }
        & $recargar
        & $refrescarPie
    }.GetNewClosure())
    $btnClose.Add_Click({ $form.Close() })

    $form.Add_Shown({ & $recargar; & $refrescarPie })
    $form.CancelButton = $btnClose
    [void](Set-CvGuiTheme -Form $form)   # tema de la sesion
    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:borrados
}

Export-ModuleMember -Function *
