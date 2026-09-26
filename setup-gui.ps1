<#
    setup-gui.ps1 - El mismo setup que setup.ps1, pero en VENTANA (WinForms) en vez de consola.

    Hace lo mismo y sobre el mismo config: instalar/cambiar versiones de herramientas, ver el estado,
    comprobar la compatibilidad GPU, lanzar las baterias de test, editar/restablecer la configuracion
    y limpiar Proceso\ y logs\. No duplica logica: los DATOS salen de lib\SetupCore.psm1 (compartido
    con la consola) y la ventana vive en lib\GuiSetup.psm1.

    Las acciones largas (instalar una herramienta, una bateria de tests) se lanzan como
    'setup.ps1 -Task ...' en su propia consola, para ver el progreso sin bloquear la ventana.

    Lanzar:  setup-gui.cmd   (o)   powershell -NoProfile -ExecutionPolicy Bypass -Sta -File setup-gui.ps1
    Si el equipo no tiene GUI (o el host no es STA) se avisa y se remite a setup.cmd (consola).
#>

[CmdletBinding()]
param(
    # Fichero de configuracion a editar/gestionar (por defecto config.json junto al programa).
    # Admite ruta absoluta o relativa al directorio actual. Mismo parametro que setup.ps1.
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
# Mismos modulos que setup.ps1 (ConfigEditor aporta Get-CvEditorOptions, que la ventana reutiliza
# para los desplegables) mas GuiSetup (la ventana) y SetupCore (los datos).
$modules = @(
    'Log'
    'Io'
    'Config'
    'Context'
    'Console'
    'Gui'
    'GuiSetup'
    'GuiConfig'
    'Exec'
    'Job'
    'Tools'
    'Profile'
    'ConfigEditor'
    'SetupCore'
    # Las VENTANAS, una por formulario (lib\form\); la logica que se prueba sin abrir
    # ninguna se queda en los modulos de arriba.
    'form\GuiSetupWindow'
    'form\GuiConfigChooser'
    'form\GuiToolsWindow'
    'form\GuiLogsWindow'
    'form\GuiMaintenanceWindow'
    'form\GuiCleanWindow'
    'form\GuiConfigWindow'
    'form\GuiJobProfileDialog'
    'form\GuiProfileEditorWindow'
    'form\GuiProfilesWindow'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# Sin -Config se PREGUNTA que configuracion gestionar (config.json, config.debug.json, u otra): es el
# equivalente de elegir entre setup.cmd y setup-Debug.cmd, pero sin cerrar y abrir otro lanzador. Con
# -Config explicito no se pregunta. Cancelar = no abrir nada.
if ([string]::IsNullOrWhiteSpace($Config)) {
    if (-not (Initialize-CvGui)) {
        Write-Host 'No hay entorno grafico (o el host no es STA). Usa setup.cmd, que hace lo mismo en consola.'
        return
    }
    $Config = Show-CvSetupConfigChooser -Root $Root
    if ([string]::IsNullOrWhiteSpace($Config)) { return }   # cancelado por el usuario
}

# Arranque comun (config + contexto + marcas + log + apariencia + cabecera), igual que setup.ps1: asi
# la ventana usa EXACTAMENTE el mismo contexto y deja su propio transcript en logs\.
$sess    = Start-CvSession -Root $Root -Config $Config -TitleSuffix ' - Setup (ventana)' -Subtitle 'Setup' -LogPrefix 'setup-gui'
$ctx     = $sess.Context
$CfgPath = $sess.ConfigPath
$CfgName = Split-Path -Leaf $CfgPath
$logFile = $sess.LogFile

# Tema de las ventanas (gui.theme) para toda la sesion; ver Convert-gui.ps1.
[void](Set-CvGuiThemeDefault -Theme "$($ctx.GuiTheme)")

# 'Alterno' = NO es el config.json de junto al programa. Se compara la RUTA ya resuelta, no si vino
# -Config: ahora el chooser siempre rellena -Config, y elegir el normal no debe salir como alterno.
$isAlt = ($CfgPath -ne (Join-Path $Root 'config.json'))
Write-CvLog 'SETUP' ("Abriendo setup en ventana ({0})..." -f $CfgName)

$ok = Show-CvSetupWindow -Context $ctx -Root $Root -CfgPath $CfgPath -CfgName $CfgName -IsAlt $isAlt -CurrentLog "$logFile"
if (-not $ok) {
    Write-CvLog 'SETUP' '[ERR] - No se pudo abrir la ventana (sin entorno grafico o el host no es STA).'
    Write-CvLog 'SETUP' 'Usa setup.cmd (la version de consola hace exactamente lo mismo).'
}

Write-CvLog 'SETUP' 'Hecho.'
if ($logFile) { Stop-CvLog }
