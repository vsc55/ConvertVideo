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
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
# setup no usa el pipeline completo (Job = patrones de limpieza de Proceso; ConfigEditor = editor de
# config.json; Profile = catálogos de opciones que el editor lista en los menús -Get-CvEditorOptions-).
$modules = @(
    'Log'
    'Config'
    'Context'
    'Console'
    'Gui'
    'Exec'
    'Job'
    'Tools'
    'Profile'
    'ConfigEditor'
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
function Invoke-TestScript {
    # Lanza un script de test (test\*.ps1) como PROCESO HIJO (no dot-source: termina con 'exit 0/1'
    # y en el mismo proceso cerraria setup). El codigo de salida del hijo queda en $LASTEXITCODE.
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Label, [string]$Info = '')
    Clear-Host
    $script = Join-Path $Root $File
    if (-not (Test-Path -LiteralPath $script)) {
        Write-CvLog 'SETUP' ("No se encuentra {0} (no incluido en este paquete)." -f $File)
        Wait-Setup; return
    }
    Write-CvLog 'SETUP' ("Ejecutando {0}{1}..." -f $Label, $(if ($Info) { " ($Info)" } else { '' }))
    Write-Host ''
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script
    $code = $LASTEXITCODE
    Write-Host ''
    if ($code -eq 0) { Write-CvLog 'SETUP' ("[OK] - {0}: todo en verde." -f $Label) }
    else             { Write-CvLog 'SETUP' ("[ERROR] - {0}: fallo algun caso (codigo {1})." -f $Label, $code) }
    Wait-Setup
}
function Invoke-UnitTests    { Invoke-TestScript -File 'test\unit-tests.ps1'    -Label 'tests unitarios'    -Info 'funciones puras; sin GPU ni ffmpeg, < 1 s' }
function Invoke-FeatureTests { Invoke-TestScript -File 'test\feature-tests.ps1' -Label 'bateria de features' -Info 'E2E; usa ffmpeg; los casos de GPU se saltan si no hay NVENC' }

# ===========================================================================
#  Gestion de herramientas (catalogo 'downloads')
# ===========================================================================
function Get-AppNames {
    $apps = $ctx.Downloads
    if ($apps -is [System.Collections.IDictionary]) { return @($apps.Keys) }
    if ($apps) { return @($apps.PSObject.Properties.Name) }
    return @()
}
function Get-App {
    param([string]$Name)
    Get-CvAppDescriptor -Context $ctx -Name $Name
}
function Remove-AppVersion {
    # Borra la carpeta de una version concreta (tools\<app>\<version>\<plataforma>).
    param([string]$Name, [string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return }
    $dir = Get-CvToolDir -Context $ctx -Name $Name -Version $Version
    if (Test-Path -LiteralPath $dir) { Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue }
}
function Set-AppSelected {
    # Fija downloads.<app>.selected en config.json (solo el override). Si config.json es
    # minimo y la app o la seccion no estan, se crean con {selected} (el resto del descriptor
    # sale de los defaults al fusionar).
    param([string]$Name, [string]$Version)
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
function Show-Dirs {
    # Checklist de las carpetas de trabajo; crea las que falten y pinta su estado.
    Write-Host ''
    Write-CvLog 'SETUP' 'Directorios de trabajo:'
    foreach ($d in (Get-CvWorkDirs -Context $ctx)) {
        $name = Split-Path $d -Leaf
        if (Test-Path -LiteralPath $d) {
            Write-CvLog 'SETUP' ("  {0,-12} {1}" -f $name, (Get-CvMark $true))
        } else {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-CvLog 'SETUP' ("  {0,-12} {1} (creada)" -f $name, (Get-CvMark $true))
        }
    }
}

function Show-Status {
    Write-Host ''
    Write-CvLog 'SETUP' 'Estado de las herramientas:'
    foreach ($n in (Get-AppNames)) {
        $app = Get-App $n
        if (-not (Test-CvToolSupported -Context $ctx -Name $n)) {
            Write-CvLog 'SETUP' ("  {0} {1,-10} [NO SOPORTADO en {2}]    por defecto: {3}" -f (Get-CvMark $false), $n, (Get-CvPlatform), "$($app.selected)")
            continue
        }
        $plat = Get-CvAppPlatform -Context $ctx -Name $n
        $inst = @(Get-CvInstalledVersions -Context $ctx -Name $n)
        $instTxt = if ($inst.Count) { ($inst -join ', ') } else { 'ninguna' }
        # Marca: la version 'selected' (la que usa el conversor) esta instalada?
        $selOk = ($inst -contains "$($app.selected)")
        Write-CvLog 'SETUP' ("  {0} {1,-10} [{2}] instaladas: {3,-22} por defecto (config): {4}" -f (Get-CvMark $selOk), $n, $plat, $instTxt, "$($app.selected)")
    }
    Write-Host ''
}
function Invoke-InstallApp {
    param([string]$Name, [string]$Version, [switch]$Ask)
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
        $app = Get-App $Name
        $catalog = @()
        if ($app.versions -is [System.Collections.IDictionary]) { $catalog = @($app.versions.Keys) }
        elseif ($app.versions) { $catalog = @($app.versions.PSObject.Properties.Name) }
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

    # -Ask: fijar como version por defecto (solo si es compatible; para ffmpeg incompatible ya se
    # gestiono arriba con el fallback).
    if ($Ask -and "$((Get-App $Name).selected)" -ne $Version) {
        $a = (Read-Host ("   Fijar {0} como version por defecto de {1} en {2}? (S/n)" -f $Version, $Name, $CfgName)).Trim()
        if ($a -eq '' -or $a -match '^[SsYy]') {
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
    $proc = $ctx.Proceso
    if (-not (Test-Path -LiteralPath $proc)) { Write-CvLog 'SETUP' 'No existe la carpeta Proceso.'; return }
    $patterns = Get-CvProcesoPatterns -What $What   # fuente unica de las convenciones (lib\Job.psm1)
    $files = @(Get-CvFiles -Dir $proc -Filters $patterns -Exact)
    if ($files.Count -eq 0) { Write-CvLog 'SETUP' 'Nada que eliminar.'; return }

    Write-CvLog 'SETUP' ("Se eliminaran {0} fichero(s):" -f $files.Count)
    $files | ForEach-Object { Write-Host ("   - {0}" -f $_.Name) }
    $a = (Read-Host 'Confirmar borrado? (s/N)').Trim()
    if ($a -match '^[SsYy]') {
        $files | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-CvLog 'SETUP' '[OK] - Eliminados.'
    } else {
        Write-CvLog 'SETUP' 'Cancelado.'
    }
}

function Show-CleanMenu {
    Clear-Host
    $proc  = $ctx.Proceso
    $njob  = @(Get-ChildItem -LiteralPath $proc -Filter '*.job.json' -File -ErrorAction SilentlyContinue).Count
    $nlock = @(Get-ChildItem -LiteralPath $proc -Filter '*.lock'     -File -ErrorAction SilentlyContinue).Count
    $opts = @(
        ("Eliminar jobs (*.job.json)        [{0}]" -f $njob),
        ("Eliminar bloqueos (*.lock)        [{0}]" -f $nlock),
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

# ===========================================================================
#  Estado general (directorios de trabajo + herramientas)
# ===========================================================================
function Show-Identity {
    # Identidad del entorno: version del programa y config.json en uso (por defecto o alterno -Config).
    Write-Host ''
    Write-CvLog 'SETUP' ("{0} v{1}" -f $ctx.AppName, $ctx.Version)
    $tag = if (-not [string]::IsNullOrWhiteSpace($Config)) { 'alterno (-Config)' } else { 'por defecto' }
    $ex  = if (Test-Path -LiteralPath $CfgPath) { '' } else { '  (no existe -> se usan los valores por defecto)' }
    Write-CvLog 'SETUP' ("  config: {0}  [{1}]{2}" -f $CfgPath, $tag, $ex)
}

function Show-ProcesoStatus {
    # Estado de Proceso\: jobs pendientes, bloqueos (marcando caducados/huerfanos) y temporales.
    Write-Host ''
    Write-CvLog 'SETUP' 'Carpeta Proceso:'
    $proc = $ctx.Proceso
    if (-not (Test-Path -LiteralPath $proc)) { Write-CvLog 'SETUP' '  (no existe)'; return }
    $njob  = @(Get-ChildItem -LiteralPath $proc -Filter '*.job.json' -File -ErrorAction SilentlyContinue).Count
    $locks = @(Get-ChildItem -LiteralPath $proc -Filter '*.lock' -File -ErrorAction SilentlyContinue)
    $nstale = @($locks | Where-Object { Test-CvLockStale $_.FullName }).Count
    $ntemp = 0
    foreach ($p in (Get-CvProcesoPatterns -What temps)) { $ntemp += @(Get-ChildItem -LiteralPath $proc -Filter $p -File -ErrorAction SilentlyContinue).Count }
    $staleTxt = if ($nstale -gt 0) { "  ({0} caducado(s)/huerfano(s))" -f $nstale } else { '' }
    Write-CvLog 'SETUP' ("  jobs pendientes : {0}" -f $njob)
    Write-CvLog 'SETUP' ("  bloqueos        : {0}{1}" -f $locks.Count, $staleTxt)
    Write-CvLog 'SETUP' ("  temporales      : {0}" -f $ntemp)
}

function Show-Pending {
    # Trabajo pendiente: videos de entrada en Original\ vs convertidos (*_fix.<ext>) en Convertido\.
    Write-Host ''
    Write-CvLog 'SETUP' 'Trabajo:'
    $nin = @(Get-CvFiles -Dir $ctx.Original -Filters $ctx.Extensions -Exact).Count
    $nout = 0
    if (Test-Path -LiteralPath $ctx.Convertido) {
        $nout = @(Get-ChildItem -LiteralPath $ctx.Convertido -Filter ("*_fix.{0}" -f $ctx.OutExt) -File -ErrorAction SilentlyContinue).Count
    }
    Write-CvLog 'SETUP' ("  en Original     : {0} video(s) de entrada" -f $nin)
    Write-CvLog 'SETUP' ("  en Convertido   : {0} convertido(s)" -f $nout)
}

function Show-GpuStatus {
    # Codecs por GPU (NVENC) que soporta la grafica de ESTE equipo. Comprobacion EN VIVO: se ignora
    # la cache de config.json (gpuCache) y se resetea la memoizacion para SONDEAR cada encoder ahora
    # (util para ver el estado real, p. ej. tras cambiar de GPU o de driver).
    Write-Host ''
    Write-CvLog 'SETUP' 'Codecs por GPU (NVENC) soportados por esta grafica (comprobacion en vivo):'
    $gpu = Get-CvGpuName
    Write-CvLog 'SETUP' ("  GPU: {0}" -f $(if ($gpu) { $gpu } else { '(no detectada)' }))
    if ([string]::IsNullOrWhiteSpace("$($ctx.FFmpeg)") -or -not (Test-Path -LiteralPath $ctx.FFmpeg)) {
        Write-CvLog 'SETUP' '  [AVISO] - ffmpeg no instalado: no se puede comprobar. Instala ffmpeg primero.'
        return
    }
    Reset-CvGpuEncCache                                   # forzar sonda (sin cache)
    foreach ($e in (Get-CvGpuEncoders)) {
        $ok = Test-CvGpuEncoder -Context $ctx -Encoder $e
        # Solo el estado va como BADGE con fondo de color (verde=soportado, rojo=no); el resto de la
        # linea en color normal. Write-CvBadge escribe inline (el llamador cierra el salto de linea).
        Write-Host ("[SETUP]   {0} {1,-12} " -f (Get-CvMark $ok), $e) -NoNewline
        if ($ok) { Write-CvBadge -Text 'soportado'    -Fg Black -Bg Green }
        else     { Write-CvBadge -Text 'NO soportado' -Fg White -Bg Red }
        Write-Host ''
    }
    Reset-CvGpuEncCache                                   # no dejar la memoizacion "sucia"
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
function Show-ToolsMenu {
    while ($true) {
        Clear-Host
        $names = @(Get-AppNames)
        $opts  = @()
        foreach ($n in $names) { $opts += ("Instalar / cambiar version de {0}" -f $n) }
        $opts += 'Reinstalar TODO (version por defecto de cada app)'
        $sel = Select-FromList -Title 'HERRAMIENTAS (instalar / versiones)' -Options $opts -NoneLabel 'volver' -DefaultIndex 1
        if ($sel -eq '') { return }
        Clear-Host
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
    $opts += 'Ejecutar tests unitarios (funciones puras, sin GPU)'
    $opts += 'Ejecutar bateria de features (E2E, usa ffmpeg)'

    $headers[$opts.Count] = 'Configuracion'
    $optEditCfg  = ("Editar configuracion ({0})" -f $CfgName)
    $optResetCfg = ("Restablecer {0} (valores por defecto)" -f $CfgName)
    $opts += $optEditCfg
    $opts += $optResetCfg

    $headers[$opts.Count] = 'Limpieza'
    $opts += 'Limpiar jobs / bloqueos (carpeta Proceso)'
    $opts += 'Limpiar logs (carpeta logs)'

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
    elseif ($choice -eq $optResetCfg) {
        Reset-Config                         # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Limpiar jobs / bloqueos (carpeta Proceso)') {
        Show-CleanMenu                       # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Limpiar logs (carpeta logs)') {
        Clear-Logs                           # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Comprobar compatibilidad GPU (NVENC de ffmpeg)') {
        Show-NvencCheck                      # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Ejecutar tests unitarios (funciones puras, sin GPU)') {
        Invoke-UnitTests                     # limpia y pausa por su cuenta
    }
    elseif ($choice -eq 'Ejecutar bateria de features (E2E, usa ffmpeg)') {
        Invoke-FeatureTests                  # limpia y pausa por su cuenta
    }
}

Clear-Host
Write-CvLog 'SETUP' 'Hecho.'

# Cerrar el log de la sesion.
if ($logFile) { Stop-CvLog }
