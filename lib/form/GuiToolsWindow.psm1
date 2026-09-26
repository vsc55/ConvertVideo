<#
    form\GuiToolsWindow.psm1 - VENTANA de las herramientas (ffmpeg, mkvtoolnix, aacgain, 7zr).

    Que version hay instalada de cada una, cual es la predeterminada y que se puede instalar. Los
    DATOS salen de lib\SetupCore.psm1 y la descarga la hace lib\Tools.psm1 (con verificacion SHA256),
    lanzada como 'setup.ps1 -Task install ...' en su propia consola: instalar es largo.
#>

function Show-CvToolsWindow {
    <#
        Instalar / cambiar la version de una herramienta del catalogo 'downloads'. Lista las apps con
        su estado (versiones instaladas y cual es la 'selected') y, al elegir una, sus versiones
        descargables. La instalacion se lanza con 'setup.ps1 -Task install' en su propia consola
        (descarga + verificacion SHA256 + comprobacion NVENC pueden tardar), y al cerrarse esa consola
        se refresca la lista.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CfgPath
    )
    if (-not (Initialize-CvGui)) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Herramientas (instalar / versiones)'
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(720, 500)

    $lstApps = New-Object System.Windows.Forms.ListBox
    $lstApps.Location = New-Object System.Drawing.Point(12, 30)
    $lstApps.Size     = New-Object System.Drawing.Size(330, 320)
    $lstApps.Font     = (New-CvGuiFont 9)
    $form.Controls.Add($lstApps)

    $lblApps = New-Object System.Windows.Forms.Label
    $lblApps.Text     = 'Herramienta:'
    $lblApps.AutoSize = $true
    $lblApps.Location = New-Object System.Drawing.Point(12, 10)
    $form.Controls.Add($lblApps)

    $lblVers = New-Object System.Windows.Forms.Label
    $lblVers.Text     = 'Version a instalar:'
    $lblVers.AutoSize = $true
    $lblVers.Location = New-Object System.Drawing.Point(360, 10)
    $form.Controls.Add($lblVers)

    $lstVers = New-Object System.Windows.Forms.ListBox
    $lstVers.Location = New-Object System.Drawing.Point(360, 30)
    $lstVers.Size     = New-Object System.Drawing.Size(320, 250)
    $lstVers.Font     = (New-CvGuiFont 9)
    $form.Controls.Add($lstVers)

    $chkDef = New-Object System.Windows.Forms.CheckBox
    $chkDef.Text     = 'Fijar como version por defecto (selected)'
    $chkDef.AutoSize = $true
    $chkDef.Checked  = $true
    $chkDef.Location = New-Object System.Drawing.Point(360, 290)
    $form.Controls.Add($chkDef)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text     = 'Instalar'
    $btnInstall.Location = New-Object System.Drawing.Point(360, 318)
    $btnInstall.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnInstall)

    # Poner en uso una version que YA esta instalada, sin volver a descargarla: es lo que hacia falta
    # para volver atras sin reinstalar (y para arreglar un 'selected' que apunta a una version que se
    # ha borrado). La regla -solo versiones instaladas- vive en Set-CvSetupVersionInUse.
    $btnUse = New-Object System.Windows.Forms.Button
    $btnUse.Text     = 'Usar esta version'
    $btnUse.Location = New-Object System.Drawing.Point(360, 356)
    $btnUse.Size     = New-Object System.Drawing.Size(150, 30)
    $btnUse.Name     = 'cvToolUse'
    $form.Controls.Add($btnUse)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Cerrar'
    $btnClose.Location = New-Object System.Drawing.Point(530, 318)
    $btnClose.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnClose)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.AutoSize  = $false
    $lblInfo.Location  = New-Object System.Drawing.Point(12, 396)
    $lblInfo.Size      = New-Object System.Drawing.Size(668, 50)
    $lblInfo.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $form.Controls.Add($lblInfo)

    $st = @{ Apps = @() }

    $reload = {
        $sel = $lstApps.SelectedIndex
        $st.Apps = @(Get-CvSetupToolStatus -Context $Context)
        $lstApps.Items.Clear()
        foreach ($t in $st.Apps) {
            if (-not $t.Supported) {
                [void]$lstApps.Items.Add(("{0} {1,-10} NO SOPORTADO ({2})" -f (Get-CvMark $false), $t.Name, $t.Platform))
            } else {
                $instTxt = if (@($t.Installed).Count) { (@($t.Installed) -join ', ') } else { 'ninguna' }
                [void]$lstApps.Items.Add(("{0} {1,-10} sel:{2,-8} inst: {3}" -f (Get-CvMark $t.SelectedOk), $t.Name, $t.Selected, $instTxt))
            }
        }
        if ($lstApps.Items.Count -gt 0) { $lstApps.SelectedIndex = [Math]::Max(0, [Math]::Min($sel, $lstApps.Items.Count - 1)) }
    }

    $lstApps.Add_SelectedIndexChanged({
        $lstVers.Items.Clear()
        $i = $lstApps.SelectedIndex
        if ($i -lt 0 -or $i -ge @($st.Apps).Count) { return }
        $t = @($st.Apps)[$i]
        foreach ($v in (Get-CvSetupAppVersions -Context $Context -Name $t.Name)) {
            $tag = ''
            if ("$v" -eq "$($t.Selected)") { $tag = '   (por defecto)' }
            if (@($t.Installed) -contains "$v") { $tag += '   [instalada]' }
            [void]$lstVers.Items.Add(("{0}{1}" -f $v, $tag))
        }
        if ($lstVers.Items.Count -gt 0) { $lstVers.SelectedIndex = 0 }
        $btnUse.Enabled = ($t.Supported -and @($t.Installed).Count -gt 0)
        $lblInfo.Text = if ($t.Supported) {
            'Instalar descarga y verifica (consola aparte). "Usar esta version" solo cambia cual se usa, entre las ya instaladas.'
        } else {
            ("{0} no tiene build para la plataforma de este equipo ({1})." -f $t.Name, $t.Platform)
        }
    })

    $btnInstall.Add_Click({
        $i = $lstApps.SelectedIndex
        if ($i -lt 0 -or $i -ge @($st.Apps).Count) { return }
        $t = @($st.Apps)[$i]
        if (-not $t.Supported) { Show-CvGuiInfo -Title 'Herramientas' -Message ("{0} no esta soportada en esta plataforma." -f $t.Name); return }
        if ($lstVers.SelectedIndex -lt 0) { Show-CvGuiInfo -Title 'Herramientas' -Message 'Elige una version.'; return }
        $ver = ("$($lstVers.SelectedItem)" -split '\s+')[0]
        if (-not (Show-CvGuiConfirm -Title 'Instalar' -Message ("Instalar {0} {1}?`n`nSe borra esa version si ya estaba y se descarga de nuevo." -f $t.Name, $ver))) { return }
        $targs = @('-Task', 'install', '-App', $t.Name, '-Version', $ver)
        if ($chkDef.Checked) { $targs += '-SetDefault' }
        $form.Enabled = $false
        try {
            [void](Start-CvSetupTask -Root $Root -CfgPath $CfgPath -TaskArgs $targs -Wait)
        } finally {
            $form.Enabled = $true
        }
        & $reload
    })
    # Usar una version YA instalada, sin descargar nada: es lo que faltaba para volver a una version
    # anterior que ya se tenia (y para arreglar un 'selected' que apunta a una version borrada).
    $btnUse.Add_Click({
        $i = $lstApps.SelectedIndex
        if ($i -lt 0 -or $i -ge @($st.Apps).Count) { return }
        $t = @($st.Apps)[$i]
        if ($lstVers.SelectedIndex -lt 0) { Show-CvGuiInfo -Title 'Herramientas' -Message 'Elige una version.'; return }
        $ver = ("$($lstVers.SelectedItem)" -split '\s+')[0]
        $r = Set-CvSetupVersionInUse -Context $Context -CfgPath $CfgPath -Name $t.Name -Version $ver
        $lblInfo.Text = $(if ($r.Ok) { ("Hecho: {0} (en {1}). No se ha descargado nada." -f $r.Reason, (Split-Path -Leaf $CfgPath)) } else { $r.Reason })
        if ($r.Ok) { & $reload }
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
