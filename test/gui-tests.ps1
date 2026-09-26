<#
    gui-tests.ps1 - Bateria del SETUP: nucleo de datos (SetupCore) + ventana (GuiSetup).

    Complementa a unit-tests.ps1 (funciones puras) y a run-tests/feature-tests (pipeline con ffmpeg).
    Aqui se prueba lo que sostiene a las dos caras de setup:

      DATOS   : SetupCore devuelve el estado (identidad, carpetas, herramientas, Proceso, trabajo) y
                los candidatos de limpieza, sobre un ROOT temporal montado a proposito (no toca nada
                del proyecto real).
      VENTANA : se ABRE de verdad el editor de configuracion y se le dan ordenes sin raton (los
                controles llevan .Name: cvTree / cvText / cvCombo / cvList / cvDefault / cvSave), para
                comprobar el camino critico: editar un numero, un enum y una lista, volver una clave a
                su valor por defecto y guardar SOLO lo que difiere del default.

    Los casos de VENTANA se SALTAN (SKIP, no FAIL) si el host no es STA o no hay entorno grafico, para
    que la bateria sirva igual en una sesion sin GUI.

    REGLA al tocar las ventanas de setup (lib\form\) o GuiSetup.psm1: los caminos que ejercita esta
    bateria NO pueden sacar un dialogo
    MODAL (Show-CvGuiInfo / MessageBox). Un aviso modal deja la bateria colgada para siempre esperando
    a que una persona pulse Aceptar -deja de ser desatendida y de servir en CI-. Ya paso con el aviso
    de "config.json actualizado" al guardar: se quito (el llamador ya informa en su panel de salida).
    Si una accion NECESITA confirmar algo, que lo haga el LLAMADOR, no la funcion que se prueba.

    Uso:  powershell -ExecutionPolicy Bypass -Sta -File test\gui-tests.ps1
    Sale con 0 si todo pasa (los SKIP no cuentan como fallo), 1 si algo falla.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = Split-Path -Parent $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
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

# --- Mini-harness (mismo estilo que unit-tests.ps1) ---
$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert-Eq {
    param([string]$Name, $Expected, $Actual)
    $e = if ($Expected -is [System.Array]) { ($Expected -join '|') } else { "$Expected" }
    $a = if ($Actual   -is [System.Array]) { ($Actual   -join '|') } else { "$Actual" }
    if ($e -ceq $a) {
        $script:pass++; Write-Host ("  [OK]    {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:fail++; Write-Host ("  [FALLO] {0}`n           esperado: <{1}>`n           obtenido: <{2}>" -f $Name, $e, $a) -ForegroundColor Red
    }
}
function Assert-True { param([string]$Name, $Cond) Assert-Eq $Name $true ([bool]$Cond) }
function Write-Skip  { param([string]$Name, [string]$Why) $script:skip++; Write-Host ("  [SKIP]  {0}  ({1})" -f $Name, $Why) -ForegroundColor Yellow }

# ================================================================================================
# ROOT temporal: carpetas de trabajo y config propios, para no tocar el proyecto real.
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_gui_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$tmpCfg  = Join-Path $tmpRoot 'config.json'
Set-Content -Path $tmpCfg -Value '{ "behavior": { "workers": 3 }, "encode": { "subtitles": { "defaultLang": "spa" } } }' -Encoding UTF8
$ctx = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg

try {

# ================================================================================================
Write-Host "`nSetupCore - identidad y carpetas" -ForegroundColor Cyan
$id = Get-CvSetupIdentity -Context $ctx -CfgPath $tmpCfg -IsAlt $true
Assert-Eq   'Identity AppName'  'ConvertVideo' $id.AppName
Assert-Eq   'Identity Version'  (Get-CvVersion) $id.Version
Assert-Eq   'Identity CfgName'  'config.json'  $id.CfgName
Assert-True 'Identity IsAlt'    $id.IsAlt
Assert-True 'Identity Exists'   $id.Exists
$idNo = Get-CvSetupIdentity -Context $ctx -CfgPath (Join-Path $tmpRoot 'no-existe.json')
Assert-Eq   'Identity sin fichero' $false $idNo.Exists
Assert-Eq   'Identity IsAlt default' $false $idNo.IsAlt

# New-CvContext ya crea las carpetas de trabajo, asi que en marcha normal ninguna sale como 'creada'.
$d1 = @(Get-CvSetupDirStatus -Context $ctx)
Assert-True 'Dirs: hay carpetas'        ($d1.Count -ge 4)
Assert-True 'Dirs: todas Ok'            (@($d1 | Where-Object { -not $_.Ok }).Count -eq 0)
Assert-True 'Dirs: ninguna recreada'    (@($d1 | Where-Object { $_.Created }).Count -eq 0)
# Si falta una (borrada a mano con el programa abierto), se REHACE y se marca como creada.
Remove-Item -Recurse -Force -LiteralPath $ctx.Convertido
$d2 = @(Get-CvSetupDirStatus -Context $ctx)
$conv = $d2 | Where-Object { $_.Path -eq $ctx.Convertido } | Select-Object -First 1
Assert-True 'Dirs: recrea la que falta' ($conv.Created -and $conv.Ok)
Assert-True 'Dirs: existe de nuevo'     (Test-Path -LiteralPath $ctx.Convertido)
Assert-True 'Dirs: solo esa se recreo'  (@($d2 | Where-Object { $_.Created }).Count -eq 1)

# ================================================================================================
Write-Host "`nSetupCore - herramientas" -ForegroundColor Cyan
$apps = @(Get-CvSetupAppNames -Context $ctx)
Assert-True 'Apps: incluye ffmpeg'  ($apps -contains 'ffmpeg')
$tools = @(Get-CvSetupToolStatus -Context $ctx)
Assert-Eq   'Tools: una fila por app' $apps.Count $tools.Count
$ff = $tools | Where-Object { $_.Name -eq 'ffmpeg' } | Select-Object -First 1
Assert-True 'Tools: ffmpeg soportado'      $ff.Supported
Assert-True 'Tools: selected no vacio'     ("$($ff.Selected)" -ne '')
Assert-True 'Tools: SelectedOk es bool'    ($ff.SelectedOk -is [bool])
# Sin instalar nada en el root temporal, 'instaladas' viene vacio y la marca es $false.
Assert-Eq   'Tools: sin instalar'     0     @($ff.Installed).Count
Assert-Eq   'Tools: SelectedOk false' $false $ff.SelectedOk
$vers = @(Get-CvSetupAppVersions -Context $ctx -Name 'ffmpeg')
Assert-True 'Versiones del catalogo'  ($vers.Count -ge 1)
Assert-True 'Catalogo trae la selected' ($vers -contains "$($ff.Selected)")

# ================================================================================================
Write-Host "`nSetupCore - usar una version ya instalada (sin reinstalar)" -ForegroundColor Cyan
# Cambiar downloads.<app>.selected sin descargar nada. Solo vale si esa version ESTA instalada: un
# 'selected' apuntando a una carpeta que no existe deja al conversor sin ffmpeg, y el error que sale
# al final es un "no se puede encontrar el archivo especificado" que no explica nada (paso de verdad).
$verFake = '9.9.9'
$dirFake = Get-CvToolDir -Context $ctx -Name 'ffmpeg' -Version $verFake
$rNo = Set-CvSetupVersionInUse -Context $ctx -CfgPath $tmpCfg -Name 'ffmpeg' -Version $verFake
Assert-Eq   'Version en uso: no instalada -> no' $false $rNo.Ok
Assert-True 'Version en uso: dice por que'       ($rNo.Reason -match 'no esta instalada')
Assert-Eq   'Version en uso: sin version -> no'  $false (Set-CvSetupVersionInUse -Context $ctx -CfgPath $tmpCfg -Name 'ffmpeg').Ok
# Se finge instalada creando sus ficheros (es lo que mira Test-CvToolInstalled).
New-Item -ItemType Directory -Path $dirFake -Force | Out-Null
foreach ($f in @((Get-CvAppDescriptor -Context $ctx -Name 'ffmpeg').files)) {
    Set-Content -Path (Join-Path $dirFake $f) -Value 'x' -Encoding ASCII
}
$rSi = Set-CvSetupVersionInUse -Context $ctx -CfgPath $tmpCfg -Name 'ffmpeg' -Version $verFake
Assert-True 'Version en uso: instalada -> si'    $rSi.Ok
Assert-Eq   'Version en uso: queda en el config' $verFake "$((Read-CvConfigFile -Path $tmpCfg).downloads.ffmpeg.selected)"
# Y el contexto recargado ya apunta a ella (que es el efecto que se busca).
Assert-Eq   'Version en uso: la usa el contexto' $verFake "$((New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg).FFmpegVersion)"
Remove-Item -Recurse -Force -LiteralPath (Join-Path $ctx.Root 'tools\ffmpeg') -ErrorAction SilentlyContinue

# ================================================================================================
Write-Host "`nSetupCore - Proceso, trabajo y limpieza" -ForegroundColor Cyan
$p0 = Get-CvSetupProcesoStatus -Context $ctx
Assert-True 'Proceso existe (creada arriba)' $p0.Exists
Assert-Eq   'Proceso vacio: jobs'  0 $p0.Jobs
Assert-Eq   'Proceso vacio: locks' 0 $p0.Locks
# Sembrar un job, un lock y un temporal para comprobar recuento y candidatos de limpieza.
Set-Content -Path (Join-Path $ctx.Proceso 'peli.job.json') -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $ctx.Proceso 'peli.lock')     -Value ''   -Encoding UTF8
Set-Content -Path (Join-Path $ctx.Proceso 'peli.mkv')      -Value ''   -Encoding UTF8
$p1 = Get-CvSetupProcesoStatus -Context $ctx
Assert-Eq 'Proceso: 1 job'    1 $p1.Jobs
Assert-Eq 'Proceso: 1 lock'   1 $p1.Locks
Assert-Eq 'Proceso: 1 temp'   1 $p1.Temps
Assert-Eq 'Limpieza jobs'     1 @(Get-CvSetupCleanTargets -Context $ctx -What 'jobs').Count
Assert-Eq 'Limpieza locks'    1 @(Get-CvSetupCleanTargets -Context $ctx -What 'locks').Count
Assert-Eq 'Limpieza all = 3'  3 @(Get-CvSetupCleanTargets -Context $ctx -What 'all').Count
# El borrado es del nucleo (lo comparten consola y ventana).
Assert-Eq 'Borrado devuelve n' 1 (Remove-CvSetupFiles -Files @(Get-CvSetupCleanTargets -Context $ctx -What 'jobs'))
Assert-Eq 'Tras borrar: 0 jobs' 0 (Get-CvSetupProcesoStatus -Context $ctx).Jobs
Assert-Eq 'Borrado de nada = 0' 0 (Remove-CvSetupFiles -Files @())
$w = Get-CvSetupWorkStatus -Context $ctx
Assert-Eq 'Trabajo: 0 entradas'    0 $w.Input
Assert-Eq 'Trabajo: 0 convertidos' 0 $w.Converted

# ================================================================================================
Write-Host "`nSetupCore - catalogo de baterias" -ForegroundColor Cyan
$suites = @(Get-CvSetupTestSuites)
Assert-True 'Baterias: hay catalogo'      ($suites.Count -ge 2)
Assert-True 'Baterias: todas con Value'   (@($suites | Where-Object { -not "$($_.Value)".Trim() }).Count -eq 0)
Assert-True 'Baterias: todas con File'    (@($suites | Where-Object { -not "$($_.File)".Trim() }).Count -eq 0)
Assert-True 'Baterias: todas con Text'    (@($suites | Where-Object { -not "$($_.Text)".Trim() }).Count -eq 0)
# Cada script del catalogo tiene que EXISTIR de verdad en el repo.
foreach ($s in $suites) {
    Assert-True ("Bateria '{0}' existe" -f $s.Value) (Test-Path -LiteralPath (Join-Path $Root $s.File))
}
Assert-Eq   'Bateria por clave'      'unit' (Get-CvSetupTestSuite -Suite 'unit').Value
Assert-Eq   'Bateria case-insensitive' 'unit' (Get-CvSetupTestSuite -Suite 'UNIT').Value
Assert-True 'Bateria inexistente -> null' ($null -eq (Get-CvSetupTestSuite -Suite 'nope'))

# ================================================================================================
Write-Host "`nCaches de las ventanas (ver y limpiar desde setup)" -ForegroundColor Cyan
# En <config>.gui.json conviven dos cosas: como quedo cada ventana y lo deducido de los archivos ya
# convertidos. Setup deja borrar una, otra o las dos; cada opcion tiene que quitar SOLO lo suyo.
# En su PROPIA carpeta: un config*.json suelto en el root temporal se cuela en el selector de
# configuraciones que se prueba mas abajo (y ahi se cuentan los que hay).
$cacheRoot = Join-Path $tmpRoot 'caches'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
$cacheCfg = Join-Path $cacheRoot 'config.json'
[void](Save-CvTextFile -Path $cacheCfg -Text '{ "behavior": { "workers": 1 } }')
$ctxCache = New-CvContext -Root $cacheRoot -ConfigPath $cacheCfg
function Set-CacheDePrueba {
    [void](Save-CvGuiLayout -Context $ctxCache -Key 'cola'  -Layout ([ordered]@{ width = 1320 }))
    [void](Save-CvGuiLayout -Context $ctxCache -Key 'setup' -Layout ([ordered]@{ width = 1020 }))
    [void](Save-CvGuiLayout -Context $ctxCache -Key 'colaBordes' -Layout @(
        [pscustomobject]@{ Src = 'a.mkv'; Out = 'a_fix.mkv'; Stamp = '1'; Data = @{ Text = '[x]' } }
        [pscustomobject]@{ Src = 'b.mkv'; Out = 'b_fix.mkv'; Stamp = '2'; Data = @{ Text = '[ ]' } }
    ))
}
Assert-Eq   'Caches: sin fichero, no hay nada' $false ([bool](Get-CvGuiCacheStatus -Context $ctxCache).Exists)
Set-CacheDePrueba
$cSt = Get-CvGuiCacheStatus -Context $ctxCache
Assert-Eq   'Caches: dos ventanas recordadas'  2 ([int]$cSt.Layouts)
Assert-Eq   'Caches: dos archivos analizados'  2 ([int]$cSt.Files)
Assert-Eq   'Caches: el total suma'            4 ([int]$cSt.Total)
Assert-True 'Caches: el texto dice donde esta' ((Get-CvSetupCacheText -Context $ctxCache) -match 'config\.gui\.json')
# Borrar SOLO lo de los archivos: las ventanas se quedan.
$rc = Clear-CvGuiCache -Context $ctxCache -What 'files'
Assert-Eq   'Caches: borrar archivos quita 2'  2 ([int]$rc.Removed)
$cSt = Get-CvGuiCacheStatus -Context $ctxCache
Assert-Eq   'Caches: y deja las ventanas'      2 ([int]$cSt.Layouts)
Assert-Eq   'Caches: sin archivos'             0 ([int]$cSt.Files)
# Borrar SOLO las ventanas: los archivos se quedan.
Set-CacheDePrueba
$rc = Clear-CvGuiCache -Context $ctxCache -What 'layout'
Assert-Eq   'Caches: borrar ventanas quita 2'  2 ([int]$rc.Removed)
$cSt = Get-CvGuiCacheStatus -Context $ctxCache
Assert-Eq   'Caches: y deja los archivos'      2 ([int]$cSt.Files)
Assert-Eq   'Caches: sin ventanas'             0 ([int]$cSt.Layouts)
# Y borrarlo todo se lleva el fichero.
Set-CacheDePrueba
$rc = Clear-CvGuiCache -Context $ctxCache -What 'all'
Assert-Eq   'Caches: borrar todo quita 4'      4 ([int]$rc.Removed)
Assert-Eq   'Caches: el fichero desaparece'    $false ([bool](Get-CvGuiCacheStatus -Context $ctxCache).Exists)
# Sobre un fichero que ya no esta no puede fallar (se llama desde una ventana).
$rc = Clear-CvGuiCache -Context $ctxCache -What 'all'
Assert-Eq   'Caches: sin fichero no falla'     $true ([bool]$rc.Ok)

# ================================================================================================
Write-Host "`nMantenimiento (todo lo que se puede limpiar, en una lista)" -ForegroundColor Cyan
# Antes cada cosa estaba en su boton: jobs y bloqueos por un lado, logs por otro, caches por otro.
# Ahora sale TODO junto, con su recuento, y se limpia lo que se marque. Las dos caras leen esto.
$mRoot = Join-Path $tmpRoot 'mant'
foreach ($d in @('Original', 'Proceso', 'Convertido', 'logs')) { New-Item -ItemType Directory -Path (Join-Path $mRoot $d) -Force | Out-Null }
$mCfg = Join-Path $mRoot 'config.json'
[void](Save-CvTextFile -Path $mCfg -Text '{ "behavior": { "workers": 1 } }')
$ctxM = New-CvContext -Root $mRoot -ConfigPath $mCfg
Set-Content -Path (Join-Path $ctxM.Proceso 'Serie_1x01.job.json') -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $ctxM.Proceso 'Serie_1x02.job.json') -Value '{}' -Encoding UTF8
Set-Content -Path (Join-Path $ctxM.Proceso 'Serie_1x01.lock') -Value 'PID=1;HOST=x' -Encoding UTF8
$mLogViejo = Join-Path $ctxM.Logs 'Convert_20260101_1.log'
$mLogAhora = Join-Path $ctxM.Logs 'Convert_20260102_2.log'
Set-Content -Path $mLogViejo -Value 'viejo' -Encoding UTF8
Set-Content -Path $mLogAhora -Value 'el de ahora' -Encoding UTF8
[void](Save-CvGuiLayout -Context $ctxM -Key 'cola' -Layout ([ordered]@{ width = 1320 }))
[void](Save-CvGuiLayout -Context $ctxM -Key 'colaBordes' -Layout @(
    [pscustomobject]@{ Src = 'a.mkv'; Out = 'a_fix.mkv'; Stamp = '1'; Data = @{ Text = '[x]' } }
))
$mIt = @(Get-CvSetupMaintenanceItems -Context $ctxM -CurrentLog $mLogAhora)
Assert-Eq   'Mantenimiento: seis cosas que limpiar' 6 $mIt.Count
function Get-MCount { param([string]$K) [int](@($mIt | Where-Object { $_.Key -eq $K })[0].Count) }
Assert-Eq   'Mantenimiento: dos jobs'       2 (Get-MCount 'jobs')
Assert-Eq   'Mantenimiento: un bloqueo'     1 (Get-MCount 'locks')
Assert-Eq   'Mantenimiento: un log viejo'   1 (Get-MCount 'logs')
Assert-Eq   'Mantenimiento: una ventana'    1 (Get-MCount 'cacheLayout')
Assert-Eq   'Mantenimiento: un archivo analizado' 1 (Get-MCount 'cacheFiles')
Assert-Eq   'Mantenimiento: borrar jobs avisa' $true ([bool](@($mIt | Where-Object { $_.Key -eq 'jobs' })[0].Warn))
Assert-True 'Mantenimiento: cada fila dice que se pierde' ((@($mIt | Where-Object { "$($_.Detail)".Trim() -eq '' })).Count -eq 0)
Assert-True 'Mantenimiento: el texto lo lista' ((Get-CvSetupMaintenanceText -Context $ctxM -CurrentLog $mLogAhora) -match 'Jobs preparados')
# Limpiar SOLO lo marcado: se van los logs viejos y la cache de archivos, y lo demas se queda.
$mRes = @(Invoke-CvSetupMaintenance -Context $ctxM -Keys @('logs', 'cacheFiles') -CurrentLog $mLogAhora)
Assert-Eq   'Mantenimiento: devuelve una fila por cosa' 2 $mRes.Count
Assert-Eq   'Mantenimiento: todo fue bien' 0 @($mRes | Where-Object { -not $_.Ok }).Count
$mIt = @(Get-CvSetupMaintenanceItems -Context $ctxM -CurrentLog $mLogAhora)
Assert-Eq   'Mantenimiento: sin logs viejos' 0 (Get-MCount 'logs')
Assert-Eq   'Mantenimiento: sin archivos analizados' 0 (Get-MCount 'cacheFiles')
Assert-True 'Mantenimiento: el log en curso NO se borra' (Test-Path -LiteralPath $mLogAhora)
Assert-Eq   'Mantenimiento: los jobs siguen' 2 (Get-MCount 'jobs')
Assert-Eq   'Mantenimiento: la ventana recordada sigue' 1 (Get-MCount 'cacheLayout')
# Y limpiar lo que ya no hay no falla ni cuenta de mas.
$mRes = @(Invoke-CvSetupMaintenance -Context $ctxM -Keys @('logs') -CurrentLog $mLogAhora)
Assert-Eq   'Mantenimiento: nada que borrar = 0' 0 ([int]$mRes[0].Removed)

# ================================================================================================
Write-Host "`nSetupCore - logs (ver, no solo borrar)" -ForegroundColor Cyan
Assert-Eq 'Logs: al principio ninguno' 0 @(Get-CvSetupLogFiles -Context $ctx).Count
$logA = Join-Path $ctx.Logs 'setup_20260101_1.log'
$logB = Join-Path $ctx.Logs 'setup_20260102_2.log'
Set-Content -Path $logA -Value 'linea vieja' -Encoding UTF8
Set-Content -Path $logB -Value "primera`r`nsegunda" -Encoding UTF8
(Get-Item $logA).LastWriteTime = (Get-Date).AddDays(-2)   # forzar orden por fecha
$logs = @(Get-CvSetupLogFiles -Context $ctx)
Assert-Eq   'Logs: dos'             2 $logs.Count
Assert-Eq   'Logs: mas nuevo 1o'    'setup_20260102_2.log' $logs[0].Name
Assert-True 'Logs: tamano en KB'    ($logs[0].SizeKb -ge 1)
Assert-True 'Logs: fecha'           ($logs[0].Date -is [datetime])
Assert-Eq   'Logs: ninguno en curso' 0 @($logs | Where-Object { $_.IsCurrent }).Count
# Con -CurrentPath se marca el de la sesion en curso (la UI lo senala y no deja borrarlo).
$logsCur = @(Get-CvSetupLogFiles -Context $ctx -CurrentPath $logB)
Assert-Eq   'Logs: marca el en curso' 1 @($logsCur | Where-Object { $_.IsCurrent }).Count
Assert-True 'Logs: marca el correcto' (($logsCur | Where-Object { $_.IsCurrent }).Name -eq 'setup_20260102_2.log')
# Contenido: se lee entero y, si es enorme, solo el final (con aviso).
Assert-True 'LogText: lee el contenido' ((Get-CvSetupLogText -Path $logB) -match 'segunda')
Assert-True 'LogText: fichero ausente'  ((Get-CvSetupLogText -Path (Join-Path $ctx.Logs 'no.log')) -match 'no existe')
# Limpieza al MOSTRAR: los logs anteriores a v4.6.0 llevan un repintado de la barra por linea (en uno
# real, 4273 de 5181). Format-CvLogText colapsa cada racha y quita la copia duplicada del texto.
$barFull = (Get-CvProgressBarChars).Full
$prog1 = " - Procesando Video...  $($barFull * 4)   10%  ETA 01:00  5.0x  900.0kbits/s"
$prog2 = " - Procesando Video...  $($barFull * 8)   50%  ETA 00:30  5.0x  900.0kbits/s"
Assert-True 'Progreso: barra'        (Test-CvLogProgressLine -Line $prog1)
Assert-True 'Progreso: % + ETA'      (Test-CvLogProgressLine -Line ' - Paso...   42%  ETA 03:12  1.8x')
Assert-Eq   'Progreso: linea normal' $false (Test-CvLogProgressLine -Line '[AUDIO] - Recodificando pista 1')
Assert-Eq   'Progreso: resumen'      $false (Test-CvLogProgressLine -Line ' - Convertido 3 archivos')
$fmt = Format-CvLogText -Text (@('[INFO] - empieza', $prog1, $prog1, $prog2, '[INFO] - acaba') -join [Environment]::NewLine)
$fl  = @($fmt -split [Environment]::NewLine)
Assert-Eq   'Colapso: 5 lineas -> 4'  4 $fl.Count
Assert-True 'Colapso: avisa de cuantas' ($fl[1] -match '3 actualizaciones de progreso')
Assert-True 'Colapso: deja el ultimo'   ($fl[2] -match '50%')
Assert-Eq   'Colapso: respeta lo demas' '[INFO] - empieza' $fl[0]
Assert-Eq   'Colapso: y el final'       '[INFO] - acaba'   $fl[3]
# Una sola racha de 1 no merece aviso (solo se deja la linea).
$fmt1 = Format-CvLogText -Text (@('[INFO] - a', $prog2, '[INFO] - b') -join [Environment]::NewLine)
Assert-Eq 'Colapso: una sola no avisa' 3 @($fmt1 -split [Environment]::NewLine).Count
# Texto duplicado ('texto + relleno + texto', del doble volcado del cursor) -> una sola copia. OJO:
# el duplicado SOLO se recorta en lineas de progreso, asi que se prueba sobre una que lo sea.
$dupTxt = " - Procesando Video...   50%  ETA 01:00  5.0x"
$dup = Format-CvLogText -Text ($dupTxt + '   ' + $dupTxt)
Assert-Eq 'Duplicado: una sola copia' $dupTxt $dup
# REGRESION: el recorte del duplicado NO puede tocar lineas normales. Una linea de separadores repite
# su comienzo y se quedaba en un solo '='; igual cualquier texto que repita sus primeros caracteres.
$sep = '=' * 64
Assert-Eq 'Separador intacto'  $sep (Format-CvLogText -Text $sep)
Assert-Eq 'Guiones intactos'   ('-' * 40) (Format-CvLogText -Text ('-' * 40))
$rep = 'RESUMEN DE LA CONVERSION  RESUMEN DE LA CONVERSION'
Assert-Eq 'Texto repetido intacto' $rep (Format-CvLogText -Text $rep)
Assert-Eq 'Linea normal intacta' '[WORKER] - CODIFICANDO: peli.mkv' (Format-CvLogText -Text '[WORKER] - CODIFICANDO: peli.mkv')
# El retorno de carro deja solo el ultimo tramo (lo unico que se vio en la consola).
Assert-Eq 'CR: ultimo tramo' 'final' (Format-CvLogText -Text "viejo`rmedio`rfinal")

$big = Join-Path $ctx.Logs 'grande.log'
$bigLine = 'x' * 1000
Set-Content -Path $big -Value @(1..40 | ForEach-Object { $bigLine }) -Encoding UTF8   # ~40 KB
$tail = Get-CvSetupLogText -Path $big -MaxKb 4
Assert-True 'LogText: avisa del recorte' ($tail -match 'log recortado')
Assert-True 'LogText: recorta de verdad' ($tail.Length -lt 20000)
# El log EN USO (abierto por el transcript) tambien se puede leer: se abre en modo compartido.
$fsLock = [System.IO.File]::Open($logA, 'Open', 'Write', 'Read')
try { Assert-True 'LogText: lee uno en uso' ((Get-CvSetupLogText -Path $logA) -match 'vieja') }
finally { $fsLock.Dispose() }
Get-ChildItem -LiteralPath $ctx.Logs -Filter '*.log' | Remove-Item -Force

# ================================================================================================
Write-Host "`nEditor - que se resalta como editado" -ForegroundColor Cyan
# La marca del arbol usa la MISMA regla que el guardado (Test-CvCfgIsDefault), asi que lo resaltado
# es exactamente lo que acabara escrito en el fichero.
Assert-Eq   'Resalte: valor de fabrica'  $false (Test-CvCfgNodeModified -Value 'auto' -Path 'encode/video/tonemapHdr')
Assert-True 'Resalte: valor cambiado'    (Test-CvCfgNodeModified -Value 'off'  -Path 'encode/video/tonemapHdr')
Assert-Eq   'Resalte: lista de fabrica'  $false (Test-CvCfgNodeModified -Value @('webvtt') -Path 'encode/subtitles/toSrt')
Assert-True 'Resalte: lista cambiada'    (Test-CvCfgNodeModified -Value @('webvtt','ass') -Path 'encode/subtitles/toSrt')
Assert-Eq   'Resalte: bool de fabrica'   $false (Test-CvCfgNodeModified -Value $true -Path 'encode/video/forceFps')
Assert-True 'Resalte: bool cambiado'     (Test-CvCfgNodeModified -Value $false -Path 'encode/video/forceFps')
Assert-Eq   'Resalte: numero de fabrica' $false (Test-CvCfgNodeModified -Value 2 -Path 'behavior/workers')
Assert-True 'Resalte: numero cambiado'   (Test-CvCfgNodeModified -Value 4 -Path 'behavior/workers')

# ================================================================================================
Write-Host "`nEditor - opciones avanzadas (que se oculta sin marcar el check)" -ForegroundColor Cyan
# El nivel se declara en la propia opcion (marcador al principio de su ayuda), no en una lista
# aparte: Get-CvConfigAdvancedPaths solo DERIVA del catalogo de ayuda.
$adv = @(Get-CvConfigAdvancedPaths)
Assert-True 'Avanzadas: hay catalogo' ($adv.Count -ge 5)
# Cada ruta avanzada tiene que EXISTIR en los defaults; si se renombra una seccion, el test avisa.
foreach ($p in $adv) {
    Assert-True ("Avanzada '{0}' existe" -f $p) ($null -ne (Get-CvConfigDefaultValue $p))
}
# El marcador es metadato: NO puede colarse en el texto que se muestra.
$mark = Get-CvConfigAdvancedMark
Assert-Eq   'Ayuda sin marcador'   $false ((Get-CvHelpFor 'downloads').StartsWith($mark))
Assert-True 'Ayuda conserva texto' ((Get-CvHelpFor 'downloads') -match 'herramientas descargables')
Assert-True 'Ayuda normal intacta' ((Get-CvHelpFor 'languages/audio') -match 'idioma')
Assert-True 'Ninguna ayuda visible lleva marcador' (@(@(Get-CvConfigHelp).Keys | Where-Object { (Get-CvHelpFor $_).StartsWith($mark) }).Count -eq 0)
Assert-True 'Avanzada: downloads'          (Test-CvConfigAdvanced -Path 'downloads')
Assert-True 'Avanzada: tuning del encoder' (Test-CvConfigAdvanced -Path 'encode/video/tuning')
# Lo del dia a dia NO se oculta.
Assert-Eq   'Normal: encode'          $false (Test-CvConfigAdvanced -Path 'encode')
Assert-Eq   'Normal: languages'       $false (Test-CvConfigAdvanced -Path 'languages')
Assert-Eq   'Normal: perfil de video' $false (Test-CvConfigAdvanced -Path 'encode/video/videoEncoder')
Assert-Eq   'Normal: volumen'         $false (Test-CvConfigAdvanced -Path 'encode/audio/volume/method')
Assert-Eq   'Normal: console'         $false (Test-CvConfigAdvanced -Path 'console')
# La comparacion es EXACTA: quien oculta el subarbol es el arbol, no dando de alta cada hija.
Assert-Eq   'Avanzada: solo la raiz'  $false (Test-CvConfigAdvanced -Path 'downloads/ffmpeg')
# Contador de editadas (el que avisa de lo que se queda oculto).
$cntCfg = [pscustomobject]@{
    behavior = [pscustomobject]@{ workers = 9 }        # distinto del default (2)
    console  = [pscustomobject]@{ sepWidth = 64 }      # igual al default
}
Assert-Eq 'Editadas: cuenta solo lo distinto' 1 (Get-CvCfgModifiedCount -Node $cntCfg -Path '')

# ================================================================================================
Write-Host "`nSetupCore - configuraciones que ofrece la ventana" -ForegroundColor Cyan
# Solo existe config.json en el root temporal: aun asi debe salir el 1o y marcado como default.
$c1 = @(Get-CvSetupConfigCandidates -Root $tmpRoot)
Assert-Eq   'Configs: config.json 1o'  'config.json' $c1[0].Name
Assert-True 'Configs: marcado default' $c1[0].IsDefault
Assert-True 'Configs: existe'          $c1[0].Exists
Assert-Eq   'Configs: etiqueta'        'por defecto' $c1[0].Text
# Con un config.debug.json al lado, aparece el segundo y con su etiqueta.
Set-Content -Path (Join-Path $tmpRoot 'config.debug.json') -Value '{}' -Encoding UTF8
$c2 = @(Get-CvSetupConfigCandidates -Root $tmpRoot)
Assert-Eq   'Configs: ahora 2'         2 $c2.Count
Assert-Eq   'Configs: el 2o es debug'  'config.debug.json' $c2[1].Name
Assert-Eq   'Configs: etiqueta debug'  'depuracion' $c2[1].Text
Assert-Eq   'Configs: debug no default' $false $c2[1].IsDefault
# Sin config.json, sigue ofreciendose el primero (sin fichero se usan los valores por defecto).
$noCfgRoot = Join-Path $tmpRoot 'vacio'
New-Item -ItemType Directory -Path $noCfgRoot -Force | Out-Null
$c3 = @(Get-CvSetupConfigCandidates -Root $noCfgRoot)
Assert-Eq   'Configs: sin ficheros -> 1' 1 $c3.Count
Assert-Eq   'Configs: no existe'       $false $c3[0].Exists
Assert-True 'Configs: ruta absoluta'   ([System.IO.Path]::IsPathRooted($c3[0].Path))

# ================================================================================================
Write-Host "`nGuiSetup - informe de texto (sin ventana)" -ForegroundColor Cyan
$txt = Get-CvSetupStatusText -Context $ctx -CfgPath $tmpCfg -IsAlt $false
Assert-True 'Estado: lleva la version'   ($txt -match [regex]::Escape((Get-CvVersion)))
Assert-True 'Estado: lleva el config'    ($txt -match 'config:')
Assert-True 'Estado: lleva carpetas'     ($txt -match 'Directorios de trabajo:')
Assert-True 'Estado: lleva herramientas' ($txt -match 'Estado de las herramientas:')
Assert-True 'Estado: lleva Proceso'      ($txt -match 'Carpeta Proceso:')
Assert-True 'Estado: lleva trabajo'      ($txt -match 'Trabajo:')
Assert-True 'Estado: nombra ffmpeg'      ($txt -match 'ffmpeg')
# Sin ffmpeg instalado en el root temporal, la sonda de GPU avisa en vez de petar.
$gtxt = Get-CvSetupGpuText -Context $ctx
Assert-True 'GPU: cabecera'              ($gtxt -match 'Codecs por GPU')
Assert-True 'GPU: avisa sin ffmpeg'      ($gtxt -match 'ffmpeg no instalado')

# ================================================================================================
Write-Host "`nGuiSetup - editor de configuracion (ventana dirigida sin raton)" -ForegroundColor Cyan
$sta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
if (-not $sta) {
    Write-Skip 'Editor de configuracion' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Editor de configuracion' 'sin entorno grafico'
} else {
    # Busca un nodo del arbol por su ruta completa (.Tag), en profundidad.
    $findNode = {
        param($Nodes, [string]$Path)
        foreach ($n in $Nodes) {
            if ("$($n.Tag)" -eq $Path) { return $n }
            $r = & $findNode $n.Nodes $Path
            if ($r) { return $r }
        }
        return $null
    }
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 900
    $script:guiErr = ''
    $t.Add_Tick({
        $t.Stop()
        try {
            $f     = @([System.Windows.Forms.Application]::OpenForms)[0]
            $tree  = $f.Controls.Find('cvTree',    $true)[0]
            $text  = $f.Controls.Find('cvText',    $true)[0]
            $combo = $f.Controls.Find('cvCombo',   $true)[0]
            $list  = $f.Controls.Find('cvList',    $true)[0]
            $bDef  = $f.Controls.Find('cvDefault', $true)[0]
            $bSave = $f.Controls.Find('cvSave',    $true)[0]
            $chk   = $f.Controls.Find('cvAdvanced', $true)[0]
            # El divisor arbol / detalle: se arrastra (y se ve, que es lo que lo hace descubrible).
            $spCfg = @($f.Controls.Find('cvCfgSplit', $true))
            $script:cfgSplitOk    = ($spCfg.Count -eq 1 -and -not $spCfg[0].IsSplitterFixed)
            $script:cfgSplitAncho = $(if ($spCfg.Count -eq 1) { [int]$spCfg[0].SplitterWidth } else { 0 })
            $script:cfgSplitGrip  = $(if ($spCfg.Count -eq 1) { "$($spCfg[0].AccessibleName)" } else { '' })
            # El agarre va en el CENTRO del divisor: al cambiar el tamano de la ventana le toca otro
            # sitio, y si nadie manda repintar se queda en el hueco viejo (o sea: desaparece). Se
            # comprueba que redimensionar dispara el repintado del divisor.
            $script:cfgSplitPinta = $false
            if ($spCfg.Count -eq 1) {
                $spCfg[0].Add_Paint({ $script:cfgSplitPinta = $true })
                $script:cfgSplitPinta = $false
                $f.Height = $f.Height - 40
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 200
                [System.Windows.Forms.Application]::DoEvents()
            }

            # 0) AVANZADAS: sin marcar, 'downloads' no esta en el arbol; al marcar, aparece (y al
            #    desmarcar vuelve a irse). El resto del arbol sigue estando en los dos casos.
            $script:advOff  = ($null -eq (& $findNode $tree.Nodes 'downloads'))
            $script:advNorm = ($null -ne (& $findNode $tree.Nodes 'encode/video/videoEncoder'))
            $chk.Checked = $true
            $script:advOn   = ($null -ne (& $findNode $tree.Nodes 'downloads'))
            $script:advTun  = ($null -ne (& $findNode $tree.Nodes 'encode/video/tuning'))
            $chk.Checked = $false
            $script:advOff2 = ($null -eq (& $findNode $tree.Nodes 'downloads'))

            # 1) NUMERO: behavior/workers 3 -> 5, sin salir del campo (lo confirma el cambio de nodo).
            $tree.SelectedNode = (& $findNode $tree.Nodes 'behavior/workers')
            $script:sawText = $text.Visible
            $text.Text = '5'

            # 2) ENUM: encode/video/tonemapHdr auto -> off (desplegable).
            $tree.SelectedNode = (& $findNode $tree.Nodes 'encode/video/tonemapHdr')
            $script:sawCombo = $combo.Visible
            $combo.SelectedIndex = 1

            # 3) LISTA: languages/subtitle -> dos elementos.
            $tree.SelectedNode = (& $findNode $tree.Nodes 'languages/subtitle')
            $script:sawList = $list.Visible
            $list.Text = "spa$([Environment]::NewLine)eng"

            # 4) VOLVER AL DEFAULT: encode/subtitles/defaultLang estaba en 'spa' y su default es '';
            #    al restaurarlo, la clave debe DESAPARECER del fichero guardado.
            $tree.SelectedNode = (& $findNode $tree.Nodes 'encode/subtitles/defaultLang')
            $bDef.PerformClick()

            $bSave.PerformClick()
        } catch {
            $script:guiErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $t.Start()
    $saved = Show-CvConfigWindow -Root $tmpRoot -CfgPath $tmpCfg -CfgName 'config.json'

    Assert-Eq   'Ventana sin excepciones' '' $script:guiErr
    Assert-True 'Editor: el divisor se arrastra'   $script:cfgSplitOk
    Assert-True 'Editor: y se ve (ancho + agarre)' ($script:cfgSplitAncho -ge 8 -and $script:cfgSplitGrip -eq 'cv-grip')
    Assert-True 'Editor: el agarre se repinta al redimensionar' $script:cfgSplitPinta
    Assert-True 'Avanzadas ocultas por defecto'  $script:advOff
    Assert-True 'Lo normal se ve igualmente'     $script:advNorm
    Assert-True 'Al marcar aparece downloads'    $script:advOn
    Assert-True 'Al marcar aparece el tuning'    $script:advTun
    Assert-True 'Al desmarcar vuelve a ocultar'  $script:advOff2
    Assert-True 'Guardado confirmado'     $saved
    Assert-True 'Numero -> cuadro de texto' $script:sawText
    Assert-True 'Enum -> desplegable'       $script:sawCombo
    Assert-True 'Lista -> multilinea'       $script:sawList

    $raw = Read-CvConfigFile -Path $tmpCfg
    Assert-Eq   'Guardado: workers = 5'      5     $raw.behavior.workers
    Assert-Eq   'Guardado: tonemapHdr = off' 'off' $raw.encode.video.tonemapHdr
    Assert-Eq   'Guardado: lista de idiomas' 'spa|eng' (@($raw.languages.subtitle) -join '|')
    # Lo que vuelve al default se ELIMINA del fichero (config minimo sigue minimo).
    $subs = $raw.encode.subtitles
    Assert-True 'Guardado: defaultLang eliminado' ($null -eq $subs -or -not $subs.PSObject.Properties['defaultLang'])
    # Y no se inventa nada mas: las claves que nadie toco no aparecen.
    Assert-True 'Guardado: sin claves de mas' ($null -eq $raw.PSObject.Properties['console'])

    # El config guardado tiene que seguir siendo LEGIBLE por el contexto (no se corrompio el JSON).
    $ctx2 = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg
    Assert-Eq 'Recarga: workers'    5     $ctx2.Workers
    Assert-Eq 'Recarga: tonemapHdr' 'off' $ctx2.TonemapHdr

    # ------------------------------------------------------------------------------------------
    # Selector de configuracion (el que sustituye a tener un setup-gui-Debug.cmd): elegir el
    # config de depuracion devuelve SU ruta, y cancelar no devuelve ninguna.
    Write-Host "`nGuiSetup - selector de configuracion" -ForegroundColor Cyan
    $pick = New-Object System.Windows.Forms.Timer
    $pick.Interval = 700
    $pick.Add_Tick({
        $pick.Stop()
        $f  = @([System.Windows.Forms.Application]::OpenForms)[0]
        $ls = $f.Controls.Find('cvCfgList', $true)[0]
        $ok = $f.Controls.Find('cvCfgOk',   $true)[0]
        $script:pickCount = $ls.Items.Count
        $ls.SelectedIndex = 1          # config.debug.json (creado mas arriba en la bateria)
        $ok.PerformClick()
    })
    $pick.Start()
    $chosen = Show-CvSetupConfigChooser -Root $tmpRoot
    Assert-Eq   'Selector: 2 configs + Otro' 3 $script:pickCount
    Assert-Eq   'Selector: devuelve el debug' (Join-Path $tmpRoot 'config.debug.json') $chosen

    $pick2 = New-Object System.Windows.Forms.Timer
    $pick2.Interval = 700
    $pick2.Add_Tick({
        $pick2.Stop()
        @([System.Windows.Forms.Application]::OpenForms)[0].Close()   # cerrar = cancelar
    })
    $pick2.Start()
    Assert-Eq 'Selector: cancelar -> vacio' '' (Show-CvSetupConfigChooser -Root $tmpRoot)
}

# ================================================================================================
# DIALOGO DE VARIAS SALIDAS (Show-CvGuiChoice): lo que usa la cola para preguntar al cerrar con
# workers vivos. Se abre de verdad y se pulsa un boton por su .Name, como el resto de la bateria.
if (-not $sta) {
    Write-Skip 'Dialogo de varias salidas' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Dialogo de varias salidas' 'sin entorno grafico'
} else {
    Write-Host "`nGuiSetup - dialogo de varias salidas" -ForegroundColor Cyan
    $opts = @(
        @{ Value = 'a'; Text = 'Opcion A'; Hint = 'la primera' }
        @{ Value = 'b'; Text = 'Opcion B' }
    )
    $tc = New-Object System.Windows.Forms.Timer
    $tc.Interval = 500
    $tc.Add_Tick({
        $tc.Stop()
        $d = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cvTest' })
        if ($d.Count -gt 0) {
            $script:choiceBtns = @($d[0].Controls.Find('cvTest_a', $true)).Count + @($d[0].Controls.Find('cvTest_b', $true)).Count
            $b = @($d[0].Controls.Find('cvTest_b', $true))
            if ($b.Count -gt 0) { $b[0].PerformClick(); return }
        }
        foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
    })
    $script:choiceBtns = 0
    $tc.Start()
    Assert-Eq   'Dialogo: devuelve el boton pulsado' 'b' (Show-CvGuiChoice -Title 'Prueba' -Message 'Que hago?' -Options $opts -Name 'cvTest')
    Assert-Eq   'Dialogo: un boton por opcion'        2  $script:choiceBtns
    # Cerrarlo con la X no elige nada: quien llama decide que hacer con eso (en la cola, no cerrar).
    $tc2 = New-Object System.Windows.Forms.Timer
    $tc2.Interval = 500
    $tc2.Add_Tick({
        $tc2.Stop()
        foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
    })
    $tc2.Start()
    Assert-Eq   'Dialogo: cerrar con la X no elige' '' (Show-CvGuiChoice -Title 'Prueba' -Message 'Que hago?' -Options $opts -Name 'cvTest')
}

# ================================================================================================
# ESTADO DE LAS VENTANAS: como quedaron (tamano, divisor, columnas) se apunta junto al config y se
# vuelve a aplicar al abrir. Sin ventana: son ficheros y funciones puras.
Write-Host "`nGuiSetup - tamanos recordados de las ventanas" -ForegroundColor Cyan

Assert-Eq   'Layout: fichero junto al config' (Join-Path $tmpRoot 'config.gui.json') (Get-CvGuiLayoutPath -Context $ctx)
Assert-Eq   'Layout: sin fichero no hay nada' $null (Get-CvGuiLayout -Context $ctx -Key 'cola')
Assert-True 'Layout: se guarda' (Save-CvGuiLayout -Context $ctx -Key 'cola' -Layout ([ordered]@{
    width     = 1400
    height    = 900
    maximized = $false
    split     = 500
    cols      = @(330, 90, 130, 70, 300, 80)
}))
$lay1 = Get-CvGuiLayout -Context $ctx -Key 'cola'
Assert-Eq   'Layout: releido ancho'   1400 ([int]$lay1.width)
Assert-Eq   'Layout: releido divisor'  500 ([int]$lay1.split)
Assert-Eq   'Layout: releidas columnas' 6  (@($lay1.cols).Count)
# Guardar OTRA ventana no se lleva por delante la primera (todo vive en el mismo fichero).
[void](Save-CvGuiLayout -Context $ctx -Key 'setup' -Layout ([ordered]@{ width = 800; height = 600 }))
Assert-Eq   'Layout: la otra ventana sigue' 1400 ([int](Get-CvGuiLayout -Context $ctx -Key 'cola').width)
Assert-Eq   'Layout: y la nueva tambien'     800 ([int](Get-CvGuiLayout -Context $ctx -Key 'setup').width)
Assert-Eq   'Layout: clave desconocida' $null (Get-CvGuiLayout -Context $ctx -Key 'noexiste')
# Fichero corrupto: se ignora, no revienta (se llama al abrir la ventana).
Set-Content -Path (Get-CvGuiLayoutPath -Context $ctx) -Value '{ esto no es json' -Encoding UTF8
Assert-Eq   'Layout: json roto se ignora' $null (Get-CvGuiLayout -Context $ctx -Key 'cola')
Remove-Item -LiteralPath (Get-CvGuiLayoutPath -Context $ctx) -Force

Assert-Eq   'Layout: campo de hashtable' 10 (Get-CvGuiLayoutValue -Layout @{ split = 10 } -Name 'split')
Assert-Eq   'Layout: campo de objeto'    10 (Get-CvGuiLayoutValue -Layout ([pscustomobject]@{ split = 10 }) -Name 'split')
Assert-Eq   'Layout: campo que falta'     7 (Get-CvGuiLayoutValue -Layout @{} -Name 'split' -Default 7)
Assert-Eq   'Layout: sin layout'          7 (Get-CvGuiLayoutValue -Layout $null -Name 'split' -Default 7)

# Tamano de apertura: manda lo recordado, salvo que no quepa o sea absurdo.
$szDef = Resolve-CvGuiWindowSize -Layout $null -DefaultWidth 1180 -DefaultHeight 760
Assert-Eq   'Tamano: sin nada, el de config' '1180|760' (@($szDef.Width, $szDef.Height) -join '|')
$szSave = Resolve-CvGuiWindowSize -Layout @{ width = 1400; height = 900 } -DefaultWidth 1180 -DefaultHeight 760
Assert-Eq   'Tamano: manda el recordado' '1400|900' (@($szSave.Width, $szSave.Height) -join '|')
$szMax = Resolve-CvGuiWindowSize -Layout @{ width = 5000; height = 4000 } -DefaultWidth 1180 -DefaultHeight 760 -MaxWidth 1920 -MaxHeight 1080
Assert-Eq   'Tamano: no mayor que la pantalla' '1920|1080' (@($szMax.Width, $szMax.Height) -join '|')
$szMin = Resolve-CvGuiWindowSize -Layout @{ width = 100; height = 50 } -DefaultWidth 1180 -DefaultHeight 760 -MinWidth 860 -MinHeight 560
Assert-Eq   'Tamano: nunca bajo el minimo' '860|560' (@($szMin.Width, $szMin.Height) -join '|')
$szBad = Resolve-CvGuiWindowSize -Layout @{ width = 'xx' } -DefaultWidth 1180 -DefaultHeight 760
Assert-Eq   'Tamano: basura -> el de config' 1180 $szBad.Width
Assert-True 'Tamano: maximizada se recuerda' (Resolve-CvGuiWindowSize -Layout @{ maximized = $true } -DefaultWidth 1180 -DefaultHeight 760).Maximized

# Divisor: lo recordado si cabe; si no, el porcentaje de la config, siempre dentro de los minimos.
Assert-Eq   'Divisor: sin nada, el porcentaje' 312 (Resolve-CvGuiSplitDistance -Height 600 -Percent 52 -Min1 120 -Min2 140 -SplitterWidth 10)
Assert-Eq   'Divisor: manda el recordado'      400 (Resolve-CvGuiSplitDistance -Height 600 -Percent 52 -Saved 400 -Min1 120 -Min2 140 -SplitterWidth 10)
Assert-Eq   'Divisor: recordado que ya no cabe' 450 (Resolve-CvGuiSplitDistance -Height 600 -Percent 52 -Saved 900 -Min1 120 -Min2 140 -SplitterWidth 10)
Assert-Eq   'Divisor: nunca bajo el minimo'     120 (Resolve-CvGuiSplitDistance -Height 600 -Percent 1 -Min1 120 -Min2 140 -SplitterWidth 10)
Assert-Eq   'Divisor: ventana minuscula'        100 (Resolve-CvGuiSplitDistance -Height 200 -Percent 52 -Min1 120 -Min2 140 -SplitterWidth 10)

# ================================================================================================
# PERFILES PROPIOS en ventana (form\GuiProfilesWindow): la lista sale del config y los botones estan.
# No se pulsa 'Borrar' aqui: pide confirmacion MODAL y dejaria la bateria colgada (ver la regla de
# la cabecera). El borrado se prueba en los tests unitarios, sobre la funcion.
Write-Host "`nGuiProfilesWindow - perfiles propios en ventana" -ForegroundColor Cyan
$cfgProf = Join-Path $tmpRoot 'config.perfiles.json'
[void](Save-CvTextFile -Path $cfgProf -Text '{ "behavior": { "workers": 1 } }')
[void](Save-CvConfigProfile -Path $cfgProf -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 22) -Label 'Series CPU')
[void](Save-CvConfigProfile -Path $cfgProf -Prof (New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy') -Label 'Solo contenedor')
$ctxProf = New-CvContext -Root $tmpRoot -ConfigPath $cfgProf
Assert-Eq 'Perfiles: dos guardados' 2 (@(Get-CvConfigProfileRows -Path $cfgProf)).Count
Assert-True 'Perfiles: el texto del panel los lista' ((Get-CvSetupProfilesText -CfgPath $cfgProf) -match 'Series CPU')
Assert-True 'Perfiles: sin ninguno, el panel lo explica' ((Get-CvSetupProfilesText -CfgPath (Join-Path $tmpRoot 'no-existe.json')) -match 'No hay perfiles propios')
if (-not $sta) {
    Write-Skip 'Ventana de perfiles propios' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Ventana de perfiles propios' 'sin entorno grafico'
} else {
    $tpw = New-Object System.Windows.Forms.Timer
    $tpw.Interval = 400
    $script:pwErr   = ''
    $script:pwRows  = ''
    $script:pwBtns  = 0
    $script:pwInfo  = ''
    $script:pwWaits = 0
    $tpw.Add_Tick({
        try {
            $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cvProfiles' })
            if ($f.Count -eq 0) {
                $script:pwWaits++
                if ($script:pwWaits -gt 50) { $tpw.Stop(); $script:pwErr = 'no se abrio la ventana' }
                return
            }
            $lvp = @($f[0].Controls.Find('cvProfilesList', $true))
            if ($lvp.Count -eq 0 -or $lvp[0].Items.Count -eq 0) { $script:pwWaits++; return }
            $tpw.Stop()
            $script:pwRows = (@($lvp[0].Items | ForEach-Object { "{0}|{1}={2}" -f $_.Text, $_.SubItems[1].Text, $_.SubItems[2].Text }) -join ',')
            # Marcar uno DE SERIE: se puede duplicar, pero no editar ni borrar.
            $lvp[0].Items[$lvp[0].Items.Count - 1].Selected = $true
            $script:pwSerieDup  = [bool]$f[0].Controls.Find('cvProfilesDup', $true)[0].Enabled
            $script:pwSerieEdit = [bool]$f[0].Controls.Find('cvProfilesEdit', $true)[0].Enabled
            $script:pwSerieDel  = [bool]$f[0].Controls.Find('cvProfilesDel', $true)[0].Enabled
            # Y uno PROPIO: los tres.
            $lvp[0].Items[0].Selected = $true
            $script:pwPropEdit = [bool]$f[0].Controls.Find('cvProfilesEdit', $true)[0].Enabled
            $script:pwPropDel  = [bool]$f[0].Controls.Find('cvProfilesDel', $true)[0].Enabled
            foreach ($n in @('cvProfilesNew', 'cvProfilesDup', 'cvProfilesEdit', 'cvProfilesDel', 'cvProfilesDef', 'cvProfilesClose')) {
                $script:pwBtns += @($f[0].Controls.Find($n, $true)).Count
            }
            # Marcar como PREDETERMINADO el primero (propio): se guarda en el config y se ve el '*'.
            $lvp[0].Items[0].Selected = $true
            $f[0].Controls.Find('cvProfilesDef', $true)[0].PerformClick()
            $script:pwDefCfg  = "$(Get-CvConfigDefaultProfile -Path $cfgProf)"
            $script:pwDefMark = "$($lvp[0].Items[0].Text)"
            $script:pwDefBtn  = "$($f[0].Controls.Find('cvProfilesDef', $true)[0].Text)"
            # Y quitarlo: vuelve a ser Auto (lo de fabrica).
            $f[0].Controls.Find('cvProfilesDef', $true)[0].PerformClick()
            $script:pwDefFuera = "$(Get-CvConfigDefaultProfile -Path $cfgProf)"
            $script:pwInfo = "$($f[0].Controls.Find('cvProfilesInfo', $true)[0].Text)"
            $f[0].Close()
        } catch {
            $tpw.Stop(); $script:pwErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $tpw.Start()
    [void](Show-CvProfilesWindow -Context $ctxProf -CfgPath $cfgProf)
    $tpw.Stop()
    Assert-Eq   'Ventana perfiles: sin excepciones' '' $script:pwErr
    Assert-True 'Ventana perfiles: lista los dos'   ($script:pwRows -match 'Series CPU' -and $script:pwRows -match 'Solo contenedor')
    Assert-True 'Ventana perfiles: con su etiqueta' ($script:pwRows -match 'CRF22')
    Assert-Eq   'Ventana perfiles: los seis botones' 6 $script:pwBtns
    Assert-Eq   'Ventana perfiles: marca el predeterminado' 'Series CPU' $script:pwDefCfg
    Assert-True 'Ventana perfiles: y lo senala con *'  ($script:pwDefMark -match '^\*')
    Assert-Eq   'Ventana perfiles: el boton pasa a quitarlo' 'Quitar predet.' $script:pwDefBtn
    Assert-Eq   'Ventana perfiles: quitarlo deja Auto' 'Auto' $script:pwDefFuera
    Assert-True 'Ventana perfiles: dice cuantos hay' ($script:pwInfo -match '2 propios')
    Assert-True 'Ventana perfiles: tambien los de serie' ($script:pwRows -match 'de serie')
    Assert-True 'Ventana perfiles: los propios se marcan' ($script:pwRows -match 'Series CPU\|propio')
    Assert-Eq   'Ventana perfiles: un de serie se duplica' $true  $script:pwSerieDup
    Assert-Eq   'Ventana perfiles: pero no se edita'       $false $script:pwSerieEdit
    Assert-Eq   'Ventana perfiles: ni se borra'            $false $script:pwSerieDel
    Assert-Eq   'Ventana perfiles: un propio si se edita'  $true  $script:pwPropEdit
    Assert-Eq   'Ventana perfiles: y se borra'             $true  $script:pwPropDel
}

# ================================================================================================
# PIEZAS COMUNES de las ventanas (Gui.psm1), con controles de verdad: el desplegable de catalogo y
# el panel que sigue un log. Las usan la cola, setup y los perfiles; aqui se prueban una sola vez.
Write-Host "`nGui - desplegable de catalogo y panel de log" -ForegroundColor Cyan
if (-not $sta) {
    Write-Skip 'Piezas comunes de ventana' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Piezas comunes de ventana' 'sin entorno grafico'
} else {
    # --- Combo de catalogo: el valor elegido sale con su TIPO, no como texto ---
    $catal = @(
        @{ Value = 2; Text = 'estereo' }
        @{ Value = 6; Text = '5.1' }
    )
    $cbT = New-CvGuiCatalogCombo -Items $catal -Current 6 -Name 'cvTestCombo'
    Assert-Eq   'Combo: una entrada por valor'   2 $cbT.Items.Count
    Assert-Eq   'Combo: deja elegido el actual'  6 (Get-CvGuiComboValue -Combo $cbT)
    Assert-True 'Combo: el valor conserva el tipo' ((Get-CvGuiComboValue -Combo $cbT) -is [int])
    # Un valor que NO esta en el catalogo se anade y se deja elegido (el fallo del perfil 'auto'
    # resuelto, que caia en la primera entrada y convertia el job a copy).
    $cbRaro = New-CvGuiCatalogCombo -Items $catal -Current 7
    Assert-Eq   'Combo: el valor de fuera se anade'   3 $cbRaro.Items.Count
    Assert-Eq   'Combo: y queda elegido'              '7' "$(Get-CvGuiComboValue -Combo $cbRaro)"
    # Entrada vacia = "usa el global".
    $cbVacio = New-CvGuiCatalogCombo -Items $catal -EmptyText '(el global)'
    Assert-Eq   'Combo: con entrada vacia delante'    3 $cbVacio.Items.Count
    Assert-Eq   'Combo: vacia elegida por defecto'    '' "$(Get-CvGuiComboValue -Combo $cbVacio)"
    Assert-Eq   'Combo: sin catalogo no revienta'     '' "$(Get-CvGuiComboValue -Combo (New-CvGuiCatalogCombo -Items @()))"
    foreach ($c in @($cbT, $cbRaro, $cbVacio)) { $c.Dispose() }

    # --- Panel de log: solo relee si el fichero cambio, solo repinta si el texto es otro ---
    $lgFile = Join-Path $ctx.Logs 'Convert_20260919_praba_1234.log'
    [void](Save-CvTextFile -Path $lgFile -Text "[GLOBAL] - primera linea`r`n[WORKER] - segunda")
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $stLog = @{}
    Assert-Eq   'Log: la primera vez pinta'      $true  (Update-CvGuiLogView -TextBox $tb -State $stLog -Path $lgFile)
    Assert-True 'Log: y sale el contenido'       ($tb.Text -match 'primera linea')
    Assert-Eq   'Log: sin cambios no repinta'    $false (Update-CvGuiLogView -TextBox $tb -State $stLog -Path $lgFile)
    Start-Sleep -Milliseconds 20
    [void](Save-CvTextFile -Path $lgFile -Text "[GLOBAL] - primera linea`r`n[WORKER] - segunda`r`n[WORKER] - tercera")
    Assert-Eq   'Log: si cambia, repinta'        $true  (Update-CvGuiLogView -TextBox $tb -State $stLog -Path $lgFile)
    Assert-True 'Log: con lo nuevo'              ($tb.Text -match 'tercera')
    Assert-True 'Log: y sigue el final'          ($tb.SelectionStart -eq $tb.TextLength)
    # Sin log que seguir: se dice, y no se deja lo de antes pintado.
    Assert-Eq   'Log: sin ruta pone el aviso'    $true  (Update-CvGuiLogView -TextBox $tb -State $stLog -Path '' -EmptyText 'Este worker no dejo log.')
    Assert-Eq   'Log: y es lo unico que queda'   'Este worker no dejo log.' $tb.Text
    $tb.Dispose()
    Remove-Item -LiteralPath $lgFile -Force -ErrorAction SilentlyContinue
}

# ================================================================================================
# EL TEMA aplicado a una ventana de verdad: que cada tipo de control coja sus colores, que un aviso
# conserve SU color (rojo sigue rojo) y que al volver a claro se deshaga.
Write-Host "`nGui - tema oscuro sobre una ventana" -ForegroundColor Cyan
if (-not $sta) {
    Write-Skip 'Tema de ventana' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Tema de ventana' 'sin entorno grafico'
} else {
    $fT = New-Object System.Windows.Forms.Form
    $tbT = New-Object System.Windows.Forms.TextBox
    $fT.Controls.Add($tbT)
    $lvT = New-Object System.Windows.Forms.ListView
    [void]$lvT.Columns.Add('Archivo', 100)
    $fT.Controls.Add($lvT)
    $cbT = New-Object System.Windows.Forms.ComboBox
    $fT.Controls.Add($cbT)
    $btT = New-Object System.Windows.Forms.Button
    $fT.Controls.Add($btT)
    $lbT = New-Object System.Windows.Forms.Label       # un aviso en ROJO
    $fT.Controls.Add($lbT)
    $tabT = New-CvGuiTabs -Name 'cvTabsPrueba'
    $tpT = Add-CvGuiTab -Tabs $tabT -Text 'Una pestana'
    $fT.Controls.Add($tabT)
    $sepT = New-CvGuiSeparator
    $fT.Controls.Add($sepT)
    $spT = New-Object System.Windows.Forms.SplitContainer
    $spT.Orientation = 'Vertical'
    $fT.Controls.Add($spT)
    [void](Set-CvGuiSplitGrip -Split $spT -Tooltip 'de prueba')
    $menuT = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menuT.Items.Add('Una opcion')
    $lvT.ContextMenuStrip = $menuT

    # --- La paleta en si (necesita System.Drawing, por eso vive aqui y no en los unitarios) ---
    # La paleta: los dos temas definen LOS MISMOS roles (si no, una ventana se quedaria sin color).
    $palL = Get-CvGuiPalette -Theme 'light'
    $palD = Get-CvGuiPalette -Theme 'dark'
    foreach ($rol in @('Back', 'Panel', 'Fore', 'Muted', 'Border', 'Accent', 'Ok', 'Warn', 'Error', 'Edited')) {
        Assert-True ("Paleta: claro tiene {0}" -f $rol)  ($null -ne $palL[$rol])
        Assert-True ("Paleta: oscuro tiene {0}" -f $rol) ($null -ne $palD[$rol])
    }
    Assert-Eq   'Paleta: se identifica'     'dark' "$($palD.Name)"
    # En oscuro el fondo es OSCURO y el texto CLARO (y al reves en claro): parece obvio, pero es lo que
    # se rompe al tocar un color a mano.
    $claridad = { param($c) (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) }
    Assert-True 'Paleta: oscuro tiene el fondo oscuro' ((& $claridad $palD.Back) -lt 90)
    Assert-True 'Paleta: oscuro tiene el texto claro'  ((& $claridad $palD.Fore) -gt 180)
    Assert-True 'Paleta: claro tiene el texto oscuro'  ((& $claridad $palL.Fore) -lt 90)
    # El texto apagado se distingue del normal pero se sigue leyendo sobre el fondo.
    Assert-True 'Paleta: apagado != texto normal' ("$($palD.Muted)" -ne "$($palD.Fore)")
    Assert-True 'Paleta: apagado legible en oscuro' ((& $claridad $palD.Muted) -gt (& $claridad $palD.Back) + 40)
    # Los tres estados son distintos entre si en los dos temas (si no, un error parece un aviso).
    foreach ($pal in @($palL, $palD)) {
        $tres = @("$($pal.Ok)", "$($pal.Warn)", "$($pal.Error)")
        Assert-Eq ("Paleta {0}: ok/aviso/error distintos" -f $pal.Name) 3 (@($tres | Select-Object -Unique)).Count
    }
    # Y en oscuro los tres se leen (el Firebrick de siempre sobre casi negro no).
    foreach ($rol in @('Ok', 'Warn', 'Error')) {
        Assert-True ("Paleta: {0} legible en oscuro" -f $rol) ((& $claridad $palD[$rol]) -gt (& $claridad $palD.Back) + 60)
    }
    # El resaltado de lo EDITADO (arbol del editor de config) es un rol mas: el azul oscuro de tema
    # claro sobre el fondo casi negro del oscuro no se leia.
    Assert-True 'Paleta: editado legible en oscuro' ((& $claridad $palD.Edited) -gt (& $claridad $palD.Back) + 60)
    Assert-True 'Paleta: editado legible en claro'  ((& $claridad $palL.Edited) -lt (& $claridad $palL.Back) - 60)
    Assert-True 'Paleta: editado se distingue del texto normal' ("$($palD.Edited)" -ne "$($palD.Fore)")
    Assert-Eq   'Rol: editado' "$($palD.Edited)" "$(Get-CvGuiRoleColor -Palette $palD -Role 'edited')"
    # Rol -> color.
    Assert-Eq 'Rol: error'  "$($palD.Error)" "$(Get-CvGuiRoleColor -Palette $palD -Role 'error')"
    Assert-Eq 'Rol: muted'  "$($palD.Muted)" "$(Get-CvGuiRoleColor -Palette $palD -Role 'muted')"
    Assert-Eq 'Rol: lo que no existe -> texto normal' "$($palD.Fore)" "$(Get-CvGuiRoleColor -Palette $palD -Role 'loquesea')"
    # Iconos: en oscuro se aclaran (si no, el verde oscuro del play se pierde contra el fondo).
    $rgb = @(46, 125, 50)
    Assert-Eq   'Icono: en claro no se toca' '46,125,50' ((Get-CvGuiIconRgb -Rgb $rgb -Light $false) -join ',')
    $claro = @(Get-CvGuiIconRgb -Rgb $rgb -Light $true)
    Assert-True 'Icono: en oscuro se aclara'  ($claro[0] -gt 46 -and $claro[1] -gt 125 -and $claro[2] -gt 50)
    Assert-True 'Icono: sin pasarse de 255'   ((@($claro | Where-Object { $_ -gt 255 })).Count -eq 0)

    $palD = Get-CvGuiPalette -Theme 'dark'
    [void](Set-CvGuiRole -Control $lbT -Role 'error' -Palette $palD)
    $devuelta = Set-CvGuiTheme -Form $fT -Theme 'dark'
    Assert-Eq   'Tema: devuelve la paleta aplicada' 'dark' "$($devuelta.Name)"
    Assert-Eq   'Tema: el fondo de la ventana'  "$($palD.Back)"  "$($fT.BackColor)"
    Assert-Eq   'Tema: el cuadro de texto'      "$($palD.Panel)" "$($tbT.BackColor)"
    Assert-Eq   'Tema: la lista'                "$($palD.Panel)" "$($lvT.BackColor)"
    Assert-Eq   'Tema: el desplegable es plano' 'Flat' "$($cbT.FlatStyle)"
    Assert-Eq   'Tema: el boton es plano'       'Flat' "$($btT.FlatStyle)"
    Assert-Eq   'Pestanas: la tira es nuestra'  "$($palD.Back)" "$($tabT.Tag.Strip.BackColor)"
    Assert-Eq   'Pestanas: la primera queda puesta' 0 ([int]$tabT.Tag.Index)
    # OJO: no se mira .Visible -con la ventana sin mostrar siempre es falso, porque es la visibilidad
    # EFECTIVA-, sino cual es la pagina activa (en una ventana de verdad si se ve, ver el banco).
    Assert-Eq   'Pestanas: y su pagina es la activa' $true ((Get-CvGuiTabPage -Tabs $tabT) -eq $tpT)
    $tpT2 = Add-CvGuiTab -Tabs $tabT -Text 'Otra'
    $avisos = @{ N = 0 }
    [void](Add-CvGuiTabChanged -Tabs $tabT -Action ({ $avisos.N++ }.GetNewClosure()))
    [void](Select-CvGuiTab -Tabs $tabT -Page $tpT2)
    Assert-Eq   'Pestanas: al cambiar pasa a la otra' $true ((Get-CvGuiTabPage -Tabs $tabT) -eq $tpT2)
    Assert-Eq   'Pestanas: y se esconde la primera' $false ([bool]$tpT.Visible)
    Assert-Eq   'Pestanas: cual esta activa'    'Otra' "$(Get-CvGuiTabPage -Tabs $tabT | ForEach-Object { @($tabT.Tag.Texts)[[int]$tabT.Tag.Index] })"
    Assert-Eq   'Pestanas: avisa del cambio'    1 ([int]$avisos.N)
    Assert-Eq   'Tema: el menu sin degradados'  'System' "$($menuT.RenderMode)"
    Assert-Eq   'Tema: el menu oscuro'          "$($palD.Panel)" "$($menuT.BackColor)"
    # Lo importante: el aviso NO se pinta del color del texto normal.
    Assert-Eq   'Tema: el aviso conserva su rojo' "$($palD.Error)" "$($lbT.ForeColor)"
    Assert-True 'Tema: y no es el texto normal'   ("$($lbT.ForeColor)" -ne "$($palD.Fore)")
    # Las listas se pintan enteras (cabecera y filas), TAMBIEN las que llevan casillas: ahi el
    # cuadradito lo dibuja el propio pintor (si no, con OwnerDraw no lo pinta nadie).
    Assert-Eq   'Tema: la lista se pinta entera' $true ([bool]$lvT.OwnerDraw)
    $lvChk = New-Object System.Windows.Forms.ListView
    $lvChk.CheckBoxes = $true
    [void]$lvChk.Columns.Add('Pista', 100)
    $fT.Controls.Add($lvChk)
    [void](Set-CvGuiTheme -Form $fT -Theme 'dark')
    Assert-Eq   'Tema: la lista con casillas tambien' $true ([bool]$lvChk.OwnerDraw)
    # El separador de la barra tiene que seguir VIENDOSE tras aplicar el tema DOS veces (se aplica al
    # montar la ventana y otra vez en 'Shown'): cuando se reconocia por su color, la segunda pasada
    # lo pintaba del color del fondo y las lineas de la barra desaparecian.
    # El icono de la aplicacion: dibujado (no hay .png que instalar) y en la ventana.
    $icoB = New-CvGuiAppBitmap -Size 32
    Assert-Eq   'Icono: sale del tamano pedido' '32x32' ("{0}x{1}" -f $icoB.Width, $icoB.Height)
    $pintados = 0
    for ($ix = 0; $ix -lt 32; $ix += 2) {
        for ($iy = 0; $iy -lt 32; $iy += 2) { if ($icoB.GetPixel($ix, $iy).A -gt 10) { $pintados++ } }
    }
    Assert-True 'Icono: tiene dibujo'           ($pintados -gt 100)
    $icoB.Dispose()
    $icoBytes = Get-CvGuiAppIconBytes -Sizes @(16, 32)
    Assert-Eq   'Icono .ico: es un icono'       1 ([int][BitConverter]::ToUInt16($icoBytes, 2))
    Assert-Eq   'Icono .ico: con los dos tamanos' 2 ([int][BitConverter]::ToUInt16($icoBytes, 4))
    Assert-True 'Icono .ico: el primero es de 16' ([int]$icoBytes[6] -eq 16)
    Assert-True 'Tema: la ventana lleva el icono' ($null -ne $fT.Icon)
    Assert-Eq   'Separador: del color del borde'  "$($palD.Border)" "$($sepT.BackColor)"
    [void](Set-CvGuiTheme -Form $fT -Theme 'dark')
    Assert-Eq   'Separador: y sigue tras repetir el tema' "$($palD.Border)" "$($sepT.BackColor)"
    Assert-True 'Separador: no se confunde con el fondo' ("$($sepT.BackColor)" -ne "$($palD.Back)")
    # El desplegable plano deja una flecha fantasma al estirarse si no se repinta.
    Assert-Eq   'Combo: se repinta al cambiar de tamano' 'cv-repaint' "$($cbT.AccessibleName)"
    # El divisor: ancho para poder pincharlo y con su agarre pintado.
    Assert-True 'Divisor: ancho para agarrarlo'   ($spT.SplitterWidth -ge 8)
    Assert-Eq   'Divisor: lleva agarre'           'cv-grip' "$($spT.AccessibleName)"
    Assert-Eq   'Divisor: se puede arrastrar'     $false ([bool]$spT.IsSplitterFixed)

    # REGRESION: cambiar el tema tiene que valer para las ventanas que se abran DESPUES. Antes cada
    # ventana aplicaba el tema del CONTEXTO cargado al arrancar, asi que al cambiarlo en la cola las
    # demas (editor de jobs, perfiles, setup) seguian abriendose con el color viejo.
    $fNueva = New-Object System.Windows.Forms.Form
    [void](Set-CvGuiTheme -Form $fNueva)        # sin -Theme: el de la sesion
    Assert-Eq   'Tema: una ventana nueva hereda el de la sesion' "$($palD.Back)" "$($fNueva.BackColor)"
    $fNueva.Dispose()

    # Volver a claro deshace lo que se pueda deshacer.
    $palL = Set-CvGuiTheme -Form $fT -Theme 'light'
    Assert-Eq   'Tema: vuelta a claro'          'light' "$($palL.Name)"
    Assert-Eq   'Tema: fondo claro otra vez'    "$($palL.Back)"  "$($fT.BackColor)"
    Assert-Eq   'Tema: el aviso sigue en rojo (el claro)' "$($palL.Error)" "$($lbT.ForeColor)"
    $fT.Dispose()
    # El tema de la SESION queda fijado por la ultima llamada (lo usan los dialogos sin contexto).
    Assert-Eq   'Tema: la sesion recuerda el ultimo' 'light' (Get-CvGuiThemeName)
}

} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
}

# ================================================================================================
$total = $script:pass + $script:fail
Write-Host ("`n{0}" -f ('=' * 48))
if ($script:fail -eq 0) {
    Write-Host ("OK  {0}/{1} casos de setup pasados ({2} saltados)." -f $script:pass, $total, $script:skip) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FALLO  {0}/{1} pasados, {2} fallidos ({3} saltados)." -f $script:pass, $total, $script:fail, $script:skip) -ForegroundColor Red
    exit 1
}
