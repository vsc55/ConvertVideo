<#
    form\GuiConfigChooser.psm1 - DIALOGO de con que config*.json trabajar.

    Es el equivalente en ventana de elegir entre Convert.cmd y Convert-Debug.cmd sin cambiar de
    lanzador: sale al arrancar setup-gui o la cola sin -Config, y lo que se elija manda el resto de
    la sesion.
#>

function Show-CvSetupConfigChooser {
    <#
        Pregunta QUE configuracion gestionar al abrir la ventana sin -Config: lista los 'config*.json'
        que haya junto al programa (Get-CvSetupConfigCandidates, con 'config.json' preseleccionado) y
        ofrece 'Otro...' para buscar uno en disco. Es el equivalente de elegir entre setup.cmd y
        setup-Debug.cmd, pero sin tener que cerrar y abrir otro lanzador.

        Devuelve la ruta elegida, o '' si se cancela (el llamador no abre nada). Con -Config en la
        linea de comandos esta pregunta NO aparece.
    #>
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Initialize-CvGui)) { return '' }

    $items = @(Get-CvSetupConfigCandidates -Root $Root)
    $otro  = 'Otro... (buscar un fichero)'

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Que configuracion quieres gestionar?'
    $form.StartPosition   = 'CenterScreen'
    $form.Size            = New-Object System.Drawing.Size(520, 300)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(12, 12)
    $lst.Size     = New-Object System.Drawing.Size(480, 190)
    $lst.Font     = (New-CvGuiFont 10)
    $lst.Name     = 'cvCfgList'
    foreach ($c in $items) {
        $tag = if ($c.Text) { "   ({0})" -f $c.Text } else { '' }
        $ex  = if ($c.Exists) { '' } else { '   [no existe -> valores por defecto]' }
        [void]$lst.Items.Add(("{0}{1}{2}" -f $c.Name, $tag, $ex))
    }
    [void]$lst.Items.Add($otro)
    $lst.SelectedIndex = 0
    $form.Controls.Add($lst)

    # Alto a la medida de lo que hay (con 3 opciones no tiene sentido una caja de 10 lineas), pero
    # acotado: a partir de unos cuantos config*.json la lista hace scroll en vez de crecer sin fin.
    # IntegralHeight = $false: con el valor por defecto ($true) el ListBox RECORTA su alto al multiplo
    # de ItemHeight y, al descontar el borde, se perdia la ultima fila (salia scroll con 3 opciones).
    $lst.IntegralHeight = $false
    $rows = [Math]::Max(3, [Math]::Min($lst.Items.Count, 10))
    $lst.Height  = ($rows * $lst.ItemHeight) + 10
    $btnTop      = $lst.Bottom + 12
    $form.ClientSize = New-Object System.Drawing.Size(504, ($btnTop + 42))

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Aceptar'
    $btnOk.Size     = New-Object System.Drawing.Size(110, 30)
    $btnOk.Location = New-Object System.Drawing.Point(262, $btnTop)
    $btnOk.Name     = 'cvCfgOk'
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancelar'
    $btnCancel.Size     = New-Object System.Drawing.Size(110, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(382, $btnTop)
    $form.Controls.Add($btnCancel)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $st = @{ Path = '' }
    $accept = {
        $i = $lst.SelectedIndex
        if ($i -lt 0) { return }
        if ($i -ge $items.Count) {
            # 'Otro...': buscador de ficheros. Si se cancela, se vuelve a la lista (no se cierra).
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title            = 'Elige un fichero de configuracion'
            $dlg.InitialDirectory = $Root
            $dlg.Filter           = 'Configuracion JSON (*.json)|*.json|Todos (*.*)|*.*'
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $st.Path = $dlg.FileName
        } else {
            $st.Path = $items[$i].Path
        }
        $form.Close()
    }
    $btnOk.Add_Click($accept)
    $lst.Add_DoubleClick($accept)      # doble clic = elegir, como en cualquier lista
    $btnCancel.Add_Click({ $st.Path = ''; $form.Close() })

    [void](Set-CvGuiTheme -Form $form)   # tema de la sesion
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Path
}

# El EDITOR DE CONFIGURACION en ventana (Show-CvConfigWindow y sus ayudantes del arbol) vive en
# lib\GuiConfig.psm1: es una ventana entera por si misma -la mas grande de setup- y se abre tambien
# desde la cola.

# ===========================================================================
#  Dialogos de herramientas y limpieza
# ===========================================================================

Export-ModuleMember -Function *
