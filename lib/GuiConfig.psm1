<#
    GuiConfig.psm1 - El arbol del editor de config.json, sin la ventana.

    Pasar de la config a nodos y al reves (Resolve-CvCfgNode, Add-CvCfgNodes), como se resume el
    valor de cada clave en una linea (Format-CvCfgPreview, Update-CvCfgNodeText) y como se marca lo
    que esta cambiado respecto a lo de partida (Set-CvCfgNodeStyle, Test-CvCfgNodeModified,
    Get-CvCfgModifiedCount).

    Los DEFAULTS y el guardado son de lib\Config.psm1: aqui no se decide ningun valor. La ventana
    esta en form\GuiConfigWindow.psm1.
#>

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

Export-ModuleMember -Function *
