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

    REGLA al tocar GuiSetup.psm1: los caminos que ejercita esta bateria NO pueden sacar un dialogo
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
    'Config'
    'Context'
    'Console'
    'Gui'
    'GuiSetup'
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
