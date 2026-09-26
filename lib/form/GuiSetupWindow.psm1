<#
    form\GuiSetupWindow.psm1 - VENTANA de setup: el mismo setup de siempre, con raton.

    Hermana en modo grafico de setup.ps1 (consola). Las dos pintan EXACTAMENTE lo mismo porque los
    DATOS salen de lib\SetupCore.psm1 (fuente unica): aqui solo cambia el RENDER (botones y panel de
    salida en vez de menus numerados), con los textos de lib\GuiSetup.psm1.

    Las acciones LARGAS (instalar una herramienta, lanzar una bateria de tests) NO se ejecutan en la
    ventana: se lanzan con Start-CvSetupTask en su propia consola, para ver el progreso en vivo sin
    que WinForms -de un solo hilo- se quede congelado.

    Desde aqui se abren sus dialogos: form\GuiToolsWindow.psm1, form\GuiLogsWindow.psm1,
    form\GuiMaintenanceWindow.psm1 y el editor de config (form\GuiConfigWindow.psm1) y los perfiles
    (form\GuiProfilesWindow.psm1), que tambien se abren desde la cola.
#>

function Show-CvSetupWindow {
    <#
        Ventana principal de setup: los mismos grupos y acciones que el menu de consola (herramientas,
        estado, compatibilidad GPU, pruebas, configuracion, limpieza) como botones, con un panel de
        SALIDA donde se vuelca el resultado de cada accion. Devuelve cuando el usuario cierra.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CfgPath,
        [string]$CfgName = 'config.json',
        [bool]$IsAlt = $false,
        # Log de la sesion EN CURSO: el visor lo marca y la limpieza lo respeta (esta en uso).
        [string]$CurrentLog = ''
    )
    if (-not (Initialize-CvGui)) { return $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("{0} {1} - Setup" -f $Context.AppName, $Context.Version)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize   = New-Object System.Drawing.Size(860, 560)
    # Se abre COMO SE DEJO (lo mismo que la cola): el tamano recordado se valida contra los minimos y
    # contra la pantalla de hoy, y si no hay nada apuntado se usa el de la config (gui.setupWidth /
    # gui.setupHeight). Lo manda gui.rememberLayout.
    $pantalla = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $recordado = $(if ([bool]$Context.GuiRemember) { Get-CvGuiLayout -Context $Context -Key 'setup' } else { $null })
    $tam = Resolve-CvGuiWindowSize -Layout $recordado `
        -DefaultWidth ([int]$Context.GuiSetupWidth) -DefaultHeight ([int]$Context.GuiSetupHeight) `
        -MinWidth 860 -MinHeight 560 -MaxWidth $pantalla.Width -MaxHeight $pantalla.Height
    $form.Size = New-Object System.Drawing.Size([int]$tam.Width, [int]$tam.Height)
    if ([bool]$tam.Maximized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized }
    $form.Add_FormClosing({
        # En FormClosing una excepcion se lleva la aplicacion por delante: esto no puede lanzar.
        if (-not [bool]$Context.GuiRemember) { return }
        try {
            $max = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
            $rb  = $(if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) { $form.Bounds } else { $form.RestoreBounds })
            [void](Save-CvGuiLayout -Context $Context -Key 'setup' -Layout ([ordered]@{
                width     = [int]$rb.Width
                height    = [int]$rb.Height
                maximized = $max
            }))
        } catch { }
    })

    # --- panel de acciones (izquierda) ---
    $side = New-Object System.Windows.Forms.FlowLayoutPanel
    $side.Dock          = 'Left'
    $side.Width         = 330
    $side.FlowDirection = 'TopDown'
    $side.WrapContents  = $false
    $side.AutoScroll    = $true
    $side.Padding       = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($side)

    # --- salida (derecha): titulo de la accion + texto ---
    # En REJILLA y no con Dock Top+Fill: el reparto de un Dock depende del z-order y el titulo acababa
    # pintado ENCIMA de las dos primeras lineas del texto. Con TableLayoutPanel cada fila es suya.
    $outBox = New-Object System.Windows.Forms.TableLayoutPanel
    $outBox.Dock        = 'Fill'
    $outBox.Padding     = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $outBox.ColumnCount = 1
    $outBox.RowCount    = 2
    [void]$outBox.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$outBox.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    [void]$outBox.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($outBox)
    $outBox.BringToFront()

    # Titulo de la accion en su propia etiqueta (antes eran lineas de '=' dentro del texto, que
    # forzaban un ancho minimo de 78 caracteres y provocaban la barra horizontal).
    $outTitle = New-Object System.Windows.Forms.Label
    $outTitle.Dock      = 'Fill'
    $outTitle.AutoSize  = $false
    $outTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $outTitle.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $outTitle.Text      = 'ESTADO'
    $outBox.Controls.Add($outTitle, 0, 0)

    $out = New-Object System.Windows.Forms.RichTextBox
    $out.Dock       = 'Fill'
    $out.ReadOnly   = $true
    # WordWrap ACTIVO: las lineas del informe son largas y, sin ajuste, la caja salia con barra
    # horizontal y el texto medio escondido. Se ajustan al ancho y la ventana se puede agrandar.
    $out.WordWrap   = $true
    $out.Font       = (New-CvGuiFont 9)
    $out.DetectUrls = $false
    $out.BorderStyle = 'None'
    $outBox.Controls.Add($out, 0, 1)

    $status = New-Object System.Windows.Forms.StatusStrip
    $lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
    $lblStatus.Text = ("config: {0}" -f $CfgPath)
    [void]$status.Items.Add($lblStatus)
    $form.Controls.Add($status)

    # Escribe en el panel de salida (reemplaza el contenido; el titulo va en su etiqueta).
    $write = {
        param([string]$Title, [string]$Body)
        $outTitle.Text = $Title
        $out.Text      = $Body
        $out.SelectionStart  = 0        # dejar la vista arriba del todo, no donde estuviera antes
        $out.SelectionLength = 0
        $out.ScrollToCaret()
    }
    $busy = {
        param([string]$Msg)
        $out.Text = $Msg
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $out.Refresh(); $form.Refresh()
    }

    # Helper para crear cada boton del panel lateral.
    $addHeader = {
        param([string]$Text)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $Text
        $l.AutoSize  = $true
        $l.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $l.ForeColor = (Get-CvGuiCurrentPalette).Muted
        $l.Margin    = New-Object System.Windows.Forms.Padding(3, 10, 3, 2)
        $side.Controls.Add($l)
    }
    $addButton = {
        param([string]$Text, $OnClick)
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $Text
        $b.Width     = 290
        $b.Height    = 32
        $b.TextAlign = 'MiddleLeft'
        $b.Margin    = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
        $b.Add_Click($OnClick)
        $side.Controls.Add($b)
        return $b
    }

    & $addHeader 'Herramientas'
    [void](& $addButton '  Instalar / gestionar herramientas...' {
        Show-CvToolsWindow -Context $Context -Root $Root -CfgPath $CfgPath
        & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt)
    })

    & $addHeader 'Estado'
    [void](& $addButton '  Ver estado (directorios y herramientas)' {
        & $busy 'Recogiendo el estado...'
        try { & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt) }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

    & $addHeader 'Compatibilidad'
    [void](& $addButton '  Comprobar compatibilidad GPU (NVENC)' {
        & $busy 'Sondeando los encoders por GPU (puede tardar unos segundos)...'
        try { & $write 'COMPATIBILIDAD GPU' (Get-CvSetupGpuText -Context $Context) }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

    & $addHeader 'Pruebas'
    foreach ($s in (Get-CvSetupTestSuites)) {
        # Copia local: sin ella todos los botones compartirian la ultima $s del bucle.
        $suite = "$($s.Value)"
        $label = "$($s.Text)"
        $info  = "$($s.Info)"
        [void](& $addButton ("  {0}" -f $label) {
            [void](Start-CvSetupTask -Root $Root -CfgPath $CfgPath -TaskArgs @('-Task', 'tests', '-Suite', $suite))
            & $write 'PRUEBAS' ("Lanzada la bateria '{0}' en una consola aparte ({1})." -f $label, $info)
        }.GetNewClosure())
    }

    & $addHeader 'Configuracion'
    [void](& $addButton ("  Editar configuracion ({0})" -f $CfgName) {
        if (Show-CvConfigWindow -Root $Root -CfgPath $CfgPath -CfgName $CfgName) {
            & $write 'CONFIGURACION' ("{0} actualizado. Los cambios se aplican en la proxima conversion." -f $CfgName)
        } else {
            & $write 'CONFIGURACION' 'Sin cambios.'
        }
    })
    # Perfiles: crear / duplicar / editar / borrar los PROPIOS de config.json ('profiles'), y los
    # de serie en solo lectura para poder duplicarlos. La ventana vive en GuiProfile.psm1 porque la
    # comparten setup y la cola.
    [void](& $addButton '  Perfiles...' {
        [void](Show-CvProfilesWindow -Context $Context -CfgPath $CfgPath)
        & $write 'PERFILES' (Get-CvSetupProfilesText -CfgPath $CfgPath)
    })
    [void](& $addButton ("  Restablecer {0}" -f $CfgName) {
        $msg = ("Restablecer {0} a los valores por defecto?`n`nSe CONSERVA el catalogo de herramientas (downloads).`nSe guarda una copia en {0}.bak." -f $CfgName)
        if (-not (Show-CvGuiConfirm -Title 'Restablecer configuracion' -Message $msg)) { & $write 'CONFIGURACION' 'Cancelado.'; return }
        [void](Reset-CvConfig -Path $CfgPath)
        & $write 'CONFIGURACION' ("{0} restablecido (copia en {0}.bak; catalogo de herramientas conservado)." -f $CfgName)
    })

    # MANTENIMIENTO en un sitio: jobs, bloqueos, temporales, logs viejos y caches de las ventanas.
    # Antes eran tres botones repartidos entre 'Limpieza' y 'Logs' y habia que ir a buscarlos.
    & $addHeader 'Mantenimiento'
    [void](& $addButton '  Limpiar (jobs, bloqueos, logs, caches)...' {
        $n = Show-CvMaintenanceWindow -Context $Context -CurrentLog $CurrentLog
        & $write 'MANTENIMIENTO' (("Borrados {0} elemento(s). Queda esto:`n`n" -f $n) + (Get-CvSetupMaintenanceText -Context $Context -CurrentLog $CurrentLog))
    })
    [void](& $addButton '  Limpiar Proceso fichero a fichero...' {
        Show-CvCleanWindow -Context $Context
        & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt)
    })

    & $addHeader 'Logs'
    [void](& $addButton '  Ver logs...' {
        Show-CvLogsWindow -Context $Context -CurrentLog $CurrentLog
        & $write 'LOGS' ("{0} log(s) en {1}." -f @(Get-CvSetupLogFiles -Context $Context).Count, $Context.Logs)
    })
    # Si el MENU no cabe en el alto de la ventana, se agranda hasta que quepa (sin pasarse de la
    # pantalla). Asi anadir una opcion no deja la ultima seccion cortada detras de una barra de
    # scroll -que es justo lo que paso al meter 'Mantenimiento'-. Si el usuario dejo un tamano
    # apuntado, manda el suyo: lo eligio el.
    $form.Add_Load({
        try {
            if ($null -ne $recordado) { return }
            $ult = @($side.Controls)[(@($side.Controls).Count - 1)]
            if ($null -eq $ult) { return }
            $falta = ([int]$ult.Bottom + 12) - [int]$side.ClientSize.Height
            if ($falta -gt 0) {
                $libre = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea.Height
                $form.Height = [Math]::Min($libre, ([int]$form.Height + $falta))
            }
        } catch { }
    }.GetNewClosure())

    # Estado nada mas abrir, para que la ventana no arranque vacia.
    & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt)
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
