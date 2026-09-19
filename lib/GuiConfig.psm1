<#
    GuiConfig.psm1 - El EDITOR DE config.json en VENTANA (WinForms).

    Arbol de secciones a la izquierda y, a la derecha, el valor de la clave elegida con el control
    que le toca, su ayuda y su valor de fabrica. Sale de GuiSetup.psm1 -donde nacio- porque es una
    ventana entera por si misma (la mas grande de setup) y no solo la abre setup: la cola tambien
    llega a ella cuando ofrece abrir la configuracion.

    Lo que se edita y COMO se guarda no esta aqui: son los mismos helpers que usa el editor de
    consola (Get-CvEditorOptions para los enum, Get-CvHelpFor para la ayuda, Get-CvConfigDefaultValue
    para el default y Update-CvConfigEdits al guardar). Aqui solo cambia el RENDER.
#>

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

        El azul sale de la PALETA (rol 'edited'), no fijo: el de tema claro sobre el fondo casi negro
        del oscuro no se leia.
    #>
    param($TreeNode, [bool]$Modified, $BoldFont, $Palette = $null)
    if ($Modified) {
        if ($BoldFont) { $TreeNode.NodeFont = $BoldFont }
        $pal = $(if ($null -ne $Palette) { $Palette } else { Get-CvGuiCurrentPalette })
        $TreeNode.ForeColor = Get-CvGuiRoleColor -Palette $pal -Role 'edited'
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
    $split.Name       = 'cvCfgSplit'
    $form.Controls.Add($split)
    # Se puede arrastrar para dar mas sitio al arbol o al detalle, pero de serie el divisor es una
    # franja del color del fondo y no se ve: se ensancha y se le pinta el agarre (lo mismo que la
    # cola, ver Set-CvGuiSplitGrip).
    [void](Set-CvGuiSplitGrip -Split $split -Tooltip 'Arrastra esta linea para repartir el ancho entre el arbol y el detalle')
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
    $lblDef.ForeColor = (Get-CvGuiCurrentPalette).Muted
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
    $lblDirty.ForeColor = (Get-CvGuiCurrentPalette).Muted
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
        $lblDirty.ForeColor = (Get-CvGuiCurrentPalette).Error
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
    [void](Set-CvGuiTheme -Form $form)   # tema de la sesion
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Saved
}

Export-ModuleMember -Function *
