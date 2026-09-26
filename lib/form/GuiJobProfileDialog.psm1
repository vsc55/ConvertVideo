<#
    form\GuiJobProfileDialog.psm1 - DIALOGO de ELEGIR PERFIL para un lote (o para un job).

    El mismo paso que la consola hace una vez al empezar a preparar: que perfil se aplica. Los
    perfiles -los de serie y los tuyos- salen de lib\Profile.psm1, que es tambien quien los guarda:
    aqui no se escribe JSON.
#>

function Show-CvJobProfileDialog {
    <#
        Elige el PERFIL con el que preparar, igual que el menu de perfiles de la consola y con las
        MISMAS etiquetas (Get-CvJobProfileOptions -> Format-CvProfileLabel). Se pregunta UNA vez para
        todo el lote, como hace la consola al empezar PREPARAR.

        Ademas de elegir, desde aqui se MANTIENEN los perfiles propios (los de config.json, que en la
        lista salen como [config]): 'Ajustar...' permite guardar lo ajustado con un nombre, 'Nuevo...'
        parte de cero y 'Borrar' quita el marcado. Lo guardado aparece en la lista al momento -se
        relee del fichero, no del contexto- y tambien en el menu de la consola, que lee lo mismo.

        Devuelve el perfil elegido, o $null si se cancela.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Info = ''
    )
    if (-not (Initialize-CvGui)) { return $null }
    # Los perfiles propios se releen del FICHERO (no del contexto): asi uno recien guardado aparece
    # sin reiniciar la aplicacion.
    $cfgPath = "$($Context.ConfigPath)"
    $opts = @(Get-CvJobProfileOptions -Context $Context -Profiles $(if ($cfgPath) { @(Get-CvConfigProfiles -Path $cfgPath) } else { $null }))

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = (Get-CvText -Key 'perfil.tit')
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(720, 460)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $(if ($Info) { $Info } else { (Get-CvText -Key 'perfil.cual') })
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(696, 20)
    $form.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location       = New-Object System.Drawing.Point(12, 36)
    $lst.Size           = New-Object System.Drawing.Size(696, 370)
    $lst.Font           = (New-CvGuiFont 9)
    $lst.IntegralHeight = $false
    $lst.Name           = 'cvProfList'
    $form.Controls.Add($lst)

    # Rehacer la lista (al arrancar y despues de crear / editar / borrar un perfil propio). -Keep es
    # el nombre del perfil que hay que dejar marcado; sin el, el PREDETERMINADO (config
    # 'defaultProfile', que se elige en setup > Perfiles), y de fabrica ese es 'Auto'.
    $fill = {
        param([string]$Keep = '')
        $propios = @(if ($cfgPath) { @(Get-CvConfigProfiles -Path $cfgPath) } else { @() })
        $script:cvProfOpts = @(Get-CvJobProfileOptions -Context $Context -Profiles $propios)
        $opts = $script:cvProfOpts
        # Se relee del FICHERO, como los perfiles: cambiarlo en setup vale sin reiniciar.
        $defKey = Get-CvDefaultProfileKey -Default $(if ($cfgPath) { Get-CvConfigDefaultProfile -Path $cfgPath } else { '' }) -Extra $propios
        $lst.BeginUpdate()
        try {
            $lst.Items.Clear()
            foreach ($o in $opts) {
                $tag = if ($o.Group -eq 'config.json') { '[config] ' } else { '' }
                # '*' delante del predeterminado, igual que en el menu de consola.
                $pre = $(if ("$($o.Key)" -eq "$defKey") { '* ' } else { '  ' })
                [void]$lst.Items.Add(("{0}{1}{2}" -f $pre, $tag, $o.Text))
            }
        } finally { $lst.EndUpdate() }
        $sel = 0
        for ($i = 0; $i -lt $opts.Count; $i++) {
            if ("$($opts[$i].Key)" -eq "$defKey") { $sel = $i }
        }
        if ("$Keep" -ne '') {
            for ($i = 0; $i -lt $opts.Count; $i++) {
                if ("$($opts[$i].Label)" -ne '' -and "$($opts[$i].Label)" -eq "$Keep") { $sel = $i; break }
            }
        }
        if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = $sel }
    }
    & $fill

    $st = @{ Prof = $null }
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = (Get-CvText -Key 'comun.aceptar')
    $btnOk.Size     = New-Object System.Drawing.Size(120, 30)
    $btnOk.Location = New-Object System.Drawing.Point(462, 416)
    $btnOk.Name     = 'cvProfOk'
    $btnOk.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        if ($i -ge 0 -and $i -lt $opts.Count) { $st.Prof = $opts[$i].Prof }
        $form.Close()
    })
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = (Get-CvText -Key 'comun.cancelar')
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(588, 416)
    $btnCancel.Name     = 'cvProfCancel'
    $btnCancel.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancel)

    # 'Ajustar...' = la opcion Custom del menu de consola: partir del perfil marcado y cambiarle lo
    # que haga falta (bitrate, encoder, ancho maximo...). Lo que salga se usa tal cual.
    $btnTune = New-Object System.Windows.Forms.Button
    $btnTune.Text     = (Get-CvText -Key 'comun.ajustar')
    $btnTune.Size     = New-Object System.Drawing.Size(110, 30)
    $btnTune.Location = New-Object System.Drawing.Point(12, 416)
    $btnTune.Name     = 'cvProfTune'
    $btnTune.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        $base = if ($i -ge 0 -and $i -lt $opts.Count) { $opts[$i].Prof } else { $null }
        # Con -CfgPath, el editor ofrece ademas GUARDARLO con nombre; si se guarda, tambien se usa
        # aqui (que es a lo que se habia venido).
        $tuned = Show-CvProfileEditorWindow -Context $Context -Prof $base -CfgPath $cfgPath
        if ($null -ne $tuned) { $st.Prof = $tuned; $form.Close() }
    })
    $form.Controls.Add($btnTune)

    # 'Nuevo...' = crear un perfil PROPIO desde cero y dejarlo guardado en el config. Se queda
    # marcado en la lista, pero no se cierra el dialogo: crear no es elegir.
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text     = (Get-CvText -Key 'comun.nuevo')
    $btnNew.Size     = New-Object System.Drawing.Size(110, 30)
    $btnNew.Location = New-Object System.Drawing.Point(130, 416)
    $btnNew.Name     = 'cvProfNew'
    $btnNew.Enabled  = ($cfgPath -ne '')
    $btnNew.Add_Click({
        # Para dejar marcado el que se acaba de crear: se mira que nombre hay ahora y no antes (el
        # editor devuelve el perfil, no con que nombre se guardo).
        $antes = @(@(Get-CvConfigProfiles -Path $cfgPath) | ForEach-Object { Get-CvProfileLabel $_ })
        [void](Show-CvProfileEditorWindow -Context $Context -CfgPath $cfgPath -ForSave)
        $nuevo = @(@(Get-CvConfigProfiles -Path $cfgPath) | ForEach-Object { Get-CvProfileLabel $_ } | Where-Object { $antes -notcontains $_ })
        & $fill $(if ($nuevo.Count -gt 0) { "$($nuevo[0])" } else { '' })
    })
    $form.Controls.Add($btnNew)

    # 'Borrar' solo vale para los PROPIOS: los de serie no estan en ningun fichero que se pueda tocar.
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text     = (Get-CvText -Key 'comun.borrar')
    $btnDel.Size     = New-Object System.Drawing.Size(110, 30)
    $btnDel.Location = New-Object System.Drawing.Point(248, 416)
    $btnDel.Name     = 'cvProfDel'
    $btnDel.Enabled  = $false
    $btnDel.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $opts.Count) { return }
        $lbl = "$($opts[$i].Label)"
        if ($lbl -eq '') { return }
        if (-not (Show-CvGuiConfirm -Title (Get-CvText -Key 'perfiles.tit') -Message (Get-CvText -Key 'perfil.borrar.msg' -Values @($lbl)))) { return }
        $r = Remove-CvConfigProfile -Path $cfgPath -Label $lbl
        if (-not $r.Ok) { Show-CvGuiInfo -Title (Get-CvText -Key 'perfiles.tit') -Message (Get-CvText -Key 'perfil.borrar.no' -Values @($r.Error)) }
        & $fill
    })
    $form.Controls.Add($btnDel)

    # Borrar solo se enciende sobre un perfil propio.
    $lst.Add_SelectedIndexChanged({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        # Solo los propios CON nombre: uno escrito a mano en el config sin 'label' no se puede
        # identificar para borrarlo.
        $btnDel.Enabled = ($cfgPath -ne '') -and ($i -ge 0) -and ($i -lt $opts.Count) -and ("$($opts[$i].Label)" -ne '')
    })

    $lst.Add_DoubleClick({ $btnOk.PerformClick() })
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Prof
}

Export-ModuleMember -Function *
