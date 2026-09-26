<#
    I18n.psm1 - El TEXTO que se ensena, fuera del codigo.

    Una clave por mensaje ('cola.boton.iniciar') y un fichero por idioma en lang\<idioma>.json, que
    se lee con Read-CvJsonFile: UTF-8 explicito. Eso ademas arregla algo viejo -las tildes-: en un
    .psm1 sin BOM, PowerShell 5.1 lee los acentos como ANSI y se corrompen, y por eso todo el texto
    del codigo esta escrito sin tildes ('codificacion'). En el JSON se escriben bien.

    El idioma es de la SESION, no del contexto, por lo mismo que el tema de las ventanas: $ctx es
    una FOTO del arranque y lo que se cambia en caliente no se veria (ver ref-gotchas.md). Los
    lanzadores llaman a Set-CvLanguage con lo que diga la config y a partir de ahi Get-CvText lo usa
    sin que haya que ir pasando el idioma por todas partes.

    Si una clave no esta en el idioma pedido se busca en CASTELLANO, y si tampoco esta se devuelve
    LA PROPIA CLAVE. Nunca una cadena vacia: un texto que falta tiene que verse, no dejar un hueco.
    Lo mismo que hace New-CvGuiCatalogControl al encontrarse un tipo que no conoce.
#>

$script:CvLangBase = 'es'      # el idioma en el que se escribe primero, y el respaldo de todos

function Get-CvUiLanguages {
    <#
        Idiomas de la interfaz (ui.language). El 1o = default de fabrica ('auto').

        NO es una lista escrita a mano: sale de los ficheros que haya en lang\, y cada idioma dice
        SU PROPIO NOMBRE en su fichero ('lang.name': "English", "Francais"...). Asi anadir un idioma
        es soltar un .json y ya aparece; si el nombre lo tuviera que dar otro, cada idioma nuevo
        obligaria a tocar TODOS los demas ficheros para traducir como se llama.

        El castellano esta siempre aunque falte su fichero: es el respaldo, y sin el la validacion
        de ui.language rechazaria el unico idioma que seguro se puede pintar.
    #>
    param([string]$Dir = '')
    $out = @(
        @{ Value = 'auto'; Text = (Get-CvText -Key 'lang.auto') }
    )
    # Sin @() alrededor: Get-CvLangAvailable devuelve ,$array y envolverlo lo dejaria en UN
    # elemento (el array entero), que es la trampa de siempre de este repo.
    $codigos = Get-CvLangAvailable -Dir $Dir
    if (@($codigos) -notcontains $script:CvLangBase) { $codigos = @($script:CvLangBase) + @($codigos) }
    foreach ($c in ($codigos | Sort-Object)) {
        $propio = (Get-CvLangResources -Lang $c -Dir $Dir)['lang.name']
        $out += @{
            Value = $c
            Text  = $(if ("$propio" -ne '') { "$propio" } else { $c })
        }
    }
    return ,$out
}

function Get-CvLangDir {
    <# La carpeta lang\, al lado de lib\. Se puede apuntar a otra (-Dir) para las pruebas. #>
    param([string]$Dir = '')
    if ("$Dir" -ne '') { return $Dir }
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'lang')
}

function Get-CvLangAvailable {
    <# Que idiomas hay de verdad en disco (los .json de lang\). #>
    param([string]$Dir = '')
    $d = Get-CvLangDir -Dir $Dir
    if (-not (Test-Path -LiteralPath $d)) { return ,@() }
    $out = @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File | ForEach-Object { $_.BaseName })
    return ,$out
}

function Resolve-CvLanguage {
    <#
        PURO. Que idioma toca de verdad: 'auto' es el del sistema SI hay traduccion, y cualquier
        cosa que no tenga fichero cae en castellano. Asi un config con 'fr' no deja la interfaz en
        blanco, y un Windows en aleman no obliga a traducir el aleman para poder arrancar.
    #>
    param(
        [string]$Lang = 'auto',
        [string]$SystemLang = '',
        $Available = @()
    )
    $hay = @($Available | ForEach-Object { "$_".ToLowerInvariant() })
    $pedido = "$Lang".Trim().ToLowerInvariant()
    if ($pedido -eq 'auto' -or $pedido -eq '') { $pedido = "$SystemLang".Trim().ToLowerInvariant() }
    # 'es-ES' vale como 'es': se queda con la parte de delante.
    if ($pedido -match '^([a-z]{2})[-_]') { $pedido = $Matches[1] }
    if ($pedido -ne '' -and $hay -contains $pedido) { return $pedido }
    return $script:CvLangBase
}

function ConvertTo-CvLangMap {
    <# El JSON leido (objeto) a tabla clave -> texto, que es como se consulta. #>
    param($Json)
    $map = @{}
    if ($null -eq $Json) { return $map }
    foreach ($p in $Json.PSObject.Properties) { $map["$($p.Name)"] = "$($p.Value)" }
    return $map
}

function Get-CvLangResources {
    <# Los textos de un idioma, como tabla. Si no hay fichero, tabla vacia (no se revienta). #>
    param(
        [Parameter(Mandatory)][string]$Lang,
        [string]$Dir = ''
    )
    $p = Join-Path (Get-CvLangDir -Dir $Dir) ("{0}.json" -f $Lang)
    return (ConvertTo-CvLangMap -Json (Read-CvJsonFile -Path $p -Quiet))
}

function Set-CvLanguage {
    <#
        Fija el idioma de la SESION (lo llaman los lanzadores con lo que diga la config) y deja
        cargados sus textos y los de respaldo. Devuelve el idioma ya resuelto.
    #>
    param(
        [string]$Lang = 'auto',
        [string]$Dir = ''
    )
    $sys = ''
    try { $sys = (Get-Culture).TwoLetterISOLanguageName } catch { $sys = '' }
    $res = Resolve-CvLanguage -Lang $Lang -SystemLang $sys -Available (Get-CvLangAvailable -Dir $Dir)
    $script:CvLang    = $res
    $script:CvLangMap = Get-CvLangResources -Lang $res -Dir $Dir
    $script:CvLangFb  = $(if ($res -eq $script:CvLangBase) { $script:CvLangMap } else { Get-CvLangResources -Lang $script:CvLangBase -Dir $Dir })
    return $res
}

function Get-CvLanguage {
    <# El idioma de esta sesion. Si nadie lo ha fijado, se resuelve solo la primera vez. #>
    if ("$script:CvLang" -eq '') { [void](Set-CvLanguage -Lang 'auto') }
    return $script:CvLang
}

function Get-CvText {
    <#
        El texto de una clave, ya en el idioma de la sesion.

        -Values son los datos que van dentro de la frase ({0}, {1}...). Van APARTE del texto a
        proposito: el orden de las palabras cambia de un idioma a otro, asi que la frase entera
        -incluido donde cae cada dato- es cosa del fichero de idioma, no del codigo.

        Si el formato no cuadra con lo que se le pasa (una traduccion con un {1} de mas), se
        devuelve la frase SIN rellenar en vez de reventar a media codificacion; para eso esta
        Test-CvLangResources, que lo caza en las pruebas y no en marcha.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        $Values = @()
    )
    if ("$script:CvLang" -eq '') { [void](Set-CvLanguage -Lang 'auto') }
    $txt = $null
    if ($script:CvLangMap.ContainsKey($Key)) { $txt = $script:CvLangMap[$Key] }
    elseif ($null -ne $script:CvLangFb -and $script:CvLangFb.ContainsKey($Key)) { $txt = $script:CvLangFb[$Key] }
    if ($null -eq $txt) { return $Key }        # una clave que falta se VE; no se devuelve vacio
    $vals = @($Values)
    if ($vals.Count -eq 0) { return $txt }
    try { return ($txt -f $vals) } catch { return $txt }
}

function Get-CvTextPlaceholders {
    <# PURO. Que huecos ({0}, {1}...) lleva una frase, ordenados y sin repetir. #>
    param([string]$Text = '')
    $n = @()
    foreach ($m in [regex]::Matches("$Text", '\{(\d+)(?::[^}]*)?\}')) { $n += [int]$m.Groups[1].Value }
    return ,@($n | Sort-Object -Unique)
}

function Test-CvLangResources {
    <#
        PURO. Compara una traduccion con el idioma base y devuelve lo que hay que arreglar:

          Faltan       claves del base que la traduccion no tiene (saldrian en castellano)
          Sobran       claves que ya no usa nadie (el base las quito)
          Huecos       claves cuyos {0},{1}... no coinciden: ESTO es lo que revienta al formatear,
                       y es justo lo que no se ve leyendo el fichero por encima

        Es lo que convierte "traducir" en algo que se puede comprobar en la bateria.
    #>
    param(
        $Base = @{},
        $Other = @{}
    )
    $faltan = @()
    $huecos = @()
    foreach ($k in @($Base.Keys | Sort-Object)) {
        if (-not $Other.ContainsKey($k)) { $faltan += $k; continue }
        $a = (Get-CvTextPlaceholders -Text "$($Base[$k])") -join ','
        $b = (Get-CvTextPlaceholders -Text "$($Other[$k])") -join ','
        if ($a -ne $b) { $huecos += $k }
    }
    $sobran = @($Other.Keys | Where-Object { -not $Base.ContainsKey($_) } | Sort-Object)
    [ordered]@{
        Faltan = @($faltan)
        Sobran = @($sobran)
        Huecos = @($huecos)
    }
}

Export-ModuleMember -Function *
