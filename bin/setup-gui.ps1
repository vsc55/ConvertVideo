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

# La raiz del PROYECTO es la carpeta de arriba: los scripts viven en bin\ y todo lo demas
# -lib\, lang\, tools\, Original\...- cuelga de la raiz, no de aqui.
$Root = Split-Path -Parent $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
# Mismos modulos que setup.ps1 (ConfigEditor aporta Get-CvEditorOptions, que la ventana reutiliza
# para los desplegables) mas GuiSetup (la ventana) y SetupCore (los datos).
$modules = @(
    'Log'
    'Io'
    'I18n'
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
    'form\GuiSplashWindow'
)
# Primero SOLO lo ligero, para sacar cuanto antes la PANTALLA DE ARRANQUE (gui.splash), igual que la
# cola: setup tardaba varios segundos en salir sin nada a la vista. Lo demas carga con ella delante.
$ligeros = @(
    'Log'
    'Io'
    'I18n'
    'Config'
    'Context'
    'form\GuiSplashWindow'
)
foreach ($m in $ligeros) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}
$ini = Get-CvStartupPrefs -Root $Root -Path $Config
[void](Set-CvLanguage -Lang $ini.Language)
$splashTit = ("{0} {1}" -f (Get-CvAppName), (Get-CvVersion))
$splashOscura = ((Resolve-CvGuiTheme -Theme "$($ini.Theme)" -SystemDark (Test-CvWindowsDarkMode)) -eq 'dark')
$abrirSplash = {
    param([string]$Key)
    if (-not [bool]$ini.Splash) { return $null }
    return (Start-CvSplashWindow -Title $splashTit -Text (Get-CvText -Key $Key) -TimeoutSec ([int]$ini.SplashTimeoutSec) `
        -Dark $splashOscura -IconPath (Join-Path $Root 'icon.ico'))
}
$splash = & $abrirSplash 'splash.modulos'

try {
    foreach ($m in $modules) {
        # Los ligeros ya estan: volver a cargarlos con -Force solo costaria tiempo.
        if ($null -ne (Get-Module -Name (Split-Path -Leaf $m))) { continue }
        Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
    }

    # Sin -Config se PREGUNTA que configuracion gestionar (config.json, config.debug.json, u otra), la
    # misma pregunta que hace setup.ps1 en consola y sobre la misma lista. Con -Config explicito no se
    # pregunta. Cancelar = no abrir nada.
    if ([string]::IsNullOrWhiteSpace($Config)) {
        if (-not (Initialize-CvGui)) {
            Write-Host (Get-CvText -Key 'sg.singui')
            return
        }
        # El idioma de la sesion lo fija Start-CvSession con el config ELEGIDO, que es justo lo que se
        # esta preguntando; para la pregunta vale el de las preferencias de arranque (arriba). La
        # pantalla de arranque se quita mientras se elige (estaria encima del selector) y vuelve
        # para lo que queda.
        Stop-CvSplashWindow -Splash $splash
        $Config = Show-CvSetupConfigChooser -Root $Root
        if ([string]::IsNullOrWhiteSpace($Config)) { return }   # cancelado por el usuario
        $splash = & $abrirSplash 'splash.sesion'
    }
    Set-CvSplashText -Splash $splash -Text (Get-CvText -Key 'splash.sesion')

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
    $isAlt = ($CfgPath -ne (Get-CvDefaultConfigPath -Root $Root))
    Write-CvLog 'SETUP' (Get-CvText -Key 'sg.abriendo' -Values @($CfgName))

    Set-CvSplashText -Splash $splash -Text (Get-CvText -Key 'splash.setup')
    # La ventana quita la pantalla de arranque en cuanto se dibuja (-Splash).
    $ok = Show-CvSetupWindow -Context $ctx -Root $Root -CfgPath $CfgPath -CfgName $CfgName -IsAlt $isAlt -CurrentLog "$logFile" -Splash $splash
    if (-not $ok) {
        Write-CvLog 'SETUP' (Get-CvText -Key 'sg.noventana')
        Write-CvLog 'SETUP' (Get-CvText -Key 'sg.usaconsola')
    }

    Write-CvLog 'SETUP' (Get-CvText -Key 'cli.hecho')
    if ($logFile) { Stop-CvLog }
} finally {
    # Por si algo ha salido antes de abrir la ventana (un error, cancelar el selector).
    Stop-CvSplashWindow -Splash $splash
}
