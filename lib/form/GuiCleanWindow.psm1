<#
    form\GuiCleanWindow.psm1 - DIALOGO de limpieza: que se va a borrar, con la cuenta delante.

    Se abre desde mantenimiento. Nunca borra el log de la sesion en curso (lib\Log.psm1 lo excluye) y
    siempre ensena que y cuanto antes de tocar nada.
#>

function Show-CvCleanWindow {
    <#
        Limpieza de la carpeta Proceso: elegir QUE borrar (jobs / bloqueos / temporales / todo), ver la
        lista exacta de ficheros y confirmar. Los candidatos y el borrado salen de SetupCore, los
        mismos que usa la consola.
    #>
    param([Parameter(Mandatory)]$Context)
    if (-not (Initialize-CvGui)) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = (Get-CvText -Key 'limpiar.tit')
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(640, 470)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location      = New-Object System.Drawing.Point(12, 30)
    $combo.Width         = 400
    $combo.DropDownStyle = 'DropDownList'
    $form.Controls.Add($combo)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = (Get-CvText -Key 'limpiar.que')
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(12, 10)
    $form.Controls.Add($lbl)

    $files = New-Object System.Windows.Forms.TextBox
    $files.Location   = New-Object System.Drawing.Point(12, 65)
    $files.Size       = New-Object System.Drawing.Size(600, 300)
    $files.Multiline  = $true
    $files.ReadOnly   = $true
    $files.ScrollBars = 'Both'
    $files.WordWrap   = $false
    $files.Font       = (New-CvGuiFont 9)
    $form.Controls.Add($files)

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text     = (Get-CvText -Key 'comun.eliminar')
    $btnDel.Location = New-Object System.Drawing.Point(12, 378)
    $btnDel.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnDel)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = (Get-CvText -Key 'comun.cerrar')
    $btnClose.Location = New-Object System.Drawing.Point(462, 378)
    $btnClose.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnClose)

    # Mismas cuatro opciones que el menu de consola, con el recuento de cada una.
    $p = Get-CvSetupProcesoStatus -Context $Context
    $whats = @(
        @{ Value = 'jobs';  Text = (Get-CvText -Key 'limpiar.op.jobs'  -Values @($p.Jobs)) }
        @{ Value = 'locks'; Text = (Get-CvText -Key 'limpiar.op.locks' -Values @($p.Locks)) }
        @{ Value = 'temps'; Text = (Get-CvText -Key 'limpiar.op.temps' -Values @($p.Temps)) }
        @{ Value = 'all';   Text = (Get-CvText -Key 'limpiar.op.all') }
    )
    foreach ($w in $whats) { [void]$combo.Items.Add($w.Text) }

    $refresh = {
        $i = $combo.SelectedIndex
        if ($i -lt 0) { return }
        $f = @(Get-CvSetupCleanTargets -Context $Context -What $whats[$i].Value)
        $files.Text = if ($f.Count -eq 0) { (Get-CvText -Key 'limpiar.nada') } else { (@($f | ForEach-Object { $_.Name }) -join [Environment]::NewLine) }
        $btnDel.Enabled = ($f.Count -gt 0)
    }
    $combo.Add_SelectedIndexChanged($refresh)

    $btnDel.Add_Click({
        $i = $combo.SelectedIndex
        if ($i -lt 0) { return }
        $f = @(Get-CvSetupCleanTargets -Context $Context -What $whats[$i].Value)
        if ($f.Count -eq 0) { return }
        if (-not (Show-CvGuiConfirm -Title (Get-CvText -Key 'limpiar.confirm.tit') -Message (Get-CvText -Key 'limpiar.confirm.msg' -Values @($f.Count)))) { return }
        $n = Remove-CvSetupFiles -Files $f
        Show-CvGuiInfo -Title (Get-CvText -Key 'limpiar.hecho.tit') -Message (Get-CvText -Key 'limpiar.hecho.msg' -Values @($n))
        & $refresh
    })
    $btnClose.Add_Click({ $form.Close() })

    $combo.SelectedIndex = 0
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
}

# ===========================================================================
#  Ventana principal
# ===========================================================================

Export-ModuleMember -Function *
