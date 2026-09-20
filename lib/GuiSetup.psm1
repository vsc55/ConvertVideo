<#
    GuiSetup.psm1 - Setup en VENTANA (WinForms): el mismo setup, con raton.

    Hermana en modo grafico de setup.ps1 (consola). Las dos interfaces pintan EXACTAMENTE lo mismo
    porque los DATOS salen de lib\SetupCore.psm1 (fuente unica): aqui solo cambia el RENDER (botones
    y panel de salida en vez de menus numerados).

    Las acciones LARGAS (instalar una herramienta, lanzar una bateria de tests) NO se ejecutan en la
    ventana: se lanzan como 'setup.ps1 -Task ...' en su propia consola, para ver el progreso en vivo
    sin que la ventana se quede congelada (WinForms es de un solo hilo).

    Aqui vive la ventana de setup y SUS dialogos (herramientas, logs, limpieza, selector de config).
    Lo que se abre tambien desde otras ventanas tiene su propio modulo: el editor de config.json en
    lib\GuiConfig.psm1 y las ventanas de perfiles en lib\GuiProfile.psm1. Lo generico -abrir
    WinForms, avisos y confirmaciones, la fuente, el doble bufer, el tamano recordado de cada
    ventana- esta en lib\Gui.psm1, que es lo que comparten todas. Requiere hilo STA, lo normal en
    powershell.exe. Fail-soft: Initialize-CvGui (ver Gui.psm1) devuelve $false sin GUI.
#>

function Get-CvSetupStatusText {
    <#
        Informe de ESTADO como texto plano (identidad + carpetas + herramientas + Proceso + trabajo),
        a partir de los datos de SetupCore: lo mismo que pinta Show-Estado en consola, pero sin
        colores. La GPU va aparte (Get-CvSetupGpuText) porque su sonda es lenta.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$CfgPath, [bool]$IsAlt = $false)
    $L = New-Object System.Collections.Generic.List[string]
    $id = Get-CvSetupIdentity -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt
    $L.Add(("{0} v{1}" -f $id.AppName, $id.Version))
    $tag = if ($id.IsAlt) { 'alterno (-Config)' } else { 'por defecto' }
    $ex  = if ($id.Exists) { '' } else { '  (no existe -> se usan los valores por defecto)' }
    $L.Add(("  config: {0}  [{1}]{2}" -f $id.CfgPath, $tag, $ex))

    $L.Add('')
    $L.Add('Directorios de trabajo:')
    foreach ($d in (Get-CvSetupDirStatus -Context $Context)) {
        $extra = if ($d.Created) { ' (creada)' } else { '' }
        $L.Add(("  {0,-12} {1}{2}" -f $d.Name, (Get-CvMark $d.Ok), $extra))
    }

    $L.Add('')
    $L.Add('Estado de las herramientas:')
    foreach ($t in (Get-CvSetupToolStatus -Context $Context)) {
        if (-not $t.Supported) {
            $L.Add(("  {0} {1,-10} [NO SOPORTADO en {2}]    por defecto: {3}" -f (Get-CvMark $false), $t.Name, $t.Platform, $t.Selected))
            continue
        }
        $instTxt = if (@($t.Installed).Count) { (@($t.Installed) -join ', ') } else { 'ninguna' }
        $L.Add(("  {0} {1,-10} [{2}] instaladas: {3,-22} por defecto (config): {4}" -f (Get-CvMark $t.SelectedOk), $t.Name, $t.Platform, $instTxt, $t.Selected))
    }

    $L.Add('')
    $L.Add('Carpeta Proceso:')
    $p = Get-CvSetupProcesoStatus -Context $Context
    if (-not $p.Exists) {
        $L.Add('  (no existe)')
    } else {
        $staleTxt = if ($p.Stale -gt 0) { "  ({0} caducado(s)/huerfano(s))" -f $p.Stale } else { '' }
        $L.Add(("  jobs pendientes : {0}" -f $p.Jobs))
        $L.Add(("  bloqueos        : {0}{1}" -f $p.Locks, $staleTxt))
        $L.Add(("  temporales      : {0}" -f $p.Temps))
    }

    $L.Add('')
    $L.Add('Trabajo:')
    $w = Get-CvSetupWorkStatus -Context $Context
    $L.Add(("  en Original     : {0} video(s) de entrada" -f $w.Input))
    $L.Add(("  en Convertido   : {0} convertido(s)" -f $w.Converted))
    return ($L -join [Environment]::NewLine)
}

function Get-CvSetupProfilesText {
    <# Texto del panel de salida con los perfiles PROPIOS del config (los de 'profiles'). #>
    param([Parameter(Mandatory)][string]$CfgPath)
    $rows = @(Get-CvConfigProfileRows -Path $CfgPath)
    $serie = @(Get-CvBuiltinProfileRows).Count
    $sb = New-Object System.Text.StringBuilder
    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('No hay perfiles propios guardados.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Con "Perfiles..." creas uno y aparece en el menu de perfiles al preparar,')
        [void]$sb.AppendLine('tanto en la ventana de la cola como en la consola.')
        [void]$sb.AppendLine(("Ahi estan tambien los {0} de serie: no se editan, pero se DUPLICAN para partir de ellos." -f $serie))
        return $sb.ToString()
    }
    [void]$sb.AppendLine(("{0} perfil(es) propios en {1}:" -f $rows.Count, (Split-Path -Leaf $CfgPath)))
    [void]$sb.AppendLine('')
    foreach ($r in $rows) {
        [void]$sb.AppendLine(("  {0}" -f $r.Label))
        [void]$sb.AppendLine(("      {0}" -f $r.Text))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("Y los {0} de serie, que salen en la misma ventana en solo lectura: no se editan, pero se DUPLICAN para partir de ellos." -f $serie))
    return $sb.ToString()
}

function Get-CvSetupGpuText {
    <# Sonda EN VIVO de los encoders por GPU como texto (lo mismo que Show-GpuStatus, sin badges). #>
    param([Parameter(Mandatory)]$Context)
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('Codecs por GPU (NVENC) soportados por esta grafica (comprobacion en vivo):')
    $g = Get-CvSetupGpuStatus -Context $Context
    $L.Add(("  GPU: {0}" -f $(if ($g.Gpu) { $g.Gpu } else { '(no detectada)' })))
    if (-not $g.Ready) {
        $L.Add('  [AVISO] - ffmpeg no instalado: no se puede comprobar. Instala ffmpeg primero.')
        return ($L -join [Environment]::NewLine)
    }
    foreach ($e in $g.Encoders) {
        $txt = if ($e.Ok) { 'soportado' } else { 'NO soportado' }
        $L.Add(("  {0} {1,-12} {2}" -f (Get-CvMark $e.Ok), $e.Name, $txt))
    }
    return ($L -join [Environment]::NewLine)
}

function Start-CvSetupTask {
    <#
        Lanza 'setup.ps1 -Task <...>' en su PROPIA consola (Start-Process) y devuelve sin esperar: asi
        la ventana sigue viva mientras la descarga o la bateria de tests corren con su progreso a la
        vista. -Wait espera a que termine (util para refrescar el estado justo despues).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string[]]$TaskArgs,
        [switch]$Wait
    )
    $script = Join-Path $Root 'setup.ps1'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script), '-Config', ('"{0}"' -f $CfgPath)) + $TaskArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -PassThru
    if ($Wait -and $p) { $p.WaitForExit() }
    return $p
}

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
    $form.Text          = 'Logs'
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
    $btnOpen    = & $mkBtn '  Abrir fuera' 130 'cvLogOpen'
    $btnRefresh = & $mkBtn '  Actualizar'  120 'cvLogRefresh'
    $btnDel     = & $mkBtn '  Eliminar este log' 160 'cvLogDelete'
    $btnClose   = & $mkBtn '  Cerrar' 110 ''

    # Crudo vs decorado: por defecto se muestra LIMPIO (se colapsan los repintados de la barra de los
    # logs antiguos); marcando la casilla se ve el fichero TAL CUAL, por si hay que revisar algo que
    # la limpieza recoge o simplemente comparar con el original.
    $chkRaw = New-Object System.Windows.Forms.CheckBox
    $chkRaw.Text     = 'Ver crudo (sin limpiar)'
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
            $cur = if ($l.IsCurrent) { '  <- en curso' } else { '' }
            [void]$lst.Items.Add(("{0:dd/MM/yy HH:mm}  {1,5} KB  {2}{3}" -f $l.Date, $l.SizeKb, $l.Name, $cur))
        }
        if ($lst.Items.Count -gt 0) {
            $lst.SelectedIndex = [Math]::Max(0, [Math]::Min($sel, $lst.Items.Count - 1))
        } else {
            $txt.Text = '(no hay logs en la carpeta logs)'
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
        [void](Open-CvGuiPath -Path "$($l.Path)" -Title 'Logs')
    })
    $btnRefresh.Add_Click($reload)
    $btnDel.Add_Click({
        $l = & $current
        if ($null -eq $l) { return }
        if ($l.IsCurrent) { Show-CvGuiInfo -Title 'Logs' -Message 'Ese es el log de la sesion en curso: esta en uso y no se puede borrar.'; return }
        if (-not (Show-CvGuiConfirm -Title 'Eliminar log' -Message ("Eliminar {0}?" -f $l.Name))) { return }
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
    $form.Text          = 'Mantenimiento'
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
    $lbl.Text     = 'Marca lo que quieras borrar:'
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
    [void]$lv.Columns.Add('Que', 300)
    [void]$lv.Columns.Add('Cuantos', 70, 'Right')
    [void]$lv.Columns.Add('Que se pierde', 300)
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
    $btnDo    = & $mkBtn 'Limpiar lo marcado' 'cvMaintRun'
    $btnClose = & $mkBtn 'Cerrar'             'cvMaintClose'

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
            'No has marcado nada.'
        } elseif ($avisa) {
            ("Se borraran {0} elemento(s). OJO: entre ellos los JOBS, que habria que volver a preparar." -f $n)
        } else {
            ("Se borraran {0} elemento(s)." -f $n)
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
        $msg = "Se va a borrar:`n`n{0}`n`nSeguro?" -f ($detalle -join "`n")
        if (-not (Show-CvGuiConfirm -Title 'Mantenimiento' -Message $msg)) { return }
        $r = @(Invoke-CvSetupMaintenance -Context $Context -Keys $ks -CurrentLog $CurrentLog)
        foreach ($x in $r) { $script:borrados += [int]$x.Removed }
        $malos = @($r | Where-Object { -not $_.Ok })
        if ($malos.Count -gt 0) {
            Show-CvGuiInfo -Title 'Mantenimiento' -Message (("Algo no se pudo borrar:`n`n" + ((@($malos | ForEach-Object { "{0}: {1}" -f $_.Text, $_.Error })) -join "`n")))
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

function Show-CvCleanWindow {
    <#
        Limpieza de la carpeta Proceso: elegir QUE borrar (jobs / bloqueos / temporales / todo), ver la
        lista exacta de ficheros y confirmar. Los candidatos y el borrado salen de SetupCore, los
        mismos que usa la consola.
    #>
    param([Parameter(Mandatory)]$Context)
    if (-not (Initialize-CvGui)) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Limpiar carpeta Proceso'
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(640, 470)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location      = New-Object System.Drawing.Point(12, 30)
    $combo.Width         = 400
    $combo.DropDownStyle = 'DropDownList'
    $form.Controls.Add($combo)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = 'Que eliminar:'
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
    $btnDel.Text     = 'Eliminar'
    $btnDel.Location = New-Object System.Drawing.Point(12, 378)
    $btnDel.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnDel)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Cerrar'
    $btnClose.Location = New-Object System.Drawing.Point(462, 378)
    $btnClose.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnClose)

    # Mismas cuatro opciones que el menu de consola, con el recuento de cada una.
    $p = Get-CvSetupProcesoStatus -Context $Context
    $whats = @(
        @{ Value = 'jobs';  Text = ("Jobs (*.job.json)              [{0}]" -f $p.Jobs) }
        @{ Value = 'locks'; Text = ("Bloqueos y estado de workers   [{0}]" -f $p.Locks) }
        @{ Value = 'temps'; Text = ("Temporales (mkv / m4a / wav)   [{0}]" -f $p.Temps) }
        @{ Value = 'all';   Text = 'TODO (jobs + bloqueos + temporales)' }
    )
    foreach ($w in $whats) { [void]$combo.Items.Add($w.Text) }

    $refresh = {
        $i = $combo.SelectedIndex
        if ($i -lt 0) { return }
        $f = @(Get-CvSetupCleanTargets -Context $Context -What $whats[$i].Value)
        $files.Text = if ($f.Count -eq 0) { '(nada que eliminar)' } else { (@($f | ForEach-Object { $_.Name }) -join [Environment]::NewLine) }
        $btnDel.Enabled = ($f.Count -gt 0)
    }
    $combo.Add_SelectedIndexChanged($refresh)

    $btnDel.Add_Click({
        $i = $combo.SelectedIndex
        if ($i -lt 0) { return }
        $f = @(Get-CvSetupCleanTargets -Context $Context -What $whats[$i].Value)
        if ($f.Count -eq 0) { return }
        if (-not (Show-CvGuiConfirm -Title 'Confirmar borrado' -Message ("Se eliminaran {0} fichero(s) de Proceso. Continuar?" -f $f.Count))) { return }
        $n = Remove-CvSetupFiles -Files $f
        Show-CvGuiInfo -Title 'Limpieza' -Message ("Eliminados {0} fichero(s)." -f $n)
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
