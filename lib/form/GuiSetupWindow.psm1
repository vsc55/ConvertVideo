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
        [string]$CurrentLog = '',
        # Pantalla de arranque (Start-CvSplashWindow) que se quita en cuanto la ventana se dibuja.
        $Splash = $null,
        # Seccion que se abre sola en cuanto la ventana se ve: 'config' o 'tools' (la piden los
        # botones de la cola). Es lo mismo que pulsar su boton.
        [string]$Open = ''
    )
    if (-not (Initialize-CvGui)) { return $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = (Get-CvText -Key 'setup.tit' -Values @($Context.AppName, $Context.Version))
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
        # Con el contexto de AHORA ($vivo, se rehace al guardar config): apagar gui.rememberLayout en
        # el editor no servia hasta volver a abrir setup.
        $ctxAhora = if ($null -ne $vivo -and $null -ne $vivo.Ctx) { $vivo.Ctx } else { $Context }
        if (-not [bool]$ctxAhora.GuiRemember) { return }
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
    $side.Name          = 'cvSetupMenu'   # con nombre para poder mirar el MENU sin raton (bateria)
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
    $outTitle.Font      = Get-CvGuiFont -Size 10 -Style Bold
    $outTitle.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $outTitle.Text      = (Get-CvText -Key 'setup.cab.estado')
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
    $out.Name        = 'cvSetupOut'   # con nombre para poder leer el panel sin raton (bateria)
    $outBox.Controls.Add($out, 0, 1)

    $status = New-Object System.Windows.Forms.StatusStrip
    $lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
    $lblStatus.Text = (Get-CvText -Key 'setup.cfg.actual' -Values @($CfgPath))
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

    # EL CONTEXTO, EN UNA TABLA. Lo que se guarde en el editor de configuracion puede cambiar hasta
    # las carpetas de trabajo (paths.base), asi que el $ctx con el que se abrio la ventana deja de
    # valer y hay que REHACERLO. Va en un hashtable porque asignar $Context = ... dentro de un
    # manejador crearia una variable local y el cambio no saldria de ahi (ver ref-gotchas.md). La
    # consola no tiene este problema: rehace su contexto en cada vuelta al menu.
    $vivo = @{ Ctx = $Context }
    $recarga = {
        try { $vivo.Ctx = New-CvContext -Root $Root -ConfigPath $CfgPath; return '' }
        catch { return "$($_.Exception.Message)" }
    }

    # Helper para crear cada boton del panel lateral.
    $addHeader = {
        param([string]$Text)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $Text
        $l.AutoSize  = $true
        $l.Font      = Get-CvGuiFont -Size 9 -Style Bold
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

    # Los dos espacios de delante de cada boton son sangria del menu, no parte del texto.
    # ESTADO va primero: es lo que se ensena al abrir -y lo que se mira cuando algo no cuadra-, asi
    # que el menu empieza por ahi. La comprobacion de la GPU va en la misma seccion: tambien es
    # "como esta esto", no una accion que cambie nada.
    & $addHeader (Get-CvText -Key 'setup.sec.estado')
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.estado')) {
        & $busy (Get-CvText -Key 'setup.busy.estado')
        try { & $write (Get-CvText -Key 'setup.cab.estado') (Get-CvSetupStatusText -Context $vivo.Ctx -CfgPath $CfgPath -IsAlt $IsAlt) }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.gpu')) {
        & $busy (Get-CvText -Key 'setup.busy.gpu')
        try { & $write (Get-CvText -Key 'setup.cab.gpu') (Get-CvSetupGpuText -Context $vivo.Ctx) }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

    & $addHeader (Get-CvText -Key 'setup.sec.herr')
    $btnHerr = (& $addButton ('  ' + (Get-CvText -Key 'setup.btn.herr')) {
        Show-CvToolsWindow -Context $vivo.Ctx -Root $Root -CfgPath $CfgPath
        [void](& $recarga)   # se puede haber cambiado la version EN USO: el contexto la lleva dentro
        & $write (Get-CvText -Key 'setup.cab.estado') (Get-CvSetupStatusText -Context $vivo.Ctx -CfgPath $CfgPath -IsAlt $IsAlt)
    })
    $btnHerr.Name = 'cvSetupTools'

    & $addHeader (Get-CvText -Key 'setup.sec.pruebas')
    foreach ($s in (Get-CvSetupTestSuites)) {
        # Copia local: sin ella todos los botones compartirian la ultima $s del bucle.
        $suite = "$($s.Value)"
        $label = "$($s.Text)"
        $info  = "$($s.Info)"
        [void](& $addButton ("  {0}" -f $label) {
            [void](Start-CvSetupTask -Root $Root -CfgPath $CfgPath -TaskArgs @('-Task', 'tests', '-Suite', $suite))
            & $write (Get-CvText -Key 'setup.cab.pruebas') (Get-CvText -Key 'setup.pruebas.lanzada' -Values @($label, $info))
        }.GetNewClosure())
    }

    # Que monitor es cada uno (para gui.testScreenNumber): su numero, en grande, en cada pantalla.
    $btnMon = (& $addButton ('  ' + (Get-CvText -Key 'setup.btn.monitores')) {
        $ini = Get-CvStartupPrefs -Root $Root -Path $CfgPath
        $filas = @(Show-CvGuiMonitorIds -Seconds ([int]$vivo.Ctx.GuiIdentifySec) -Mode "$($ini.TestScreen)" -Number ([int]$ini.TestScreenNumber))
        $txt = @($filas | ForEach-Object {
            $n = @((Get-CvText -Key 'mon.resolucion' -Values @($_.Bounds.Width, $_.Bounds.Height)))
            if ($_.Primary) { $n += (Get-CvText -Key 'mon.principal') }
            if ($_.Tests)   { $n += (Get-CvText -Key 'mon.pruebas') }
            (Get-CvText -Key 'mon.info' -Values @($_.Number, ($n -join ', ')))
        })
        & $write (Get-CvText -Key 'setup.cab.monitores') ((@((Get-CvText -Key 'setup.monitores.intro' -Values @("$($ini.TestScreen)", [int]$ini.TestScreenNumber))) + $txt) -join [Environment]::NewLine)
    })
    $btnMon.Name = 'cvSetupMonitors'

    & $addHeader (Get-CvText -Key 'setup.sec.config')
    $btnCfg = (& $addButton ('  ' + (Get-CvText -Key 'setup.btn.config' -Values @($CfgName))) {
        # Abrir el editor cuesta unos segundos (monta un arbol con todas las claves): con el cursor de
        # espera y el aviso en el panel, no parece que setup se haya colgado.
        & $write (Get-CvText -Key 'setup.cab.config') (Get-CvText -Key 'setup.cfg.abriendo')
        $out.Refresh()
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        if (Show-CvConfigWindow -Root $Root -CfgPath $CfgPath -CfgName $CfgName) {
            # Se relee lo guardado y se ensena el estado YA con lo nuevo: si se ha cambiado
            # paths.base, lo primero que se quiere ver es a donde apunta ahora cada carpeta.
            $msg = (Get-CvText -Key 'setup.cfg.guardado' -Values @($CfgName))
            $err = & $recarga
            if ("$err" -ne '') { $msg = $msg + [Environment]::NewLine + (Get-CvText -Key 'setup.cfg.norecarga' -Values @($err)) }
            & $write (Get-CvText -Key 'setup.cab.config') ($msg + [Environment]::NewLine + [Environment]::NewLine +
                (Get-CvSetupStatusText -Context $vivo.Ctx -CfgPath $CfgPath -IsAlt $IsAlt))
        } else {
            & $write (Get-CvText -Key 'setup.cab.config') (Get-CvText -Key 'setup.cfg.sincambios')
        }
    })
    $btnCfg.Name = 'cvSetupConfig'
    # Perfiles: crear / duplicar / editar / borrar los PROPIOS de config.json ('profiles'), y los
    # de serie en solo lectura para poder duplicarlos. La ventana vive en GuiProfile.psm1 porque la
    # comparten setup y la cola.
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.perfiles')) {
        [void](Show-CvProfilesWindow -Context $vivo.Ctx -CfgPath $CfgPath)
        & $write (Get-CvText -Key 'setup.cab.perfiles') (Get-CvSetupProfilesText -CfgPath $CfgPath)
    })
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.reset' -Values @($CfgName))) {
        $msg = Get-CvText -Key 'setup.reset.msg' -Values @($CfgName)
        if (-not (Show-CvGuiConfirm -Title (Get-CvText -Key 'setup.reset.tit') -Message $msg)) { & $write (Get-CvText -Key 'setup.cab.config') (Get-CvText -Key 'setup.reset.cancel'); return }
        if (-not (Reset-CvConfig -Path $CfgPath)) {
            & $write (Get-CvText -Key 'setup.cab.config') (Get-CvText -Key 'setup.reset.nobak' -Values @($CfgName))
            return
        }
        # Como al guardar desde el editor: el contexto se REHACE. Si no, las demas ventanas de setup
        # (mantenimiento, limpieza, logs, herramientas) seguian con las carpetas de ANTES del reset, y
        # mantenimiento podia limpiar un Proceso\ que ya no era el bueno.
        $msg = (Get-CvText -Key 'setup.reset.hecho' -Values @($CfgName))
        $err = & $recarga
        if ("$err" -ne '') { $msg = $msg + [Environment]::NewLine + (Get-CvText -Key 'setup.cfg.norecarga' -Values @($err)) }
        & $write (Get-CvText -Key 'setup.cab.config') $msg
    })

    # MANTENIMIENTO en un sitio: jobs, bloqueos, temporales, logs viejos y caches de las ventanas.
    # Antes eran tres botones repartidos entre 'Limpieza' y 'Logs' y habia que ir a buscarlos.
    & $addHeader (Get-CvText -Key 'setup.sec.mant')
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.mant')) {
        $n = Show-CvMaintenanceWindow -Context $vivo.Ctx -CurrentLog $CurrentLog
        & $write (Get-CvText -Key 'setup.cab.mant') (Get-CvText -Key 'setup.mant.hecho' -Values @($n, (Get-CvSetupMaintenanceText -Context $vivo.Ctx -CurrentLog $CurrentLog)))
    })
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.limpiar')) {
        Show-CvCleanWindow -Context $vivo.Ctx
        & $write (Get-CvText -Key 'setup.cab.estado') (Get-CvSetupStatusText -Context $vivo.Ctx -CfgPath $CfgPath -IsAlt $IsAlt)
    })

    & $addHeader (Get-CvText -Key 'setup.sec.logs')
    [void](& $addButton ('  ' + (Get-CvText -Key 'setup.btn.logs')) {
        Show-CvLogsWindow -Context $vivo.Ctx -CurrentLog $CurrentLog
        & $write (Get-CvText -Key 'setup.cab.logs') (Get-CvText -Key 'setup.logs.hay' -Values @(@(Get-CvSetupLogFiles -Context $vivo.Ctx).Count, $vivo.Ctx.Logs))
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
    & $write (Get-CvText -Key 'setup.cab.estado') (Get-CvSetupStatusText -Context $vivo.Ctx -CfgPath $CfgPath -IsAlt $IsAlt)
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    # Al frente en cuanto se dibuje: lanzada desde un acceso directo MINIMIZADO, Windows la dejaria
    # detras de lo que estuvieras usando (ver Set-CvGuiForeground).
    $form.Add_Shown({ Stop-CvSplashWindow -Splash $Splash })
    if ([bool]$Context.GuiBringToFront) { $form.Add_Shown({ [void](Set-CvGuiForeground -Form $form) }) }
    # -Open: la seccion pedida se abre sola, DESPUES de que la ventana se vea (BeginInvoke: si se
    # abriera dentro de Shown, su dialogo saldria antes de que esta terminara de pintarse).
    $abrir = switch ("$Open".ToLower()) { 'config' { $btnCfg } 'tools' { $btnHerr } default { $null } }
    if ($null -ne $abrir) {
        # La accion se crea AQUI, en el ambito de la funcion: un GetNewClosure anidado dentro de otro
        # no ve las variables del de fuera ($abrir llegaba vacio; ver ref-gotchas.md).
        $pulsar = [System.Action]({ $abrir.PerformClick() }.GetNewClosure())
        $form.Add_Shown({
            try { [void]$form.BeginInvoke($pulsar) } catch { }
        }.GetNewClosure())
    }
    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
