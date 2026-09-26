<#
    SetupCore.psm1 - DATOS de las acciones de setup (sin interfaz).

    Fuente unica de "que se sabe / que se hace" en setup, para que las DOS interfaces -la consola
    (setup.ps1) y la ventana (setup-gui.ps1 / form\GuiSetupWindow.psm1)- pinten lo MISMO sin duplicar logica:
    cada funcion devuelve DATOS (objetos), nunca texto con colores ni prompts, y cada UI decide como
    renderizarlos (marcas y badges en consola, iconos y listas en la ventana).

    Aqui NO se escribe en pantalla ni se pregunta nada: las confirmaciones (borrados, reset) las hace
    la UI y luego llama a la funcion que ejecuta. Las funciones de estado son de solo lectura salvo
    Get-CvSetupDirStatus, que CREA las carpetas de trabajo que falten (igual que hacia setup.ps1).
#>

function Get-CvSetupIdentity {
    <#
        Identidad del entorno: nombre/version del programa y config.json en uso (el de por defecto o
        el alterno pasado con -Config). 'IsAlt' = se indico un config a mano; 'Exists' = el fichero
        existe (si no, se usan los valores por defecto).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CfgPath,
        [bool]$IsAlt = $false
    )
    [pscustomobject]@{
        AppName = "$($Context.AppName)"
        Version = "$($Context.Version)"
        CfgPath = $CfgPath
        CfgName = (Split-Path -Leaf $CfgPath)
        IsAlt   = $IsAlt
        Exists  = (Test-Path -LiteralPath $CfgPath)
    }
}

function Get-CvSetupDirStatus {
    <#
        Carpetas de trabajo (Get-CvWorkDirs) con su estado. OJO: CREA las que falten (es lo que hacia
        setup.ps1 al mostrar el estado) y lo marca en 'Created', para que la UI lo diga.
    #>
    param([Parameter(Mandatory)]$Context)
    $out = @()
    foreach ($d in (Get-CvWorkDirs -Context $Context)) {
        $existed = Test-Path -LiteralPath $d
        if (-not $existed) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $out += [pscustomobject]@{
            Name    = (Split-Path $d -Leaf)
            Path    = $d
            Ok      = (Test-Path -LiteralPath $d)
            Created = (-not $existed)
        }
    }
    return @($out)
}

function Get-CvSetupAppNames {
    <# Nombres de las apps del catalogo 'downloads' (hashtable o PSCustomObject, segun de donde venga). #>
    param([Parameter(Mandatory)]$Context)
    $apps = $Context.Downloads
    if ($apps -is [System.Collections.IDictionary]) { return @($apps.Keys) }
    if ($apps) { return @($apps.PSObject.Properties.Name) }
    return @()
}

function Get-CvSetupToolStatus {
    <#
        Estado de cada app del catalogo: si la plataforma la soporta, versiones instaladas, la version
        'selected' (la que usa el conversor) y si esa esta instalada ('SelectedOk' = la marca de OK).
    #>
    param([Parameter(Mandatory)]$Context)
    $out = @()
    foreach ($n in (Get-CvSetupAppNames -Context $Context)) {
        $app = Get-CvAppDescriptor -Context $Context -Name $n
        $sel = "$($app.selected)"
        if (-not (Test-CvToolSupported -Context $Context -Name $n)) {
            $out += [pscustomobject]@{
                Name       = $n
                Supported  = $false
                Platform   = (Get-CvPlatform)
                Installed  = @()
                Selected   = $sel
                SelectedOk = $false
            }
            continue
        }
        $inst = @(Get-CvInstalledVersions -Context $Context -Name $n)
        $out += [pscustomobject]@{
            Name       = $n
            Supported  = $true
            Platform   = (Get-CvAppPlatform -Context $Context -Name $n)
            Installed  = $inst
            Selected   = $sel
            SelectedOk = ($inst -contains $sel)
        }
    }
    return @($out)
}

function Get-CvSetupAppVersions {
    <# Versiones del CATALOGO de una app (las descargables), en el orden en que vienen del descriptor. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $app = Get-CvAppDescriptor -Context $Context -Name $Name
    if ($app.versions -is [System.Collections.IDictionary]) { return @($app.versions.Keys) }
    if ($app.versions) { return @($app.versions.PSObject.Properties.Name) }
    return @()
}

function Get-CvSetupGpuStatus {
    <#
        Codecs por GPU (NVENC) soportados por ESTA grafica, sondeados EN VIVO: se ignora la cache de
        config.json (gpuCache) reseteando la memoizacion antes y despues, para ver el estado real (p.
        ej. tras cambiar de GPU o de driver). 'Ready' = hay ffmpeg con el que comprobar; si no, la
        lista de encoders viene vacia y la UI avisa.
    #>
    param([Parameter(Mandatory)]$Context)
    $gpu   = Get-CvGpuName
    $exe   = "$($Context.FFmpeg)"
    $ready = (-not [string]::IsNullOrWhiteSpace($exe)) -and (Test-Path -LiteralPath $exe)
    $encs  = @()
    if ($ready) {
        Reset-CvGpuEncCache                     # forzar sonda (sin cache)
        foreach ($e in (Get-CvGpuEncoders)) {
            $encs += [pscustomobject]@{
                Name = $e
                Ok   = (Test-CvGpuEncoder -Context $Context -Encoder $e)
            }
        }
        Reset-CvGpuEncCache                     # no dejar la memoizacion "sucia"
    }
    [pscustomobject]@{
        Gpu      = $(if ($gpu) { $gpu } else { '' })
        Ready    = $ready
        Encoders = @($encs)
    }
}

function Get-CvSetupProcesoStatus {
    <# Contenido de Proceso\: jobs pendientes, bloqueos (y cuantos caducados/huerfanos) y temporales. #>
    param([Parameter(Mandatory)]$Context)
    $proc = $Context.Proceso
    if (-not (Test-Path -LiteralPath $proc)) {
        return [pscustomobject]@{
            Exists = $false
            Jobs   = 0
            Locks  = 0
            Stale  = 0
            Temps  = 0
        }
    }
    # 'Locks' cuenta TODOS los ficheros de control (Get-CvProcesoPatterns -What locks: los *.lock, el
    # estado que publica cada worker y la bandera de parada), que es justo lo que borra la limpieza de
    # 'bloqueos'. Los CADUCADOS solo se miran en los *.lock, que son los que guardan el PID.
    $nlock = 0
    foreach ($p in (Get-CvProcesoPatterns -What locks)) { $nlock += @(Get-ChildItem -LiteralPath $proc -Filter $p -File -ErrorAction SilentlyContinue).Count }
    $locks = @(Get-ChildItem -LiteralPath $proc -Filter '*.lock' -File -ErrorAction SilentlyContinue)
    $ntemp = 0
    foreach ($p in (Get-CvProcesoPatterns -What temps)) { $ntemp += @(Get-ChildItem -LiteralPath $proc -Filter $p -File -ErrorAction SilentlyContinue).Count }
    [pscustomobject]@{
        Exists = $true
        Jobs   = @(Get-ChildItem -LiteralPath $proc -Filter '*.job.json' -File -ErrorAction SilentlyContinue).Count
        Locks  = $nlock
        Stale  = @($locks | Where-Object { Test-CvLockStale $_.FullName }).Count
        Temps  = $ntemp
    }
}

function Get-CvSetupWorkStatus {
    <# Trabajo pendiente: videos de entrada en Original\ frente a convertidos (*_fix.<ext>) en Convertido\. #>
    param([Parameter(Mandatory)]$Context)
    $nout = 0
    if (Test-Path -LiteralPath $Context.Convertido) {
        $nout = @(Get-ChildItem -LiteralPath $Context.Convertido -Filter ("*_fix.{0}" -f $Context.OutExt) -File -ErrorAction SilentlyContinue).Count
    }
    [pscustomobject]@{
        Input     = @(Get-CvFiles -Dir $Context.Original -Filters $Context.Extensions -Exact).Count
        Converted = $nout
    }
}

function Get-CvSetupCleanTargets {
    <#
        Ficheros de Proceso\ que borraria una limpieza ('jobs'|'locks'|'temps'|'all'), SIN borrar nada:
        la UI los ensena, confirma y luego llama a Remove-CvSetupFiles. Los patrones salen de la fuente
        unica Get-CvProcesoPatterns (Job.psm1).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('jobs','locks','temps','all')][string]$What = 'all'
    )
    $proc = $Context.Proceso
    if (-not (Test-Path -LiteralPath $proc)) { return @() }
    return @(Get-CvFiles -Dir $proc -Filters (Get-CvProcesoPatterns -What $What) -Exact)
}

function Get-CvSetupMaintenanceItems {
    <#
        TODO lo que se puede limpiar, en una sola lista y con su recuento: jobs, bloqueos y
        temporales de Proceso\, logs, y lo cacheado por las ventanas. Antes cada cosa vivia en su
        propio boton/menu y habia que ir a buscarlas de una en una.

        Es DATO: no borra ni pregunta. Cada fila @{ Key; Text; Detail; Count; Warn }:
          Key    'jobs'|'locks'|'temps'|'logs'|'cacheLayout'|'cacheFiles'
          Text   como se ensena en la lista
          Detail una linea de que se pierde al borrarlo
          Count  cuantos elementos hay (0 = no hay nada que borrar)
          Warn   $true si conviene pensarselo (borrar jobs es rehacer el PREPARAR)

        -CurrentLog: el log de la sesion en curso, que NO se cuenta (esta abierto).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$CurrentLog = ''
    )
    $out = @()
    foreach ($par in @(
        @{ Key = 'jobs';  Warn = $true;  Text = (Get-CvText -Key 'mant.it.jobs');  Detail = (Get-CvText -Key 'mant.it.jobs.d') }
        @{ Key = 'locks'; Warn = $false; Text = (Get-CvText -Key 'mant.it.locks'); Detail = (Get-CvText -Key 'mant.it.locks.d') }
        @{ Key = 'temps'; Warn = $false; Text = (Get-CvText -Key 'mant.it.temps'); Detail = (Get-CvText -Key 'mant.it.temps.d') }
    )) {
        $out += [pscustomobject]@{
            Key    = $par.Key
            Text   = $par.Text
            Detail = $par.Detail
            Count  = @(Get-CvSetupCleanTargets -Context $Context -What $par.Key).Count
            Warn   = [bool]$par.Warn
        }
    }
    $logs = @(Get-CvSetupLogFiles -Context $Context -CurrentPath $CurrentLog | Where-Object { -not $_.IsCurrent })
    $kb   = 0
    foreach ($l in $logs) { $kb += [int]$l.SizeKb }
    $out += [pscustomobject]@{
        Key    = 'logs'
        Text   = (Get-CvText -Key 'mant.it.logs')
        Detail = (Get-CvText -Key 'mant.it.logs.d' -Values @((Format-CvSize -Kb $kb)))
        Count  = $logs.Count
        Warn   = $false
    }
    $c = Get-CvGuiCacheStatus -Context $Context
    $out += [pscustomobject]@{
        Key    = 'cacheLayout'
        Text   = (Get-CvText -Key 'mant.it.layout')
        Detail = (Get-CvText -Key 'mant.it.layout.d')
        Count  = [int]$c.Layouts
        Warn   = $false
    }
    $out += [pscustomobject]@{
        Key    = 'cacheFiles'
        Text   = (Get-CvText -Key 'mant.it.files')
        Detail = (Get-CvText -Key 'mant.it.files.d')
        Count  = [int]$c.Files
        Warn   = $false
    }
    return @($out)
}

function Invoke-CvSetupMaintenance {
    <#
        Limpia lo pedido (-Keys, las mismas claves de Get-CvSetupMaintenanceItems) y devuelve una
        fila por clave con lo que se ha quitado: @{ Key; Text; Removed; Ok; Error }.

        Borra, pero no pregunta ni pinta: confirma la UI, que es la que sabe como hacerlo.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string[]]$Keys = @(),
        [string]$CurrentLog = ''
    )
    $items = @{}
    foreach ($i in @(Get-CvSetupMaintenanceItems -Context $Context -CurrentLog $CurrentLog)) { $items[$i.Key] = $i }
    $res = @()
    foreach ($k in @($Keys)) {
        $txt = $(if ($items.ContainsKey($k)) { "$($items[$k].Text)" } else { $k })
        $n = 0
        $ok = $true
        $err = ''
        switch ($k) {
            'jobs'  { $n = Remove-CvSetupFiles -Files (Get-CvSetupCleanTargets -Context $Context -What 'jobs') }
            'locks' { $n = Remove-CvSetupFiles -Files (Get-CvSetupCleanTargets -Context $Context -What 'locks') }
            'temps' { $n = Remove-CvSetupFiles -Files (Get-CvSetupCleanTargets -Context $Context -What 'temps') }
            'logs'  {
                $viejos = @(Get-CvSetupLogFiles -Context $Context -CurrentPath $CurrentLog | Where-Object { -not $_.IsCurrent })
                foreach ($l in $viejos) {
                    try { Remove-Item -LiteralPath $l.Path -Force -ErrorAction Stop; $n++ } catch { $ok = $false; $err = "$_" }
                }
            }
            'cacheLayout' { $r = Clear-CvGuiCache -Context $Context -What 'layout'; $n = [int]$r.Removed; $ok = [bool]$r.Ok; $err = "$($r.Error)" }
            'cacheFiles'  { $r = Clear-CvGuiCache -Context $Context -What 'files';  $n = [int]$r.Removed; $ok = [bool]$r.Ok; $err = "$($r.Error)" }
            default { $ok = $false; $err = 'no se sabe que es eso' }
        }
        $res += [pscustomobject]@{
            Key     = $k
            Text    = $txt
            Removed = $n
            Ok      = $ok
            Error   = $err
        }
    }
    return @($res)
}

function Get-CvSetupMaintenanceText {
    <# Las filas de mantenimiento como texto, para el panel de setup y para la consola. #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$CurrentLog = ''
    )
    $L = New-Object System.Collections.Generic.List[string]
    foreach ($i in @(Get-CvSetupMaintenanceItems -Context $Context -CurrentLog $CurrentLog)) {
        $L.Add(("  {0,4}  {1}" -f $i.Count, $i.Text))
        $L.Add(("        {0}" -f $i.Detail))
    }
    return ($L -join [Environment]::NewLine)
}

function Get-CvSetupCacheText {
    <#
        Que hay en las CACHES de las ventanas, como texto de una linea por cosa. Lo ensenan igual la
        consola y la ventana (Get-CvGuiCacheStatus es quien lo mira; esto solo lo redacta).
    #>
    param([Parameter(Mandatory)]$Context)
    $c = Get-CvGuiCacheStatus -Context $Context
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add(("Fichero: {0}" -f $c.Path))
    if (-not $c.Exists) {
        $L.Add('  (no existe: no hay nada cacheado)')
        return ($L -join [Environment]::NewLine)
    }
    $L.Add(("  ocupa {0} KB" -f $c.SizeKb))
    $L.Add(("  ventanas recordadas : {0}{1}" -f $c.Layouts, $(if ($c.Layouts -gt 0) { "   ({0})" -f ((@($c.LayoutKeys)) -join ', ') } else { '' })))
    $L.Add(("  archivos analizados : {0}   (bordes deducidos de los ya convertidos)" -f $c.Files))
    $L.Add('')
    $L.Add('Es ESTADO: borrarlo no pierde nada. Las ventanas volveran a abrirse con los tamanos de')
    $L.Add('config.json y los bordes se volveran a deducir la proxima vez que se abra la cola.')
    return ($L -join [Environment]::NewLine)
}

function Remove-CvSetupFiles {
    <# Borra los ficheros dados (best-effort) y devuelve cuantos habia. Comun a consola y ventana. #>
    param($Files)
    $f = @($Files)
    if ($f.Count -eq 0) { return 0 }
    $f | Remove-Item -Force -ErrorAction SilentlyContinue
    return $f.Count
}

function Set-CvSetupAppSelected {
    <#
        Fija downloads.<app>.selected en el config (solo el OVERRIDE). Si el fichero es minimo y la app
        o la seccion no estan, se crean con {selected}: el resto del descriptor sale de los defaults al
        fusionar. Devuelve $true si lo guardo.
    #>
    param(
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )
    $cfg = Read-CvConfigFile -Path $CfgPath
    if (-not $cfg.PSObject.Properties['downloads'] -or $null -eq $cfg.downloads) {
        $cfg | Add-Member -NotePropertyName 'downloads' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $cfg.downloads.PSObject.Properties[$Name]) {
        $cfg.downloads | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($cfg.downloads.$Name.PSObject.Properties['selected']) { $cfg.downloads.$Name.selected = $Version }
    else { $cfg.downloads.$Name | Add-Member -NotePropertyName 'selected' -NotePropertyValue $Version -Force }
    Save-CvConfigFile -Path $CfgPath -Config $cfg
    return $true
}

function Set-CvSetupVersionInUse {
    <#
        Cambia la version EN USO de una app (downloads.<app>.selected) a una que YA ESTA INSTALADA,
        SIN reinstalar nada. Hasta ahora la unica forma de tocar 'selected' era instalando, asi que
        para volver a una version que ya se tenia habia que descargarla otra vez.

        Exige que este instalada A PROPOSITO: 'selected' apuntando a una carpeta que no existe deja al
        conversor sin ffmpeg, y lo que sale al final es el "el sistema no puede encontrar el archivo
        especificado" de Process.Start, que no explica nada (paso de verdad).

        Devuelve @{ Ok; Reason }. Es DATO: no pregunta ni pinta; confirma la UI.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string]$Name,
        [string]$Version = ''
    )
    if ([string]::IsNullOrWhiteSpace($Version)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no se ha indicado ninguna version' }
    }
    if (-not (Test-CvToolInstalled -Context $Context -Name $Name -Version $Version)) {
        $inst = @(Get-CvInstalledVersions -Context $Context -Name $Name)
        $hay  = if ($inst.Count -gt 0) { "instalada(s): {0}" -f ($inst -join ', ') } else { 'no hay ninguna instalada' }
        return [pscustomobject]@{
            Ok     = $false
            Reason = ("{0} {1} no esta instalada ({2}); instalala antes de ponerla en uso." -f $Name, $Version, $hay)
        }
    }
    [void](Set-CvSetupAppSelected -CfgPath $CfgPath -Name $Name -Version $Version)
    return [pscustomobject]@{
        Ok     = $true
        Reason = ("{0} pasa a usar la version {1}" -f $Name, $Version)
    }
}

function Remove-CvSetupAppVersion {
    <# Borra la carpeta de una version concreta de una app (tools\<app>\<version>\<plataforma>). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return }
    $dir = Get-CvToolDir -Context $Context -Name $Name -Version $Version
    if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue }
}

function Get-CvSetupLogFiles {
    <#
        Logs de logs\ para ENSENARLOS: el mas reciente primero, con tamano y fecha ya formateados.
        A diferencia del borrado, aqui NO se excluye el log de la sesion en curso (justo el que suele
        interesar): -ExceptPath sigue disponible para quien quiera dejarlo fuera.
        Devuelve @{ Name; Path; SizeKb; Date; IsCurrent }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$ExceptPath = '',
        [string]$CurrentPath = ''
    )
    $out = @()
    foreach ($f in @(Get-CvLogFiles -Context $Context -ExceptPath $ExceptPath | Sort-Object LastWriteTime -Descending)) {
        $out += [pscustomobject]@{
            Name      = $f.Name
            Path      = $f.FullName
            SizeKb    = [int][math]::Ceiling($f.Length / 1024.0)
            Date      = $f.LastWriteTime
            IsCurrent = ("$CurrentPath" -ne '' -and $f.FullName -eq "$CurrentPath")
        }
    }
    return @($out)
}

function Test-CvLogProgressLine {
    <# PURO. $true si la linea es un REPINTADO de la barra de progreso (lleva su '%' junto a ETA, la
       velocidad o el bloque de la barra). Sirve para colapsarlos al mostrar un log. #>
    param([string]$Line)
    $l = "$Line"
    # Caracteres de la barra por su fuente unica (nunca literales en el fichero: ver Get-CvProgressBarChars).
    $ch = Get-CvProgressBarChars
    if ($l.Contains($ch.Full + $ch.Full) -or $l.Contains($ch.Empty + $ch.Empty)) { return $true }
    return ($l -match '\d+%' -and $l -match '(ETA |kbits/s|\dx\b)')
}

function Format-CvLogText {
    <#
        PURO. Deja legible un log con linea de progreso VIVA. Desde v4.6.0 esa linea ya no entra en el
        transcript, pero los logs ANTERIORES estan llenos de ella: en uno real, 4273 de 5181 lineas.
        Tres arreglos, por linea y por bloque:
          1) Si la linea trae retornos de carro, se queda con el ULTIMO tramo: es lo unico que llego a
             verse en la consola (lo anterior quedo sobrescrito).
          2) Quita la copia duplicada del texto ('texto + relleno + texto'), que venia del doble
             volcado con el que se recolocaba el cursor.
          3) Colapsa cada RACHA de repintados en el ultimo (el estado final), avisando de cuantos se
             han recogido; asi se ve el progreso al que se llego sin miles de lineas por medio.
        El fichero NO se toca: esto es solo para mostrarlo (con 'Abrir fuera' se ve tal cual).
    #>
    param([string]$Text)
    $out = New-Object System.Collections.Generic.List[string]
    # Estado de la racha en un hashtable y volcado INLINE (no en un scriptblock invocado con '&'):
    # asignar dentro de un scriptblock crea la variable en SU ambito y el contador nunca se reiniciaba,
    # asi que la racha se volcaba dos veces. Misma trampa de ambito que en los manejadores de la GUI.
    $run  = 0          # repintados consecutivos vistos
    $last = ''         # ultimo repintado de la racha (el estado al que se llego)
    foreach ($raw in ("$Text" -split "`n")) {
        $l = "$raw".TrimEnd("`r")
        if ($l.Contains("`r")) { $l = ($l -split "`r")[-1] }        # (1) solo el ultimo tramo
        if (Test-CvLogProgressLine -Line $l) {
            # (2) SOLO en las lineas de progreso: 'texto + relleno + texto' -> una sola copia. Ojo,
            # esto NO puede aplicarse a cualquier linea: el doble volcado es cosa del repintado, y
            # una linea de separadores ('=' x 64) o cualquier texto que repita su comienzo se
            # quedaria truncada (paso: los separadores salian como un solo '=').
            if ($l.Length -gt 32) {
                $head = $l.Substring(0, 16)
                $j = $l.IndexOf($head, 1)
                if ($j -gt 0) { $l = $l.Substring(0, $j).TrimEnd() }
            }
            $run++; $last = $l; continue                            # (3) racha
        }
        if ($run -gt 0) {
            if ($run -gt 1) { $out.Add(("[... {0} actualizaciones de progreso ...]" -f $run)) }
            $out.Add($last)
            $run = 0; $last = ''
        }
        $out.Add($l)
    }
    if ($run -gt 0) {
        if ($run -gt 1) { $out.Add(("[... {0} actualizaciones de progreso ...]" -f $run)) }
        $out.Add($last)
    }
    return ($out -join [Environment]::NewLine)
}

function Get-CvSetupLogText {
    <#
        Contenido de un log para mostrarlo. Dos cuidados que no son opcionales aqui:
          - Se abre con FileShare ReadWrite: el log de la sesion EN CURSO lo tiene abierto el
            transcript y un File::ReadAllText normal fallaria por bloqueo.
          - Si pasa de -MaxKb se lee solo el FINAL (lo ultimo es lo que interesa) y se avisa con una
            primera linea, para no cargar en memoria un log de decenas de MB.
        Ademas se pasa por Format-CvLogText, que colapsa los repintados de la barra de progreso de los
        logs antiguos (hasta el 82% de las lineas); con -Raw se devuelve el contenido tal cual.

        Devuelve el texto (o un aviso si no se puede leer): nunca lanza.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxKb = 512, [switch]$Raw)
    if (-not (Test-Path -LiteralPath $Path)) { return '(el fichero ya no existe)' }
    try {
        $max = [long]$MaxKb * 1024
        $fs  = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $head = ''
            if ($fs.Length -gt $max) {
                [void]$fs.Seek(($fs.Length - $max), [System.IO.SeekOrigin]::Begin)
                $head = ("[... log recortado: se muestran los ultimos {0} KB de {1} KB ...]" -f $MaxKb, [int][math]::Ceiling($fs.Length / 1024.0)) + [Environment]::NewLine
            }
            $sr = New-Object System.IO.StreamReader($fs)
            try {
                $body = $sr.ReadToEnd()
                # Legible por defecto (se colapsan los repintados de la barra); -Raw lo deja tal cual.
                if (-not $Raw) { $body = Format-CvLogText -Text $body }
                return ($head + $body)
            } finally { $sr.Dispose() }
        } finally {
            $fs.Dispose()
        }
    } catch {
        return ("(no se pudo leer el log: {0})" -f $_.Exception.Message)
    }
}

function Get-CvSetupConfigCandidates {
    <#
        Ficheros de configuracion que se ofrecen al arrancar la VENTANA sin -Config: los 'config*.json'
        que haya junto al programa. 'config.json' va SIEMPRE el primero y aunque NO exista (sin fichero
        se usan los valores por defecto, que es justo lo que hace el conversor); el resto, por nombre.

        Devuelve @{ Path; Name; Exists; IsDefault; Text }, donde Text es la etiqueta para la UI
        ('por defecto', 'depuracion', o vacia) - la UI no vuelve a decidir nada.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $def  = Join-Path $Root 'config.json'
    $out  = @()
    $seen = @{}
    $make = {
        param([string]$Path)
        $name = Split-Path -Leaf $Path
        $txt  = if ($name -eq 'config.json') { 'por defecto' } elseif ($name -eq 'config.debug.json') { 'depuracion' } else { '' }
        [pscustomobject]@{
            Path      = $Path
            Name      = $name
            Exists    = (Test-Path -LiteralPath $Path)
            IsDefault = ($name -eq 'config.json')
            Text      = $txt
        }
    }
    $out += (& $make $def)
    $seen[$def.ToLower()] = $true
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter 'config*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($seen.ContainsKey($f.FullName.ToLower())) { continue }
        $seen[$f.FullName.ToLower()] = $true
        $out += (& $make $f.FullName)
    }
    return @($out)
}

function Get-CvSetupTestSuites {
    <#
        FUENTE UNICA de las baterias de test que ofrece setup (consola y ventana): clave, script,
        etiqueta y una nota de que hace cada una. 'Exists' lo resuelve el llamador con -Root.
    #>
    @(
        @{
            Value = 'unit'
            File  = 'test\unit-tests.ps1'
            Text  = (Get-CvText -Key 'suite.unit')
            Info  = (Get-CvText -Key 'suite.unit.i')
        }
        @{
            Value = 'features'
            File  = 'test\feature-tests.ps1'
            Text  = (Get-CvText -Key 'suite.features')
            Info  = (Get-CvText -Key 'suite.features.i')
        }
        @{
            Value = 'gui'
            File  = 'test\gui-tests.ps1'
            Text  = (Get-CvText -Key 'suite.gui')
            Info  = (Get-CvText -Key 'suite.gui.i')
        }
        @{
            Value = 'cola'
            File  = 'test\gui-convert-tests.ps1'
            Text  = (Get-CvText -Key 'suite.cola')
            Info  = (Get-CvText -Key 'suite.cola.i')
        }
    )
}

function Get-CvSetupTestSuite {
    <# Una bateria del catalogo por su clave ('unit'|'features'), o $null si no existe. #>
    param([string]$Suite)
    $s = "$Suite".ToLower()
    Get-CvSetupTestSuites | Where-Object { $_.Value -eq $s } | Select-Object -First 1
}

Export-ModuleMember -Function *
