<#
    form\GuiWorkerLogWindow.psm1 - VENTANA del log de un worker (o del de la sesion).

    Se abre desde la cola para mirar en vivo lo que escribe un worker concreto. El repintado va por
    Update-CvGuiLogView (lib\Gui.psm1), que solo toca el control cuando el fichero ha cambiado de
    verdad; la lista de logs a elegir sale de Get-CvConvertLogChoices (lib\GuiConvert.psm1).
#>

function Show-CvWorkerLogWindow {
    <#
        Ventana con lo que esta haciendo UN worker: su log en vivo. Se abre BAJO PETICION -doble clic
        en la fila que se esta codificando, o el menu contextual-, que es mas barato que tener una
        pestana por worker abierta todo el rato.

        Es MODAL, como el resto de dialogos del programa: mientras esta abierta no se toca la cola
        (que sigue refrescandose por dentro). Se probo a hacerla sin modo, para poder dejarla mirando
        mientras se trabaja en la lista, y no salio bien: toda la aplicacion cuelga de ShowDialog y
        una ventana sin modo encima dejaba ventanas que no se cerraban. Si algun dia se cambia, hay
        que validarlo con una ventana abierta de verdad, no solo con la bateria.

        Lee el TRANSCRIPT del worker (logs\Convert_<fecha>_<PID>.log, cuya ruta publica el propio
        worker en su fichero de estado), asi que:
          - depende de behavior.log (si esta apagado no hay nada que leer, y se dice);
          - va unos segundos por detras, porque PowerShell vuelca el transcript por bloques;
          - NO trae la barra de progreso en vivo: desde 4.6.0 esa linea se escribe con
            [Console]::Write justo para no inundar el log. El % en vivo esta en la fila de la cola.

        Devuelve $true cuando se cierra.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [int]$WorkerPid  = 0,
        [string]$LogPath = '',
        [string]$File    = '',
        # Texto FIJO: el trozo de log de un archivo que ya termino (no hay worker al que seguir).
        [string]$Text    = ''
    )
    if (-not (Initialize-CvGui)) { return $null }
    $vivo = ($WorkerPid -gt 0 -and "$Text" -eq '')

    $st = @{
        Stamp = ''
        Path  = "$LogPath"
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = $(if ($vivo) {
        ("Worker #{0}{1}" -f $WorkerPid, $(if ($File) { " - $File" } else { '' }))
    } else {
        ("Proceso de {0}" -f $(if ($File) { $File } else { 'este archivo' }))
    })
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(980, 560)
    $form.MinimumSize   = New-Object System.Drawing.Size(560, 320)
    $form.Name          = 'cvWorkerLog'

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(8)
    $grid.ColumnCount = 1
    $grid.RowCount    = 3
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
    $form.Controls.Add($grid)

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Dock      = 'Fill'
    $lblHead.TextAlign = 'MiddleLeft'
    $lblHead.Name      = 'cvWlHead'
    $grid.Controls.Add($lblHead, 0, 0)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Dock       = 'Fill'
    $txt.Multiline  = $true
    $txt.ReadOnly   = $true
    $txt.ScrollBars = 'Both'
    $txt.WordWrap   = $false
    $txt.Font       = (New-CvGuiFont 9)
    $txt.Name       = 'cvWlText'
    $grid.Controls.Add($txt, 0, 1)
    [void](Set-CvGuiDoubleBuffered -Control $txt)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 2)

    $chkFollow = New-Object System.Windows.Forms.CheckBox
    $chkFollow.Text     = 'Seguir el final'
    $chkFollow.Checked  = $true
    $chkFollow.Visible  = $vivo     # en un log ya terminado no hay nada que seguir
    $chkFollow.AutoSize = $true
    $chkFollow.Margin   = New-Object System.Windows.Forms.Padding(3, 6, 12, 3)
    $chkFollow.Name     = 'cvWlFollow'
    $bar.Controls.Add($chkFollow)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text   = 'Abrir fuera'
    $btnOpen.Width  = 110
    $btnOpen.Height = 26
    $btnOpen.Name   = 'cvWlOpen'
    $bar.Controls.Add($btnOpen)
    $btnOpen.Add_Click({
        if (-not $st.Path) { return }
        [void](Open-CvGuiPath -Path "$($st.Path)" -Title 'Log' -Quiet)
    })

    # Refresco: solo se relee si el fichero ha cambiado (tamano+fecha), y solo el rabo. En el modo
    # de archivo TERMINADO no hay nada que refrescar: se pinta el trozo de log y se acabo.
    $tick = {
        try {
            if (-not $vivo) {
                $lblHead.Text = ("Asi quedo: {0}{1}" -f $File, $(if ($st.Path) { "   (de {0})" -f [System.IO.Path]::GetFileName($st.Path) } else { '' }))
                if ($txt.Text -eq '') {
                    $txt.Text = $(if ("$Text" -ne '') { $Text } else { 'No se encontro en los logs el paso de este archivo (puede que se convirtiera hace mucho, o con behavior.log apagado).' })
                }
                return
            }
            $w = @(Get-CvWorkerStates -Context $Context | Where-Object { [int]$_.Pid -eq $WorkerPid })
            if ($w.Count -gt 0) {
                if ("$($w[0].Log)" -ne '') { $st.Path = "$($w[0].Log)" }
                $lblHead.Text = $(if ([bool]$w[0].Alive) {
                    ("Worker #{0}: {1}{2}" -f $WorkerPid, $(if ("$($w[0].File)") { "$($w[0].File)" } else { 'sin archivo' }), $(if ("$($w[0].Step)") { "  -  $($w[0].Step)" } else { '' }))
                } else {
                    ("Worker #{0}: ya no esta en marcha (esto es lo ultimo que dejo escrito)" -f $WorkerPid)
                })
            } else {
                $lblHead.Text = ("Worker #{0}: ya no esta en marcha" -f $WorkerPid)
            }
            # Seguir el log (solo relee si ha cambiado, solo repinta si es otro texto): lo mismo
            # que hace la pestana Log de la cola, en una sola funcion (Update-CvGuiLogView).
            [void](Update-CvGuiLogView -TextBox $txt -State $st -Key 'Stamp' -Path "$($st.Path)" `
                -Follow ([bool]$chkFollow.Checked) `
                -EmptyText 'Este worker no dejo log. Se escribe solo con behavior.log activado en la configuracion.')
        } catch { }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick($tick)
    $form.Add_Shown({ & $tick; if ($vivo) { $timer.Start() } })
    $form.Add_FormClosing({ $timer.Stop() })
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
