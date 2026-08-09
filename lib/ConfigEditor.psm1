<#
    ConfigEditor.psm1 - Editor INTERACTIVO de config.json (usado por setup.ps1).

    UI por encima de las funciones puras del arbol de config de Config.psm1 (Get-CvNode*/Set-CvNodeVal/
    Update-CvConfigEdits/ConvertTo-CvJson...) y de los menus de Console.psm1 (Select-FromList). Se separa
    de Config.psm1 para que ese modulo siga siendo la capa de datos (defaults/serializacion/IO) sin UI.
    Punto de entrada: Edit-CvConfigFile. Estado interno de "hubo cambios": $script:CvEditDirty.
#>

$script:CvEditDirty = $false

function Get-CvEditorOptions {
    <#
        Catalogo de OPCIONES válidas de una clave escalar de config, para que el editor de setup muestre
        un MENÚ en vez de pedir que se escriba el valor a mano. Se indexa por el NOMBRE de la clave (hoja).
        Devuelve $null si la clave no tiene un conjunto fijo de opciones (número/texto libre), o un objeto
        { AllowCustom=[bool]; Items=@([pscustomobject]@{ Value; Label; Desc }) }:
          - Value = valor real que se guarda (con su TIPO: int para canales, '' para "sin tope", etc.).
          - Label = texto del menú (por defecto el propio Value; especial para '' u opciones con matiz).
          - Desc  = descripción corta que se muestra junto a la opción.
          - AllowCustom = $true si además se permite teclear un valor no listado (p. ej. tonemapCurve, level).
        Reutiliza los catálogos existentes (Get-CvVolumeMethods/Get-CvTonemapCurves/Get-CvVideoEncoders/
        Get-CvAudioCodecs/Get-CvAudioChannels/Get-CvNvencMultipass/Get-CvDownmixModes) como fuente única.
    #>
    param([Parameter(Mandatory)][string]$Key)
    # Convierte un catálogo @{Value;Text} (o valores planos) en Items {Value;Label;Desc}. NO define
    # valores aquí: TODO sale de catálogos centrales (fuente única) de Config.psm1 / Profile.psm1.
    #  - Config:  Get-CvOutputContainers/TonemapHdrModes/AnamorphicModes/QualityCheckModes/MaxCodecOptions/
    #             NvencTiers, Get-CvVolumeMethods, Get-CvTonemapCurves, Get-CvSubtitleEditorModes.
    #  - Profile: Get-CvVideoEncoders, Get-CvVideoProfileOptions/LevelOptions, Get-CvNvencMultipass,
    #             Get-CvAudioEncoders, Get-CvAudioCodecs, Get-CvAudioChannels, Get-CvDownmixModes,
    #             Get-CvDetectBorderModes.
    $items = {
        param($cat) @($cat | ForEach-Object {
            if ($_ -is [string]) { [pscustomobject]@{ Value = $_; Label = "$_"; Desc = '' } }
            else { [pscustomobject]@{ Value = $_.Value; Label = $(if ("$($_.Value)" -eq '') { '(vacio)' } else { "$($_.Value)" }); Desc = "$($_.Text)" } }
        })
    }
    $ret = { param($cat, [bool]$custom) [pscustomobject]@{ AllowCustom = $custom; Items = (& $items $cat) } }
    switch ($Key) {
        # --- contenedor / vídeo ---
        'outputExtension' { return (& $ret (Get-CvOutputContainers) $false) }
        'videoEncoder'    { return [pscustomobject]@{ AllowCustom = $false; Items = ((& $items (Get-CvVideoEncoders)) + [pscustomobject]@{ Value = 'auto'; Label = 'auto'; Desc = 'mejor encoder del equipo (se resuelve al preparar)' }) } }
        'videoProfile'    { return (& $ret (Get-CvVideoProfileOptions) $true) }   # codec-dependiente -> permite custom
        'videoLevel'      { return (& $ret (Get-CvVideoLevelOptions)   $true) }
        'level'           { return (& $ret (Get-CvVideoLevelOptions)   $true) }
        'multipass'       { return (& $ret (Get-CvNvencMultipass) $false) }
        'tonemapHdr'      { return (& $ret (Get-CvTonemapHdrModes) $false) }
        'tonemapCurve'    { return (& $ret (Get-CvTonemapCurves) $true) }         # libplacebo admite más -> custom
        'anamorphic'      { return (& $ret (Get-CvAnamorphicModes) $false) }
        'qualityCheck'    { return (& $ret (Get-CvQualityCheckModes) $false) }
        'maxCodec'        { return (& $ret (Get-CvMaxCodecOptions) $false) }
        'tier'            { return (& $ret (Get-CvNvencTiers) $false) }
        'detectBorder'    { return (& $ret (Get-CvDetectBorderModes) $false) }
        # --- audio ---
        'method'          { return (& $ret (Get-CvVolumeMethods) $false) }
        'encoder'         { return (& $ret (Get-CvAudioEncoders) $false) }
        'audioEncoder'    { return (& $ret (Get-CvAudioEncoders) $false) }
        'codec'           { return (& $ret (Get-CvAudioCodecs) $false) }
        'audioCodec'      { return (& $ret (Get-CvAudioCodecs) $false) }
        'channels'        { return [pscustomobject]@{ AllowCustom = $false; Items = @(Get-CvAudioChannels | ForEach-Object { [pscustomobject]@{ Value = [int]$_.Value; Label = "$($_.Value)"; Desc = "$($_.Text)" } }) } }
        'audioChannels'   { return [pscustomobject]@{ AllowCustom = $false; Items = @(Get-CvAudioChannels | ForEach-Object { [pscustomobject]@{ Value = [int]$_.Value; Label = "$($_.Value)"; Desc = "$($_.Text)" } }) } }
        'downmixMode'     { return (& $ret (Get-CvDownmixModes) $false) }
        # --- preview ---
        'subtitleEditor'  { return (& $ret (Get-CvSubtitleEditorModes) $false) }
        # --- consola (colores del .NET ConsoleColor, no un literal de datos) ---
        'background'      { return (& $ret ([enum]::GetNames([System.ConsoleColor])) $false) }
        'foreground'      { return (& $ret ([enum]::GetNames([System.ConsoleColor])) $false) }
    }
    return $null
}

function Read-CvEditorPause {
    <# Pausa "ENTER para continuar" propia del editor (equivalente a la de setup), para poder leer un
       mensaje antes de que el siguiente Clear-Host lo borre. #>
    Write-Host ''
    [void](Read-Host 'ENTER para continuar')
}

function Edit-Scalar {
    <#
        Devuelve @{ changed=$bool; value=... } conservando el tipo. La marca `<= por defecto` senala
        el valor POR DEFECTO DE FABRICA (-Default, de Get-CvConfigDefaults), NO el actual; el actual
        se muestra en el titulo. La opcion 0 (cancelar) deja el valor actual sin cambios.
    #>
    param([string]$Key, $Current, [string]$Kind, $Default = $null)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    # 1) Opciones ENUMERADAS: si la clave tiene un catálogo de valores, se ofrece un MENÚ (en vez de
    #    escribir a mano). Va ANTES que 'bool' para cubrir casos de 3 opciones (p. ej. detectBorder:
    #    false/true/auto, que por defecto es bool pero admite 'auto').
    $spec = Get-CvEditorOptions -Key $Key
    if ($null -ne $spec) {
        $items  = @($spec.Items)
        $labels = @($items | ForEach-Object { $_.Label })
        $descs  = @($items | ForEach-Object { $_.Desc })
        $custom = 'custom (escribir otro valor)'
        # Índice por defecto: marca el DEFAULT de fábrica (o, si no está, el actual).
        $byVal = { param($v) $i = 0; for (; $i -lt $items.Count; $i++) { if ("$($items[$i].Value)" -eq "$v") { return $i } }; return -1 }
        $di = & $byVal $Default
        if ($di -lt 0) { $di = & $byVal $Current }
        if ($di -lt 0) { $di = 0 }
        $menuOpts  = if ($spec.AllowCustom) { $labels + $custom } else { $labels }
        $menuDescs = if ($spec.AllowCustom) { $descs  + 'teclear un valor no listado' } else { $descs }
        $p = Select-FromList -Title ("{0} (actual: {1})" -f $Key, $Current) -Options $menuOpts -Descriptions $menuDescs -NoneLabel 'cancelar (dejar actual)' -DefaultIndex ($di + 1)
        if ($p -eq '') { return @{ changed = $false } }
        if ($spec.AllowCustom -and $p -eq $custom) {
            $c = (Read-Host ("   {0}: nuevo valor [ENTER=cancelar]" -f $Key)).Trim()
            if ($c -eq '') { return @{ changed = $false } }
            return @{ changed = $true; value = "$c" }
        }
        # Mapear la etiqueta elegida de vuelta a su Value (conserva el TIPO: int, bool, string...).
        $sel = $items | Where-Object { $_.Label -eq $p } | Select-Object -First 1
        return @{
            changed = $true
            value   = $sel.Value
        }
    }

    if ($Kind -eq 'bool') {
        $def = if ($Default) { 1 } else { 2 }   # marca el DEFAULT de fabrica (no el actual)
        $p = Select-FromList -Title ("{0} (actual: {1})" -f $Key, "$Current".ToLower()) -Options @('true','false') -NoneLabel 'cancelar (dejar actual)' -DefaultIndex $def
        if ($p -eq '') { return @{ changed = $false } }
        return @{
            changed = $true
            value   = ($p -eq 'true')
        }
    }

    # Numero / texto libre: sin menu; se muestra actual y default, ENTER = dejar actual.
    $defTxt = if ($null -ne $Default) { ", por defecto: $Default" } else { '' }
    $ans = (Read-Host ("   {0}  (actual: {1}{2})  nuevo valor [ENTER=cancelar]" -f $Key, $Current, $defTxt)).Trim()
    if ($ans -eq '') { return @{ changed = $false } }
    if ($Kind -eq 'number') {
        if ($ans -match '^-?\d+$') {
            return @{
                changed = $true
                value   = [long]$ans
            }
        }
        $d = 0.0
        if ([double]::TryParse($ans, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
            return @{
                changed = $true
                value   = $d
            }
        }
        Write-Host '   Numero no valido.' -ForegroundColor Yellow
        return @{ changed = $false }
    }
    return @{
        changed = $true
        value   = $ans
    }
}

function Edit-Array {
    <# Editor de listas de cadenas (idiomas, etc.). Devuelve @{ changed; value=@(...) }. #>
    param([string]$Key, $Arr)
    $items = @(@($Arr) | ForEach-Object { "$_" })
    $changed = $false
    while ($true) {
        Clear-Host
        $opts = @()
        for ($i = 0; $i -lt $items.Count; $i++) { $opts += ("[{0}] {1}" -f $i, $items[$i]) }
        $opts += '(+) Anadir elemento'
        if ($items.Count -gt 0) { $opts += '(-) Eliminar elemento' }
        $sel = Select-FromList -Title ("Lista '{0}'  ({1} elementos)" -f $Key, $items.Count) -Options $opts -NoneLabel 'volver' -DefaultIndex 0
        if ($sel -eq '') { break }
        if ($sel -eq '(+) Anadir elemento') {
            $v = (Read-Host '   Nuevo valor').Trim()
            if ($v -ne '') { $items = @($items) + $v; $changed = $true }
        }
        elseif ($sel -eq '(-) Eliminar elemento') {
            $d = (Read-Host '   Indice a eliminar').Trim()
            $n = 0
            if ([int]::TryParse($d, [ref]$n) -and $n -ge 0 -and $n -lt $items.Count) {
                $tmp = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $items.Count; $i++) { if ($i -ne $n) { [void]$tmp.Add($items[$i]) } }
                $items = @($tmp.ToArray()); $changed = $true
            } else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
        }
        elseif ($sel -match '^\[(\d+)\]') {
            $i  = [int]$Matches[1]
            $nv = (Read-Host ("   Nuevo valor para [{0}] (actual: {1}) [ENTER=cancelar]" -f $i, $items[$i])).Trim()
            if ($nv -ne '') { $items[$i] = $nv; $changed = $true }
        }
    }
    return @{
        changed = $changed
        value   = @($items)
    }
}

function Edit-Node {
    <#
        Navega un objeto de config: escalares se editan, objetos se recorren, arrays con su editor.
        -CfgName = nombre del fichero en uso (para el breadcrumb del titulo). Marca $script:CvEditDirty
        si hay algun cambio. La seccion 'profiles' (array de objetos) no se edita aqui (se avisa).
    #>
    param($Node, [string]$Path, [string]$CfgName = 'config.json')
    while ($true) {
        Clear-Host
        # 'gpuCache' (raiz) es cache de maquina que gestiona la sonda de GPU (Initialize-CvGpuCaps),
        # no configuracion editable: no se muestra en el editor (pero se conserva en el fichero).
        $keys = @(Get-CvNodeKeys $Node | Where-Object { -not ($Path -eq '' -and $_ -eq 'gpuCache') })
        $opts = @(); $descs = @()
        foreach ($k in $keys) {
            $v = Get-CvNodeVal $Node $k
            $kind = Get-CvNodeKind $v
            $preview = switch ($kind) {
                'object' { '{...}' }
                'array'  { '[' + ((@($v) | ForEach-Object { "$_" }) -join ', ') + ']' }
                'bool'   { "$v".ToLower() }
                'null'   { 'null' }
                default  { "$v" }
            }
            if ($preview.Length -gt 42) { $preview = $preview.Substring(0, 39) + '...' }
            $opts  += ("{0} = {1}" -f $k, $preview)
            # Ayuda de la opcion (que hace) mostrada junto al valor; ruta con '/' como aqui.
            $descs += (Get-CvHelpFor $(if ($Path) { "$Path/$k" } else { "$k" }))
        }
        $title = if ($Path) { "$CfgName > $Path" } else { $CfgName }
        $sel = Select-FromList -Title $title -Options $opts -Descriptions $descs -NoneLabel 'volver' -DefaultIndex 0
        if ($sel -eq '') { break }
        $key  = $keys[[array]::IndexOf($opts, $sel)]
        $val  = Get-CvNodeVal $Node $key
        $kind = Get-CvNodeKind $val
        if ($Path -eq '' -and $key -eq 'profiles') {
            # Perfiles propios: array de objetos; el editor de listas (escalares) los corromperia.
            Clear-Host
            Write-CvLog 'SETUP' ("Los perfiles propios se editan a mano en {0} (seccion 'profiles')." -f $CfgName)
            Write-CvLog 'SETUP' 'Se anaden al menu USAR PERFIL a continuacion de los de serie (14, 15, ...; ver docs/ref-perfiles.md).'
            Read-CvEditorPause
            continue
        }
        if ($kind -eq 'object') {
            $sub = if ($Path) { "$Path/$key" } else { "$key" }
            Edit-Node -Node $val -Path $sub -CfgName $CfgName
        }
        elseif ($kind -eq 'array') {
            $r = Edit-Array -Key $key -Arr $val
            if ($r.changed) { Set-CvNodeVal $Node $key $r.value; $script:CvEditDirty = $true }
        }
        else {
            # Default de fabrica de esta opcion (por su ruta), para marcarlo en el editor.
            $defVal = Get-CvConfigDefaultValue $(if ($Path) { "$Path/$key" } else { "$key" })
            $r = Edit-Scalar -Key $key -Current $val -Kind $kind -Default $defVal
            if ($r.changed) { Set-CvNodeVal $Node $key $r.value; $script:CvEditDirty = $true }
        }
    }
}

function Edit-CvConfigFile {
    <#
        Editor interactivo del fichero de config -CfgPath (nombre -CfgName para los textos). Edita el
        config FUSIONADO (defaults + overrides) para mostrar TODAS las opciones aunque el fichero sea
        minimo; al guardar aplica SOLO lo que difiere del default sobre el fichero crudo (lo que vuelve
        al default se elimina). No pausa al terminar: eso lo hace el llamador (setup).
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$CfgPath, [string]$CfgName = 'config.json')
    Clear-Host
    Write-CvLog 'SETUP' ("Editor de {0} (0 = volver en cada nivel)." -f $CfgName)
    $cfg    = Get-CvConfig -Root $Root -Path $CfgPath
    $before = Get-CvConfig -Root $Root -Path $CfgPath
    $script:CvEditDirty = $false
    Edit-Node -Node $cfg -Path '' -CfgName $CfgName
    if ($script:CvEditDirty) {
        if (Read-YesNo ("Guardar cambios en {0}?" -f $CfgName) $true) {
            # Aplicar SOLO lo editado sobre el fichero ACTUAL (crudo): lo que difiere del default se
            # guarda; lo que vuelve al default se elimina del fichero.
            $raw = if (Test-Path -LiteralPath $CfgPath) { Read-CvConfigFile -Path $CfgPath } else { [pscustomobject]@{} }
            Update-CvConfigEdits -Edited $cfg -Before $before -Default (Get-CvConfigDefaults) -Target $raw
            Save-CvConfigFile -Path $CfgPath -Config $raw
            Write-CvLog 'SETUP' ("[OK] - {0} actualizado (solo los valores distintos del default)." -f $CfgName)
        } else {
            Write-CvLog 'SETUP' 'Cambios descartados.'
        }
    } else {
        Write-CvLog 'SETUP' 'Sin cambios.'
    }
}

Export-ModuleMember -Function *
