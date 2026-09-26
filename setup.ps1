<#
    setup.ps1 - Gestion de herramientas y configuracion.

    Menu principal:
      - Instalar / cambiar version de ffmpeg (u otra app del catalogo 'downloads').
      - Reinstalar TODO (version por defecto de cada app).
      - Editar configuracion: editor navegable de TODO config.json (idiomas, encode,
        bordes, volumen, comportamiento, consola, descargas...) sin tocarlo a mano.

    Reutiliza el catalogo 'downloads' de config.json y las funciones de descarga de
    lib\Tools.psm1 (las mismas que usa Convert.ps1 cuando falta una herramienta).
    El guardado/reset de config.json vive en lib\Config.psm1.

    Lanzar:  setup.cmd   (o)   powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
#>

[CmdletBinding()]
param(
    # Fichero de configuracion a editar/gestionar (por defecto config.json junto al programa).
    # Admite ruta absoluta o relativa al directorio actual.
    [string]$Config = '',
    # Modo NO INTERACTIVO: ejecuta UNA accion y sale, en vez de abrir el menu. Lo usa la ventana
    # (setup-gui.ps1) para las acciones LARGAS -instalar una herramienta, lanzar una bateria-, que
    # se lanzan en su propia consola para ver el progreso en vivo sin bloquear la ventana; tambien
    # sirve para automatizar setup desde un .cmd o CI.
    #   -Task install -App ffmpeg -Version 7.1.1 [-SetDefault]
    #   -Task tests   -Suite unit|features|gui|cola
    [ValidateSet('', 'install', 'tests')][string]$Task = '',
    [string]$App = '',          # -Task install: app del catalogo 'downloads'
    [string]$Version = '',      # -Task install: version a instalar
    [switch]$SetDefault,        # -Task install: fijar esa version como 'selected' (sin preguntar)
    [string]$Suite = ''         # -Task tests: clave de la bateria (Get-CvSetupTestSuites)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
# setup no usa el pipeline completo (Job = patrones de limpieza de Proceso; ConfigEditor = editor de
# config.json; Profile = catálogos de opciones que el editor lista en los menús -Get-CvEditorOptions-).
$modules = @(
    'Log'
    'Io'
    'I18n'
    'Config'
    'Context'
    'Console'
    'Gui'
    'Exec'
    'Job'
    'Tools'
    'Profile'
    'ConfigEditor'
    'SetupCore'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# Arranque comun (config + contexto + marcas + log + apariencia + cabecera). Ver Start-CvSession.
$sess    = Start-CvSession -Root $Root -Config $Config -TitleSuffix ' - Setup' -Subtitle 'Setup' -LogPrefix 'setup'
$ctx     = $sess.Context
$CfgPath = $sess.ConfigPath
$CfgName = Split-Path -Leaf $CfgPath   # nombre del fichero en uso (config.json o el alterno -Config); para los textos
$logFile = $sess.LogFile

function Wait-Setup {
    # Pausa antes de limpiar la pantalla, para poder leer la info mostrada.
    Write-Host ''
    Read-Host 'ENTER para continuar' | Out-Null
}

function Reset-Config {
    # UI del reset; la logica vive en Reset-CvConfig (modulo Config).
    Clear-Host
    Write-CvLog 'SETUP' ("Restablecer {0} a los valores por defecto." -f $CfgName)
    Write-CvLog 'SETUP' 'Se CONSERVA el catalogo de herramientas (downloads). El resto vuelve al valor por defecto.'
    $a = (Read-Host 'Continuar? (s/N)').Trim()
    if ($a -notmatch '^[SsYy]') { Write-CvLog 'SETUP' 'Cancelado.'; Wait-Setup; return }
    [void](Reset-CvConfig -Path $CfgPath)
    Write-CvLog 'SETUP' ("[OK] - {0} restablecido (copia en {0}.bak; catalogo de herramientas conservado)." -f $CfgName)
    Wait-Setup
}

function Clear-Logs {
    # UI de limpieza de logs; la logica vive en Log.psm1 (excluye el log de la sesion actual).
    Clear-Host
    $files = @(Get-CvLogFiles -Context $ctx -ExceptPath $logFile)
    if ($files.Count -eq 0) { Write-CvLog 'SETUP' 'No hay logs que eliminar.'; Wait-Setup; return }
    Write-CvLog 'SETUP' ("Se eliminaran {0} log(s):" -f $files.Count)
    $files | ForEach-Object { Write-Host ("   - {0}" -f $_.Name) }
    $a = (Read-Host 'Confirmar borrado? (s/N)').Trim()
    if ($a -match '^[SsYy]') {
        [void](Remove-CvLogFiles -Files $files)
        Write-CvLog 'SETUP' '[OK] - Logs eliminados.'
    } else {
        Write-CvLog 'SETUP' 'Cancelado.'
    }
    Wait-Setup
}

# ===========================================================================
#  Pruebas (baterias de test\)
# ===========================================================================
function Invoke-TestSuite {
    # Lanza una bateria del catalogo (Get-CvSetupTestSuites) como PROCESO HIJO (no dot-source: termina
    # con 'exit 0/1' y en el mismo proceso cerraria setup). El codigo de salida queda en $LASTEXITCODE.
    param([Parameter(Mandatory)][string]$Suite)
    Clear-Host
    $s = Get-CvSetupTestSuite -Suite $Suite
    if (-not $s) { Write-CvLog 'SETUP' ("Bateria desconocida: {0}" -f $Suite); Wait-Setup; return }
    $script = Join-Path $Root $s.File
    if (-not (Test-Path -LiteralPath $script)) {
        Write-CvLog 'SETUP' ("No se encuentra {0} (no incluido en este paquete)." -f $s.File)
        Wait-Setup; return
    }
    Write-CvLog 'SETUP' ("Ejecutando {0}{1}..." -f $s.Text, $(if ($s.Info) { " ($($s.Info))" } else { '' }))
    Write-Host ''
    # -Sta: powershell.exe ya lo es por defecto, pero se fija explicito porque la bateria de setup
    # abre ventanas WinForms (que exigen STA) y sin el se saltaria esos casos.
    & powershell -NoProfile -ExecutionPolicy Bypass -Sta -File $script
    $code = $LASTEXITCODE
    Write-Host ''
    if ($code -eq 0) { Write-CvLog 'SETUP' ("[OK] - {0}: todo en verde." -f $s.Text) }
    else             { Write-CvLog 'SETUP' ("[ERROR] - {0}: fallo algun caso (codigo {1})." -f $s.Text, $code) }
    Wait-Setup
}

# ===========================================================================
#  Gestion de herramientas (catalogo 'downloads')
# ===========================================================================
# Los DATOS de cada pantalla salen de lib\SetupCore.psm1 (fuente unica, compartida con la ventana
# de setup-gui.ps1); aqui solo se RENDERIZAN en consola (marcas, badges, alineacion).
function Get-AppNames { Get-CvSetupAppNames -Context $ctx }
function Get-App {
    param([string]$Name)
    Get-CvAppDescriptor -Context $ctx -Name $Name
}
function Remove-AppVersion {
    param([string]$Name, [string]$Version)
    Remove-CvSetupAppVersion -Context $ctx -Name $Name -Version $Version
}
function Set-AppSelected {
    param([string]$Name, [string]$Version)
    Set-CvSetupAppSelected -CfgPath $CfgPath -Name $Name -Version $Version
}
function Show-Dirs {
    # Checklist de las carpetas de trabajo (Get-CvSetupDirStatus crea las que falten).
    Write-Host ''
    Write-CvLog 'SETUP' 'Directorios de trabajo:'
    foreach ($d in (Get-CvSetupDirStatus -Context $ctx)) {
        $extra = if ($d.Created) { ' (creada)' } else { '' }
        Write-CvLog 'SETUP' ("  {0,-12} {1}{2}" -f $d.Name, (Get-CvMark $d.Ok), $extra)
    }
}

function Show-Status {
    Write-Host ''
    Write-CvLog 'SETUP' 'Estado de las herramientas:'
    foreach ($t in (Get-CvSetupToolStatus -Context $ctx)) {
        if (-not $t.Supported) {
            Write-CvLog 'SETUP' ("  {0} {1,-10} [NO SOPORTADO en {2}]    por defecto: {3}" -f (Get-CvMark $false), $t.Name, $t.Platform, $t.Selected)
            continue
        }
        $instTxt = if (@($t.Installed).Count) { (@($t.Installed) -join ', ') } else { 'ninguna' }
        # Marca: la version 'selected' (la que usa el conversor) esta instalada?
        Write-CvLog 'SETUP' ("  {0} {1,-10} [{2}] instaladas: {3,-22} por defecto (config): {4}" -f (Get-CvMark $t.SelectedOk), $t.Name, $t.Platform, $instTxt, $t.Selected)
    }
    Write-Host ''
}
function Invoke-InstallApp {
    param([string]$Name, [string]$Version, [switch]$Ask, [switch]$SetDefault)
    if ([string]::IsNullOrWhiteSpace($Version)) { Write-CvLog 'SETUP' ("[ERR] - {0}: version no indicada" -f $Name); return $false }
    if (-not (Test-CvToolSupported -Context $ctx -Name $Name)) {
        Write-CvLog 'SETUP' ("[NO SOPORTADO] - {0} no tiene build para la plataforma de este equipo ({1})." -f $Name, (Get-CvPlatform))
        return $false
    }
    Write-CvLog 'SETUP' ("Reinstalando {0} {1} (se borra esa version y se descarga)..." -f $Name, $Version)
    Remove-AppVersion -Name $Name -Version $Version
    $nvOk = $true
    $ok = Install-CvTool -Context $ctx -Name $Name -Version $Version -NvencOk ([ref]$nvOk)
    if (-not $ok) { Write-CvLog 'SETUP' ("[ERR] - Fallo la instalacion de {0} {1}" -f $Name, $Version); return $false }

    # FALLBACK NVENC (solo ffmpeg): si la version instalada NO es compatible con NVENC en este equipo,
    # se PRUEBAN las versiones ANTERIORES del catalogo (mas nueva -> mas antigua), instalando (descarga
    # + verifica) y comprobando NVENC cada una, hasta dar con la primera compatible; esa se fija como
    # predeterminada. Si ninguna es compatible, se avisa (perfil CPU o actualizar driver).
    if ($Name -eq 'ffmpeg' -and -not $nvOk) {
        $catalog = @(Get-CvSetupAppVersions -Context $ctx -Name $Name)
        $cands = @(Get-CvNvencFallbackCandidates -Failed $Version -Available $catalog)
        $chosen = ''
        foreach ($cv in $cands) {
            Write-CvLog 'SETUP' ("[GPU] - {0} {1} no es compatible; probando la version anterior {2}..." -f $Name, $Version, $cv)
            $cvOk = $false
            if ((Install-CvTool -Context $ctx -Name $Name -Version $cv -NvencOk ([ref]$cvOk)) -and $cvOk) { $chosen = $cv; break }
        }
        if ($chosen) {
            if (Set-AppSelected -Name $Name -Version $chosen) { Write-CvLog 'SETUP' ("[OK] - {0}: {1}.selected = {2} (compatible con NVENC)" -f $CfgName, $Name, $chosen) }
            else { Write-CvLog 'SETUP' ("[AVISO] - No se pudo actualizar {0}." -f $CfgName) }
        } else {
            Write-CvLog 'SETUP' ("[AVISO] - Ninguna version anterior de {0} es compatible con NVENC en este equipo. Usa un perfil CPU (libx264/libx265) o actualiza el driver NVIDIA." -f $Name)
        }
        return $true
    }

    # Fijar como version por defecto (solo si es compatible; para ffmpeg incompatible ya se gestiono
    # arriba con el fallback). -Ask PREGUNTA (menu de consola); -SetDefault lo hace SIN preguntar (lo
    # usa el modo -Task, donde la ventana ya pregunto por su cuenta).
    if (($Ask -or $SetDefault) -and "$((Get-App $Name).selected)" -ne $Version) {
        $yes = $true
        if ($Ask -and -not $SetDefault) {
            $a = (Read-Host ("   Fijar {0} como version por defecto de {1} en {2}? (S/n)" -f $Version, $Name, $CfgName)).Trim()
            $yes = ($a -eq '' -or $a -match '^[SsYy]')
        }
        if ($yes) {
            if (Set-AppSelected -Name $Name -Version $Version) { Write-CvLog 'SETUP' ("[OK] - {0}: {1}.selected = {2}" -f $CfgName, $Name, $Version) }
            else { Write-CvLog 'SETUP' ("[AVISO] - No se pudo actualizar {0}." -f $CfgName) }
        }
    }
    return $true
}

# ===========================================================================
#  Compatibilidad GPU (NVENC) de las versiones de ffmpeg instaladas
# ===========================================================================
function Show-NvencCheck {
    Clear-Host
    if (-not (Test-CvToolSupported -Context $ctx -Name 'ffmpeg')) {
        Write-CvLog 'SETUP' ("ffmpeg [NO SOPORTADO] en esta plataforma ({0})." -f (Get-CvPlatform))
        Wait-Setup; return
    }
    $vers = @(Get-CvInstalledVersions -Context $ctx -Name 'ffmpeg')
    if ($vers.Count -eq 0) {
        Write-CvLog 'SETUP' 'No hay ninguna version de ffmpeg instalada. Instala una primero.'
        Wait-Setup; return
    }
    Write-CvLog 'SETUP' ("Comprobando NVENC (codificacion por GPU) en {0} version(es) de ffmpeg..." -f $vers.Count)
    foreach ($v in $vers) {
        Write-Host ''
        [void](Write-CvNvencReport -Context $ctx -Version $v -Tag ("[FFMPEG {0}]" -f $v))
    }
    Wait-Setup
}

# ===========================================================================
#  Mantenimiento de la carpeta Proceso (jobs / bloqueos / temporales)
# ===========================================================================
function Clear-Proceso {
    param([ValidateSet('jobs','locks','temps','all')][string]$What)
    if (-not (Test-Path -LiteralPath $ctx.Proceso)) { Write-CvLog 'SETUP' 'No existe la carpeta Proceso.'; return }
    $files = @(Get-CvSetupCleanTargets -Context $ctx -What $What)   # que se borraria (aun sin borrar)
    if ($files.Count -eq 0) { Write-CvLog 'SETUP' 'Nada que eliminar.'; return }

    Write-CvLog 'SETUP' ("Se eliminaran {0} fichero(s):" -f $files.Count)
    $files | ForEach-Object { Write-Host ("   - {0}" -f $_.Name) }
    $a = (Read-Host 'Confirmar borrado? (s/N)').Trim()
    if ($a -match '^[SsYy]') {
        [void](Remove-CvSetupFiles -Files $files)
        Write-CvLog 'SETUP' '[OK] - Eliminados.'
    } else {
        Write-CvLog 'SETUP' 'Cancelado.'
    }
}

function Show-ProfilesMenu {
    <#
        Perfiles PROPIOS (config.json -> 'profiles'): los que se anaden a los de serie en el menu de
        USAR PERFIL. Aqui se crean, se editan, se duplican y se borran, en vez de escribirlos a mano
        en el fichero como habia que hacer hasta ahora. Duplicar vale tambien sobre los de SERIE:
        partir de uno que ya funciona es lo comodo para hacerse el suyo (los de serie en si no se
        tocan: viven en el codigo, no en el config).

        El perfil se construye con el MISMO builder interactivo que la opcion Custom del menu de
        perfiles (New-CustomProfile), y se guarda con Save-CvProfileInteractive: las dos caras
        (consola y ventana) escriben con las mismas funciones de lib\Profile.psm1.
    #>
    while ($true) {
        Clear-Host
        $rows = @(Get-CvConfigProfileRows -Path $CfgPath)
        Write-CvLog 'SETUP' ("Perfiles propios de {0}: {1}   (los de serie salen al duplicar)" -f $CfgName, $rows.Count)
        if ($rows.Count -gt 0) {
            Write-Host ''
            foreach ($r in $rows) { Write-Host ("   - {0}   ({1})" -f $r.Label, $r.Text) -ForegroundColor Gray }
        }
        Write-Host ''
        Write-CvLog 'SETUP' ("Predeterminado (sale marcado al preparar): {0}" -f (Get-CvConfigDefaultProfile -Path $CfgPath))
        Write-Host ''
        $optNew = 'Crear un perfil nuevo'
        $optDup = 'Duplicar un perfil (propio o de serie)'
        $optDef = 'Elegir el perfil predeterminado'
        $opts = @($optNew, $optDup, $optDef)
        if ($rows.Count -gt 0) { $opts += @('Editar un perfil', 'Borrar un perfil') }
        $sel = Select-FromList -Title 'PERFILES' -Options $opts -NoneLabel 'volver' -DefaultIndex 0
        if ($sel -eq '') { return }

        # Para editar / duplicar / borrar, primero cual. Al duplicar entran tambien los de serie.
        $target = $null
        if ($sel -ne $optNew) {
            $pool = $(if ($sel -eq $optDup -or $sel -eq $optDef) { @(Get-CvProfileManagerRows -Path $CfgPath) } else { $rows })
            # Para elegir el predeterminado entra tambien 'Auto', que es el de fabrica.
            if ($sel -eq $optDef) {
                $pool = @($pool) + @([pscustomobject]@{
                    Label = 'Auto'
                    Text  = 'mejor encoder de este equipo (GPU si puede, si no CPU)'
                    Kind  = 'auto'
                    Prof  = $null
                })
            }
            if ($pool.Count -eq 0) { continue }
            # Se elige por POSICION, no por nombre: un perfil propio podria llamarse igual que la
            # etiqueta de uno de serie ('Perfil 3') y se cogeria el que no es.
            $ops = @()
            for ($i = 0; $i -lt $pool.Count; $i++) {
                $ops += @{
                    Value = "$i"
                    Text  = ("{0}   [{1}]   ({2})" -f $pool[$i].Label, "$($pool[$i].Kind)", $pool[$i].Text)
                }
            }
            $pick = Select-FromList -Title 'QUE PERFIL:' -Options $ops -NoneLabel 'volver' -DefaultIndex 1
            if ("$pick" -eq '') { continue }
            $target = $pool[[int]"$pick"]
            if ($null -eq $target) { continue }
        }

        Clear-Host
        switch ($sel) {
            'Crear un perfil nuevo' {
                # -NoSaveOffer: aqui el guardado no se OFRECE, se da por hecho (a eso se ha venido),
                # asi que lo pide este menu y no el builder.
                $p = New-CustomProfile -Context $ctx -NoSaveOffer
                if ($null -ne $p) { [void](Save-CvProfileInteractive -Prof $p -Path $CfgPath) }
                else { Write-CvLog 'SETUP' 'Cancelado.' }
                Wait-Setup
            }
            'Editar un perfil' {
                Write-CvLog 'SETUP' ("Editando '{0}'. Se parte de sus valores; al terminar se guarda con el mismo nombre." -f $target.Label)
                $p = New-CustomProfile -Context $ctx -Seed $target.Prof -NoSaveOffer
                if ($null -ne $p) { [void](Save-CvProfileInteractive -Prof $p -Path $CfgPath -Current $target.Label) }
                else { Write-CvLog 'SETUP' 'Cancelado.' }
                Wait-Setup
            }
            'Duplicar un perfil (propio o de serie)' {
                Write-CvLog 'SETUP' ("Duplicando '{0}'. Cambia lo que quieras y dale OTRO nombre." -f $target.Label)
                $p = New-CustomProfile -Context $ctx -Seed $target.Prof -NoSaveOffer
                if ($null -ne $p) { [void](Save-CvProfileInteractive -Prof $p -Path $CfgPath) }
                else { Write-CvLog 'SETUP' 'Cancelado.' }
                Wait-Setup
            }
            'Elegir el perfil predeterminado' {
                $r = Save-CvConfigDefaultProfile -Path $CfgPath -Label "$($target.Label)"
                if ($r.Ok) { Write-CvLog 'SETUP' ("[OK] - Predeterminado: '{0}' (sale marcado al preparar, y con ENTER en el menu)." -f $target.Label) }
                else { Write-CvLog 'SETUP' ("[ERROR] - {0}" -f $r.Error) }
                Wait-Setup
            }
            'Borrar un perfil' {
                if (Read-YesNo ("Borrar el perfil '{0}'?" -f $target.Label) $false) {
                    $r = Remove-CvConfigProfile -Path $CfgPath -Label $target.Label
                    if ($r.Ok) { Write-CvLog 'SETUP' ("[OK] - Borrado '{0}' (quedan {1})." -f $target.Label, $r.Count) }
                    else { Write-CvLog 'SETUP' ("[ERROR] - {0}" -f $r.Error) }
                } else {
                    Write-CvLog 'SETUP' 'Cancelado.'
                }
                Wait-Setup
            }
        }
    }
}

function Show-CleanMenu {
    Clear-Host
    $proc  = $ctx.Proceso
    $njob  = @(Get-ChildItem -LiteralPath $proc -Filter '*.job.json' -File -ErrorAction SilentlyContinue).Count
    $nlock = @(Get-ChildItem -LiteralPath $proc -Filter '*.lock'     -File -ErrorAction SilentlyContinue).Count
    $opts = @(
        ("Eliminar jobs (*.job.json)        [{0}]" -f $njob),
        ("Eliminar bloqueos y estado de workers [{0}]" -f $nlock),
        'Eliminar temporales (mkv / m4a / wav)',
        'Eliminar TODO (jobs + bloqueos + temporales)'
    )
    $sel = Select-FromList -Title ("Limpiar carpeta Proceso") -Options $opts -NoneLabel 'volver' -DefaultIndex 0
    if ($sel -eq '') { return }
    Clear-Host
    switch -Wildcard ($sel) {
        'Eliminar jobs*'       { Clear-Proceso -What 'jobs' }
        'Eliminar bloqueos*'   { Clear-Proceso -What 'locks' }
        'Eliminar temporales*' { Clear-Proceso -What 'temps' }
        'Eliminar TODO*'       { Clear-Proceso -What 'all' }
    }
    Wait-Setup
}

function Show-MaintenanceMenu {
    <#
        MANTENIMIENTO en un solo sitio: jobs, bloqueos y temporales de Proceso, logs de sesiones
        anteriores y lo cacheado por las ventanas. Antes cada cosa tenia su entrada en el menu
        principal y habia que ir a buscarlas por separado.

        Las filas y el borrado salen de SetupCore (Get-CvSetupMaintenanceItems /
        Invoke-CvSetupMaintenance), los mismos que usa la ventana.
    #>
    while ($true) {
        Clear-Host
        Write-CvLog 'SETUP' 'Mantenimiento: esto es lo que hay ahora mismo'
        Write-Host ''
        Write-Host (Get-CvSetupMaintenanceText -Context $ctx -CurrentLog $logFile) -ForegroundColor Gray
        Write-Host ''
        $items = @(Get-CvSetupMaintenanceItems -Context $ctx -CurrentLog $logFile)
        $ops = @()
        foreach ($i in $items) {
            $ops += @{
                Value = "$($i.Key)"
                Text  = ("{0,4}  {1}{2}" -f $i.Count, $i.Text, $(if ([bool]$i.Warn) { '   (OJO: habria que volver a preparar)' } else { '' }))
            }
        }
        $ops += @{
            Value = 'ALL'
            Text  = ("{0,4}  TODO lo de arriba" -f (($items | Measure-Object -Property Count -Sum).Sum))
        }
        $sel = Select-FromList -Title 'MANTENIMIENTO (que borrar)' -Options $ops -NoneLabel 'volver' -DefaultIndex 0
        if ("$sel" -eq '') { return }
        $claves = $(if ("$sel" -eq 'ALL') { @($items | ForEach-Object { "$($_.Key)" }) } else { @("$sel") })
        $cuantos = 0
        foreach ($i in $items) { if ($claves -contains "$($i.Key)") { $cuantos += [int]$i.Count } }
        if ($cuantos -le 0) { Write-CvLog 'SETUP' 'No hay nada que borrar ahi.'; Wait-Setup; continue }
        Clear-Host
        if (-not (Read-YesNo ("Borrar {0} elemento(s)?" -f $cuantos) $false)) { Write-CvLog 'SETUP' 'Cancelado.'; Wait-Setup; continue }
        foreach ($r in @(Invoke-CvSetupMaintenance -Context $ctx -Keys $claves -CurrentLog $logFile)) {
            if ($r.Ok) { Write-CvLog 'SETUP' ("[OK] - {0}: {1} borrado(s)." -f $r.Text, $r.Removed) }
            else { Write-CvLog 'SETUP' ("[ERROR] - {0}: {1}" -f $r.Text, $r.Error) }
        }
        Wait-Setup
    }
}

# ===========================================================================
#  Estado general (directorios de trabajo + herramientas)
# ===========================================================================
function Show-Identity {
    # Identidad del entorno: version del programa y config.json en uso (por defecto o alterno -Config).
    Write-Host ''
    $id = Get-CvSetupIdentity -Context $ctx -CfgPath $CfgPath -IsAlt (-not [string]::IsNullOrWhiteSpace($Config))
    Write-CvLog 'SETUP' ("{0} v{1}" -f $id.AppName, $id.Version)
    $tag = if ($id.IsAlt) { 'alterno (-Config)' } else { 'por defecto' }
    $ex  = if ($id.Exists) { '' } else { '  (no existe -> se usan los valores por defecto)' }
    Write-CvLog 'SETUP' ("  config: {0}  [{1}]{2}" -f $id.CfgPath, $tag, $ex)
}

function Show-ProcesoStatus {
    # Estado de Proceso\: jobs pendientes, bloqueos (marcando caducados/huerfanos) y temporales.
    Write-Host ''
    Write-CvLog 'SETUP' 'Carpeta Proceso:'
    $p = Get-CvSetupProcesoStatus -Context $ctx
    if (-not $p.Exists) { Write-CvLog 'SETUP' '  (no existe)'; return }
    $staleTxt = if ($p.Stale -gt 0) { "  ({0} caducado(s)/huerfano(s))" -f $p.Stale } else { '' }
    Write-CvLog 'SETUP' ("  jobs pendientes : {0}" -f $p.Jobs)
    Write-CvLog 'SETUP' ("  bloqueos        : {0}{1}" -f $p.Locks, $staleTxt)
    Write-CvLog 'SETUP' ("  temporales      : {0}" -f $p.Temps)
}

function Show-Pending {
    # Trabajo pendiente: videos de entrada en Original\ vs convertidos (*_fix.<ext>) en Convertido\.
    Write-Host ''
    Write-CvLog 'SETUP' 'Trabajo:'
    $w = Get-CvSetupWorkStatus -Context $ctx
    Write-CvLog 'SETUP' ("  en Original     : {0} video(s) de entrada" -f $w.Input)
    Write-CvLog 'SETUP' ("  en Convertido   : {0} convertido(s)" -f $w.Converted)
}

function Show-GpuStatus {
    # Codecs por GPU (NVENC) que soporta la grafica de ESTE equipo. Comprobacion EN VIVO: se ignora
    # la cache de config.json (gpuCache) y se resetea la memoizacion para SONDEAR cada encoder ahora
    # (util para ver el estado real, p. ej. tras cambiar de GPU o de driver).
    Write-Host ''
    Write-CvLog 'SETUP' 'Codecs por GPU (NVENC) soportados por esta grafica (comprobacion en vivo):'
    $g = Get-CvSetupGpuStatus -Context $ctx               # sondea en vivo (ignora la cache gpuCache)
    Write-CvLog 'SETUP' ("  GPU: {0}" -f $(if ($g.Gpu) { $g.Gpu } else { '(no detectada)' }))
    if (-not $g.Ready) {
        Write-CvLog 'SETUP' '  [AVISO] - ffmpeg no instalado: no se puede comprobar. Instala ffmpeg primero.'
        return
    }
    foreach ($e in $g.Encoders) {
        # Solo el estado va como BADGE con fondo de color (verde=soportado, rojo=no); el resto de la
        # linea en color normal. Write-CvBadge escribe inline (el llamador cierra el salto de linea).
        Write-Host ("[SETUP]   {0} {1,-12} " -f (Get-CvMark $e.Ok), $e.Name) -NoNewline
        if ($e.Ok) { Write-CvBadge -Text 'soportado'    -Fg Black -Bg Green }
        else       { Write-CvBadge -Text 'NO soportado' -Fg White -Bg Red }
        Write-Host ''
    }
}

function Show-Estado {
    $sep = Get-CvSepLine
    Write-Host $sep
    Write-Host 'ESTADO'
    Write-Host $sep
    Show-Identity
    Show-Dirs
    Show-Status
    Show-GpuStatus
    Show-ProcesoStatus
    Show-Pending
    Write-Host $sep
}

# ===========================================================================
#  Submenu de herramientas (instalar / cambiar version de cada app)
# ===========================================================================
function Show-UseVersionMenu {
    # Cambiar la version EN USO entre las YA instaladas, sin descargar nada. Antes la unica forma de
    # tocar 'selected' era instalando, asi que volver a una version que ya se tenia obligaba a
    # bajarla otra vez. La regla (solo versiones instaladas) vive en Set-CvSetupVersionInUse.
    Clear-Host
    $names = @(Get-AppNames)
    $app = Select-FromList -Title 'USAR UNA VERSION YA INSTALADA (no se descarga nada)' -Options $names -NoneLabel 'volver' -DefaultIndex 1
    if ($app -eq '') { return }
    Clear-Host
    $inst = @(Get-CvInstalledVersions -Context $ctx -Name $app)
    if ($inst.Count -eq 0) {
        Write-CvLog 'SETUP' ("No hay ninguna version de {0} instalada; instala una primero." -f $app)
        Wait-Setup; return
    }
    $cur  = "$((Get-App $app).selected)"
    $opts = @($inst | ForEach-Object { if ("$_" -eq $cur) { "{0}   (en uso)" -f $_ } else { "$_" } })
    $v = Select-FromList -Title ("Version de {0} que se usara" -f $app) -Options $opts -NoneLabel 'volver' -DefaultIndex 1
    if ($v -eq '') { return }
    Clear-Host
    $ver = ("$v" -split '\s+')[0]
    $r = Set-CvSetupVersionInUse -Context $ctx -CfgPath $CfgPath -Name $app -Version $ver
    if ($r.Ok) { Write-CvLog 'SETUP' ("[OK] - {0}: {1} (no se ha descargado nada)." -f $CfgName, $r.Reason) }
    else       { Write-CvLog 'SETUP' ("[ERR] - {0}" -f $r.Reason) }
    Wait-Setup
}

function Show-ToolsMenu {
    while ($true) {
        Clear-Host
        $names = @(Get-AppNames)
        $opts  = @()
        foreach ($n in $names) { $opts += ("Instalar / cambiar version de {0}" -f $n) }
        $opts += 'Usar una version YA instalada (sin descargar)'
        $opts += 'Reinstalar TODO (version por defecto de cada app)'
        $sel = Select-FromList -Title 'HERRAMIENTAS (instalar / versiones)' -Options $opts -NoneLabel 'volver' -DefaultIndex 1
        if ($sel -eq '') { return }
        Clear-Host
        if ($sel -like 'Usar una version*') {
            Show-UseVersionMenu
            continue
        }
        if ($sel -like 'Reinstalar TODO*') {
            foreach ($n in $names) { Invoke-InstallApp -Name $n -Version "$((Get-App $n).selected)" | Out-Null }
        } else {
            $name = $names[[array]::IndexOf($opts, $sel)]
            $ver  = Select-CvToolVersion -Context $ctx -Name $name
            if ($ver -ne '') { Invoke-InstallApp -Name $name -Version $ver -Ask | Out-Null }
            else { Write-CvLog 'SETUP' 'Cancelado.' }
        }
        Wait-Setup
    }
}

# ===========================================================================
#  Modo NO INTERACTIVO (-Task): una accion y salir, sin menu
# ===========================================================================
if ($Task -ne '') {
    switch ($Task) {
        'install' {
            if ($App -eq '' -or $Version -eq '') {
                Write-CvLog 'SETUP' '[ERR] - -Task install necesita -App y -Version.'
            } else {
                [void](Invoke-InstallApp -Name $App -Version $Version -SetDefault:$SetDefault)
            }
        }
        'tests' {
            Invoke-TestSuite -Suite $Suite   # pausa al terminar para poder leer el resultado
        }
    }
    if ($logFile) { Stop-CvLog }
    return
}

# ===========================================================================
#  Menu principal
# ===========================================================================
$exit = $false
while (-not $exit) {
    $ctx = New-CvContext -Root $Root -ConfigPath $CfgPath   # recargar por si cambio config.json
    Clear-Host
    Show-CvHeader -Context $ctx -Subtitle 'Setup'          # re-dibujar la cabecera en cada vuelta al menu

    $opts    = @()
    $headers = @{}

    $headers[$opts.Count] = 'Herramientas'
    $opts += 'Instalar / gestionar herramientas (ffmpeg, aacgain, mkvtoolnix...)'

    $headers[$opts.Count] = 'Estado'
    $opts += 'Ver estado (directorios y herramientas)'

    $headers[$opts.Count] = 'Compatibilidad'
    $opts += 'Comprobar compatibilidad GPU (NVENC de ffmpeg)'

    $headers[$opts.Count] = 'Pruebas'
    # Una entrada por bateria del catalogo (fuente unica Get-CvSetupTestSuites, compartida con la GUI).
    $testOpts = @{}
    foreach ($s in (Get-CvSetupTestSuites)) {
        $lbl = ("Ejecutar {0} ({1})" -f "$($s.Text)".ToLower(), $s.Info)
        $testOpts[$lbl] = $s.Value
        $opts += $lbl
    }

    $headers[$opts.Count] = 'Configuracion'
    $optEditCfg  = ("Editar configuracion ({0})" -f $CfgName)
    $optProfiles = ("Perfiles ({0} propios guardados; los de serie se pueden duplicar)" -f @(Get-CvConfigProfiles -Path $CfgPath).Count)
    $optResetCfg = ("Restablecer {0} (valores por defecto)" -f $CfgName)
    $opts += $optEditCfg
    $opts += $optProfiles
    $opts += $optResetCfg

    $headers[$opts.Count] = 'Limpieza'
    $opts += 'Limpiar (jobs, bloqueos, temporales, logs y caches)'
    $opts += 'Limpiar Proceso fichero a fichero'

    $choice = Select-FromList -Options $opts -NoneLabel 'salir' -DefaultIndex 0 -NoneKey 'S' -Headers $headers
    if ($choice -eq '') { $exit = $true; continue }

    if ($choice -eq 'Instalar / gestionar herramientas (ffmpeg, aacgain, mkvtoolnix...)') {
        Show-ToolsMenu                       # submenu con una entrada por app + reinstalar todo
    }
    elseif ($choice -eq 'Ver estado (directorios y herramientas)') {
        Clear-Host
        Show-Estado
        Wait-Setup
    }
    elseif ($choice -eq $optEditCfg) {
        # Editor en lib\ConfigEditor.psm1. Sin pausa al salir: vuelve directo al menu principal
        # (el guardado ya fue una accion explicita; el menu se redibuja limpio a continuacion).
        Edit-CvConfigFile -Root $Root -CfgPath $CfgPath -CfgName $CfgName
    }
    elseif ($choice -eq $optProfiles) {
        Show-ProfilesMenu                    # crear / editar / duplicar / borrar perfiles propios
    }
    elseif ($choice -eq $optResetCfg) {
        Reset-Config                         # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Limpiar (jobs, bloqueos, temporales, logs y caches)') {
        Show-MaintenanceMenu                 # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Limpiar Proceso fichero a fichero') {
        Show-CleanMenu                       # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Comprobar compatibilidad GPU (NVENC de ffmpeg)') {
        Show-NvencCheck                      # limpia y pausa por su cuenta
    }
    elseif ($testOpts.ContainsKey($choice)) {
        Invoke-TestSuite -Suite $testOpts[$choice]   # limpia y pausa por su cuenta
    }
}

Clear-Host
Write-CvLog 'SETUP' 'Hecho.'

# Cerrar el log de la sesion.
if ($logFile) { Stop-CvLog }
