<#
    form\GuiLogsWindow.psm1 - VENTANA de los logs: cuales hay, abrirlos y mirarlos por dentro.

    El listado sale de lib\Log.psm1 (que es tambien quien sabe cual es el log de la sesion en curso,
    el unico que no se puede borrar) y el repintado en vivo va por Update-CvGuiLogView.
#>

function Show-CvLogsWindow {
    <#
        Visor de los logs de logs\: lista a la izquierda (el mas reciente arriba, con fecha y tamano;
        el de la sesion en curso marcado) y contenido a la derecha. Ademas de leerlos aqui, permite
        abrir el fichero con el programa asociado de Windows y borrar el que este seleccionado.

        El log EN CURSO se puede leer (Get-CvSetupLogText abre en modo compartido) pero NO borrar:
        esta en uso por el transcript.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$CurrentLog = ''
    )
    if (-not (Initialize-CvGui)) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = (Get-CvText -Key 'logs.tit')
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(1000, 640)
    $form.MinimumSize   = New-Object System.Drawing.Size(720, 420)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 2
    $grid.RowCount    = 2
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 390)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    $form.Controls.Add($grid)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Dock = 'Fill'
    $lst.Font = (New-CvGuiFont 9)
    $lst.Name = 'cvLogList'
    $lst.HorizontalScrollbar = $true   # los nombres llevan fecha y PID: no siempre caben
    $grid.Controls.Add($lst, 0, 0)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Dock       = 'Fill'
    $txt.Multiline  = $true
    $txt.ReadOnly   = $true
    $txt.ScrollBars = 'Both'
    $txt.WordWrap   = $false      # los logs vienen alineados; mejor barra horizontal que romper lineas
    $txt.Font       = (New-CvGuiFont 9)
    $txt.Name       = 'cvLogText'
    $grid.Controls.Add($txt, 1, 0)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 1)
    $grid.SetColumnSpan($bar, 2)

    $mkBtn = {
        param([string]$Text, [int]$Width, [string]$Name)
        $b = New-Object System.Windows.Forms.Button
        $b.Text   = $Text
        $b.Width  = $Width
        $b.Height = 30
        if ($Name) { $b.Name = $Name }
        $bar.Controls.Add($b)
        return $b
    }
    # Los dos espacios de delante son el hueco del icono, no parte del texto: por eso no van en
    # el fichero de idioma.
    $btnOpen    = & $mkBtn ('  ' + (Get-CvText -Key 'comun.abrirfuera'))  130 'cvLogOpen'
    $btnRefresh = & $mkBtn ('  ' + (Get-CvText -Key 'comun.actualizar'))  120 'cvLogRefresh'
    $btnDel     = & $mkBtn ('  ' + (Get-CvText -Key 'logs.btn.eliminar')) 160 'cvLogDelete'
    $btnClose   = & $mkBtn ('  ' + (Get-CvText -Key 'comun.cerrar'))      110 ''

    # Crudo vs decorado: por defecto se muestra LIMPIO (se colapsan los repintados de la barra de los
    # logs antiguos); marcando la casilla se ve el fichero TAL CUAL, por si hay que revisar algo que
    # la limpieza recoge o simplemente comparar con el original.
    $chkRaw = New-Object System.Windows.Forms.CheckBox
    $chkRaw.Text     = (Get-CvText -Key 'logs.vercrudo')
    $chkRaw.AutoSize = $true
    $chkRaw.Margin   = New-Object System.Windows.Forms.Padding(16, 7, 3, 3)
    $chkRaw.Name     = 'cvLogRaw'
    $bar.Controls.Add($chkRaw)

    $st = @{ Logs = @() }

    $reload = {
        $sel = $lst.SelectedIndex
        $st.Logs = @(Get-CvSetupLogFiles -Context $Context -CurrentPath $CurrentLog)
        $lst.Items.Clear()
        foreach ($l in $st.Logs) {
            $cur = if ($l.IsCurrent) { (Get-CvText -Key 'logs.encurso') } else { '' }
            [void]$lst.Items.Add(("{0:dd/MM/yy HH:mm}  {1,5} KB  {2}{3}" -f $l.Date, $l.SizeKb, $l.Name, $cur))
        }
        if ($lst.Items.Count -gt 0) {
            $lst.SelectedIndex = [Math]::Max(0, [Math]::Min($sel, $lst.Items.Count - 1))
        } else {
            $txt.Text = (Get-CvText -Key 'logs.vacio')
        }
    }
    $current = {
        $i = $lst.SelectedIndex
        if ($i -lt 0 -or $i -ge @($st.Logs).Count) { return $null }
        return @($st.Logs)[$i]
    }

    # Vuelca el log elegido en el panel, en el modo que marque la casilla.
    $render = {
        $l = & $current
        if ($null -eq $l) { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $txt.Text = (Get-CvSetupLogText -Path $l.Path -Raw:$chkRaw.Checked)
            $txt.SelectionStart  = 0
            $txt.SelectionLength = 0
            $txt.ScrollToCaret()
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
    $lst.Add_SelectedIndexChanged($render)
    $chkRaw.Add_CheckedChanged($render)      # cambiar de modo recarga el log que este a la vista
    $btnOpen.Add_Click({
        $l = & $current
        if ($null -eq $l) { return }
        [void](Open-CvGuiPath -Path "$($l.Path)" -Title (Get-CvText -Key 'logs.tit'))
    })
    $btnRefresh.Add_Click($reload)
    $btnDel.Add_Click({
        $l = & $current
        if ($null -eq $l) { return }
        if ($l.IsCurrent) { Show-CvGuiInfo -Title (Get-CvText -Key 'logs.tit') -Message (Get-CvText -Key 'logs.enuso'); return }
        if (-not (Show-CvGuiConfirm -Title (Get-CvText -Key 'logs.del.tit') -Message (Get-CvText -Key 'logs.del.msg' -Values @($l.Name)))) { return }
        Remove-Item -Force -LiteralPath $l.Path -ErrorAction SilentlyContinue
        $txt.Text = ''
        & $reload
    })
    $btnClose.Add_Click({ $form.Close() })

    & $reload
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
}

Export-ModuleMember -Function *
