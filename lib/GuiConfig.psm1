<#
    GuiConfig.psm1 - El arbol del editor de config.json, sin la ventana.

    Pasar de la config a nodos y al reves (Resolve-CvCfgNode, Add-CvCfgNodes), como se resume el
    valor de cada clave en una linea (Format-CvCfgPreview, Update-CvCfgNodeText), como se marca lo
    que esta cambiado respecto a lo de partida (Set-CvCfgNodeStyle, Test-CvCfgNodeModified,
    Get-CvCfgModifiedCount) y el BUSCADOR (Get-CvCfgSearchIndex, Find-CvCfgSearchHits).

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

function ConvertTo-CvCfgSearchText {
    <#
        PURO. Un texto listo para comparar: en minusculas y SIN TILDES (una i con tilde vale como i),
        para que buscar no dependa de acertar con los acentos ni con las mayusculas.
    #>
    param([string]$Text = '')
    $d = "$Text".Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
}

function Get-CvCfgSearchIndex {
    <#
        El INDICE del buscador del editor: por cada clave (secciones incluidas), un texto con todo lo
        que alguien podria escribir para encontrarla:

          - la ruta, con '/' y con '.' ('encode/audio/syncMaxAhead' y 'encode.audio.syncMaxAhead',
            que es como se escribe en los docs) y el nombre de la clave a secas;
          - su AYUDA (Get-CvConfigHelp, sin el marcador de avanzada), solo en las opciones: una
            seccion se busca por su nombre (si no, una palabra de su ayuda la sacaba entera);
          - su valor actual y el de fabrica;
          - las opciones de su desplegable, con su descripcion (Get-CvEditorOptions).

        Ya normalizado (ConvertTo-CvCfgSearchText). Se monta una vez y se reutiliza en cada tecla:
        sacar la ayuda de 200 claves en cada pulsacion se notaria. -Help se pasa para no rehacerla.
        Devuelve un hashtable ruta -> texto.
    #>
    param(
        [Parameter(Mandatory)]$Node,
        [string]$Path = '',
        $Help = $null,
        $Index = $null
    )
    if ($null -eq $Index) { $Index = @{} }
    if ($null -eq $Help) { $Help = Get-CvConfigHelp }
    $marca = Get-CvConfigAdvancedMark
    foreach ($k in (Get-CvNodeKeys $Node)) {
        if ($Path -eq '' -and $k -eq 'gpuCache') { continue }
        $v    = Get-CvNodeVal $Node $k
        $kind = Get-CvNodeKind $v
        $full = if ($Path) { "$Path/$k" } else { "$k" }
        $partes = New-Object System.Collections.Generic.List[string]
        $partes.Add($full)
        $partes.Add(($full -replace '/', '.'))
        $partes.Add("$k")
        if ($kind -eq 'object') {
            # Una SECCION solo por su nombre: casar por su ayuda la sacaba ENTERA (buscar 'sincronia
            # audio' ensenaba las 26 opciones de audio porque la ayuda de la seccion habla de
            # sincronia). Asi, lo que diga la ayuda filtra opcion a opcion, que es lo util.
            $Index[$full] = ConvertTo-CvCfgSearchText -Text ($partes -join ' | ')
            [void](Get-CvCfgSearchIndex -Node $v -Path $full -Help $Help -Index $Index)
            continue
        }
        if ($Help.ContainsKey($full)) {
            $h = "$($Help[$full])"
            if ($h.StartsWith($marca)) { $h = $h.Substring($marca.Length) }
            $partes.Add($h)
        }
        $partes.Add((Format-CvCfgPreview $v 400))
        $def = Get-CvConfigDefaultValue $full
        if ($null -ne $def) { $partes.Add((Format-CvCfgPreview $def 400)) }
        $spec = Get-CvEditorOptions -Key $k
        if ($null -ne $spec) {
            foreach ($it in @($spec.Items)) { $partes.Add(("{0} {1} {2}" -f $it.Value, $it.Label, $it.Desc)) }
        }
        $Index[$full] = ConvertTo-CvCfgSearchText -Text ($partes -join ' | ')
    }
    return $Index
}

function Find-CvCfgSearchHits {
    <#
        PURO. Las claves del indice (Get-CvCfgSearchIndex) que casan con lo escrito: TODAS las
        palabras tienen que estar, en cualquier orden y sin importar tildes ni mayusculas ('audio
        sincro' encuentra la ayuda que habla de la sincronia del audio, lleve tilde o no). Devuelve
        un hashtable ruta -> $true, o $null si la busqueda esta vacia (= no filtrar).
    #>
    param($Index, [string]$Query = '')
    $palabras = @((ConvertTo-CvCfgSearchText -Text $Query) -split '\s+' | Where-Object { $_ -ne '' })
    if ($palabras.Count -eq 0) { return $null }
    $hits = @{}
    foreach ($p in @($Index.Keys)) {
        $txt = "$($Index[$p])"
        $todas = $true
        foreach ($w in $palabras) {
            if (-not $txt.Contains($w)) { $todas = $false; break }
        }
        if ($todas) { $hits[$p] = $true }
    }
    return $hits
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

        -Match (lo que devuelve Find-CvCfgSearchHits) FILTRA el arbol a lo que casa con el buscador:
        una hoja sale si casa; una seccion, entera si casa ella (buscar 'audio' ensena toda la
        seccion) o con solo lo que case dentro, y abierta. Buscando se ven tambien las AVANZADAS
        -si no, no encontrarias lo que buscas-, y en -Stats.Matches se cuentan las hojas que salen.
    #>
    param($Parent, $Node, [string]$Path, $BoldFont = $null, [bool]$ShowAdvanced = $false, $Stats = $null, $Match = $null)
    $anyMod = $false
    $filtrando = ($null -ne $Match)
    foreach ($k in (Get-CvNodeKeys $Node)) {
        if ($Path -eq '' -and $k -eq 'gpuCache') { continue }
        $v    = Get-CvNodeVal $Node $k
        $kind = Get-CvNodeKind $v
        $full = if ($Path) { "$Path/$k" } else { "$k" }
        if ($filtrando) {
            $casa = $Match.ContainsKey($full)
            if ($kind -ne 'object' -and -not $casa) { continue }
            $tn = New-Object System.Windows.Forms.TreeNode
            $tn.Tag = $full
            if ($kind -eq 'object') {
                $tn.Text = "$k"
                # Casa la seccion: entera (sin filtro dentro). Si no, solo lo que case dentro.
                $sub = $(if ($casa) { $null } else { $Match })
                if (Add-CvCfgNodes -Parent $tn -Node $v -Path $full -BoldFont $BoldFont -ShowAdvanced $true -Stats $Stats -Match $sub) { $anyMod = $true }
                if ($tn.Nodes.Count -eq 0) { continue }
                [void]$Parent.Nodes.Add($tn)
                $tn.Expand()
            } else {
                $tn.Text = ("{0} = {1}" -f $k, (Format-CvCfgPreview $v))
                [void]$Parent.Nodes.Add($tn)
                $mod = Test-CvCfgNodeModified -Value $v -Path $full
                Set-CvCfgNodeStyle -TreeNode $tn -Modified $mod -BoldFont $BoldFont
                if ($mod) { $anyMod = $true }
                if ($null -ne $Stats) { $Stats.Matches = [int]$Stats.Matches + 1 }
            }
            continue
        }
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
        if ($null -ne $Stats -and $kind -ne 'object') { $Stats.Matches = [int]$Stats.Matches + 1 }
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
