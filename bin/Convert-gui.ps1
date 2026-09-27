<#
    Convert-gui.ps1 - La COLA de conversion en VENTANA (WinForms), en vez de N consolas negras.

    Hoy, al contestar "workers en paralelo = 3", Convert.ps1 abre dos consolas mas y hay que mirarlas
    de una en una. Esta ventana las sustituye por un panel unico: todos los archivos de Original\ con
    su estado (sin preparar / en cola / codificando / hecho), el worker que lleva cada uno, su avance
    en vivo y el log; y desde ahi se arrancan, se paran o se cortan los workers.

    No duplica nada: los DATOS salen de lib\WorkerCore.psm1 y la ventana de lib\form\GuiConvertWindow.psm1. Los
    workers son procesos aparte (Convert.ps1 -WorkerOnly -Unattended): la ventana no codifica, porque
    WinForms es de un solo hilo y se quedaria congelada (igual que setup-gui con 'setup.ps1 -Task').

    Los archivos SIN preparar se pueden preparar aqui mismo (doble clic: editor del job en ventana,
    lib\form\GuiJobWindow.psm1) o en la consola de siempre con el boton 'Preparar (consola)'.

    Con que configuracion trabaja: con la de siempre, sin preguntar. Para elegir otra, Convert-gui-Config.cmd
    (que es esto mismo con -AskConfig) o MANTENER Mayus mientras arranca la cola normal (gui.askConfigKey).

    Lanzar:  Convert-gui.cmd   (o)   powershell -NoProfile -ExecutionPolicy Bypass -Sta -File Convert-gui.ps1
    Sin entorno grafico (o sin STA) se avisa y se remite a Convert.cmd.
#>

[CmdletBinding()]
param(
    # Fichero de configuracion a usar (por defecto el de config\). Admite ruta absoluta o relativa.
    # Mismo parametro que Convert.ps1 y setup.ps1; si se da, no se pregunta nada.
    [string]$Config = '',
    # PREGUNTAR con que config*.json trabajar en vez de abrir el de siempre. Es lo que pasa
    # Convert-gui-Config.cmd, y lo que se consigue tambien MANTENIENDO Mayus al arrancar la cola
    # normal (gui.askConfigKey). Con -Config explicito se ignora: mandar una ruta es mas concreto.
    [switch]$AskConfig
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# La raiz del PROYECTO es la carpeta de arriba: los scripts viven en bin\ y todo lo demas
# -lib\, lang\, tools\, Original\...- cuelga de la raiz, no de aqui.
$Root = Split-Path -Parent $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
# Los mismos modulos que Convert.ps1 (el editor de jobs usa las MISMAS funciones de deteccion y
# seleccion que PREPARAR: MediaInfo, Profile, Video, Audio, Subtitle) mas los de ventana.
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
    'GuiConvert'
    'GuiJob'
    'Exec'
    'Job'
    'JobCore'
    'WorkerCore'
    'Tools'
    'MediaInfo'
    'Profile'
    'Video'
    'Audio'
    'Subtitle'
    'SubtitleSRT'
    'SetupCore'
    # Las VENTANAS, una por formulario (lib\form\); la logica que se prueba sin abrir
    # ninguna se queda en los modulos de arriba.
    'form\GuiConvertWindow'
    'form\GuiWorkerLogWindow'
    'form\GuiJobWindow'
    'form\GuiJobBulkWindow'
    'form\GuiPrepareWindow'
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
# Las teclas, LO PRIMERO y con un solo modulo cargado: el truco es "manten Mayus mientras arranca",
# y cargar los veintitantos modulos cuesta unos segundos en los que habria que seguir aguantandola
# (medido: de 5 s a menos de 2). Asi se mira lo que habia pulsado al ARRANCAR, que es lo que la
# persona ha hecho, y no lo que siga pulsado un rato despues.
Import-Module (Join-Path $Lib 'Console.psm1') -Force
$teclasAlArrancar = Get-CvModifierKeysDown

foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# Con que configuracion se trabaja. Por defecto, con la de siempre y sin preguntar nada: la cola es
# lo que se abre a diario de un doble clic. Se pregunta (mismo selector que setup-gui) de dos formas:
#   - con -AskConfig, que es lo que pasa Convert-gui-Config.cmd;
#   - o MANTENIENDO la tecla que diga gui.askConfigKey -Mayus de fabrica- mientras arranca la cola
#     normal, el truco de toda la vida de Windows, para no tener que buscar el otro lanzador.
# Con -Config explicito no se pregunta ni con la tecla: dar una ruta es mas concreto que una tecla.
if ([string]::IsNullOrWhiteSpace($Config)) {
    # Las preferencias de ANTES de la sesion (idioma de la pregunta y tecla), del config por defecto:
    # el elegido todavia no se sabe, que es justo lo que se esta preguntando.
    $ini = Get-CvStartupPrefs -Root $Root
    if ($AskConfig -or (Test-CvAskConfigKey -Setting $ini.AskConfigKey -Keys $teclasAlArrancar)) {
        if (-not (Initialize-CvGui)) {
            Write-Host (Get-CvText -Key 'cg.singui')
            return
        }
        [void](Set-CvLanguage -Lang $ini.Language)
        $Config = Show-CvSetupConfigChooser -Root $Root
        if ([string]::IsNullOrWhiteSpace($Config)) { return }   # cancelado por el usuario
    }
}

# Arranque comun (config + contexto + marcas + log + apariencia), igual que Convert.ps1 y setup.ps1.
$sess    = Start-CvSession -Root $Root -Config $Config -TitleSuffix ' - Cola (ventana)' -Subtitle 'Cola de conversion' -LogPrefix 'Convert-gui'
$ctx     = $sess.Context
$cfgPath = $sess.ConfigPath
$cfgName = Split-Path -Leaf $cfgPath
$logFile = $sess.LogFile

# Tema de las ventanas (gui.theme): se fija UNA vez para toda la SESION. A partir de aqui lo usan
# todas -incluidas las que se abran DESPUES de cambiarlo con el boton 'Tema' de la barra-, en vez de
# quedarse cada una con el valor que tenia el config al arrancar.
[void](Set-CvGuiThemeDefault -Theme "$($ctx.GuiTheme)")

# Antes de nada, comprobar que estan las herramientas: sin ffmpeg no se puede ni analizar ni
# codificar, y descubrirlo a mitad -con la excepcion cruda de Process.Start- no ayuda a nadie. Si
# falta algo se ofrece abrir setup AQUI MISMO, que es donde se arregla.
$ready = Test-CvConvertReady -Context $ctx
if (-not $ready.Ok) {
    Write-CvLog 'COLA' ("[ERR] - {0}" -f $ready.Reason)
    $abrir = Show-CvGuiConfirm -Title (Get-CvText -Key 'cg.faltan') -Message (
        ("No se puede trabajar todavia: {0}`n`nQuieres abrir setup ahora para instalarla o elegir otra version?" -f $ready.Reason))
    if ($abrir) {
        $setup = Join-Path $Root 'setup-gui.cmd'
        try { [void](Start-Process -FilePath $setup -ArgumentList @('-Config', ('"{0}"' -f $cfgPath)) -WorkingDirectory $Root) }
        catch { Write-CvLog 'COLA' (Get-CvText -Key 'cg.setup.no' -Values @($_.Exception.Message)) }
        if ($logFile) { Stop-CvLog }
        return
    }
    Write-CvLog 'COLA' (Get-CvText -Key 'cg.solomirar')
} elseif (@($ready.Warnings).Count -gt 0) {
    foreach ($w in @($ready.Warnings)) { Write-CvLog 'COLA' ("[AVISO] - {0}" -f $w) }
    Show-CvGuiInfo -Title (Get-CvText -Key 'cg.aviso') -Message (
        ("Se puede trabajar, pero:`n`n - {0}`n`nSe arregla en setup (Herramientas)." -f ((@($ready.Warnings) -join "`n - "))))
}

Write-CvLog 'COLA' (Get-CvText -Key 'cg.abriendo' -Values @($cfgName))
$ok = Show-CvConvertWindow -Context $ctx -Root $Root -CfgPath $cfgPath -CfgName $cfgName -CurrentLog "$logFile"
if (-not $ok) {
    Write-CvLog 'COLA' (Get-CvText -Key 'cg.noventana')
    Write-CvLog 'COLA' (Get-CvText -Key 'cg.usaconsola')
}

Write-CvLog 'COLA' (Get-CvText -Key 'cli.hecho')
if ($logFile) { Stop-CvLog }
