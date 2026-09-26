<#
    form\GuiProfilesWindow.psm1 - VENTANA de gestion de perfiles: los tuyos, uno al lado del otro.

    Ver, crear, duplicar, editar y borrar los perfiles de config.json. Todo pasa por
    lib\Profile.psm1 (Save-CvConfigProfile / Remove-CvConfigProfile): ninguna interfaz escribe el
    JSON por su cuenta.
#>

function Show-CvProfilesWindow {
    <#
        Gestion de perfiles: los PROPIOS del config ('profiles') -crear, duplicar, editar, borrar- y
        debajo los de SERIE en solo lectura, que no se pueden tocar pero SI duplicar: partir de uno
        que ya funciona es la forma comoda de hacerse el suyo. Es el equivalente en ventana del
        submenu 'Perfiles' de setup, y escribe por las mismas funciones.

        Hasta 4.7.0 estos perfiles solo se podian escribir A MANO en config.json.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CfgPath
    )
    if (-not (Initialize-CvGui)) { return $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("Perfiles ({0})" -f (Split-Path -Leaf $CfgPath))
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(880, 520)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 420)
    $form.Name          = 'cvProfiles'

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 3
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    $form.Controls.Add($grid)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.HideSelection = $false
    $lv.MultiSelect   = $false
    $lv.Font          = (New-CvGuiFont 9)
    $lv.Name          = 'cvProfilesList'
    [void]$lv.Columns.Add('Nombre', 240)   # cabe el '*' del predeterminado sin comerse el nombre
    [void]$lv.Columns.Add('Tipo', 90)
    [void]$lv.Columns.Add('Que hace', 520)
    # 'Que hace' se queda con lo que sobre (y de paso no queda cabecera sin columna).
    [void](Set-CvGuiListFillColumn -List $lv -Index 2 -Min 300)
    [void](Set-CvGuiDoubleBuffered -Control $lv)
    $grid.Controls.Add($lv, 0, 0)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Dock      = 'Fill'
    $lblInfo.TextAlign = 'MiddleLeft'
    $lblInfo.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblInfo.Name      = 'cvProfilesInfo'
    $grid.Controls.Add($lblInfo, 0, 1)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 2)

    # Botones con AutoSize (un ancho fijo corta el texto en cuanto cambia la fuente o el DPI).
    $mkBtn = {
        param([string]$Text, [string]$Name, [int]$Width = 110)
        $b = New-Object System.Windows.Forms.Button
        $b.Text         = $Text
        $b.Height       = 30
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.MinimumSize  = New-Object System.Drawing.Size($Width, 30)
        $b.Margin       = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
        $b.Name         = $Name
        $bar.Controls.Add($b)
        return $b
    }
    $btnNew   = & $mkBtn 'Nuevo...'  'cvProfilesNew'
    $btnDup   = & $mkBtn 'Duplicar'  'cvProfilesDup'
    $btnEdit  = & $mkBtn 'Editar...' 'cvProfilesEdit'
    $btnDel   = & $mkBtn 'Borrar'    'cvProfilesDel'
    $btnDef   = & $mkBtn 'Predeterminado' 'cvProfilesDef' 130
    $btnClose = & $mkBtn 'Cerrar'    'cvProfilesClose'

    $st = @{ Rows = @(); Default = 'Auto' }
    $current = {
        if ($lv.SelectedIndices.Count -eq 0) { return $null }
        $i = $lv.SelectedIndices[0]
        if ($i -lt 0 -or $i -ge @($st.Rows).Count) { return $null }
        return @($st.Rows)[$i]
    }
    $enable = {
        $r = & $current
        $propio = ($null -ne $r -and "$($r.Kind)" -eq 'propio')
        # Duplicar vale para cualquiera (incluso uno de serie: de ahi sale un perfil propio nuevo);
        # editar y borrar, solo los propios: los de serie viven en el codigo.
        $btnDup.Enabled  = ($null -ne $r)
        $btnEdit.Enabled = $propio
        $btnDel.Enabled  = $propio
        # Predeterminado: marcarlo, o quitarlo si ya lo es (entonces vuelve a serlo 'Auto', que es
        # lo de fabrica). Cualquiera vale, tambien uno de serie: elegir no es editar.
        $esDef = ($null -ne $r -and "$($r.Label)" -eq "$($st.Default)")
        $btnDef.Enabled = ($null -ne $r)
        $btnDef.Text    = $(if ($esDef) { 'Quitar predet.' } else { 'Predeterminado' })
    }
    $reload = {
        # Rehacer la lista pierde la seleccion (Items.Clear), y aqui se rehace tambien al marcar el
        # predeterminado: sin devolverla, se queda sin fila marcada y los botones se apagan solos.
        $marcada = $(if ($lv.SelectedIndices.Count -gt 0) { [int]$lv.SelectedIndices[0] } else { -1 })
        $st.Rows    = @(Get-CvProfileManagerRows -Path $CfgPath)
        $st.Default = "$(Get-CvConfigDefaultProfile -Path $CfgPath)"
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            foreach ($r in $st.Rows) {
                # '*' delante del predeterminado, como en el menu de consola y en el dialogo.
                $it = New-Object System.Windows.Forms.ListViewItem($(if ("$($r.Label)" -eq "$($st.Default)") { "* $($r.Label)" } else { "  $($r.Label)" }))
                [void]$it.SubItems.Add($(if ("$($r.Kind)" -eq 'serie') { 'de serie' } else { 'propio' }))
                [void]$it.SubItems.Add("$($r.Text)")
                # Los de serie, en gris: se ve de un vistazo que ahi no se puede escribir.
                if ("$($r.Kind)" -eq 'serie') { $it.ForeColor = (Get-CvGuiCurrentPalette).Muted }
                [void]$lv.Items.Add($it)
            }
        } finally { $lv.EndUpdate() }
        if ($marcada -ge 0 -and $marcada -lt $lv.Items.Count) { $lv.Items[$marcada].Selected = $true }
        $propios = @($st.Rows | Where-Object { "$($_.Kind)" -eq 'propio' }).Count
        $serie   = @($st.Rows).Count - $propios
        $lblInfo.Text = $(if ($propios -eq 0) {
            ('Todavia no hay perfiles propios: con "Nuevo..." creas uno, o marca uno de los {0} de serie y "Duplicar" para partir de el.   *  = {1} (el que sale marcado al preparar).' -f $serie, $st.Default)
        } else {
            ('{0} propios (salen como [config] en el menu de perfiles) y {1} de serie, que no se editan pero se duplican.   *  = {2} (el que sale marcado al preparar).' -f $propios, $serie, $st.Default)
        })
        & $enable
    }
    $lv.Add_SelectedIndexChanged({ & $enable })

    $btnNew.Add_Click({
        [void](Show-CvProfileEditorWindow -Context $Context -CfgPath $CfgPath -ForSave)
        & $reload
    })
    $btnEdit.Add_Click({
        $r = & $current
        if ($null -eq $r -or "$($r.Kind)" -ne 'propio') { return }
        [void](Show-CvProfileEditorWindow -Context $Context -Prof $r.Prof -CfgPath $CfgPath -Name $r.Label -ForSave)
        & $reload
    })
    $btnDup.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        # Sin -Name: es OTRO perfil, asi que hay que ponerle un nombre nuevo (si se repite, se avisa).
        [void](Show-CvProfileEditorWindow -Context $Context -Prof $r.Prof -CfgPath $CfgPath -ForSave)
        & $reload
    })
    $btnDel.Add_Click({
        $r = & $current
        if ($null -eq $r -or "$($r.Kind)" -ne 'propio') { return }
        if (-not (Show-CvGuiConfirm -Title 'Perfiles' -Message ("Borrar el perfil '{0}'?" -f $r.Label))) { return }
        $res = Remove-CvConfigProfile -Path $CfgPath -Label $r.Label
        if (-not $res.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo borrar: {0}" -f $res.Error) }
        & $reload
    })
    $btnDef.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        $nuevo = $(if ("$($r.Label)" -eq "$($st.Default)") { 'Auto' } else { "$($r.Label)" })
        $res = Save-CvConfigDefaultProfile -Path $CfgPath -Label $nuevo
        if (-not $res.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo guardar: {0}" -f $res.Error) }
        & $reload
    })
    $btnClose.Add_Click({ $form.Close() })
    $lv.Add_DoubleClick({
        $r = & $current
        if ($null -ne $r -and "$($r.Kind)" -eq 'serie') { $btnDup.PerformClick() } else { $btnEdit.PerformClick() }
    })

    $form.Add_Shown({ & $reload })
    $form.CancelButton = $btnClose
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
