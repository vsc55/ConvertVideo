<#
    GuiSetup.psm1 - Setup en VENTANA (WinForms): el mismo setup, con raton.

    Hermana en modo grafico de setup.ps1 (consola). Las dos interfaces pintan EXACTAMENTE lo mismo
    porque los DATOS salen de lib\SetupCore.psm1 (fuente unica) y la configuracion se edita con los
    mismos helpers que el editor de texto (Get-CvEditorOptions para los enum, Get-CvHelpFor para la
    ayuda, Get-CvConfigDefaultValue para el default y Update-CvConfigEdits al guardar): aqui solo
    cambia el RENDER (arbol, desplegables y botones en vez de menus numerados).

    Las acciones LARGAS (instalar una herramienta, lanzar una bateria de tests) NO se ejecutan en la
    ventana: se lanzan como 'setup.ps1 -Task ...' en su propia consola, para ver el progreso en vivo
    sin que la ventana se quede congelada (WinForms es de un solo hilo).

    Separado de Gui.psm1 (ventanas genericas: Show-CvTextWindow) por tamano y proposito. Requiere
    hilo STA, lo normal en powershell.exe. Fail-soft: Initialize-CvGui devuelve $false si no hay GUI.
#>

function Initialize-CvGui {
    <# Carga WinForms/Drawing y activa los estilos visuales. $false si no hay GUI/STA (el llamador cae
       a la consola). Idempotente: se puede llamar en cada entrada. #>
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        return $true
    } catch {
        return $false
    }
}

function New-CvGuiFont {
    <# Fuente monoespaciada para los paneles de salida (texto alineado en columnas). #>
    param([int]$Size = 9)
    New-Object System.Drawing.Font('Consolas', $Size)
}

function Show-CvGuiInfo {
    <# Aviso modal simple. #>
    param([string]$Title = 'Setup', [string]$Message = '')
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-CvGuiConfirm {
    <# Confirmacion modal (Si/No). Devuelve $true si el usuario acepta. El equivalente del
       'Confirmar? (s/N)' de la consola: por defecto marca NO, para no borrar de un ENTER. #>
    param([string]$Title = 'Confirmar', [string]$Message = '')
    $r = [System.Windows.Forms.MessageBox]::Show($Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

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

    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Path
}

# ===========================================================================
#  Editor de configuracion (arbol + ayuda por clave)
# ===========================================================================

function Resolve-CvCfgNode {
    <# Nodo del config por su ruta 'a/b/c' ('' = raiz). $null si la ruta no existe. #>
    param($Root, [string]$Path)
    $n = $Root
    if ("$Path" -eq '') { return $n }
    foreach ($seg in ("$Path" -split '/')) {
        if ($null -eq $n) { return $null }
        $n = Get-CvNodeVal $n $seg
    }
    return $n
}

function Format-CvCfgPreview {
    <# Vista corta del valor de una clave para el arbol ('fps = 23.976', 'audio = {...}'). #>
    param($Value, [int]$Max = 38)
    $kind = Get-CvNodeKind $Value
    $txt = switch ($kind) {
        'object' { '{...}' }
        'array'  { '[' + ((@($Value) | ForEach-Object { "$_" }) -join ', ') + ']' }
        'bool'   { "$Value".ToLower() }
        'null'   { 'null' }
        default  { "$Value" }
    }
    if ($txt.Length -gt $Max) { $txt = $txt.Substring(0, $Max - 3) + '...' }
    return $txt
}

function Set-CvCfgNodeStyle {
    <#
        Resalta un nodo hoja segun si su valor DIFIERE del de fabrica: azul y negrita = editado (es
        decir, lo que acabara escrito en config.json); normal = valor por defecto. Se llama al montar
        el arbol y cada vez que se cambia un valor, para que el resaltado siga siendo cierto.
    #>
    param($TreeNode, [bool]$Modified, $BoldFont)
    if ($Modified) {
        if ($BoldFont) { $TreeNode.NodeFont = $BoldFont }
        $TreeNode.ForeColor = [System.Drawing.Color]::FromArgb(0, 70, 170)
    } else {
        $TreeNode.NodeFont  = $null                          # vuelve a la fuente del TreeView
        $TreeNode.ForeColor = [System.Drawing.Color]::Empty   # vuelve al color normal
    }
}

function Test-CvCfgNodeModified {
    <# $true si el valor de esa ruta NO es el de fabrica (Test-CvCfgIsDefault, la misma regla que usa
       el guardado). Una ruta sin default de fabrica cuenta como editada si trae valor. #>
    param($Value, [string]$Path)
    return (-not (Test-CvCfgIsDefault -Value $Value -Default (Get-CvConfigDefaultValue $Path)))
}

function Get-CvCfgModifiedCount {
    <# N. de hojas de un nodo del config (recursivo) cuyo valor NO es el de fabrica. Lo usa el editor
       para decir cuantas opciones editadas se estan quedando ocultas al no mostrar las avanzadas. #>
    param($Node, [string]$Path)
    $n = 0
    foreach ($k in (Get-CvNodeKeys $Node)) {
        $v    = Get-CvNodeVal $Node $k
        $full = if ($Path) { "$Path/$k" } else { "$k" }
        if ((Get-CvNodeKind $v) -eq 'object') { $n += (Get-CvCfgModifiedCount -Node $v -Path $full) }
        elseif (Test-CvCfgNodeModified -Value $v -Path $full) { $n++ }
    }
    return $n
}

function Add-CvCfgNodes {
    <#
        Rellena (recursivo) el TreeView con las claves de $Node. La ruta completa de cada clave va en
        .Tag, que es lo que usa el panel de la derecha para leer/escribir el valor. Se oculta
        'gpuCache' en la raiz (cache de maquina, no configuracion), igual que el editor de consola.

        Ademas RESALTA las hojas cuyo valor no es el de fabrica y DEVUELVE $true si hay alguna dentro,
        lo que hace que cada seccion con algo editado se abra sola: al entrar, lo que has tocado esta
        a la vista sin ir desplegando a ciegas, y el resto del arbol se queda recogido.

        -ShowAdvanced $false (por defecto) OCULTA las ramas avanzadas (Get-CvConfigAdvancedPaths: el
        catalogo de descargas, betas, ajuste fino del encoder...) para que el arbol muestre solo lo que
        se toca a diario. En -Stats (hashtable) se devuelve cuantas opciones EDITADAS se han quedado
        ocultas, para poder avisar: si no, alguien podria no encontrar algo que si habia cambiado.
    #>
    param($Parent, $Node, [string]$Path, $BoldFont = $null, [bool]$ShowAdvanced = $false, $Stats = $null)
    $anyMod = $false
    foreach ($k in (Get-CvNodeKeys $Node)) {
        if ($Path -eq '' -and $k -eq 'gpuCache') { continue }
        $v    = Get-CvNodeVal $Node $k
        $kind = Get-CvNodeKind $v
        $full = if ($Path) { "$Path/$k" } else { "$k" }
        if ((-not $ShowAdvanced) -and (Test-CvConfigAdvanced -Path $full)) {
            if ($null -ne $Stats) {
                $hidden = if ($kind -eq 'object') { Get-CvCfgModifiedCount -Node $v -Path $full }
                          elseif (Test-CvCfgNodeModified -Value $v -Path $full) { 1 } else { 0 }
                $Stats.Hidden += $hidden
            }
            continue
        }
        $tn   = New-Object System.Windows.Forms.TreeNode
        $tn.Text = if ($kind -eq 'object') { "$k" } else { ("{0} = {1}" -f $k, (Format-CvCfgPreview $v)) }
        $tn.Tag  = $full
        [void]$Parent.Nodes.Add($tn)
        if ($kind -eq 'object') {
            if (Add-CvCfgNodes -Parent $tn -Node $v -Path $full -BoldFont $BoldFont -ShowAdvanced $ShowAdvanced -Stats $Stats) {
                $tn.Expand()          # la seccion tiene algo editado dentro: abrirla
                $anyMod = $true
            }
        } else {
            $mod = Test-CvCfgNodeModified -Value $v -Path $full
            Set-CvCfgNodeStyle -TreeNode $tn -Modified $mod -BoldFont $BoldFont
            if ($mod) { $anyMod = $true }
        }
    }
    return $anyMod
}

function Update-CvCfgNodeText {
    <# Refresca el texto de un nodo hoja tras editarlo (para que el arbol muestre el valor nuevo). #>
    param($TreeNode, $Value)
    $key = ("$($TreeNode.Tag)" -split '/')[-1]
    $TreeNode.Text = ("{0} = {1}" -f $key, (Format-CvCfgPreview $Value))
}

function Show-CvConfigWindow {
    <#
        Editor de configuracion en VENTANA: arbol de secciones a la izquierda y, a la derecha, el valor
        de la clave elegida con el control que le toca (desplegable para los enum -Get-CvEditorOptions-,
        true/false para los bool, texto para numeros y cadenas, una linea por elemento para las listas),
        mas su AYUDA (Get-CvHelpFor) y su valor POR DEFECTO de fabrica (Get-CvConfigDefaultValue).

        Semantica de guardado IDENTICA al editor de consola (Edit-CvConfigFile): se edita el config
        FUSIONADO (para ver TODAS las opciones aunque el fichero sea minimo) y al guardar se aplica
        SOLO lo que difiere del default sobre el fichero crudo (Update-CvConfigEdits), de modo que un
        config.json minimo sigue minimo y lo que vuelve al default se elimina.

        Devuelve $true si se guardo.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CfgPath,
        [string]$CfgName = 'config.json'
    )
    if (-not (Initialize-CvGui)) { return $false }

    # Estado mutable compartido por los manejadores de eventos (un hashtable: se captura por
    # referencia, mientras que asignar a una variable suelta dentro de un handler crearia una local).
    $st = @{
        Cfg     = (Get-CvConfig -Root $Root -Path $CfgPath)   # fusionado: lo que se edita
        Before  = (Get-CvConfig -Root $Root -Path $CfgPath)   # copia intacta: la referencia del diff
        Dirty   = $false
        Saved   = $false
        Node    = $null      # TreeNode seleccionado
        Path    = ''         # su ruta completa
        Loading = $false     # $true mientras se rellenan los controles (evita marcar Dirty)
        Bold    = $null      # fuente de las claves editadas (se crea al montar el arbol)
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("Editar configuracion ({0})" -f $CfgName)
    $form.StartPosition = 'CenterScreen'
    $form.Size          = New-Object System.Drawing.Size(1000, 660)
    $form.MinimumSize   = New-Object System.Drawing.Size(820, 520)

    # OJO con el SplitContainer: fijar SplitterDistance ANTES de que la ventana tenga su tamano real
    # no sirve de nada (al redimensionarse mueve el divisor proporcionalmente y el arbol se comia casi
    # toda la ventana). Se fija en el evento Shown, cuando el tamano ya es el definitivo, y se declara
    # FixedPanel = Panel1 para que al agrandar la ventana crezca el panel de la DERECHA (la ayuda),
    # no el arbol. Los minimos evitan que un arrastron deje un panel inservible.
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock       = 'Fill'
    $split.FixedPanel = 'Panel1'
    $form.Controls.Add($split)
    # El divisor se coloca en Shown, cuando el ancho ya es el definitivo: hacerlo antes no sirve (al
    # redimensionarse la ventana el divisor se mueve proporcionalmente y el arbol se comia casi todo).
    # Los MinSize TAMBIEN van aqui y DESPUES de SplitterDistance: asignarlos antes lanza
    # "SplitterDistance debe estar entre Panel1MinSize y Ancho - Panel2MinSize" (el control aun tiene
    # su tamano por defecto). FixedPanel=Panel1 hace que al agrandar crezca la parte de la DERECHA.
    $p1Min = 220
    $p2Min = 320
    $form.Add_Shown({
        $d = [int]($split.Width * 0.36)
        $split.SplitterDistance = [Math]::Max($p1Min, [Math]::Min($d, $split.Width - $p2Min - $split.SplitterWidth))
        $split.Panel1MinSize = $p1Min
        $split.Panel2MinSize = $p2Min
    })

    # Panel izquierdo en REJILLA (interruptor arriba, arbol debajo). Con Dock Top+Fill el reparto
    # depende del z-order y el arbol quedaba RECORTADO por arriba, tapado por el interruptor.
    $leftGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $leftGrid.Dock        = 'Fill'
    $leftGrid.ColumnCount = 1
    $leftGrid.RowCount    = 2
    [void]$leftGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$leftGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    [void]$leftGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $split.Panel1.Controls.Add($leftGrid)

    # Interruptor de opciones avanzadas, encima del arbol. Sin marcar (lo normal) el arbol muestra solo
    # lo que se toca a diario; marcado, aparece todo (catalogo de descargas, betas, tuning...).
    $chkAdv = New-Object System.Windows.Forms.CheckBox
    $chkAdv.Dock     = 'Fill'
    $chkAdv.Text     = 'Mostrar opciones avanzadas'
    $chkAdv.Name     = 'cvAdvanced'
    $leftGrid.Controls.Add($chkAdv, 0, 0)

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock       = 'Fill'
    $tree.Font       = (New-CvGuiFont 9)
    $tree.HideSelection = $false
    # Los controles que manipula el usuario van con .Name para poder encontrarlos (Controls.Find):
    # asi la bateria de humo puede dirigir la ventana sin raton (ver test\gui-tests.ps1).
    $tree.Name       = 'cvTree'
    $leftGrid.Controls.Add($tree, 0, 1)

    # --- panel derecho: clave, control del valor, default y ayuda ---
    # En REJILLA (TableLayoutPanel), no en posiciones absolutas: con Location/Width fijos, al estrechar
    # el panel los controles se salian de la ventana. Aqui cada fila se ajusta sola (AutoSize) y la
    # ayuda se queda con todo el alto sobrante (Percent 100); todo a lo ancho del panel (Dock Fill).
    $right = New-Object System.Windows.Forms.TableLayoutPanel
    $right.Dock        = 'Fill'
    $right.Padding     = New-Object System.Windows.Forms.Padding(10)
    $right.ColumnCount = 1
    $right.RowCount    = 6
    [void]$right.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($h in @(28, 20, 132, 22, 32)) {
        [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $h)))
    }
    [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $split.Panel2.Controls.Add($right)

    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text      = 'Elige una opcion en el arbol'
    $lblKey.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblKey.Dock      = 'Fill'
    $lblKey.AutoSize  = $false
    $lblKey.AutoEllipsis = $true      # una ruta larga se recorta con '...' en vez de desbordar
    $right.Controls.Add($lblKey, 0, 0)

    $lblVal = New-Object System.Windows.Forms.Label
    $lblVal.Text     = 'Valor:'
    $lblVal.Dock     = 'Fill'
    $lblVal.AutoSize = $false
    $right.Controls.Add($lblVal, 0, 1)

    # Los tres controles de valor comparten celda (solo uno visible segun el tipo de la clave): van en
    # un panel propio, el unico sitio donde conviene posicion fija (el alto de cada uno es distinto).
    $valBox = New-Object System.Windows.Forms.Panel
    $valBox.Dock = 'Fill'
    $right.Controls.Add($valBox, 0, 2)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Dock    = 'Top'
    $combo.Name    = 'cvCombo'
    $combo.Visible = $false
    $valBox.Controls.Add($combo)

    $text = New-Object System.Windows.Forms.TextBox
    $text.Dock    = 'Top'
    $text.Name    = 'cvText'
    $text.Visible = $false
    $valBox.Controls.Add($text)

    $list = New-Object System.Windows.Forms.TextBox
    $list.Dock       = 'Fill'
    $list.Multiline  = $true
    $list.ScrollBars = 'Vertical'
    $list.Font       = (New-CvGuiFont 9)
    $list.Visible    = $false
    $list.Name       = 'cvList'
    $valBox.Controls.Add($list)

    $lblDef = New-Object System.Windows.Forms.Label
    $lblDef.Dock      = 'Fill'
    $lblDef.AutoSize  = $false
    $lblDef.AutoEllipsis = $true
    $lblDef.ForeColor = [System.Drawing.Color]::DimGray
    $right.Controls.Add($lblDef, 0, 3)

    $btnDef = New-Object System.Windows.Forms.Button
    $btnDef.Text     = 'Volver al valor por defecto'
    $btnDef.Width    = 200
    $btnDef.Height   = 26
    $btnDef.Anchor   = 'Top,Left'
    $btnDef.Enabled  = $false
    $btnDef.Name     = 'cvDefault'
    $right.Controls.Add($btnDef, 0, 4)

    $help = New-Object System.Windows.Forms.TextBox
    $help.Dock        = 'Fill'
    $help.Multiline   = $true
    $help.ReadOnly    = $true
    $help.ScrollBars  = 'Vertical'      # solo vertical: el texto se ajusta al ancho (WordWrap por defecto)
    $help.BackColor   = [System.Drawing.SystemColors]::Control
    $help.BorderStyle = 'FixedSingle'
    $right.Controls.Add($help, 0, 5)

    # --- barra inferior: guardar / cancelar ---
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock   = 'Bottom'
    $bar.Height = 46
    $form.Controls.Add($bar)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text   = 'Guardar'
    $btnSave.Width  = 110
    $btnSave.Height = 28
    $btnSave.Anchor = 'Top,Right'
    $btnSave.Name   = 'cvSave'
    $bar.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text   = 'Cancelar'
    $btnCancel.Width  = 110
    $btnCancel.Height = 28
    $btnCancel.Anchor = 'Top,Right'
    $bar.Controls.Add($btnCancel)

    $lblDirty = New-Object System.Windows.Forms.Label
    $lblDirty.AutoSize  = $true
    $lblDirty.Location  = New-Object System.Drawing.Point(12, 14)
    $lblDirty.ForeColor = [System.Drawing.Color]::DimGray
    $lblDirty.Text      = 'Sin cambios'
    $bar.Controls.Add($lblDirty)

    # Los botones se pegan a la derecha de la barra (el resto del panel derecho ya se ajusta solo).
    $layoutBar = {
        $btnSave.Left   = $bar.ClientSize.Width - $btnSave.Width - 12
        $btnSave.Top    = 9
        $btnCancel.Left = $btnSave.Left - $btnCancel.Width - 8
        $btnCancel.Top  = 9
    }
    $bar.Add_Resize($layoutBar)

    # --- helpers de estado ---
    $markDirty = {
        $st.Dirty = $true
        $lblDirty.Text      = 'Hay cambios sin guardar'
        $lblDirty.ForeColor = [System.Drawing.Color]::Firebrick
    }

    # Escribe un valor nuevo en el config fusionado y refresca el arbol.
    $apply = {
        param($newVal)
        if ($st.Loading -or "$($st.Path)" -eq '') { return }
        $segs   = "$($st.Path)" -split '/'
        $key    = $segs[-1]
        $parent = Resolve-CvCfgNode -Root $st.Cfg -Path (($segs[0..($segs.Count - 2)]) -join '/')
        if ($null -eq $parent) { return }
        $old = Get-CvNodeVal $parent $key
        if ("$old" -ceq "$newVal" -and (Get-CvNodeKind $old) -ne 'array') { return }   # sin cambio real
        Set-CvNodeVal $parent $key $newVal
        if ($st.Node) {
            Update-CvCfgNodeText -TreeNode $st.Node -Value $newVal
            # Reevaluar el resaltado: si el valor deja de ser el de fabrica se marca, y si vuelve a
            # serlo (boton 'Volver al valor por defecto') se desmarca.
            Set-CvCfgNodeStyle -TreeNode $st.Node -Modified (Test-CvCfgNodeModified -Value $newVal -Path $st.Path) -BoldFont $st.Bold
        }
        & $markDirty
    }

    # Convierte el texto tecleado al TIPO que toca (mismo criterio que Edit-Scalar de la consola:
    # entero -> [long]; decimal -> double INVARIANTE; si no parsea, se deja el texto).
    $coerce = {
        param([string]$Raw, [string]$Kind)
        if ($Kind -ne 'number') { return $Raw }
        if ($Raw -match '^-?\d+$') { return [long]$Raw }
        $d = 0.0
        if ([double]::TryParse($Raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
        return $null      # numero no valido: el llamador avisa y no aplica
    }

    # --- seleccion en el arbol: preparar el panel derecho ---
    $tree.Add_AfterSelect({
        # Confirmar lo que quedara a medias en el nodo ANTERIOR ($st.Path aun apunta a el) antes de
        # recargar los controles: si no, escribir un valor y saltar a otra clave lo perderia.
        if (-not $st.Loading) { [void](& $commitText); & $commitList }
        $st.Loading = $true
        try {
            $node = $tree.SelectedNode
            $st.Node = $node
            $st.Path = if ($node) { "$($node.Tag)" } else { '' }
            $combo.Visible = $false; $text.Visible = $false; $list.Visible = $false
            $right.RowStyles[2].Height = 0      # sin control de valor (seccion): sin hueco muerto
            $btnDef.Enabled = $false
            $lblKey.Text = if ($st.Path) { $st.Path } else { 'Elige una opcion en el arbol' }
            $help.Text   = (Get-CvHelpFor $st.Path)
            $lblDef.Text = ''
            if (-not $node) { return }

            $segs   = "$($st.Path)" -split '/'
            $key    = $segs[-1]
            $parent = Resolve-CvCfgNode -Root $st.Cfg -Path (($segs[0..($segs.Count - 2)]) -join '/')
            $val    = if ($null -ne $parent) { Get-CvNodeVal $parent $key } else { $null }
            $kind   = Get-CvNodeKind $val

            # 'profiles' (raiz) es un array de OBJETOS: el editor de listas lo corromperia, igual que
            # en consola. Se explica y no se ofrece control.
            if ($st.Path -eq 'profiles') {
                $help.Text = ("Los perfiles propios se editan a mano en {0} (seccion 'profiles')." -f $CfgName) + [Environment]::NewLine +
                             'Se anaden al menu USAR PERFIL a continuacion de los de serie (14, 15, ...; ver docs/ref-perfiles.md).'
                return
            }
            if ($kind -eq 'object') {
                $help.Text = if ($help.Text) { $help.Text } else { 'Seccion: elige una opcion dentro.' }
                return
            }

            $defVal = Get-CvConfigDefaultValue $st.Path
            $lblDef.Text = if ($null -ne $defVal) { ("Por defecto: {0}" -f (Format-CvCfgPreview $defVal 60)) } else { '' }
            $btnDef.Enabled = ($null -ne $defVal)

            if ($kind -eq 'array') {
                $right.RowStyles[2].Height = 132   # la lista necesita alto; un escalar, una linea
                $list.Text = ((@($val) | ForEach-Object { "$_" }) -join [Environment]::NewLine)
                $list.Visible = $true
                $lblVal.Text = 'Valor (un elemento por linea):'
                return
            }
            $right.RowStyles[2].Height = 30
            $lblVal.Text = 'Valor:'

            # Enum con catalogo -> desplegable (misma fuente que el editor de consola).
            $spec = Get-CvEditorOptions -Key $key
            if ($null -ne $spec) {
                $combo.Items.Clear()
                foreach ($it in @($spec.Items)) { [void]$combo.Items.Add("$($it.Label)") }
                $combo.DropDownStyle = if ($spec.AllowCustom) { 'DropDown' } else { 'DropDownList' }
                $cur = "$val"
                $idx = -1
                for ($i = 0; $i -lt @($spec.Items).Count; $i++) { if ("$(@($spec.Items)[$i].Value)" -eq $cur) { $idx = $i; break } }
                if ($idx -ge 0) { $combo.SelectedIndex = $idx } else { $combo.Text = $cur }
                $combo.Visible = $true
                # La descripcion del valor elegido se anade a la ayuda de la clave.
                $descs = @(@($spec.Items) | Where-Object { "$($_.Desc)".Trim() -ne '' } | ForEach-Object { "  {0}: {1}" -f $_.Label, $_.Desc })
                if ($descs.Count -gt 0) { $help.Text = ($help.Text + [Environment]::NewLine + [Environment]::NewLine + 'Valores:' + [Environment]::NewLine + ($descs -join [Environment]::NewLine)).Trim() }
                return
            }
            if ($kind -eq 'bool') {
                $combo.Items.Clear()
                [void]$combo.Items.Add('true'); [void]$combo.Items.Add('false')
                $combo.DropDownStyle = 'DropDownList'
                $combo.SelectedIndex = if ([bool]$val) { 0 } else { 1 }
                $combo.Visible = $true
                return
            }
            $text.Text = "$val"
            $text.Visible = $true
        } finally {
            $st.Loading = $false
        }
    })

    # --- aplicar cambios de cada control ---
    $combo.Add_SelectedIndexChanged({
        if ($st.Loading) { return }
        $key  = ("$($st.Path)" -split '/')[-1]
        $spec = Get-CvEditorOptions -Key $key
        if ($null -ne $spec) {
            $sel = @($spec.Items) | Where-Object { "$($_.Label)" -eq "$($combo.Text)" } | Select-Object -First 1
            if ($null -ne $sel) { & $apply $sel.Value; return }
        }
        & $apply ($combo.Text -eq 'true')     # bool sin catalogo
    })
    # Enum con AllowCustom: valor tecleado a mano.
    $combo.Add_Leave({
        if ($st.Loading -or $combo.DropDownStyle -eq 'DropDownList') { return }
        $key  = ("$($st.Path)" -split '/')[-1]
        $spec = Get-CvEditorOptions -Key $key
        $sel = if ($null -ne $spec) { @($spec.Items) | Where-Object { "$($_.Label)" -eq "$($combo.Text)" } | Select-Object -First 1 } else { $null }
        if ($null -ne $sel) { & $apply $sel.Value } else { & $apply "$($combo.Text)" }
    })
    # Confirma lo que haya escrito en el cuadro de texto / la lista. Se llama al SALIR del control,
    # al pulsar Enter y TAMBIEN antes de guardar: si no, escribir un valor y pulsar directamente
    # 'Guardar' (o cerrar) perderia la edicion sin avisar.
    $commitText = {
        if ($st.Loading -or -not $text.Visible -or "$($st.Path)" -eq '') { return $true }
        $segs   = "$($st.Path)" -split '/'
        $parent = Resolve-CvCfgNode -Root $st.Cfg -Path (($segs[0..($segs.Count - 2)]) -join '/')
        if ($null -eq $parent) { return $true }
        $kind = Get-CvNodeKind (Get-CvNodeVal $parent $segs[-1])
        $v = & $coerce $text.Text.Trim() $kind
        if ($null -eq $v) {
            Show-CvGuiInfo -Title 'Valor no valido' -Message ("'{0}' no es un numero valido para {1}." -f $text.Text, $st.Path)
            return $false
        }
        & $apply $v
        return $true
    }
    $commitList = {
        if ($st.Loading -or -not $list.Visible -or "$($st.Path)" -eq '') { return }
        # OJO: sin coma unaria. '& $sb (,$x)' pasaria un array ANIDADO (@(@(...))) y la lista se
        # guardaria como un solo elemento 'System.Object[]'.
        $items = @($list.Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
        & $apply $items
    }
    $text.Add_Leave({ [void](& $commitText) })
    $text.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true      # sin esto la consola de Windows pita al pulsar Enter
            [void](& $commitText)
        }
    })
    $list.Add_Leave({ & $commitList })
    $btnDef.Add_Click({
        $defVal = Get-CvConfigDefaultValue $st.Path
        if ($null -eq $defVal) { return }
        & $apply $defVal
        # Refrescar el control A MANO con el valor nuevo. NO se re-selecciona el nodo del arbol para
        # recargarlo: eso dispararia AfterSelect, que confirma lo que hubiera en el cuadro de texto
        # (todavia el valor VIEJO) y desharia justo lo que acabamos de restaurar.
        $st.Loading = $true
        try {
            if ($list.Visible) {
                $list.Text = ((@($defVal) | ForEach-Object { "$_" }) -join [Environment]::NewLine)
            } elseif ($combo.Visible) {
                $key  = ("$($st.Path)" -split '/')[-1]
                $spec = Get-CvEditorOptions -Key $key
                $idx  = -1
                if ($null -ne $spec) {
                    for ($i = 0; $i -lt @($spec.Items).Count; $i++) { if ("$(@($spec.Items)[$i].Value)" -eq "$defVal") { $idx = $i; break } }
                } else {
                    $idx = if ([bool]$defVal) { 0 } else { 1 }    # bool sin catalogo: true / false
                }
                if ($idx -ge 0) { $combo.SelectedIndex = $idx } else { $combo.Text = "$defVal" }
            } elseif ($text.Visible) {
                $text.Text = "$defVal"
            }
        } finally {
            $st.Loading = $false
        }
    })

    # --- guardar / cancelar ---
    $btnSave.Add_Click({
        # Confirmar primero lo que este a medias en el control con el foco (ver $commitText).
        if (-not (& $commitText)) { return }
        & $commitList
        # Mismo camino que el editor de consola: aplicar SOLO lo distinto del default sobre el fichero
        # CRUDO, para que un config minimo siga minimo.
        $raw = if (Test-Path -LiteralPath $CfgPath) { Read-CvConfigFile -Path $CfgPath } else { [pscustomobject]@{} }
        Update-CvConfigEdits -Edited $st.Cfg -Before $st.Before -Default (Get-CvConfigDefaults) -Target $raw
        Save-CvConfigFile -Path $CfgPath -Config $raw
        $st.Saved = $true
        $st.Dirty = $false
        # SIN aviso modal al guardar: el llamador ya informa (la ventana principal lo escribe en su
        # panel de salida) y un MessageBox aqui obliga a un clic de mas... y deja la bateria de tests
        # BLOQUEADA esperando a que alguien lo cierre, que es justo lo contrario de desatendida.
        $form.Close()
    })
    $btnCancel.Add_Click({ $form.Close() })
    $form.Add_FormClosing({
        if ($st.Dirty -and -not $st.Saved) {
            if (-not (Show-CvGuiConfirm -Title 'Cambios sin guardar' -Message 'Hay cambios sin guardar. Salir y descartarlos?')) {
                $_.Cancel = $true
            }
        }
    })

    # Fuente en negrita para las claves editadas (la del propio arbol, en Bold): se guarda en el
    # estado porque tambien la usa $apply al re-resaltar un valor que se acaba de cambiar.
    $st.Bold = New-Object System.Drawing.Font($tree.Font, [System.Drawing.FontStyle]::Bold)

    # (Re)construye el arbol segun el interruptor de avanzadas, conservando la clave seleccionada si
    # sigue estando visible. La etiqueta del check avisa si se quedan opciones EDITADAS ocultas.
    $buildTree = {
        $keep = "$($st.Path)"
        $stats = @{ Hidden = 0 }
        $tree.BeginUpdate()
        $tree.Nodes.Clear()
        [void](Add-CvCfgNodes -Parent $tree -Node $st.Cfg -Path '' -BoldFont $st.Bold -ShowAdvanced $chkAdv.Checked -Stats $stats)
        $tree.EndUpdate()
        $chkAdv.Text = if ($stats.Hidden -gt 0) {
            'Mostrar opciones avanzadas  ({0} editada(s) oculta(s))' -f $stats.Hidden
        } else {
            'Mostrar opciones avanzadas'
        }
        if ($keep) {
            $find = {
                param($Nodes, [string]$P)
                foreach ($n in $Nodes) {
                    if ("$($n.Tag)" -eq $P) { return $n }
                    $r = & $find $n.Nodes $P
                    if ($r) { return $r }
                }
                return $null
            }
            $n = & $find $tree.Nodes $keep
            if ($n) { $tree.SelectedNode = $n; $n.EnsureVisible() }
        }
    }
    $chkAdv.Add_CheckedChanged($buildTree)
    & $buildTree
    & $layoutBar
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Saved
}

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
    $form.Size          = New-Object System.Drawing.Size(720, 460)

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

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Cerrar'
    $btnClose.Location = New-Object System.Drawing.Point(530, 318)
    $btnClose.Size     = New-Object System.Drawing.Size(150, 30)
    $form.Controls.Add($btnClose)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.AutoSize  = $false
    $lblInfo.Location  = New-Object System.Drawing.Point(12, 360)
    $lblInfo.Size      = New-Object System.Drawing.Size(668, 50)
    $lblInfo.ForeColor = [System.Drawing.Color]::DimGray
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
        $lblInfo.Text = if ($t.Supported) {
            'Al instalar se abre una consola con la descarga, la verificacion SHA256 y (en ffmpeg) la comprobacion NVENC.'
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
    $btnClose.Add_Click({ $form.Close() })

    & $reload
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
        try { Start-Process -FilePath $l.Path } catch { Show-CvGuiInfo -Title 'Logs' -Message ("No se pudo abrir: {0}" -f $_.Exception.Message) }
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
    [void]$form.ShowDialog()
    $form.Dispose()
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
        @{ Value = 'locks'; Text = ("Bloqueos (*.lock)              [{0}]" -f $p.Locks) }
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
    $form.Size          = New-Object System.Drawing.Size(1040, 720)
    $form.MinimumSize   = New-Object System.Drawing.Size(860, 560)

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
    $outTitle.ForeColor = [System.Drawing.Color]::DimGray
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
        $l.ForeColor = [System.Drawing.Color]::DimGray
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
    [void](& $addButton ("  Restablecer {0}" -f $CfgName) {
        $msg = ("Restablecer {0} a los valores por defecto?`n`nSe CONSERVA el catalogo de herramientas (downloads).`nSe guarda una copia en {0}.bak." -f $CfgName)
        if (-not (Show-CvGuiConfirm -Title 'Restablecer configuracion' -Message $msg)) { & $write 'CONFIGURACION' 'Cancelado.'; return }
        [void](Reset-CvConfig -Path $CfgPath)
        & $write 'CONFIGURACION' ("{0} restablecido (copia en {0}.bak; catalogo de herramientas conservado)." -f $CfgName)
    })

    & $addHeader 'Limpieza'
    [void](& $addButton '  Limpiar jobs / bloqueos (Proceso)' {
        Show-CvCleanWindow -Context $Context
        & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt)
    })

    & $addHeader 'Logs'
    [void](& $addButton '  Ver logs...' {
        Show-CvLogsWindow -Context $Context -CurrentLog $CurrentLog
        & $write 'LOGS' ("{0} log(s) en {1}." -f @(Get-CvSetupLogFiles -Context $Context).Count, $Context.Logs)
    })
    [void](& $addButton '  Limpiar logs' {
        # Se excluye el log de la sesion EN CURSO: esta abierto por el transcript.
        $logs = @(Get-CvLogFiles -Context $Context -ExceptPath $CurrentLog)
        if ($logs.Count -eq 0) { & $write 'LOGS' 'No hay logs que eliminar.'; return }
        if (-not (Show-CvGuiConfirm -Title 'Limpiar logs' -Message ("Se eliminaran {0} log(s) de la carpeta logs. Continuar?" -f $logs.Count))) {
            & $write 'LOGS' 'Cancelado.'; return
        }
        [void](Remove-CvLogFiles -Files $logs)
        & $write 'LOGS' ("Eliminados {0} log(s)." -f $logs.Count)
    })

    # Estado nada mas abrir, para que la ventana no arranque vacia.
    & $write 'ESTADO' (Get-CvSetupStatusText -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
