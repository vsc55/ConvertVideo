<#
    gui-convert-tests.ps1 - Bateria de la COLA: nucleo de datos (WorkerCore) + ventana (GuiConvert).

    Hermana de gui-tests.ps1 (que cubre setup). Aqui se prueba lo que sostiene a la ventana de la
    cola, y se prueba SIN codificar nada:

      DATOS   : sobre un ROOT temporal se siembra a mano lo que en la vida real deja el pipeline
                -videos en Original\, jobs, bloqueos vivos y caducados, salidas en Convertido\ y
                ficheros de estado de worker- y se comprueba que Get-CvQueueStatus saca de ahi el
                estado correcto de cada archivo, incluido el avance que publica un worker.
      VENTANA : se ABRE de verdad la cola y se lee sin raton (los controles llevan .Name: cvQueue /
                cvTotals / cvStart / cvStop / cvKill / cvLogPick), para comprobar que pinta una fila
                por archivo con su estado y que los botones se habilitan segun lo que hay.

    Los casos de VENTANA se SALTAN (SKIP, no FAIL) si el host no es STA o no hay entorno grafico.

    REGLA al tocar las ventanas (lib\form\) o GuiConvert.psm1 (la misma que en gui-tests.ps1): los
    caminos que ejercita esta
    bateria NO pueden sacar un dialogo MODAL, o la bateria se queda colgada esperando a que una
    persona pulse Aceptar y deja de servir desatendida. Por eso aqui NO se pulsa 'Iniciar' ni
    'Cancelar ahora': ademas de confirmar, lanzarian o mataran procesos de verdad.

    Uso:  powershell -ExecutionPolicy Bypass -Sta -File test\gui-convert-tests.ps1
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
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# --- Mini-harness (mismo estilo que unit-tests.ps1 / gui-tests.ps1) ---
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
# ROOT temporal con una cola sembrada a mano (no se toca nada del proyecto real).
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cv_cola_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$tmpCfg = Join-Path $tmpRoot 'config.json'
# gui.confirmCloseWithWorkers=false a proposito: la cola sembrada tiene un worker VIVO (este mismo
# proceso), y con la pregunta activada cerrar la ventana sacaria un dialogo MODAL que dejaria la
# bateria colgada para siempre. El aviso de cierre se prueba en su propio caso, mas abajo.
Set-Content -Path $tmpCfg -Value '{ "behavior": { "workers": 2 }, "gui": { "confirmCloseWithWorkers": false } }' -Encoding UTF8
$ctx = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg

# PID que seguro NO existe: sirve para fabricar un bloqueo/estado CADUCADO (worker muerto).
$deadPid = 0
for ($i = 999999; $i -gt 100000; $i -= 7777) {
    if ($null -eq (Get-Process -Id $i -ErrorAction SilentlyContinue)) { $deadPid = $i; break }
}

function New-FakeVideo {
    param([string]$Name, [int]$Kb = 64)
    $p = Join-Path $ctx.Original ("{0}.mkv" -f $Name)
    $bytes = New-Object byte[] ($Kb * 1024)
    [System.IO.File]::WriteAllBytes($p, $bytes)
    return $p
}
function Connect-Tools {
    <#
        Enlaza tools\ del proyecto dentro del root temporal para los casos que necesitan ffmpeg o
        ffprobe de verdad. Devuelve $true si quedo enlazado.

        Dos cuidados: el contexto ya CREA un tools\ vacio al montar el root (asi que hay que quitarlo
        antes o el enlace no se crea), y un enlace NO se borra con Remove-Item -Recurse -Force: sobre
        un punto de reparse eso puede llevarse por delante el contenido de DESTINO, es decir, las
        herramientas del repositorio. Los enlaces se quitan con 'rmdir', que solo borra el enlace.
    #>
    param([string]$Dir, [string]$Target)
    try {
        if (Test-Path -LiteralPath $Dir) {
            $it = Get-Item -LiteralPath $Dir -Force
            if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                & cmd.exe /c rmdir "$Dir" | Out-Null
            } else {
                Remove-Item -Recurse -Force -LiteralPath $Dir -ErrorAction Stop
            }
        }
        if (Test-Path -LiteralPath $Dir) { return $false }
        New-Item -ItemType Junction -Path $Dir -Target $Target -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function New-FakeLock {
    param([string]$Name, [int]$OwnerPid)
    Set-Content -Path (Join-Path $ctx.Proceso ("{0}.lock" -f $Name)) -Value ("PID={0};HOST={1}" -f $OwnerPid, $env:COMPUTERNAME) -Encoding UTF8
}

try {

# Cinco archivos, uno por estado posible.
[void](New-FakeVideo -Name 'Serie_1x01' -Kb 2048)   # hecho (hay salida)
[void](New-FakeVideo -Name 'Serie_1x02' -Kb 2048)   # codificando (bloqueo de un worker vivo)
[void](New-FakeVideo -Name 'Serie_1x03' -Kb 1024)   # en cola (job, sin bloqueo)
[void](New-FakeVideo -Name 'Serie_1x04' -Kb 1024)   # sin preparar (sin job)
[void](New-FakeVideo -Name 'Serie_1x05' -Kb 1024)   # bloqueo huerfano (worker muerto)

Set-Content -Path (Join-Path $ctx.Convertido ("Serie_1x01_fix.{0}" -f $ctx.OutExt)) -Value 'salida' -Encoding UTF8
foreach ($n in @('Serie_1x02', 'Serie_1x03', 'Serie_1x05')) {
    Set-Content -Path (Join-Path $ctx.Proceso ("{0}.job.json" -f $n)) -Value '{}' -Encoding UTF8
}
New-FakeLock -Name 'Serie_1x02' -OwnerPid $PID        # este proceso hace de worker vivo
New-FakeLock -Name 'Serie_1x05' -OwnerPid $deadPid    # worker que ya no existe

# ================================================================================================
Write-Host "`nWorkerCore - estado que publica un worker" -ForegroundColor Cyan
Start-CvWorkerState -Context $ctx -Role 'worker' -LogPath (Join-Path $ctx.Logs 'Convert_20260919_000000_1.log')
Assert-True 'Estado: se crea el fichero' (Test-Path -LiteralPath (Get-CvWorkerStatePath -Context $ctx))
$w0 = @(Get-CvWorkerStates -Context $ctx)
Assert-Eq   'Estado: un worker'      1         $w0.Count
Assert-Eq   'Estado: mi PID'         $PID      $w0[0].Pid
Assert-True 'Estado: vivo'           $w0[0].Alive
Assert-Eq   'Estado: arranca ocioso' 'idle'    $w0[0].Status

Set-CvWorkerFile -Context $ctx -File 'Serie_1x02'
$w1 = @(Get-CvWorkerStates -Context $ctx)
Assert-Eq   'Estado: archivo reclamado' 'Serie_1x02' $w1[0].File
Assert-Eq   'Estado: pasa a working'    'working'    $w1[0].Status
Assert-Eq   'Estado: sin progreso aun'  -1           $w1[0].Percent

Update-CvWorkerProgress -Context $ctx -Step 'Video' -Percent 42 -Eta '03:12' -Speed '1.8x'
$w2 = @(Get-CvWorkerStates -Context $ctx)
Assert-Eq 'Progreso: paso'      'Video' $w2[0].Step
Assert-Eq 'Progreso: por ciento' 42     $w2[0].Percent
Assert-Eq 'Progreso: ETA'       '03:12' $w2[0].Eta
Assert-Eq 'Progreso: velocidad' '1.8x'  $w2[0].Speed

# ================================================================================================
Write-Host "`nWorkerCore - la cola entera" -ForegroundColor Cyan
$rows = @(Get-CvQueueStatus -Context $ctx)
Assert-Eq 'Cola: una fila por video' 5 $rows.Count
function Get-Row { param([string]$Name) $rows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
Assert-Eq 'Fila hecho'        'done'    (Get-Row 'Serie_1x01').State
Assert-Eq 'Fila codificando'  'working' (Get-Row 'Serie_1x02').State
Assert-Eq 'Fila en cola'      'queued'  (Get-Row 'Serie_1x03').State
Assert-Eq 'Fila sin preparar' 'pending' (Get-Row 'Serie_1x04').State
Assert-Eq 'Fila huerfana'     'stale'   (Get-Row 'Serie_1x05').State
Assert-True 'Fila hecho: tamano de salida' ((Get-Row 'Serie_1x01').OutSizeKb -ge 0)
Assert-Eq   'Fila hecho: 100%'             ((Get-Row 'Serie_1x01').Percent -eq 100) $true
# Si la salida se quedo con el video ORIGINAL (recodificar la engordaba), la fila lo dice: es lo
# unico que no se ve mirando el tamano, y el job ya no existe para contarlo.
$kvFila = [pscustomobject]@{
    Name = 'Serie_1x01'
    State = 'done'
    StateText = 'Hecho'
    SizeKb = 2048
    OutSizeKb = 2000
    HasJob = $false
    BorderGuess = ''
    VideoGuess = 'original'
}
Assert-True 'Fila hecho: dice que el video es el original' ((@(Format-CvQueueRow -Row $kvFila)[6]) -match '\[video ORIGINAL\]')
$kvFila.VideoGuess = ''
# OJO: -match no distingue mayusculas, y la celda ya dice '% del original'; se busca la marca entera.
Assert-Eq   'Fila hecho: sin marca no dice nada' $false ((@(Format-CvQueueRow -Row $kvFila)[6]) -match '\[video ORIGINAL\]')
# La fila que esta en curso trae el progreso del worker que la publica (no hay que buscarlo aparte).
$r02 = Get-Row 'Serie_1x02'
Assert-Eq 'Fila en curso: worker'   $PID    $r02.WorkerPid
Assert-Eq 'Fila en curso: paso'     'Video' $r02.Step
Assert-Eq 'Fila en curso: por ciento' 42    $r02.Percent
Assert-Eq 'Fila en curso: ETA'      '03:12' $r02.Eta
Assert-True 'Fila huerfana: marcada como caducada' (Get-Row 'Serie_1x05').Stale
Assert-Eq   'Fila sin preparar: sin job' $false (Get-Row 'Serie_1x04').HasJob

$tot = Get-CvQueueTotals -Rows $rows
Assert-Eq 'Totales: total'  5 $tot.Total
Assert-Eq 'Totales: hecho'  1 $tot.Done
Assert-Eq 'Totales: curso'  1 $tot.Working
Assert-Eq 'Totales: cola'   1 $tot.Queued
Assert-Eq 'Totales: sin preparar' 1 $tot.Pending
Assert-Eq 'Totales: huerfano' 1 $tot.Stale

# REGRESION: el fichero de salida EXISTE mientras se escribe (la ruta de una sola pasada escribe
# directamente en Convertido\), asi que mirar solo la salida marcaba 'Hecho' a los pocos segundos de
# empezar, con el worker todavia codificando. Mientras haya quien lo trabaje, manda eso.
$outMedias = Join-Path $ctx.Convertido ("Serie_1x02_fix.{0}" -f $ctx.OutExt)
Set-Content -Path $outMedias -Value 'a medio escribir' -Encoding UTF8
$rMid = @(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x02' }
Assert-Eq 'Salida a medio escribir: sigue codificando' 'working' $rMid.State
Remove-Item -Force -LiteralPath $outMedias
# Y en cuanto nadie lo trabaja (sin bloqueo ni worker), la salida manda: hecho.
Remove-Item -Force -LiteralPath (Join-Path $ctx.Proceso 'Serie_1x03.job.json')
Set-Content -Path (Join-Path $ctx.Convertido ("Serie_1x03_fix.{0}" -f $ctx.OutExt)) -Value 'salida' -Encoding UTF8
Assert-Eq 'Sin nadie trabajando: hecho' 'done' (@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x03' }).State
Remove-Item -Force -LiteralPath (Join-Path $ctx.Convertido ("Serie_1x03_fix.{0}" -f $ctx.OutExt))
Set-Content -Path (Join-Path $ctx.Proceso 'Serie_1x03.job.json') -Value '{}' -Encoding UTF8

# CANCELADO a medias: queda la salida A MEDIAS y el job SIN borrar (el worker solo lo borra al acabar
# bien). Eso no es 'hecho': ademas bloquea el reintento, porque el worker salta lo que ya tiene salida.
$outMedio = Join-Path $ctx.Convertido ("Serie_1x03_fix.{0}" -f $ctx.OutExt)
Set-Content -Path $outMedio -Value 'a medias' -Encoding UTF8
$rPar = @(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x03' }
Assert-Eq   'Cancelado: sale como sin terminar' 'partial' $rPar.State
Assert-Eq   'Cancelado: no dice Hecho'          'Sin terminar' $rPar.StateText
Assert-True 'Cancelado: la fila lo explica'     ((@(Format-CvQueueRow -Row $rPar)[6]) -match 'a medias')
$bulkPar = Get-CvQueueBulkActions -Rows @($rPar)
Assert-Eq   'Cancelado: se puede purgar'        1 @($bulkPar.Purge).Count
Assert-Eq   'Cancelado: texto de purgar'        'Eliminar la salida a medias (se rehace)' $bulkPar.PurgeText
Assert-Eq   'Cancelado: purgadas'               1 (Remove-CvQueueOutput -Context $ctx -Names @('Serie_1x03'))
Assert-True 'Cancelado: la salida ya no esta'   (-not (Test-Path -LiteralPath $outMedio))
Assert-Eq   'Cancelado: vuelve a la cola'       'queued' (@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x03' }).State
# Y lo ya HECHO (salida sin job) no se ofrece purgar: ahi no hay nada roto.
Assert-Eq   'Hecho: no se ofrece purgar' 0 @((Get-CvQueueBulkActions -Rows @(@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x01' })).Purge).Count

# Un worker MUERTO que dejo su estado no cuenta como vivo ni se queda con el archivo.
$ghost = Join-Path $ctx.Proceso ("{0}.worker.json" -f $deadPid)
Set-Content -Path $ghost -Value (('{{ "pid": {0}, "host": "{1}", "status": "working", "file": "Serie_1x03", "percent": 10 }}' -f $deadPid, $env:COMPUTERNAME)) -Encoding UTF8
$wAll = @(Get-CvWorkerStates -Context $ctx)
Assert-Eq   'Fantasma: dos estados'   2 $wAll.Count
Assert-Eq   'Fantasma: no esta vivo'  1 @($wAll | Where-Object { -not $_.Alive }).Count
Assert-Eq   'Fantasma: no se apunta el archivo' 'queued' (@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -eq 'Serie_1x03' }).State
Assert-Eq   'Fantasma: se puede limpiar' 1 (Remove-CvWorkerStates -States @($wAll | Where-Object { -not $_.Alive }))
Assert-True 'Fantasma: ya no esta'    (-not (Test-Path -LiteralPath $ghost))

# ================================================================================================
Write-Host "`nWorkerCore - parada ordenada y comprobacion previa" -ForegroundColor Cyan
Assert-Eq   'Parada: al principio no hay' $false (Test-CvWorkerStop -Context $ctx)
Assert-True 'Parada: se pide'             (Set-CvWorkerStop -Context $ctx)
Assert-True 'Parada: se ve'               (Test-CvWorkerStop -Context $ctx)
Clear-CvWorkerStop -Context $ctx
Assert-Eq   'Parada: se retira'           $false (Test-CvWorkerStop -Context $ctx)
# La bandera vive en Proceso\ y se limpia con los bloqueos (patrones de Job.psm1).
[void](Set-CvWorkerStop -Context $ctx)
Assert-True 'Parada: la recoge la limpieza' (@(Get-CvSetupCleanTargets -Context $ctx -What locks | ForEach-Object { $_.Name }) -contains 'stop.flag')
Clear-CvWorkerStop -Context $ctx

# Sin ffmpeg instalado en el root temporal NO se puede trabajar: se avisa con el motivo (y con las
# versiones que SI hay) en vez de dejar que reviente el primer Process.Start. Lo comprueban tanto el
# arranque de la ventana como el de los workers y el de PREPARAR.
$ready = Test-CvConvertReady -Context $ctx
Assert-Eq   'Listo: no, falta ffmpeg' $false $ready.Ok
Assert-True 'Listo: dice por que'     ($ready.Reason -match 'ffmpeg')
Assert-True 'Listo: dice que hacer'   ($ready.Reason -match 'setup')
Assert-True 'Listo: trae lista de avisos' ($null -ne $ready.Warnings)
# Las herramientas OPCIONALES solo se avisan si esta configuracion las va a usar: con el metodo de
# volumen por defecto (loudnorm) no se dice nada de aacgain.
$ctxAac = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg
Assert-Eq   'Listo: sin aacgain configurado, sin aviso' 0 @(@((Test-CvConvertReady -Context $ctxAac).Warnings) | Where-Object { $_ -match 'aacgain' }).Count

# ================================================================================================
Write-Host "`nGuiConvert - formato de las filas (sin ventana)" -ForegroundColor Cyan

$cells = @(Format-CvQueueRow -Row (Get-Row 'Serie_1x02'))
Assert-Eq   'Celdas: son ocho'        8 $cells.Count
Assert-Eq   'Celdas: nombre'          'Serie_1x02' $cells[0]
Assert-Eq   'Celdas: estado'          'Codificando' $cells[2]
Assert-Eq   'Celdas: worker'          ("#{0}" -f $PID) $cells[5]
Assert-True 'Celdas: progreso lleva el paso' ($cells[6] -match 'Video')
Assert-True 'Celdas: progreso lleva el %'    ($cells[6] -match '42%')
Assert-True 'Celdas: progreso lleva la velocidad' ($cells[6] -match '1.8x')
Assert-Eq   'Celdas: ETA'             '03:12' $cells[7]
# La barra es la MISMA que pinta la consola (Get-CvProgressBar): si cambia alli, cambia aqui.
$bar = Get-CvProgressBar -Percent 42 -Width 12
Assert-True 'Celdas: barra como en consola' ($cells[6].Contains($bar))

$cellsDone = @(Format-CvQueueRow -Row (Get-Row 'Serie_1x01'))
Assert-Eq   'Celdas hecho: estado'    'Hecho' $cellsDone[2]
Assert-Eq   'Celdas hecho: sin worker' ''     $cellsDone[5]
$cellsStale = @(Format-CvQueueRow -Row (Get-Row 'Serie_1x05'))
Assert-Eq   'Celdas huerfana: estado' 'Bloqueo huerfano' $cellsStale[2]
Assert-True 'Celdas huerfana: lo explica' ($cellsStale[6] -match 'ya no existe')
# La barra va entre corchetes para que se vea la escala (el tramo vacio casi no pinta a 9pt).
Assert-True 'Celdas: barra delimitada' ($cells[6] -match '\[')
$cellsPend = @(Format-CvQueueRow -Row (Get-Row 'Serie_1x04'))
Assert-True 'Celdas sin preparar: lo explica' ($cellsPend[6] -match 'PREPARAR')
# Las columnas nuevas: de un vistazo, que archivos llevan recorte y cuales tienen algo de audio que
# revisar. Salen del JOB (sin ffprobe), asi que un archivo sin job las deja vacias.
$rowB = [pscustomobject]@{
    Name = 'x'; SizeKb = 0; StateText = 'En cola'; State = 'queued'; WorkerPid = 0
    Percent = -1; Step = ''; Eta = ''; Speed = ''; OutSizeKb = 0
    Crop = '1920:960:0:60'; Detect = $true; AudioSkip = $false
    AudioTracks = @([pscustomobject]@{ Index = 1; Lang = 'spa'; Sync = -0.25; Is51 = $true; Default = $true })
}
$rowB | Add-Member -NotePropertyName HasJob -NotePropertyValue $true
$cellsB = @(Format-CvQueueRow -Row $rowB)
Assert-Eq   'Celdas: bordes marcados'  '[x]' $cellsB[3]
Assert-True 'Celdas: audio con sync'   ($cellsB[4] -match 'sync -0')
Assert-True 'Celdas: audio dice 5.1'   ($cellsB[4] -match '5\.1')
$rowN = [pscustomobject]@{
    Name = 'x'; SizeKb = 0; StateText = 'En cola'; State = 'queued'; WorkerPid = 0
    Percent = -1; Step = ''; Eta = ''; Speed = ''; OutSizeKb = 0
    Crop = ''; Detect = $true; AudioSkip = $false
    AudioTracks = @([pscustomobject]@{ Index = 1; Lang = 'spa'; Sync = 0; Is51 = $false; Default = $true })
}
$rowN | Add-Member -NotePropertyName HasJob -NotePropertyValue $true
$cellsN = @(Format-CvQueueRow -Row $rowN)
Assert-Eq   'Celdas: se busco y no hay barras' '[ ]' $cellsN[3]
Assert-Eq   'Celdas: audio sin nada que decir' ''    $cellsN[4]
# Sin job no se sabe nada: las dos columnas en blanco (ni '[ ]' ni 'sin audio', que serian mentira).
$rowSin = [pscustomobject]@{
    Name = 'x'; SizeKb = 0; StateText = 'Sin preparar'; State = 'pending'; WorkerPid = 0
    Percent = -1; Step = ''; Eta = ''; Speed = ''; OutSizeKb = 0; HasJob = $false
    Crop = ''; Detect = $false; AudioSkip = $false; AudioTracks = @()
}
$cellsSin = @(Format-CvQueueRow -Row $rowSin)
Assert-Eq   'Celdas sin job: bordes en blanco' '' $cellsSin[3]
Assert-Eq   'Celdas sin job: audio en blanco'  '' $cellsSin[4]

# Acciones EN BLOQUE sobre varias filas marcadas (la lista es de seleccion multiple).
# REGRESION: los jobs sembrados aqui son '{}' (sin perfil ni secciones), que es lo que puede haber
# con un job de una version anterior o a medio escribir. El resumen tiene que SALIR igual: si lanza
# una excepcion, y la pinta un manejador de WinForms, no es un error -es un cuelgue de la aplicacion.
$sumRoto = @(Get-CvJobSummaryLines -Context $ctx -Name 'Serie_1x03')
Assert-True 'Resumen job incompleto: no revienta' ($sumRoto.Count -ge 3)
Assert-True 'Resumen job incompleto: lo dice'     ((($sumRoto -join ' ') -match 'no trae perfil'))
Assert-True 'Resumen job incompleto: sigue con lo demas' ((($sumRoto -join ' ') -match 'SALIDA'))

$bulkAll = Get-CvQueueBulkActions -Rows $rows
# Codificar solo los elegidos: solo cuentan los que estan EN COLA (lo demas no se puede lanzar).
Assert-Eq   'Bloque: a codificar'         1 @($bulkAll.Start).Count
Assert-Eq   'Bloque: texto de codificar'  'Codificar solo este' $bulkAll.StartText
Assert-Eq   'Bloque: nada que codificar si no hay cola' 0 @((Get-CvQueueBulkActions -Rows @($rows | Where-Object { $_.State -ne 'queued' })).Start).Count
Assert-Eq   'Bloque: bloqueos a liberar'  1 @($bulkAll.Free).Count
Assert-Eq   'Bloque: jobs a quitar'       2 @($bulkAll.Drop).Count      # el 'en cola' y el huerfano
Assert-True 'Bloque: no toca el que se codifica' (@($bulkAll.Drop | Where-Object { $_.State -eq 'working' }).Count -eq 0)
Assert-True 'Bloque: ni el ya hecho'      (@($bulkAll.Drop | Where-Object { $_.State -eq 'done' }).Count -eq 0)
Assert-Eq   'Bloque: texto en plural'     'Quitar de la cola los 2 seleccionados (borrar sus jobs)' $bulkAll.DropText
# Cortar SOLO lo elegido: se ofrece para las filas que se estan codificando AHORA (y mata su
# worker, no todos). En la cola sembrada hay exactamente una.
Assert-Eq   'Bloque: se puede cortar una'  1 @($bulkAll.Kill).Count
Assert-Eq   'Bloque: la que se codifica'   'Serie_1x02' @($bulkAll.Kill)[0].Name
Assert-Eq   'Bloque: texto de cortar'      'Cortar la codificacion de este' $bulkAll.KillText
Assert-Eq   'Bloque: nada que cortar sin workers' 0 @((Get-CvQueueBulkActions -Rows @($rows | Where-Object { $_.State -ne 'working' })).Kill).Count
$bulkUno = Get-CvQueueBulkActions -Rows @($rows | Where-Object { $_.State -eq 'queued' })
Assert-Eq   'Bloque: texto en singular'   'Quitar de la cola (borrar su job)' $bulkUno.DropText
Assert-Eq   'Bloque: singular al liberar' 'Liberar el bloqueo huerfano' $bulkUno.FreeText
$bulkNada = Get-CvQueueBulkActions -Rows @()
Assert-Eq   'Bloque: sin seleccion, nada' 0 (@($bulkNada.Free).Count + @($bulkNada.Drop).Count)
$bulkPend = Get-CvQueueBulkActions -Rows @($rows | Where-Object { $_.State -eq 'pending' })
Assert-Eq   'Bloque: sin preparar no tiene job que quitar' 0 @($bulkPend.Drop).Count

# Ancho de la columna de progreso: se queda con lo que sobra a la derecha, con un minimo (es la que
# mas informacion lleva: paso, barra, % y velocidad).
# Un listado de Original\ que sale VACIO no puede vaciar la ventana si la carpeta sigue con
# ficheros: Get-CvFiles se traga los errores del disco, y eso dejaba la tabla EN BLANCO.
Assert-Eq   'Listado vacio: con ficheros dentro se conserva' $true  (Test-CvQueueKeepRows -Rows 0 -Items 23 -DirExists $true -RealFiles 23)
Assert-Eq   'Listado vacio: carpeta vacia de verdad, se vacia' $false (Test-CvQueueKeepRows -Rows 0 -Items 23 -DirExists $true -RealFiles 0)
Assert-Eq   'Listado vacio: carpeta que ya no esta, se vacia' $false (Test-CvQueueKeepRows -Rows 0 -Items 23 -DirExists $false -RealFiles 0)
Assert-Eq   'Listado vacio: si la lista ya estaba vacia, nada' $false (Test-CvQueueKeepRows -Rows 0 -Items 0 -DirExists $true -RealFiles 5)
Assert-Eq   'Listado con filas: no aplica'                  $false (Test-CvQueueKeepRows -Rows 23 -Items 23 -DirExists $true -RealFiles 23)
Assert-Eq   'Progreso: ocupa lo que sobra'       400 (Get-CvQueueProgressWidth -ClientWidth 1100 -OtherWidths 700)
Assert-Eq   'Progreso: ventana estrecha -> minimo' 220 (Get-CvQueueProgressWidth -ClientWidth 800 -OtherWidths 700)
Assert-Eq   'Progreso: minimo a medida'          300 (Get-CvQueueProgressWidth -ClientWidth 400 -OtherWidths 700 -Min 300)
Assert-True 'Progreso: nunca negativo'           ((Get-CvQueueProgressWidth -ClientWidth 0 -OtherWidths 700) -gt 0)

# El temporizador: con workers, el ritmo del progreso; ARRANCANDO (recien pulsado Iniciar, ningun
# worker ha publicado todavia) tambien, porque si no se paraba justo en ese hueco y la fila no
# pasaba a 'Codificando' hasta pulsar Actualizar a mano; y parado, lo que diga la config.
$tkVivos = Get-CvQueueTickPlan -Live 2 -RefreshMs 1000 -IdleMs 0
Assert-True 'Ritmo: con workers, en marcha'      ([bool]$tkVivos.Enabled)
Assert-Eq   'Ritmo: con workers, el del progreso' 1000 ([int]$tkVivos.Interval)
$tkArr = Get-CvQueueTickPlan -Live 0 -Starting $true -RefreshMs 1000 -IdleMs 0
Assert-True 'Ritmo: arrancando, sigue mirando'   ([bool]$tkArr.Enabled)
Assert-Eq   'Ritmo: arrancando, mismo ritmo'     1000 ([int]$tkArr.Interval)
$tkPara = Get-CvQueueTickPlan -Live 0 -RefreshMs 1000 -IdleMs 0
Assert-Eq   'Ritmo: parada y sin latido, se para' $false ([bool]$tkPara.Enabled)
$tkIdle = Get-CvQueueTickPlan -Live 0 -RefreshMs 1000 -IdleMs 10000
Assert-True 'Ritmo: con latido configurado, sigue' ([bool]$tkIdle.Enabled)
Assert-Eq   'Ritmo: y al ritmo del latido'       10000 ([int]$tkIdle.Interval)


# La lista SIGUE al archivo que se esta codificando: si se sale de la zona visible se mueve sola,
# y si te has ido tu a mirar otra parte se calla (Get-CvQueueFollowPlan).
$rngUno = Get-CvQueueWorkingRange -Rows $rows
Assert-Eq   'En curso: la fila que se codifica' 1 ([int]$rngUno.First)
Assert-Eq   'En curso: y es la unica'           1 ([int]$rngUno.Last)
$rngDos = Get-CvQueueWorkingRange -Rows @(
    [pscustomobject]@{ State = 'done' }
    [pscustomobject]@{ State = 'working' }
    [pscustomobject]@{ State = 'queued' }
    [pscustomobject]@{ State = 'working' }
)
Assert-Eq   'En curso: con varios workers, el bloque' '1|3' (@($rngDos.First, $rngDos.Last) -join '|')
$rngCero = Get-CvQueueWorkingRange -Rows @([pscustomobject]@{ State = 'queued' })
Assert-Eq   'En curso: nada codificando' '-1|-1' (@($rngCero.First, $rngCero.Last) -join '|')

# La fila en curso NO se ve: hay que ir a por ella.
$plFuera = Get-CvQueueFollowPlan -HasRow $true -Visible $false
Assert-True 'Seguir: fila en curso fuera -> se mueve' ([bool]$plFuera.Scroll)
$plDentro = Get-CvQueueFollowPlan -HasRow $true -Visible $true
Assert-Eq   'Seguir: si ya se ve, no se toca' $false ([bool]$plDentro.Scroll)
# Te has ido TU a otra parte (el scroll esta en otro sitio y no lo movio la ventana): se suelta.
$plUser = Get-CvQueueFollowPlan -HasRow $true -Visible $false -Moved $true
Assert-Eq   'Seguir: te vas tu -> se suelta'   $false ([bool]$plUser.Follow)
Assert-Eq   'Seguir: y no te devuelve el scroll' $false ([bool]$plUser.Scroll)
# Y vuelves a tenerla delante: se engancha otra vez.
$plBack = Get-CvQueueFollowPlan -HasRow $true -Visible $true -Moved $true -Following $false
Assert-True 'Seguir: vuelves a ella -> se engancha' ([bool]$plBack.Follow)
# La lista RECIEN reconstruida vuelve arriba sola: eso no es que hayas movido tu (-Moved $false).
$plRebuild = Get-CvQueueFollowPlan -HasRow $true -Visible $false -Moved $false
Assert-True 'Seguir: reconstruir la lista no cuenta como scroll tuyo' ([bool]$plRebuild.Scroll)
# Ya suelta, el temporizador no la vuelve a enganchar solo.
$plSuelta = Get-CvQueueFollowPlan -HasRow $true -Visible $false -Following $false
Assert-Eq   'Seguir: suelta, sigue suelta' $false ([bool]$plSuelta.Scroll)
Assert-Eq   'Seguir: sin nada codificando, nada' $false ([bool](Get-CvQueueFollowPlan -HasRow $false -Visible $false).Scroll)
Assert-Eq   'Seguir: apagado en config, nada'    $false ([bool](Get-CvQueueFollowPlan -HasRow $true -Visible $false -Enabled $false).Scroll)
# La lista se mueve POCO: solo cuando se pone a codificar OTRO archivo. Que la fila en curso se
# salga de la vista por cualquier otro motivo no la mueve (moverla mientras la usas es peor).
Assert-Eq   'Seguir: mismo archivo, no se mueve' $false ([bool](Get-CvQueueFollowPlan -HasRow $true -Visible $false -Changed $false).Scroll)
# Y mientras la estas usando (raton apretado o acabas de marcar filas) no se mueve NADA: ni siquiera
# se da por visto el archivo, para volver a mirarlo cuando la sueltes.
$plBusy = Get-CvQueueFollowPlan -HasRow $true -Visible $false -Busy $true
Assert-Eq   'Seguir: la estas usando, no se mueve' $false ([bool]$plBusy.Scroll)
Assert-True 'Seguir: y no da nada por visto'       ([bool]$plBusy.Hold)
Assert-Eq   'Seguir: libre, no queda nada pendiente' $false ([bool](Get-CvQueueFollowPlan -HasRow $true -Visible $false).Hold)
# La clave del bloque en curso va por NOMBRE: cambiar de archivo si cuenta, moverse de fila no.
$kA = Get-CvQueueWorkingRange -Rows @(
    [pscustomobject]@{ State = 'queued';  Name = 'Serie_1x01' }
    [pscustomobject]@{ State = 'working'; Name = 'Serie_1x02' }
)
$kB = Get-CvQueueWorkingRange -Rows @(
    [pscustomobject]@{ State = 'queued';  Name = 'Serie_1x00' }
    [pscustomobject]@{ State = 'queued';  Name = 'Serie_1x01' }
    [pscustomobject]@{ State = 'working'; Name = 'Serie_1x02' }
)
Assert-Eq   'En curso: la clave no cambia al bajar de fila' "$($kA.Key)" "$($kB.Key)"
Assert-True 'En curso: pero si al cambiar de archivo' ("$($kA.Key)" -ne "$((Get-CvQueueWorkingRange -Rows @([pscustomobject]@{ State = 'working'; Name = 'Serie_1x03' })).Key)")

# Cuando se puede pulsar 'Iniciar': con workers YA en marcha NO (volver a pulsarlo abriria otro
# grupo entero de workers sobre la misma cola).
Assert-True 'Iniciar: con cola y sin workers'  (Get-CvQueueStartState -Queued 3 -Live 0).Enabled
Assert-Eq   'Iniciar: con workers en marcha'   $false (Get-CvQueueStartState -Queued 3 -Live 2).Enabled
Assert-True 'Iniciar: y dice por que'          ((Get-CvQueueStartState -Queued 3 -Live 2).Tip -match '2 worker')
Assert-Eq   'Iniciar: sin nada en cola'        $false (Get-CvQueueStartState -Queued 0 -Live 0).Enabled
Assert-Eq   'Iniciar: con parada pedida'       $false (Get-CvQueueStartState -Queued 3 -Live 0 -Stopping $true).Enabled
# Recien pulsado: los workers tardan segundos en publicar su estado y el boton NO puede seguir activo
# en ese hueco (es justo cuando se vuelve a pulsar sin querer).
Assert-Eq   'Iniciar: recien arrancado'        $false (Get-CvQueueStartState -Queued 3 -Live 0 -JustStarted $true).Enabled
Assert-True 'Iniciar: y lo dice'               ((Get-CvQueueStartState -Queued 3 -Live 0 -JustStarted $true).Tip -match 'arrancando')

# Con filas marcadas, 'Iniciar' PREGUNTA en vez de dar por hecho que la seleccion era una orden:
# marcar una fila es tambien como se lee su resumen (paso de verdad: se codifico un solo archivo,
# empezando por el 15 de la lista, y parecia que el reparto estaba roto).
$scSub = Get-CvQueueStartScope -Selected 1 -Total 22
Assert-True 'Ambito: con 1 de 22 pregunta'     $scSub.Ask
Assert-Eq   'Ambito: tres salidas'           3 @($scSub.Options).Count
Assert-Eq   'Ambito: en orden'                'sel|all|cancel' ((@($scSub.Options | ForEach-Object { $_.Value })) -join '|')
Assert-True 'Ambito: dice cuantos'             ($scSub.Message -match '1 archivo\(s\) marcados de los 22')
Assert-Eq   'Ambito: sin seleccion no pregunta' $false (Get-CvQueueStartScope -Selected 0 -Total 22).Ask
Assert-Eq   'Ambito: con TODO marcado tampoco' $false (Get-CvQueueStartScope -Selected 22 -Total 22).Ask

# El trozo de log de UN archivo: un worker encadena varios en el mismo log, asi que para mirar uno
# hay que quedarse con su tramo (de su 'CODIFICANDO:' al del siguiente).
$logLines = @(
    '[GLOBAL] [WORKER] - Buscando archivos preparados...'
    '[WORKER] CODIFICANDO: Serie_1x01'
    '   [VIDEO] - paso 1 de la primera'
    '   [OK] - terminada la primera'
    '[WORKER] CODIFICANDO: Serie_1x02'
    '   [VIDEO] - paso 1 de la segunda'
    '   [ERROR] - fallo la segunda'
)
$sec1 = Get-CvLogSection -Lines $logLines -Name 'Serie_1x01'
Assert-True 'Tramo: empieza en su CODIFICANDO' ($sec1 -match 'CODIFICANDO: Serie_1x01')
Assert-True 'Tramo: lleva lo suyo'             ($sec1 -match 'paso 1 de la primera')
Assert-True 'Tramo: no se cuela el siguiente'  (-not ($sec1 -match 'Serie_1x02'))
$sec2 = Get-CvLogSection -Lines $logLines -Name 'Serie_1x02'
Assert-True 'Tramo: el ultimo llega al final'  ($sec2 -match 'fallo la segunda')
Assert-Eq   'Tramo: archivo que no esta'  '' (Get-CvLogSection -Lines $logLines -Name 'Serie_9x09')
Assert-Eq   'Tramo: sin lineas'           '' (Get-CvLogSection -Lines @() -Name 'Serie_1x01')
# Con reintentos manda la ULTIMA vez que se intento (es como quedo la cosa).
$logRetry = @('[WORKER] CODIFICANDO: X', '   intento 1', '[WORKER] CODIFICANDO: X', '   intento 2')
Assert-True 'Tramo: con reintentos, el ultimo' ((Get-CvLogSection -Lines $logRetry -Name 'X') -match 'intento 2')

# Aviso al cerrar con workers vivos: el catalogo de salidas y su texto (puros).
$clo = @(Get-CvQueueCloseActions)
Assert-Eq   'Cierre: cuatro salidas'   4 $clo.Count
Assert-Eq   'Cierre: en orden'         'background|stop|kill|cancel' ((@($clo | ForEach-Object { $_.Value })) -join '|')
Assert-True 'Cierre: todas con texto'  (@($clo | Where-Object { "$($_.Text)" -eq '' }).Count -eq 0)
Assert-True 'Cierre: dice que no para' ((Get-CvQueueCloseMessage -Workers 2) -match 'NO lo para')
Assert-True 'Cierre: 1 worker en singular' ((Get-CvQueueCloseMessage -Workers 1) -match 'Hay 1 worker codificando')
Assert-True 'Cierre: N workers en plural'  ((Get-CvQueueCloseMessage -Workers 3) -match 'Hay 3 workers codificando')

$sum = Get-CvQueueSummaryLine -Totals $tot -Workers 2 -Stopping $false
Assert-True 'Resumen: cuenta archivos'  ($sum -match '5 archivo')
Assert-True 'Resumen: cuenta workers'   ($sum -match '2 worker')
Assert-True 'Resumen: sin parada no avisa' ($sum -notmatch 'PARADA')
Assert-True 'Resumen: con parada avisa'    ((Get-CvQueueSummaryLine -Totals $tot -Workers 1 -Stopping $true) -match 'PARADA PEDIDA')

# Selector de logs: solo los transcripts de Convert, y marcando el del worker vivo.
$logLive = Join-Path $ctx.Logs 'Convert_20260919_101010_1234.log'
Set-Content -Path $logLive -Value 'linea' -Encoding UTF8
Set-Content -Path (Join-Path $ctx.Logs 'setup_20260919_101010_1234.log') -Value 'otro' -Encoding UTF8
$fakeW = @([pscustomobject]@{ Pid = 1234; Alive = $true; Log = $logLive })
$choices = @(Get-CvConvertLogChoices -Context $ctx -Workers $fakeW)
Assert-Eq   'Logs: solo los de Convert' 1 $choices.Count
Assert-Eq   'Logs: el del worker vivo'  1234 $choices[0].WorkerPid
Assert-True 'Logs: lo marca en el texto' ($choices[0].Text -match 'en curso')


# ================================================================================================
# CATALOGOS DE LAYOUT: las filas y las columnas de las ventanas son DATOS, asi que se revisan aqui
# sin abrir ninguna. Lo que se mira es lo que rompe una ventana de verdad: un tipo de control que
# el constructor no sabe montar, dos controles con el mismo nombre (Controls.Find devolveria dos y
# la ventana engancharia el manejador al que no es) o una columna sin ancho.
Write-Host "`nCatalogos de layout (filas y columnas)" -ForegroundColor Cyan

$kinds = @('label', 'text', 'check', 'button', 'combo')

$vRows = Get-CvJobVideoRows
Assert-Eq   'Video: cuatro filas'            4 $vRows.Count
$vCells = @()
foreach ($r in $vRows) { foreach ($c in @($r.Cells)) { $vCells += $c } }
Assert-True 'Video: todas las celdas son de un tipo conocido' (@($vCells | Where-Object { $kinds -notcontains "$($_.Kind)" }).Count -eq 0)
$vNames = @($vCells | ForEach-Object { "$($_.Name)" } | Where-Object { $_ -ne '' })
Assert-Eq   'Video: nueve controles con nombre' 9 $vNames.Count
Assert-Eq   'Video: ningun nombre repetido'  $vNames.Count @($vNames | Sort-Object -Unique).Count
Assert-True 'Video: todos se llaman cvJob*'  (@($vNames | Where-Object { -not $_.StartsWith('cvJob') }).Count -eq 0)
# La fila de 'quedarse con el original' ocupa el ancho entero: si no, el texto sale cortado.
$keep = @($vCells | Where-Object { "$($_.Name)" -eq 'cvJobKeepOriginal' })[0]
Assert-Eq   'Video: la de quedarse con el original ocupa tres columnas' 3 ([int]$keep.Span)

foreach ($par in @(
    @{ N = 'audio'; C = (Get-CvJobAudioColumns); T = 6 }
    @{ N = 'subs';  C = (Get-CvJobSubColumns);   T = 5 }
    @{ N = 'cola';  C = (Get-CvQueueColumns);    T = 8 }
)) {
    $cols = @($par.C)
    Assert-Eq   ("Columnas {0}: cuantas hay" -f $par.N)       ([int]$par.T) $cols.Count
    Assert-True ("Columnas {0}: todas con texto y ancho" -f $par.N) (@($cols | Where-Object { "$($_.Text)" -eq '' -or [int]$_.Width -le 0 }).Count -eq 0)
    $keys = @($cols | ForEach-Object { "$($_.Key)" })
    Assert-Eq   ("Columnas {0}: ninguna clave repetida" -f $par.N) $keys.Count @($keys | Sort-Object -Unique).Count
}

# El numero magico que ya no hay que recordar: la de progreso se busca por su clave.
$qCols = Get-CvQueueColumns
$iPr   = Get-CvGuiCatalogIndex -Items $qCols -Key 'prog'
Assert-Eq   'Cola: la columna de progreso se encuentra por su clave' 'Progreso' "$($qCols[$iPr].Text)"
Assert-Eq   'Catalogo: una clave que no esta da -1' -1 (Get-CvGuiCatalogIndex -Items $qCols -Key 'noexiste')

foreach ($par in @(
    @{ N = 'audio'; I = (Get-CvJobAudioBarItems) }
    @{ N = 'subs';  I = (Get-CvJobSubBarItems) }
)) {
    $items = @($par.I)
    Assert-True ("Barra {0}: todos los controles son de un tipo conocido" -f $par.N) (@($items | Where-Object { $kinds -notcontains "$($_.Kind)" }).Count -eq 0)
    $nm = @($items | ForEach-Object { "$($_.Name)" } | Where-Object { $_ -ne '' })
    Assert-Eq   ("Barra {0}: ningun nombre repetido" -f $par.N) $nm.Count @($nm | Sort-Object -Unique).Count
    # Lo que no es etiqueta tiene que poder engancharse a un manejador, asi que necesita nombre.
    Assert-True ("Barra {0}: todo lo que no es etiqueta tiene nombre" -f $par.N) (@($items | Where-Object { "$($_.Kind)" -ne 'label' -and "$($_.Name)" -eq '' }).Count -eq 0)
}


# ================================================================================================
Write-Host "`nGuiConvert - ventana de la cola (leida sin raton)" -ForegroundColor Cyan
# Los casos comprueban TEXTO, asi que el idioma se fija: con 'auto', en un Windows en
# otro idioma la bateria fallaria por traduccion y no por un fallo de verdad.
[void](Set-CvLanguage -Lang 'es')

$sta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
if (-not $sta) {
    Write-Skip 'Ventana de la cola' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Ventana de la cola' 'sin entorno grafico'
} else {
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 300
    $script:guiErr = ''
    $script:guiWaits = 0
    $t.Add_Tick({
        # ESPERAR a que la ventana este montada, no dar por hecho que a los X ms ya lo esta: con la
        # maquina ocupada (esta bateria detras de otra) llegaba a destiempo y fallaban 43 casos de
        # golpe, todos con valores vacios. Se reintenta hasta que la lista tiene filas.
        try {
            $fs = @([System.Windows.Forms.Application]::OpenForms)
            $lvs = $(if ($fs.Count -gt 0) { @($fs[0].Controls.Find('cvQueue', $true)) } else { @() })
            if ($lvs.Count -eq 0 -or $lvs[0].Items.Count -eq 0) {
                $script:guiWaits++
                if ($script:guiWaits -gt 60) { $t.Stop(); $script:guiErr = 'la ventana no llego a montarse'; $fs | ForEach-Object { $_.Close() } }
                return
            }
        } catch {
            $t.Stop(); $script:guiErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            return
        }
        $t.Stop()
        try {
            $f   = @([System.Windows.Forms.Application]::OpenForms)[0]
            $lv  = $f.Controls.Find('cvQueue',  $true)[0]
            $tot = $f.Controls.Find('cvTotals', $true)[0]
            $bSt = $f.Controls.Find('cvStart',  $true)[0]
            $bSp = $f.Controls.Find('cvStop',   $true)[0]
            $bKl = $f.Controls.Find('cvKill',   $true)[0]
            $bEd = $f.Controls.Find('cvPrepareGui', $true)[0]
            $cmb = $f.Controls.Find('cvLogPick', $true)[0]
            $nw  = $f.Controls.Find('cvWorkers', $true)[0]

            $script:rowCount  = $lv.Items.Count
            $script:colCount  = $lv.Columns.Count
            $script:firstName = if ($lv.Items.Count -gt 0) { $lv.Items[0].Text } else { '' }
            # Los estados se leen de la propia lista, que es lo que ve el usuario.
            $script:states = (@($lv.Items | ForEach-Object { $_.SubItems[2].Text }) -join ',')
            $script:totals = $tot.Text
            # Botones: hay un archivo en cola -> se puede iniciar; hay un worker vivo -> se puede
            # parar y cancelar. NO se pulsan: 'Iniciar' abriria procesos de verdad y 'Cancelar ahora'
            # sacaria una confirmacion modal que dejaria la bateria colgada.
            $script:canStart = $bSt.Enabled
            $script:startText = "$($bSt.Text)"
            # Con una fila EN COLA marcada, 'Iniciar' pasa a trabajar solo con lo elegido y lo dice.
            foreach ($k in 0..($lv.Items.Count - 1)) {
                if ($lv.Items[$k].SubItems[2].Text -eq 'En cola') { $lv.Items[$k].Selected = $true }
            }
            # SIN pulsar Actualizar: marcar una fila tiene que bastar (la ventana ya no se refresca
            # sola, asi que si el texto dependiera del refresco no se enteraria hasta pulsarlo).
            $script:startTextSel = "$($bSt.Text)"
            # El menu contextual tiene que ofrecer lo mismo que el boton sobre lo elegido.
            $menu = $lv.ContextMenuStrip
            $menu.Show($lv, (New-Object System.Drawing.Point(5, 5)))   # dispara Opening (rellena textos)
            $menu.Close()
            $script:menuItems = (@($menu.Items | ForEach-Object { "$($_.Text)" }) -join '|')
            $script:menuStart = @($menu.Items | Where-Object { "$($_.Text)" -match 'Codificar solo' })[0].Enabled
            # Reproducir: con una fila EN COLA (sin salida todavia) solo se puede ver el original.
            $script:playIn1  = @($menu.Items | Where-Object { "$($_.Text)" -match 'Reproducir el ORIGINAL' })[0].Enabled
            $script:playOut1 = @($menu.Items | Where-Object { "$($_.Text)" -match 'Reproducir el CONVERTIDO' })[0].Enabled
            # Y sobre una ya HECHA (que si tiene salida), tambien el convertido.
            $lv.SelectedItems.Clear()
            foreach ($k in 0..($lv.Items.Count - 1)) {
                if ($lv.Items[$k].SubItems[2].Text -eq 'Hecho') { $lv.Items[$k].Selected = $true }
            }
            $menu.Show($lv, (New-Object System.Drawing.Point(5, 5)))
            $menu.Close()
            $script:playOut2 = @($menu.Items | Where-Object { "$($_.Text)" -match 'Reproducir el CONVERTIDO' })[0].Enabled
            $script:canStop  = $bSp.Enabled
            $script:canKill  = $bKl.Enabled
            # 'Preparar / editar' tiene que estar disponible SIN seleccionar nada: hay un archivo sin
            # preparar y el boton coge ese (si hiciera falta seleccionar antes, no se encontraria).
            $script:canEdit  = $bEd.Enabled
            $script:logItems = $cmb.Items.Count
            $script:multiSel = $lv.MultiSelect
            # La columna de progreso se estira con la ventana (no se queda en su ancho de partida).
            $script:progW    = $lv.Columns[6].Width
            $script:otherW   = 0
            for ($ci = 0; $ci -lt $lv.Columns.Count; $ci++) { if ($ci -ne 6) { $script:otherW += $lv.Columns[$ci].Width } }
            $script:colNames = (@($lv.Columns | ForEach-Object { "$($_.Text)" }) -join '|')
            $script:clientW  = $lv.ClientSize.Width
            # Pestana de resumen: al marcar una fila con job tiene que salir que se le va a hacer.
            $tabs = $f.Controls.Find('cvTabs', $true)[0]
            $sumBox = $f.Controls.Find('cvSummary', $true)[0]
            $script:tabNames  = (@($tabs.Tag.Texts) -join '|')
            $script:tabActive = "$(@($tabs.Tag.Texts)[[int]$tabs.Tag.Index])"
            # Contar las lineas ya no es un boton (el texto se cortaba segun fuente/DPI): es una
            # opcion del boton derecho SOBRE el resumen, con su linea de ayuda debajo para que se
            # sepa que esta ahi.
            $sumMenu = $sumBox.ContextMenuStrip
            $script:sumMenuItems = (@($sumMenu.Items | ForEach-Object { "$($_.Name)" }) -join '|')
            $script:hasCount  = ($null -ne $sumMenu -and @($sumMenu.Items | Where-Object { "$($_.Name)" -eq 'cvSumCount' }).Count -eq 1)
            $script:hasHint   = ($f.Controls.Find('cvSumHint', $true).Count -eq 1)
            # El divisor: la zona de abajo se puede agrandar arrastrando, y de serie se lleva un
            # buen trozo (antes era un 38% fijo y el resumen se quedaba corto).
            $sp = $f.Controls.Find('cvSplit', $true)[0]
            $script:splitOk   = ($null -ne $sp -and -not $sp.IsSplitterFixed)
            $script:splitFrac = [math]::Round($sp.SplitterDistance / [double]$sp.Height, 2)
            # Y se TIENE que ver: una franja ancha con su agarre pintado (si no, nadie lo descubre).
            $script:splitW    = [int]$sp.SplitterWidth
            foreach ($k in 0..($lv.Items.Count - 1)) { $lv.Items[$k].Selected = ($lv.Items[$k].SubItems[2].Text -eq 'En cola') }
            $f.Controls.Find('cvRefresh', $true)[0].PerformClick()
            $script:sumText = "$($sumBox.Text)"
            # Doble bufer: sin el, el refresco de cada segundo hace parpadear la lista. Se comprueba
            # la propiedad de verdad (es protegida, se lee por reflexion) y no solo que se llamara.
            $dbFlags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
            $script:dblBuf = [bool]([System.Windows.Forms.Control].GetProperty('DoubleBuffered', $dbFlags).GetValue($lv, $null))
            # Los AJUSTES (workers, ver consolas) ya no estan en la barra: viven en la pestana
            # 'Opciones', abajo con el resumen y el log.
            # Opciones: 'si el video recodificado engorda, quedarse con el original'. Es el valor de
            # PARTIDA de los jobs nuevos, asi que se guarda en el config al marcarlo.
            $bKp = @($f.Controls.Find('cvKeepOriginal', $true))
            $script:keepChk = $bKp.Count
            if ($bKp.Count -eq 1) {
                $script:keepAntes    = [bool]$bKp[0].Checked
                $bKp[0].Checked      = $true
                $script:keepGuardado = [bool](Read-CvConfigFile -Path $tmpCfg).encode.video.keepOriginalIfBigger
                $script:keepEnCtx    = [bool]$ctx.KeepOriginal
                $bKp[0].Checked      = $script:keepAntes
            }
            # La ayuda larga se ata al ANCHO DISPONIBLE (parte en varias lineas) en vez de llevar un
            # ancho fijo: con un ancho fijo se cortaba el texto y encima sobraba sitio a la derecha.
            # La pestana Opciones tiene que estar A LA VISTA para medirla: una pagina oculta no se
            # reparte el ancho de la ventana (se queda con el de diseno, 180 px).
            [void](Select-CvGuiTab -Tabs $tabs -Index (@($tabs.Tag.Texts).Count - 1))
            [System.Windows.Forms.Application]::DoEvents()
            $hKp = @($f.Controls.Find('cvKeepHelp', $true))
            if ($hKp.Count -eq 1) {
                $script:keepHelpMax  = [int]$hKp[0].MaximumSize.Width
                $script:keepHelpPan  = [int]$hKp[0].Parent.ClientSize.Width
                $script:keepHelpAlto = [int]$hKp[0].Height
                $script:keepHelpAuto = [bool]$hKp[0].AutoSize
            }
            [void](Select-CvGuiTab -Tabs $tabs -Index 0)   # se deja como estaba
            $script:defWork  = [int]$f.Controls.Find('cvWorkers', $true)[0].Value
            $script:optChk   = @($f.Controls.Find('cvShowConsoles', $true)).Count
            $script:consoleBtn = @($f.Controls.Find('cvPrepare', $true)).Count
            $script:dirBtns = @($f.Controls.Find('cvDirOriginal', $true)).Count + @($f.Controls.Find('cvDirConvertido', $true)).Count
            # Boton de TEMA: cambia claro/oscuro en caliente y lo deja guardado en el config.
            $bTh = @($f.Controls.Find('cvTheme', $true))
            $script:themeBtn = $bTh.Count
            if ($bTh.Count -eq 1) {
                $script:themeAntes = Get-CvGuiThemeName
                $bTh[0].PerformClick()
                $script:themeDespues = Get-CvGuiThemeName
                $script:themeGuardado = "$((Read-CvConfigFile -Path $tmpCfg).gui.theme)"
                # Y lo que de verdad importa: una ventana que se abra AHORA sale con el tema nuevo.
                $fNueva = New-Object System.Windows.Forms.Form
                [void](Set-CvGuiTheme -Form $fNueva)
                $script:themeHereda = ("$((Get-CvGuiPalette -Theme $script:themeDespues).Back)" -eq "$($fNueva.BackColor)")
                $fNueva.Dispose()
                $bTh[0].PerformClick()          # se deja como estaba
            }
            $f.Close()
        } catch {
            $script:guiErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $t.Start()
    $opened = Show-CvConvertWindow -Context $ctx -Root $tmpRoot -CfgPath $tmpCfg -CfgName 'config.json'

    Assert-Eq   'Ventana sin excepciones'   '' $script:guiErr
    Assert-True 'Ventana: se abrio'         $opened
    Assert-Eq   'Ventana: una fila por video' 5 $script:rowCount
    Assert-Eq   'Ventana: una columna por entrada del catalogo' (Get-CvQueueColumns).Count $script:colCount
    Assert-Eq   'Ventana: bordes y audio a la vista' 'Archivo|Tamano|Estado|Bordes|Audio|Worker|Progreso|ETA' $script:colNames
    Assert-Eq   'Ventana: primer archivo'   'Serie_1x01' $script:firstName
    Assert-Eq   'Ventana: estados en orden' 'Hecho,Codificando,En cola,Sin preparar,Bloqueo huerfano' $script:states
    Assert-True 'Ventana: resumen con recuento' ($script:totals -match '5 archivo')
    # REGRESION: la cola sembrada tiene un worker VIVO, asi que 'Iniciar' NO puede estar disponible
    # (antes lo estaba y cada pulsacion abria otro grupo de workers).
    Assert-Eq   'Ventana: Iniciar apagado con workers vivos' $false $script:canStart
    Assert-Eq   'Ventana: Iniciar sin seleccion'    'Iniciar' $script:startText
    # Opciones: la casilla del video original esta, arranca con lo que diga el config y al marcarla
    # se guarda (los jobs que se preparen despues nacen con ese valor).
    Assert-Eq   'Opciones: casilla del video original' 1 $script:keepChk
    Assert-Eq   'Opciones: arranca como el config'     $false $script:keepAntes
    Assert-True 'Opciones: al marcarla se guarda'      $script:keepGuardado
    Assert-True 'Opciones: y la ventana ya lo sabe'    $script:keepEnCtx
    Assert-True 'Opciones: la ayuda se ata al ancho disponible' ($script:keepHelpMax -gt 400 -and $script:keepHelpMax -le $script:keepHelpPan)
    Assert-True 'Opciones: y crece a lo alto lo que haga falta' ($script:keepHelpAuto -and $script:keepHelpAlto -gt 14)
    Assert-Eq   'Ventana: Iniciar con 1 elegido'    'Iniciar (1 elegidos)' $script:startTextSel
    Assert-True 'Menu: ofrece codificar lo elegido' ($script:menuItems -match 'Codificar solo este')
    Assert-True 'Menu: ofrece cortar solo esta codificacion' ($script:menuItems -match 'Cortar la codificacion')
    Assert-True 'Menu: ofrece ver el proceso' ($script:menuItems -match 'Ver el proceso|Ver lo que esta haciendo')
    Assert-True 'Ventana: botones de carpeta' ($script:dirBtns -eq 2)
    Assert-Eq   'Ventana: hay boton de tema'     1 $script:themeBtn
    Assert-True 'Tema: el boton lo cambia'       ($script:themeAntes -ne $script:themeDespues)
    Assert-Eq   'Tema: y lo guarda en el config' $script:themeDespues $script:themeGuardado
    Assert-True 'Tema: las ventanas que se abran despues lo usan' $script:themeHereda
    Assert-Eq   'Menu: Codificar solo estos, apagado con workers vivos' $false $script:menuStart
    Assert-True 'Menu: sigue con lo demas'          ($script:menuItems -match 'Quitar de la cola' -and $script:menuItems -match 'Liberar el bloqueo')
    Assert-True 'Menu: ofrece reproducir el original'   ($script:menuItems -match 'Reproducir el ORIGINAL')
    Assert-True 'Menu: ofrece reproducir el convertido' ($script:menuItems -match 'Reproducir el CONVERTIDO')
    Assert-Eq   'Menu: el original siempre se puede ver' $true  $script:playIn1
    Assert-Eq   'Menu: sin salida, no hay convertido'    $false $script:playOut1
    Assert-Eq   'Menu: con el archivo hecho, si'         $true  $script:playOut2
    Assert-True 'Ventana: Parar activo (hay worker)' $script:canStop
    Assert-True 'Ventana: Cancelar activo'           $script:canKill
    Assert-True 'Ventana: Preparar/editar activo sin seleccion' $script:canEdit
    Assert-True 'Ventana: lista logs de Convert'     ($script:logItems -ge 1)
    Assert-True 'Ventana: se pueden marcar varias filas' $script:multiSel
    Assert-True 'Ventana: la lista va con doble bufer (no parpadea)' $script:dblBuf
    # Con 8 columnas, lo que se comprueba es que la de progreso se queda con lo que sobra y nunca
    # por debajo de su minimo (el reparto exacto lo fija el caso siguiente).
    Assert-True 'Ventana: progreso no baja del minimo' ($script:progW -ge 220)
    Assert-Eq   'Ventana: pestanas en orden' 'Resumen del archivo|Log|Opciones' $script:tabNames
    Assert-Eq   'Ventana: arranca en el resumen'  'Resumen del archivo' $script:tabActive
    Assert-True 'Ventana: ofrece contar las lineas' $script:hasCount
    Assert-True 'Ventana: el divisor se puede arrastrar' $script:splitOk
    Assert-True 'Ventana: el resumen se lleva ~la mitad' ($script:splitFrac -ge 0.35 -and $script:splitFrac -le 0.7)
    Assert-True 'Ventana: el resumen se rellena'  ($script:sumText -match 'ARCHIVO :')
    Assert-Eq   'Ventana: progreso ocupa lo que sobra' (Get-CvQueueProgressWidth -ClientWidth $script:clientW -OtherWidths $script:otherW) $script:progW
    Assert-Eq   'Ventana: workers por defecto de config' 2 $script:defWork
    Assert-Eq   'Ventana: los ajustes siguen ahi' 1 $script:optChk
    # 'En consola' se quito: la ventana ya hace TODO lo que hacia esa via (incluida la deteccion de
    # audio adelantado), asi que el boton solo confundia.
    Assert-Eq   'Ventana: ya no hay boton de consola' 0 $script:consoleBtn
    Assert-True 'Ventana: el divisor se ve (franja ancha)' ($script:splitW -ge 8)
    Assert-True 'Ventana: el resumen lleva menu contextual' ($script:sumMenuItems -match 'cvSumCount')
    Assert-True 'Ventana: y deja copiarlo'                 ($script:sumMenuItems -match 'cvSumCopy')
    Assert-True 'Ventana: anuncia el boton derecho'        $script:hasHint

    # --------------------------------------------------------------------------------------------
    # Al cerrar se apunta como quedo (config gui.rememberLayout) y al volver a abrir se aplica: es
    # lo que evita recolocar la ventana y el divisor en cada arranque.
    $laySaved = Get-CvGuiLayout -Context $ctx -Key 'cola'
    Assert-True 'Ventana: al cerrar apunta como quedo' ($null -ne $laySaved -and [int]$laySaved.width -gt 0 -and [int]$laySaved.split -gt 0)
    Assert-Eq   'Ventana: apunta las 8 columnas' 8 (@($laySaved.cols).Count)

    [void](Save-CvGuiLayout -Context $ctx -Key 'cola' -Layout ([ordered]@{
        width     = 1000
        height    = 700
        maximized = $false
        split     = 300
        cols      = @(400, 90, 130, 55, 150, 70, 300, 80)
    }))
    $script:guiErr2 = ''
    $t2 = New-Object System.Windows.Forms.Timer
    $t2.Interval = 300
    $script:reWaits = 0
    $t2.Add_Tick({
        # Igual que arriba: se espera a que la ventana este montada (ver el comentario del primer
        # temporizador), no se da por hecho que a los X ms ya lo este.
        $fs2 = @([System.Windows.Forms.Application]::OpenForms)
        $sp2 = $(if ($fs2.Count -gt 0) { @($fs2[0].Controls.Find('cvSplit', $true)) } else { @() })
        if ($sp2.Count -eq 0) {
            $script:reWaits++
            if ($script:reWaits -gt 60) { $t2.Stop(); $script:guiErr2 = 'la ventana no llego a montarse'; $fs2 | ForEach-Object { $_.Close() } }
            return
        }
        $t2.Stop()
        try {
            $f2 = @([System.Windows.Forms.Application]::OpenForms)[0]
            $script:reW     = [int]$f2.Width
            $script:reH     = [int]$f2.Height
            $script:reSplit = [int]$f2.Controls.Find('cvSplit', $true)[0].SplitterDistance
            $script:reCol0  = [int]$f2.Controls.Find('cvQueue', $true)[0].Columns[0].Width
            $f2.Close()
        } catch {
            $script:guiErr2 = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $t2.Start()
    [void](Show-CvConvertWindow -Context $ctx -Root $tmpRoot -CfgPath $tmpCfg -CfgName 'config.json')
    Assert-Eq   'Reapertura sin excepciones'     '' $script:guiErr2
    Assert-Eq   'Reapertura: mismo tamano'       '1000|700' (@($script:reW, $script:reH) -join '|')
    Assert-Eq   'Reapertura: mismo divisor'      300 $script:reSplit
    Assert-Eq   'Reapertura: mismos anchos de columna' 400 $script:reCol0

    # --------------------------------------------------------------------------------------------
    # Cerrar con workers vivos PREGUNTA (gui.confirmCloseWithWorkers). La cola sembrada tiene un
    # worker vivo -este proceso-, asi que al pedir el cierre sale el dialogo; un temporizador que se
    # repite lo busca por su .Name y pulsa 'Dejarlos en segundo plano'. Es la excepcion a la regla de
    # "nada modal en la bateria", y lleva contador: a los ~5 s se sale por las bravas antes que
    # dejarla colgada.
    $cfgAsk = Join-Path $tmpRoot 'config.ask.json'
    Set-Content -Path $cfgAsk -Value '{ "behavior": { "workers": 2 }, "gui": { "confirmCloseWithWorkers": true } }' -Encoding UTF8
    $ctxAsk = New-CvContext -Root $tmpRoot -ConfigPath $cfgAsk
    $script:askSaw = $false
    $script:askBtn = 0
    $script:askTry = 0
    $t3 = New-Object System.Windows.Forms.Timer
    $t3.Interval = 500
    $t3.Add_Tick({
        $script:askTry++
        $dlg = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cvCloseAsk' })
        if ($dlg.Count -gt 0) {
            $script:askSaw = $true
            $b = @($dlg[0].Controls.Find('cvCloseAsk_background', $true))
            $script:askBtn = @($dlg[0].Controls.Find('cvCloseAsk_kill', $true)).Count + $b.Count
            if ($b.Count -gt 0) { $t3.Stop(); $b[0].PerformClick(); return }
        }
        if ($script:askTry -gt 10) { $t3.Stop(); [System.Windows.Forms.Application]::Exit(); return }
        if ($dlg.Count -eq 0) {
            $main = @([System.Windows.Forms.Application]::OpenForms)
            if ($main.Count -gt 0) { $main[0].Close() }
        }
    })
    $t3.Start()
    [void](Show-CvConvertWindow -Context $ctxAsk -Root $tmpRoot -CfgPath $cfgAsk -CfgName 'config.ask.json')
    Assert-True 'Cierre: con workers vivos pregunta'  $script:askSaw
    Assert-Eq   'Cierre: el dialogo trae sus botones' 2 $script:askBtn
}

# ================================================================================================
# LA VENTANA DEL LOG DE UN WORKER, abierta de verdad. Es MODAL (como el resto de dialogos), asi que
# la bateria la cierra desde un temporizador, igual que hace con el dialogo del perfil.
Write-Host "`nGuiConvert - ventana del log (en marcha y ya terminado)" -ForegroundColor Cyan
if (-not $sta) {
    Write-Skip 'Ventana del log de worker' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Ventana del log de worker' 'sin entorno grafico'
} else {
    $logW = Join-Path $ctx.Logs 'Convert_20260919_121212_4321.log'
    Set-Content -Path $logW -Encoding UTF8 -Value @(
        '[WORKER] CODIFICANDO: Serie_1x02'
        '   [VIDEO] - Una sola pasada (video+audio)...'
        '   [OK] - hecho'
    )
    $script:wlErr = ''
    $script:wlTry = 0
    $script:wlTxt = ''
    $script:wlHead = ''
    $tl = New-Object System.Windows.Forms.Timer
    $tl.Interval = 300
    $tl.Add_Tick({
        $script:wlTry++
        try {
            $w = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cvWorkerLog' })
            if ($w.Count -eq 0) {
                if ($script:wlTry -gt 40) { $tl.Stop(); $script:wlErr = 'no se abrio la ventana' }
                return
            }
            $tl.Stop()
            $script:wlTxt  = "$($w[0].Controls.Find('cvWlText', $true)[0].Text)"
            $script:wlHead = "$($w[0].Controls.Find('cvWlHead', $true)[0].Text)"
            $w[0].Close()
        } catch {
            $tl.Stop()
            $script:wlErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    # --- Modo EN MARCHA: sigue el log del worker vivo (el de este proceso). La ventana usa el log
    # que publica el PROPIO worker en su estado (no el que se le pase), asi que se apunta ahi.
    Start-CvWorkerState -Context $ctx -Role 'worker' -LogPath $logW
    Set-CvWorkerFile -Context $ctx -File 'Serie_1x02'
    $tl.Start()
    [void](Show-CvWorkerLogWindow -Context $ctx -WorkerPid $PID -LogPath $logW -File 'Serie_1x02')
    Assert-Eq   'Log worker: sin excepciones' '' $script:wlErr
    Assert-True 'Log worker: ensena el log'   ($script:wlTxt -match 'Una sola pasada')
    Assert-True 'Log worker: dice de quien es' ($script:wlHead -match "#$PID")

    # --- Modo YA TERMINADO: se le pasa el tramo encontrado en los logs y no sigue nada.
    $hit = Find-CvFileLog -Context $ctx -Name 'Serie_1x02'
    Assert-True 'Log terminado: lo encuentra en logs' ([bool]$hit.Found)
    Assert-True 'Log terminado: es su tramo'          ($hit.Text -match 'Una sola pasada')
    $script:wlTry = 0
    $script:wlErr = ''
    $tl.Start()
    [void](Show-CvWorkerLogWindow -Context $ctx -File 'Serie_1x02' -LogPath $hit.Path -Text $hit.Text)
    Assert-Eq   'Log terminado: sin excepciones' '' $script:wlErr
    Assert-True 'Log terminado: ensena el tramo' ($script:wlTxt -match 'Una sola pasada')
    Assert-True 'Log terminado: lo dice en la cabecera' ($script:wlHead -match 'Asi quedo')
    Remove-Item -LiteralPath $logW -Force -ErrorAction SilentlyContinue
}

# ================================================================================================
Write-Host "`nBordes de un archivo YA CONVERTIDO (necesita ffmpeg)" -ForegroundColor Cyan
# Un archivo hecho no tiene job, asi que la columna 'Bordes' solo puede salir de comparar el original
# con la salida. Se monta de verdad: se copia una fixture como origen y se genera la salida con
# ffmpeg RECORTANDOLE las barras; la cola tiene que decir '[x]'.
$toolsB = Connect-Tools -Dir (Join-Path $tmpRoot 'tools') -Target (Join-Path $Root 'tools')
$ctxB = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg   # recontextualiza con tools\ ya enlazado
$fixB = Join-Path $Root 'test\video-1080p-basico.mp4'
if (-not ($toolsB -and (Test-Path -LiteralPath $fixB) -and (Test-Path -LiteralPath "$($ctxB.FFmpeg)"))) {
    Write-Skip 'Bordes de un convertido' 'sin ffmpeg instalado o sin la fixture'
} else {
    # 'Serie_3x01': se le quitaron barras (1920x1080 -> 1920x800). 'Serie_3x02': misma proporcion.
    Copy-Item -LiteralPath $fixB -Destination (Join-Path $ctxB.Original 'Serie_3x01.mp4') -Force
    Copy-Item -LiteralPath $fixB -Destination (Join-Path $ctxB.Original 'Serie_3x02.mp4') -Force
    $outCrop = Join-Path $ctxB.Convertido ("Serie_3x01_fix.{0}" -f $ctxB.OutExt)
    $outIgual = Join-Path $ctxB.Convertido ("Serie_3x02_fix.{0}" -f $ctxB.OutExt)
    & "$($ctxB.FFmpeg)" -v quiet -y -i $fixB -t 1 -vf 'crop=1920:800' -c:v libx264 -preset ultrafast -an $outCrop 2>&1 | Out-Null
    & "$($ctxB.FFmpeg)" -v quiet -y -i $fixB -t 1 -c:v libx264 -preset ultrafast -an $outIgual 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $outCrop) -or -not (Test-Path -LiteralPath $outIgual)) {
        Write-Skip 'Bordes de un convertido' 'ffmpeg no pudo generar las salidas'
    } else {
        # Con presupuesto 0 no se analiza nada: la celda se queda como estaba (en blanco).
        $sin = @(Get-CvQueueStatus -Context $ctxB -DoneProbe 0) | Where-Object { $_.Name -eq 'Serie_3x01' }
        Assert-Eq   'Bordes hechos: sin presupuesto no se deduce' '' "$($sin.BorderGuess)"
        # La regla de cuando se puede analizar: con la cola en marcha, nunca.
        Assert-Eq   'Bordes hechos: con workers no se analiza' 0 (Get-CvQueueDoneProbeBudget -Configured 2 -LiveWorkers 1)
        Assert-Eq   'Bordes hechos: parada, lo que diga el config' 2 (Get-CvQueueDoneProbeBudget -Configured 2 -LiveWorkers 0)
        Assert-Eq   'Bordes hechos: desactivado es desactivado' 0 (Get-CvQueueDoneProbeBudget -Configured 0 -LiveWorkers 0)
        # Con presupuesto, se analizan (dos por vuelta, asi que se dan las vueltas que hagan falta).
        $fin = $null
        for ($v = 0; $v -lt 6; $v++) {
            $rr = @(Get-CvQueueStatus -Context $ctxB -DoneProbe 2)
            $fin = @{
                Crop  = "$((@($rr | Where-Object { $_.Name -eq 'Serie_3x01' })[0]).BorderGuess)"
                Igual = "$((@($rr | Where-Object { $_.Name -eq 'Serie_3x02' })[0]).BorderGuess)"
            }
            if ($fin.Crop -ne '' -and $fin.Igual -ne '') { break }
        }
        Assert-Eq   'Bordes hechos: al recortado le sale [x]'  '[x]' $fin.Crop
        Assert-Eq   'Bordes hechos: al que no, [ ]'            '[ ]' $fin.Igual
        # La cache SOBREVIVE al cierre: se guarda, se vacia la de memoria y tiene que volver del
        # fichero sin sondar nada (con presupuesto 0).
        Assert-True 'Bordes hechos: se guardan en disco' ((Save-CvDoneBorderCache -Context $ctxB) -ge 2)
        [void](Clear-CvDoneBorderCache)
        $traCero = @(Get-CvQueueStatus -Context $ctxB -DoneProbe 0) | Where-Object { $_.Name -eq 'Serie_3x01' }
        Assert-Eq   'Bordes hechos: vaciada la memoria, no hay nada' '' "$($traCero.BorderGuess)"
        [void](Import-CvDoneBorderCache -Context $ctxB)
        $traDisco = @(Get-CvQueueStatus -Context $ctxB -DoneProbe 0) | Where-Object { $_.Name -eq 'Serie_3x01' }
        Assert-Eq   'Bordes hechos: vuelve del disco sin sondar' '[x]' "$($traDisco.BorderGuess)"
        # Y al guardar se tira lo que ya no existe (aqui, la salida borrada).
        $antes = @(Get-CvGuiLayout -Context $ctxB -Key 'colaBordes').Count
        Remove-Item -LiteralPath $outIgual -Force
        [void](Save-CvDoneBorderCache -Context $ctxB)
        $despues = @(Get-CvGuiLayout -Context $ctxB -Key 'colaBordes').Count
        Assert-Eq   'Bordes hechos: la cache se limpia sola' ($antes - 1) $despues
        & "$($ctxB.FFmpeg)" -v quiet -y -i $fixB -t 1 -c:v libx264 -preset ultrafast -an $outIgual 2>&1 | Out-Null
        # Y la fila ya formateada lo ensena en su columna.
        $filaC = @(Format-CvQueueRow -Row (@(Get-CvQueueStatus -Context $ctxB -DoneProbe 0) | Where-Object { $_.Name -eq 'Serie_3x01' })[0])
        Assert-Eq   'Bordes hechos: en la columna de la lista' '[x]' $filaC[3]
        # Lo analizado se CACHEA: una segunda vuelta no vuelve a lanzar ffprobe (y por eso sale
        # relleno aunque el presupuesto sea 0).
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        [void](@(Get-CvQueueStatus -Context $ctxB -DoneProbe 2))
        $t0.Stop()
        Assert-True 'Bordes hechos: la segunda vuelta no re-analiza' ($t0.ElapsedMilliseconds -lt 900)
    }
    Remove-Item -LiteralPath (Join-Path $ctxB.Original 'Serie_3x01.mp4') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ctxB.Original 'Serie_3x02.mp4') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outCrop -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outIgual -Force -ErrorAction SilentlyContinue
}

# ================================================================================================
Write-Host "`nJobCore + editor de jobs (necesita ffprobe)" -ForegroundColor Cyan
# Estos casos trabajan con un video DE VERDAD (una fixture del repo), asi que necesitan las
# herramientas: se enlaza tools\ del proyecto en el root temporal. Sin ffprobe se saltan.
$fixture = Join-Path $Root 'test\audio-y-subs-multiidioma.mkv'
$toolsOk = $(if ($toolsB) { $true } else { Connect-Tools -Dir (Join-Path $tmpRoot 'tools') -Target (Join-Path $Root 'tools') })
$ctxJob = New-CvContext -Root $tmpRoot -ConfigPath $tmpCfg      # recontextualiza con tools\ ya enlazado
$jobInfo = $null
$jobFile = ''
if ($toolsOk -and (Test-Path -LiteralPath $fixture) -and (Test-Path -LiteralPath "$($ctxJob.FFprobe)")) {
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $ctxJob.Original 'Serie_2x01.mkv') -Force
    $jobFile = Join-Path $ctxJob.Original 'Serie_2x01.mkv'
    $jobInfo = Get-MediaInfo -Context $ctxJob -File $jobFile
}
if ($null -eq $jobInfo) {
    Write-Skip 'JobCore y editor de jobs' 'sin ffprobe instalado o sin la fixture'
} else {
    # --- Opciones que se ofrecen (salen de las mismas funciones que decide la consola) ---
    $vOpts = @(Get-CvJobVideoOptions    -Context $ctxJob -Info $jobInfo)
    $aOpts = @(Get-CvJobAudioOptions    -Context $ctxJob -Info $jobInfo)
    $sOpts = @(Get-CvJobSubtitleOptions -Context $ctxJob -Info $jobInfo)
    Assert-Eq   'Video: una pista'          1 $vOpts.Count
    Assert-True 'Video: la primera es la auto' $vOpts[0].Auto
    Assert-Eq   'Audio: tres pistas'        3 $aOpts.Count
    Assert-Eq   'Audio: una preferida (spa)' 1 @($aOpts | Where-Object { $_.Preferred }).Count
    Assert-Eq   'Audio: una auto'           1 @($aOpts | Where-Object { $_.Auto }).Count
    Assert-Eq   'Audio: la auto es la spa'  'spa' (@($aOpts | Where-Object { $_.Auto })[0].Lang)
    Assert-Eq   'Audio: posiciones 0..N'    '0,1,2' ((@($aOpts | ForEach-Object { $_.Pos })) -join ',')
    Assert-Eq   'Subs: cuatro pistas'       4 $sOpts.Count
    # Posicion 0-based entre las de SUBTITULO: es lo que necesita ffplay para reproducir con una
    # concreta ('-sst s:N'), la unica forma de ver un subtitulo de IMAGEN (PGS), que no tiene texto.
    Assert-Eq   'Subs: posiciones 0..N'     '0,1,2,3' ((@($sOpts | ForEach-Object { $_.Pos })) -join ',')
    Assert-True 'Subs: los subrip son texto' (@($sOpts | Where-Object { -not $_.IsText }).Count -eq 0)
    Assert-Eq   'Subs: dos se conservarian' 2 @($sOpts | Where-Object { $_.Auto }).Count
    Assert-Eq   'Subs: uno es el forzado'   1 @($sOpts | Where-Object { $_.AutoForced }).Count
    Assert-True 'Subs: el forzado es el corto' ((@($sOpts | Where-Object { $_.AutoForced })[0].Cues) -lt (@($sOpts | Where-Object { $_.Auto -and -not $_.AutoForced })[0].Cues))

    # --- Borrador automatico (lo que se elegiria solo, sin preguntar ni escanear) ---
    $prof  = New-CvProfile -VideoEncoder 'libx265' -Crf 30 -AudioEncoder 'aac_coder' -AudioBitrate '128k'
    $draft = New-CvJobDraft -Context $ctxJob -Prof $prof -Info $jobInfo -File $jobFile
    Assert-Eq   'Borrador: nombre'        'Serie_2x01' $draft.Name
    Assert-Eq   'Borrador: no es copy'    $false $draft.VideoSkip
    Assert-Eq   'Borrador: una pista de audio' 1 @($draft.Audio).Count
    Assert-Eq   'Borrador: audio spa'     'spa' $draft.Audio[0].Lang
    Assert-True 'Borrador: audio predeterminado' $draft.Audio[0].Default
    Assert-Eq   'Borrador: dos subtitulos' 2 @($draft.Subtitles).Count
    Assert-True 'Borrador: el forzado va primero' $draft.Subtitles[0].Forced
    Assert-True 'Borrador: valido'        (Test-CvJobDraft -Draft $draft).Ok

    # --- Filas de las tablas (puro: cruzar opciones con lo elegido) ---
    $aRows = @(Get-CvJobAudioRows -Options $aOpts -Tracks $draft.Audio)
    Assert-Eq   'Filas audio: una por pista' 3 $aRows.Count
    Assert-Eq   'Filas audio: una marcada'   1 @($aRows | Where-Object { $_.Keep }).Count
    Assert-Eq   'Filas audio: la marcada es la predeterminada' 1 @($aRows | Where-Object { $_.Default }).Count
    $sRows = @(Get-CvJobSubRows -Options $sOpts -Selected $draft.Subtitles)
    Assert-Eq   'Filas subs: una por pista'  4 $sRows.Count
    Assert-Eq   'Filas subs: dos marcadas'   2 @($sRows | Where-Object { $_.Keep }).Count

    # Marcar una segunda pista de audio y hacerla predeterminada: la predeterminada va PRIMERO.
    $eng = @($aRows | Where-Object { $_.Lang -eq 'eng' })[0]
    $eng.Keep = $true
    $eng.Default = $true
    foreach ($r in @($aRows | Where-Object { $_.Lang -ne 'eng' })) { $r.Default = $false }
    $d2 = ConvertTo-CvJobDraftFromRows -Draft $draft -AudioRows $aRows -SubRows $sRows
    Assert-Eq   'Rehecho: dos pistas de audio' 2 @($d2.Audio).Count
    Assert-Eq   'Rehecho: la predeterminada va primero' 'eng' $d2.Audio[0].Lang
    Assert-True 'Rehecho: solo una predeterminada' (@($d2.Audio | Where-Object { $_.Default }).Count -eq 1)
    Assert-True 'Rehecho: sigue siendo valido'     (Test-CvJobDraft -Draft $d2).Ok

    # --- Guardar y releer: el job escrito tiene la forma de siempre ---
    $recJob = Save-CvJobDraft -Context $ctxJob -Draft $d2 -Info $jobInfo
    Assert-True 'Guardado: existe el .job.json' (Test-CvJob -Context $ctxJob -Name 'Serie_2x01')
    Assert-Eq   'Guardado: claves' 'file|profile|ffmpegVersion|aacgainVersion|video|audio|subtitles|subtitleCues' (@($recJob.Keys) -join '|')
    $reread = Read-CvJobDraft -Context $ctxJob -Name 'Serie_2x01'
    Assert-Eq   'Releido: dos pistas'  2 @($reread.Audio).Count
    Assert-Eq   'Releido: idioma de la primera' 'eng' $reread.Audio[0].Lang
    Assert-Eq   'Releido: dos subtitulos' 2 @($reread.Subtitles).Count
    Assert-Eq   'Releido: encoder del perfil' 'libx265' "$($reread.Prof.VideoEncoder)"
    # Y la cola lo ve ya como preparado (es el efecto que se busca al prepararlo desde la ventana).
    $rowJob = @(Get-CvQueueStatus -Context $ctxJob) | Where-Object { $_.Name -eq 'Serie_2x01' }
    Assert-Eq   'La cola lo ve en cola' 'queued' $rowJob.State
    Remove-CvJob -Context $ctxJob -Name 'Serie_2x01'

    # --- AUTODISCOVER: lo que la consola resolveria sola y lo que preguntaria ---
    # Perfil que copia el video: sin recodificar no hay deteccion de bordes, asi que el plan sale al
    # instante y es determinista (el caso 'todo automatico').
    $profCopy = New-CvProfile -VideoEncoder 'copy' -AudioEncoder 'copy'
    $planAuto = Get-CvJobAutoPlan -Context $ctxJob -Prof $profCopy -Info $jobInfo -File $jobFile
    Assert-Eq   'Plan: no necesita intervencion' $false $planAuto.Manual
    Assert-Eq   'Plan: sin motivos'          0     @($planAuto.Reasons).Count
    Assert-True 'Plan: trae borrador'        ($null -ne $planAuto.Draft)
    Assert-Eq   'Plan: sin recorte'          ''    "$($planAuto.Draft.Crop)"
    # Los pasos se publican para que la UI diga por donde va (si no, parece colgada).
    $script:steps = @()
    [void](Get-CvJobAutoPlan -Context $ctxJob -Prof $profCopy -Info $jobInfo -File $jobFile -OnStep { param($t) $script:steps += $t })
    Assert-True 'Plan: informa de los pasos'  (@($script:steps).Count -ge 1)

    # Un archivo con DOS pistas en el idioma preferido: eso la consola lo pregunta, y aqui se anota.
    $fx2 = Join-Path $Root 'test\audio-espanol-estereo-y-51.mkv'
    if (Test-Path -LiteralPath $fx2) {
        Copy-Item -LiteralPath $fx2 -Destination (Join-Path $ctxJob.Original 'Serie_2x02.mkv') -Force
        $info2 = Get-MediaInfo -Context $ctxJob -File (Join-Path $ctxJob.Original 'Serie_2x02.mkv')
        $plan2 = Get-CvJobAutoPlan -Context $ctxJob -Prof $profCopy -Info $info2 -File (Join-Path $ctxJob.Original 'Serie_2x02.mkv')
        Assert-True 'Plan: varias pistas del idioma -> preguntar' $plan2.Manual
        Assert-True 'Plan: lo explica'  ((@($plan2.Reasons) -join ' ') -match 'idioma preferido')
    } else {
        Write-Skip 'Plan con varias pistas del idioma' 'falta la fixture'
    }

    # --- RESUMEN de lo que se le va a hacer al archivo (sale del job, instantaneo) ---
    [void](Save-CvJobDraft -Context $ctxJob -Draft $d2 -Info $jobInfo)
    $sum = @(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01')
    $sumTxt = ($sum -join "`n")
    Assert-True 'Resumen: nombra el archivo'    ($sumTxt -match 'ARCHIVO : Serie_2x01')
    Assert-True 'Resumen: dice el perfil'       ($sumTxt -match 'PERFIL  :')
    Assert-True 'Resumen: dice que hace el video' ($sumTxt -match 'VIDEO   :')
    Assert-True 'Resumen: cuenta las pistas de audio' ($sumTxt -match 'AUDIO   : 2 pista')
    # El '*' delante del [x] es lo que marca la pista PREDETERMINADA (antes era una palabra al final).
    Assert-True 'Resumen: marca la predeterminada'    ($sumTxt -match '\*\[x\] \[\d+\] eng')
    Assert-True 'Resumen: la default ya no es texto'  (-not ($sumTxt -match 'PREDETERMINAD'))
    Assert-True 'Resumen: lista los subtitulos' ($sumTxt -match 'SUBS    : 2')
    Assert-True 'Resumen: dice cual es forzado' ($sumTxt -match 'forzado')
    Assert-True 'Resumen: no repite la ruta de salida' (-not ($sumTxt -match 'SALIDA'))
    # Con -Info se ensenan TODAS las pistas del archivo, marcando las que se conservan y las que no,
    # y se anaden canales y numero de lineas (del tag, sin demultiplexar).
    $sumInfo = (@(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01' -Info $jobInfo) -join "`n")
    Assert-True 'Resumen: con Info da canales'  ($sumInfo -match '\dch')
    Assert-True 'Resumen: cuenta todas las de audio' ($sumInfo -match 'AUDIO   : 3 pista\(s\) en el archivo, se conservan 2')
    Assert-True 'Resumen: cuenta todos los subs'     ($sumInfo -match 'SUBS    : 4 pista\(s\) en el archivo, se conservan 2')
    Assert-Eq   'Resumen: marca 2 audios como conservados' 2 (@(($sumInfo -split "`n") | Where-Object { $_ -match '^\s+\*?\[x\] \[\d+\] (spa|eng|fra)\s+\dch' }).Count)
    Assert-Eq   'Resumen: y 1 descartado'                 1 (@(($sumInfo -split "`n") | Where-Object { $_ -match '^\s+\[ \] \[\d+\] (spa|eng|fra)\s+\dch' }).Count)
    Assert-True 'Resumen: dice cual es forzado en origen'  ($sumInfo -match 'forzado en origen')
    # Informacion del ORIGEN (resolucion, codec, bits, fps, duracion) y calidad de cada pista de audio.
    # El video se pinta como el audio y los subtitulos: cabecera + una linea por pista del archivo.
    Assert-True 'Resumen: cuenta las de video'  ($sumInfo -match 'VIDEO   : \d+ pista\(s\) en el archivo')
    Assert-True 'Resumen: describe el origen'   ($sumInfo -match '\*\[x\] \[\d+\] \d+x\d+')
    Assert-True 'Resumen: dice los fps'         ($sumInfo -match 'fps')
    Assert-True 'Resumen: dice la duracion'     ($sumInfo -match 'dura \d')
    Assert-True 'Resumen: audio con frecuencia' ($sumInfo -match 'kHz')
    Assert-True 'Resumen: audio con canales'    ($sumInfo -match 'stereo|mono|5\.1')
    # La version de ffmpeg ya no se ensena: sobra para decidir que hacer con el archivo.
    Assert-Eq   'Resumen: sin linea de ffmpeg'  $false ($sumInfo -match 'FFMPEG')
    # Y las lineas de las pistas DESCARTADAS tambien salen (el job las guarda todas).
    $dTodas = New-CvJobDraft -Context $ctxJob -Prof $profCopy -Info $jobInfo -File $jobFile
    [void](Save-CvJobDraft -Context $ctxJob -Draft $dTodas -Info $jobInfo)
    $sumTodas = (@(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01' -Info $jobInfo) -join "`n")
    Assert-True 'Resumen: lineas tambien en las descartadas' (@(($sumTodas -split "`n") | Where-Object { $_ -match '^\s+\[ \] .*\d+ lineas' }).Count -ge 1)
    # El nº de LINEAS: el job preparado por la ventana ya lo trae contado (la tabla del editor lo
    # necesita), asi que el resumen lo ensena sin volver a leer el fichero -que es lo lento-.
    $dCues = New-CvJobDraft -Context $ctxJob -Prof $profCopy -Info $jobInfo -File $jobFile
    [void](Save-CvJobDraft -Context $ctxJob -Draft $dCues -Info $jobInfo)
    $jobCues = Read-CvJob -Context $ctxJob -Name 'Serie_2x01'
    Assert-True 'Job: guarda las lineas de cada subtitulo' (@($jobCues.subtitles | Where-Object { [int]$_.Cues -gt 0 }).Count -ge 1)
    Assert-True 'Resumen: ensena las lineas del job'       ((@(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01' -Info $jobInfo) -join ' ') -match '\d+ lineas')
    # Y un recuento pasado a mano manda sobre todo lo demas.
    $conMano = (@(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01' -Info $jobInfo -CueCounts @{ 4 = 4242 }) -join ' ')
    Assert-True 'Resumen: respeta el recuento dado'        ($conMano -match '4242 lineas')
    # El nº de lineas sale del JOB (el editor ya lo conto para su tabla) o del tag NUMBER_OF_FRAMES;
    # nunca se demultiplexa aqui para averiguarlo. Este job viene del editor, asi que lo trae.
    Assert-True 'Resumen: ensena las lineas'          ($sumInfo -match '\d+ lineas')
    # Y con un job que NO las trae (el camino de consola no las guarda) y sin tag, no se inventa nada.
    $sinCues = @($sOpts | Where-Object { $_.Auto } | ForEach-Object { ConvertTo-SubSel $_.Stream -Forced $false -Default $false -Action $_.Action })
    $recSin = ConvertTo-CvJobRecord -Context $ctxJob -File $jobFile -Prof $profCopy -Info $jobInfo -VideoIndex 0 -Subtitles $sinCues `
        -AudioTracks @([pscustomobject]@{ Index = 1; Is51 = $false; Sync = 0; Lang = 'spa'; Default = $true })
    Write-CvJob -Context $ctxJob -Name 'Serie_2x01' -Job $recSin
    Assert-Eq   'Resumen: sin recuento no inventa'    $false ((@(Get-CvJobSummaryLines -Context $ctxJob -Name 'Serie_2x01' -Info $jobInfo) -join ' ') -match '\d+ lineas')
    # Sin job, lo dice y no revienta.
    Assert-True 'Resumen: sin job lo explica'   ((@(Get-CvJobSummaryLines -Context $ctxJob -Name 'no-existe') -join ' ') -match 'Sin preparar')
    Remove-CvJob -Context $ctxJob -Name 'Serie_2x01'

    # --- La VENTANA del editor, dirigida sin raton ---
    if (-not $sta) {
        Write-Skip 'Ventana del editor de jobs' 'el host no es STA (usa -Sta)'
    } elseif (-not (Initialize-CvGui)) {
        Write-Skip 'Ventana del editor de jobs' 'sin entorno grafico'
    } else {
        $tj = New-Object System.Windows.Forms.Timer
        # La ventana se abre ANTES de analizar (para que no parezca colgada), asi que hay que ESPERAR
        # a que este lista en vez de actuar a ciegas tras un tiempo fijo: se sondea hasta que la tabla
        # de audio tiene filas. Sin esto, la bateria tocaba una ventana todavia vacia.
        $tj.Interval = 300
        $script:jobErr = ''
        $script:jobWaits = 0
        $script:jobAskedProfile = $false
        $tj.Add_Tick({
            try {
                $f    = @([System.Windows.Forms.Application]::OpenForms)[0]
                # Job NUEVO: primero sale el dialogo del PERFIL (no se elige por nuestra cuenta).
                $pl = $f.Controls.Find('cvProfList', $true)
                if ($pl.Count -gt 0) {
                    $script:jobAskedProfile = $true
                    $pl[0].SelectedIndex = 0          # el primero del catalogo (copy): rapido y estable
                    $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
                    return
                }
                $lvChk = $f.Controls.Find('cvJobAudio', $true)[0]
                if ($null -eq $lvChk -or $lvChk.Items.Count -eq 0) {
                    $script:jobWaits++
                    if ($script:jobWaits -gt 100) { $tj.Stop(); $script:jobErr = 'la ventana no llego a cargar'; $f.Close() }
                    return
                }
                $tj.Stop()
                $lvAu = $f.Controls.Find('cvJobAudio',   $true)[0]
                $lvSu = $f.Controls.Find('cvJobSubs',    $true)[0]
                $script:jobHasSubPlay = ($f.Controls.Find('cvJobSubPlay', $true).Count -eq 1)
                # El formulario se dibuja desde los CATALOGOS: si uno nombra un control, la ventana
                # tiene que tenerlo, y uno solo. Es lo que sujeta el layout por catalogo -un nombre
                # mal escrito en el catalogo no da error, deja un $null que revienta al pulsar-.
                $script:jobFaltan = @()
                $catNames = @()
                foreach ($r in (Get-CvJobVideoRows)) { foreach ($c in @($r.Cells)) { $catNames += "$($c.Name)" } }
                foreach ($i in (Get-CvJobAudioBarItems)) { $catNames += "$($i.Name)" }
                foreach ($i in (Get-CvJobSubBarItems))   { $catNames += "$($i.Name)" }
                foreach ($n in @($catNames | Where-Object { $_ -ne '' })) {
                    if ($f.Controls.Find($n, $true).Count -ne 1) { $script:jobFaltan += $n }
                }
                $cmbP = $f.Controls.Find('cvJobProfile', $true)[0]
                $txL  = $f.Controls.Find('cvJobAudioLang', $true)[0]
                $bDf  = $f.Controls.Find('cvJobAudioDefault', $true)[0]
                $bSv  = $f.Controls.Find('cvJobSave',    $true)[0]
                $script:jobAudioRows = $lvAu.Items.Count
                $script:jobSubRows   = $lvSu.Items.Count
                $script:jobChecked   = @($lvAu.Items | Where-Object { $_.Checked }).Count
                $script:jobProfs     = $cmbP.Items.Count
                # Marcar la 2a pista de audio (eng), ponerle idioma a mano y hacerla predeterminada.
                $lvAu.Items[1].Checked  = $true
                $lvAu.Items[1].Selected = $true
                $txL.Text = 'eng'
                $bDf.PerformClick()
                # Conservar tambien el 3er subtitulo (el ingles), que no entraba solo.
                $lvSu.Items[2].Checked = $true
                $bSv.PerformClick()
            } catch {
                $tj.Stop()
                $script:jobErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $tj.Start()
        $savedJob = Show-CvJobWindow -Context $ctxJob -Name 'Serie_2x01' -File $jobFile

        Assert-Eq   'Editor sin excepciones'     '' $script:jobErr
        Assert-True 'Editor: pregunta el perfil de un job nuevo' $script:jobAskedProfile
        Assert-True 'Editor: guardo el job'      $savedJob
        Assert-Eq   'Editor: una fila por pista de audio' 3 $script:jobAudioRows
        Assert-Eq   'Editor: una fila por subtitulo'      4 $script:jobSubRows
        Assert-Eq   'Editor: arranca con la spa marcada'  1 $script:jobChecked
        Assert-True 'Editor: ofrece perfiles'    ($script:jobProfs -ge 2)
        Assert-True 'Editor: se puede reproducir un subtitulo' $script:jobHasSubPlay
    Assert-Eq   'Editor: estan todos los controles del catalogo' '' (@($script:jobFaltan) -join ', ')
        $saved = Read-CvJobDraft -Context $ctxJob -Name 'Serie_2x01'
        Assert-Eq   'Editor: dos pistas de audio' 2 @($saved.Audio).Count
        Assert-Eq   'Editor: la predeterminada primero' 'eng' $saved.Audio[0].Lang
        Assert-True 'Editor: solo una predeterminada' (@($saved.Audio | Where-Object { $_.Default }).Count -eq 1)
        Assert-Eq   'Editor: tres subtitulos'    3 @($saved.Subtitles).Count
        Assert-True 'Editor: el forzado sigue primero' $saved.Subtitles[0].Forced

        # ------------------------------------------------------------------------------------
        # REGRESION: con un perfil AUTO-BORDE, abrir el editor de UNO EN UNO tiene que DETECTAR los
        # bordes solo, igual que la consola. Antes la deteccion solo corria en el recorrido de
        # 'Preparar pendientes' y aqui el recorte se quedaba VACIO sin decir nada.
        Write-Host "`nGuiJob - el perfil AUTO-BORDE detecta al abrir" -ForegroundColor Cyan
        Remove-CvJob -Context $ctxJob -Name 'Serie_2x01'
        $tb = New-Object System.Windows.Forms.Timer
        $tb.Interval = 300
        $script:bordErr   = ''
        $script:bordWaits = 0
        $script:bordProf  = ''
        $script:bordMsg   = ''
        $tb.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f) { return }
                # En el dialogo de perfil se elige uno que detecte bordes (lo dice su etiqueta).
                $pl = $f.Controls.Find('cvProfList', $true)
                if ($pl.Count -gt 0) {
                    $ix = -1
                    for ($k = 0; $k -lt $pl[0].Items.Count; $k++) {
                        if ("$($pl[0].Items[$k])" -match 'AUTO-BORDE') { $ix = $k; break }
                    }
                    $script:bordProf = $(if ($ix -ge 0) { "$($pl[0].Items[$ix])" } else { '' })
                    $pl[0].SelectedIndex = [math]::Max(0, $ix)
                    $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
                    return
                }
                $lvChk = $f.Controls.Find('cvJobAudio', $true)[0]
                if ($null -eq $lvChk -or $lvChk.Items.Count -eq 0) {
                    $script:bordWaits++
                    if ($script:bordWaits -gt 150) { $tb.Stop(); $script:bordErr = 'la ventana no llego a cargar'; $f.Close() }
                    return
                }
                $tb.Stop()
                $script:bordMsg = "$($f.Controls.Find('cvJobMsg', $true)[0].Text)"
                $f.Close()
            } catch {
                $tb.Stop()
                $script:bordErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $tb.Start()
        [void](Show-CvJobWindow -Context $ctxJob -Name 'Serie_2x01' -File $jobFile)
        Assert-Eq   'Bordes: sin excepciones'    '' $script:bordErr
        Assert-True 'Bordes: hay perfil AUTO-BORDE en el catalogo' ($script:bordProf -ne '')
        # Lo que se comprueba es que la DETECCION corrio: el mensaje habla de barras/bordes/recorte,
        # en vez del 'listo para guardar' de siempre. Que salga recorte o no depende de la fixture.
        Assert-True 'Bordes: el editor los detecta al abrir' ($script:bordMsg -match 'barras|bordes|[Rr]ecorte')
        Remove-CvJob -Context $ctxJob -Name 'Serie_2x01'

        # ------------------------------------------------------------------------------------
        # AJUSTAR EL PERFIL del job: cambiar UNA cosa (aqui el bitrate de audio) sin tocar el resto.
        # Se abre sin ventana padre para probar el dialogo en aislado.
        Write-Host "`nGuiJob - ajustar el perfil (equivalente al Custom de consola)" -ForegroundColor Cyan
        $profBase = @(Get-CvJobProfileOptions -Context $ctxJob)[1].Prof
        $te = New-Object System.Windows.Forms.Timer
        $te.Interval = 400
        $script:peErr = ''
        $te.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f -or $f.Controls.Find('cvPeOk', $true).Count -eq 0) { return }
                $te.Stop()
                $f.Controls.Find('cvPeAudioBitrate', $true)[0].Text = '320k'
                $f.Controls.Find('cvPeOk', $true)[0].PerformClick()
            } catch {
                $te.Stop(); $script:peErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $te.Start()
        $profTuned = Show-CvProfileEditorWindow -Context $ctxJob -Prof $profBase
        $te.Stop()
        Assert-Eq   'Ajustar perfil: sin excepciones' '' $script:peErr
        Assert-True 'Ajustar perfil: devuelve un perfil' ($null -ne $profTuned)
        Assert-Eq   'Ajustar perfil: cambia el bitrate' '320k' "$($profTuned.AudioBitrate)"
        # Y NO cambia nada mas: encoder, control de tasa, bordes y escalado siguen igual. Ojo, esto
        # cubre el fallo de que un valor que no esta en el catalogo (encoder 'auto') se perdiera.
        Assert-Eq   'Ajustar perfil: mismo encoder'  "$($profBase.VideoEncoder)" "$($profTuned.VideoEncoder)"
        Assert-Eq   'Ajustar perfil: mismo Qmin'     "$($profBase.Qmin)"         "$($profTuned.Qmin)"
        Assert-Eq   'Ajustar perfil: mismo Qmax'     "$($profBase.Qmax)"         "$($profTuned.Qmax)"
        Assert-Eq   'Ajustar perfil: mismos bordes'  "$($profBase.DetectBorder)" "$($profTuned.DetectBorder)"
        Assert-Eq   'Ajustar perfil: mismo escalado' "$($profBase.ChangeSize)"   "$($profTuned.ChangeSize)"
        Assert-Eq   'Ajustar perfil: mismo maxWidth' "$($profBase.MaxWidth)"     "$($profTuned.MaxWidth)"
        # Cancelar no devuelve nada (no se cambia el perfil por abrir el dialogo).
        $te2 = New-Object System.Windows.Forms.Timer
        $te2.Interval = 400
        $te2.Add_Tick({
            $f = @([System.Windows.Forms.Application]::OpenForms)[0]
            if ($null -eq $f -or $f.Controls.Find('cvPeCancel', $true).Count -eq 0) { return }
            $te2.Stop()
            $f.Controls.Find('cvPeCancel', $true)[0].PerformClick()
        })
        $te2.Start()
        Assert-True 'Ajustar perfil: cancelar no devuelve nada' ($null -eq (Show-CvProfileEditorWindow -Context $ctxJob -Prof $profBase))
        $te2.Stop()

        # ------------------------------------------------------------------------------------
        # GUARDAR el perfil ajustado como PERFIL PROPIO (config.json -> 'profiles'): con -CfgPath el
        # editor ensena el nombre y el boton de guardar, y lo guardado sale ya en el menu de perfiles.
        Write-Host "`nGuiProfileEditorWindow - guardar un perfil propio desde la ventana" -ForegroundColor Cyan
        $tg = New-Object System.Windows.Forms.Timer
        $tg.Interval = 400
        $script:pgErr  = ''
        $script:pgName = 0
        $script:pgSave = 0
        $tg.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f -or $f.Controls.Find('cvPeSave', $true).Count -eq 0) { return }
                $tg.Stop()
                $script:pgName = @($f.Controls.Find('cvPeName', $true)).Count
                $script:pgSave = @($f.Controls.Find('cvPeSave', $true)).Count
                $f.Controls.Find('cvPeAudioBitrate', $true)[0].Text = '256k'
                $f.Controls.Find('cvPeName', $true)[0].Text = 'Serie de prueba'
                $f.Controls.Find('cvPeSave', $true)[0].PerformClick()
            } catch {
                $tg.Stop(); $script:pgErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $tg.Start()
        $profSaved = Show-CvProfileEditorWindow -Context $ctxJob -Prof $profBase -CfgPath $tmpCfg
        $tg.Stop()
        Assert-Eq   'Guardar perfil: sin excepciones'    '' $script:pgErr
        Assert-Eq   'Guardar perfil: hay caja de nombre'  1 $script:pgName
        Assert-Eq   'Guardar perfil: hay boton de guardar' 1 $script:pgSave
        Assert-True 'Guardar perfil: devuelve el perfil' ($null -ne $profSaved)
        $guardados = @(Get-CvConfigProfiles -Path $tmpCfg)
        Assert-Eq   'Guardar perfil: queda en el config'  1 $guardados.Count
        Assert-Eq   'Guardar perfil: con su nombre'       'Serie de prueba' (Get-CvProfileLabel $guardados[0])
        Assert-Eq   'Guardar perfil: con lo ajustado'     '256k' "$((ConvertTo-CvProfile $guardados[0]).AudioBitrate)"
        # Y a partir de ahi es UNO MAS del menu de perfiles (con su nombre, marcado como [config]).
        $optsCfg = @(Get-CvJobProfileOptions -Context $ctxJob -Profiles $guardados)
        $mio = @($optsCfg | Where-Object { $_.Label -eq 'Serie de prueba' })
        Assert-Eq   'Guardar perfil: sale en el menu'     1 $mio.Count
        Assert-Eq   'Guardar perfil: es de config.json'   'config.json' "$($mio[0].Group)"
        # Sin nombre no se guarda (y el aviso es modal, asi que aqui NO se pulsa guardar en vacio:
        # eso lo cubre Test-CvProfileName en los tests unitarios).

        # El dialogo de perfil ensena los propios y ofrece crear/borrar.
        $td = New-Object System.Windows.Forms.Timer
        $td.Interval = 400
        $script:pdErr   = ''
        $script:pdItems = ''
        $script:pdNew   = 0
        $script:pdDel   = 0
        $td.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f -or $f.Controls.Find('cvProfList', $true).Count -eq 0) { return }
                $td.Stop()
                $lp = $f.Controls.Find('cvProfList', $true)[0]
                $script:pdItems = (@($lp.Items) -join '|')
                $script:pdNew   = @($f.Controls.Find('cvProfNew', $true)).Count
                $script:pdDel   = @($f.Controls.Find('cvProfDel', $true)).Count
                # Marcar el perfil propio y aceptar: tiene que devolver ESE perfil.
                for ($k = 0; $k -lt $lp.Items.Count; $k++) {
                    if ("$($lp.Items[$k])" -match 'AC3|256K') { $lp.SelectedIndex = $k }
                }
                $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
            } catch {
                $td.Stop(); $script:pdErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $td.Start()
        $profPick = Show-CvJobProfileDialog -Context $ctxJob
        $td.Stop()
        Assert-Eq   'Dialogo perfil: sin excepciones'  '' $script:pdErr
        Assert-True 'Dialogo perfil: ensena los propios' ($script:pdItems -match '\[config\]')
        Assert-Eq   'Dialogo perfil: ofrece crear'     1 $script:pdNew
        Assert-Eq   'Dialogo perfil: ofrece borrar'    1 $script:pdDel
        Assert-True 'Dialogo perfil: devuelve el elegido' ($null -ne $profPick)
        # Se limpia para no ensuciar el resto de la bateria (el config temporal es compartido).
        [void](Remove-CvConfigProfile -Path $tmpCfg -Label 'Serie de prueba')
        Assert-Eq   'Guardar perfil: se puede borrar'  0 (@(Get-CvConfigProfiles -Path $tmpCfg)).Count

        # ------------------------------------------------------------------------------------
        # REGRESION: el desplegable tiene que ensenar el perfil QUE TIENE EL JOB, aunque no sea
        # ninguno del catalogo. Pasa siempre con 'Auto', que se guarda YA RESUELTO al encoder de este
        # equipo: al no casar, el combo caia en la primera entrada (COPY) y guardar convertia el job
        # a copy sin querer.
        $profRaro = New-CvProfile -VideoEncoder 'libx265' -Crf 30 -AudioEncoder 'aac_coder' -AudioBitrate '128k'
        $lblRaro  = Format-CvProfileLabel -Prof $profRaro
        Assert-True 'Perfil del job: no esta en el catalogo' (@(Get-CvJobProfileOptions -Context $ctxJob | Where-Object { (Format-CvProfileLabel -Prof $_.Prof) -eq $lblRaro }).Count -eq 0)
        $dRaro = New-CvJobDraft -Context $ctxJob -Prof $profRaro -Info $jobInfo -File $jobFile
        [void](Save-CvJobDraft -Context $ctxJob -Draft $dRaro -Info $jobInfo)

        $tp = New-Object System.Windows.Forms.Timer
        $tp.Interval = 300
        $script:profErr = ''
        $script:profSel = ''
        $script:profWaits = 0
        $tp.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f) { return }
                # Con el job YA creado no debe preguntar el perfil: si sale el dialogo, es un fallo.
                if ($f.Controls.Find('cvProfList', $true).Count -gt 0) {
                    $tp.Stop(); $script:profErr = 'pregunto el perfil de un job que ya existe'; $f.Close(); return
                }
                $cb = $f.Controls.Find('cvJobProfile', $true)[0]
                if ($null -eq $cb -or -not $cb.Enabled) {
                    $script:profWaits++
                    if ($script:profWaits -gt 100) { $tp.Stop(); $script:profErr = 'la ventana no llego a cargar'; $f.Close() }
                    return
                }
                $tp.Stop()
                $script:profSel = "$($cb.SelectedItem)"
                $f.Controls.Find('cvJobSave', $true)[0].PerformClick()
            } catch {
                $tp.Stop()
                $script:profErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $tp.Start()
        [void](Show-CvJobWindow -Context $ctxJob -Name 'Serie_2x01' -File $jobFile)
        $tp.Stop()
        Assert-Eq   'Perfil del job: sin excepciones'  '' $script:profErr
        Assert-True 'Perfil del job: se ensena el suyo' ($script:profSel -match [regex]::Escape($lblRaro))
        Assert-True 'Perfil del job: no cae en COPY'    ($script:profSel -notmatch 'V: COPY')
        Assert-Eq   'Perfil del job: se guarda igual'   'libx265' "$((Read-CvJobDraft -Context $ctxJob -Name 'Serie_2x01').Prof.VideoEncoder)"

        # ------------------------------------------------------------------------------------
        # PREPARAR PENDIENTES de punta a punta: elegir perfil UNA vez y recorrer los archivos.
        # Un solo temporizador va atendiendo las ventanas segun aparecen (primero el dialogo del
        # perfil, luego la del recorrido), que es como se encadenan en la vida real.
        Write-Host "`nGuiJob - preparar pendientes (recorrido completo)" -ForegroundColor Cyan
        Remove-CvJob -Context $ctxJob -Name 'Serie_2x01'
        Copy-Item -LiteralPath $fixture -Destination (Join-Path $ctxJob.Original 'Serie_3x01.mkv') -Force
        $pendientes = @(
            [pscustomobject]@{
                Name = 'Serie_3x01'
                Path = (Join-Path $ctxJob.Original 'Serie_3x01.mkv')
            }
        )
        $tw = New-Object System.Windows.Forms.Timer
        $tw.Interval = 300
        $script:wizErr   = ''
        $script:wizProfs = 0
        $script:wizRows  = ''
        $script:wizWaits = 0
        $tw.Add_Tick({
            try {
                $f = @([System.Windows.Forms.Application]::OpenForms)[0]
                if ($null -eq $f) { return }
                $pl = $f.Controls.Find('cvProfList', $true)
                if ($pl.Count -gt 0) {
                    # Dialogo del perfil: el primero del catalogo (copy) para que el recorrido sea
                    # rapido y deterministico (sin recodificar no hay escaneo de bordes).
                    $script:wizProfs = $pl[0].Items.Count
                    $pl[0].SelectedIndex = 0
                    $f.Controls.Find('cvProfOk', $true)[0].PerformClick()
                    return
                }
                $cl = $f.Controls.Find('cvPrepClose', $true)
                if ($cl.Count -gt 0) {
                    # Ventana del recorrido: esperar a que termine (el boton pasa a 'Cerrar').
                    if ("$($cl[0].Text)" -ne 'Cerrar') {
                        $script:wizWaits++
                        if ($script:wizWaits -gt 200) { $tw.Stop(); $script:wizErr = 'el recorrido no termino'; $f.Close() }
                        return
                    }
                    $lst = $f.Controls.Find('cvPrepList', $true)[0]
                    $script:wizRows = (@($lst.Items | ForEach-Object { "{0}={1}" -f $_.Text, $_.SubItems[1].Text }) -join ',')
                    $script:wizCols = (@($lst.Columns | ForEach-Object { "$($_.Text)" }) -join '|')
                    $script:wizBord = (@($lst.Items | ForEach-Object { "$($_.SubItems[2].Text)" }) -join ',')
                    $tw.Stop()
                    $cl[0].PerformClick()
                }
            } catch {
                $tw.Stop()
                $script:wizErr = "$_"
                foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
            }
        })
        $tw.Start()
        $nPrep = Show-CvPrepareWindow -Context $ctxJob -Files $pendientes
        $tw.Stop()

        Assert-Eq   'Recorrido sin excepciones'  '' $script:wizErr
        Assert-True 'Recorrido: el dialogo lista perfiles' ($script:wizProfs -ge 2)
        Assert-Eq   'Recorrido: un job preparado' 1 $nPrep
        Assert-Eq   'Recorrido: estado de la fila' 'Serie_3x01=preparado' $script:wizRows
        # Columna de bordes: se ve de un vistazo si ha entrado el recorte. El perfil del recorrido es
        # 'copy' (no se toca la imagen), asi que la celda queda vacia; el texto lo fija su test unitario.
        Assert-Eq   'Recorrido: columna de bordes' 'Archivo|Estado|Bordes / tamano|Detalle' $script:wizCols
        Assert-Eq   'Recorrido: en copy no dice nada' '' $script:wizBord
        Assert-True 'Recorrido: existe el job'    (Test-CvJob -Context $ctxJob -Name 'Serie_3x01')
        $jw = Read-CvJobDraft -Context $ctxJob -Name 'Serie_3x01'
        Assert-Eq   'Recorrido: perfil aplicado'  'copy' "$($jw.Prof.VideoEncoder)"
        # Y la cola ya lo ve preparado, que es el efecto que se busca.
        Assert-Eq   'Recorrido: la cola lo ve en cola' 'queued' (@(Get-CvQueueStatus -Context $ctxJob) | Where-Object { $_.Name -eq 'Serie_3x01' }).State
    }
}

# ================================================================================================
Write-Host "`nGuiConvert - la lista sigue al archivo que se esta codificando" -ForegroundColor Cyan
# Con la cola larga, el archivo en curso se va por debajo de la zona visible y ya no se ve lo unico
# que se mueve. La lista tiene que moverse SOLA para dejarlo a la vista... salvo que te hayas ido tu
# a mirar otra parte, que entonces no puede dar tirones. Se monta una cola larga de verdad y se
# comprueba con el scroll REAL de la ventana (TopItem), no con la funcion pura.
if (-not $sta) {
    Write-Skip 'Ventana: seguir al que se codifica' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Ventana: seguir al que se codifica' 'sin entorno grafico'
} else {
    # El unico que se codifica tiene que ser el ULTIMO de la lista (si no, ya se ve al abrir).
    Remove-Item -LiteralPath (Join-Path $ctx.Proceso 'Serie_1x02.lock') -Force -ErrorAction SilentlyContinue
    foreach ($i in 1..30) { [void](New-FakeVideo -Name ('Serie_5x{0:d2}' -f $i) -Kb 8) }
    [void](New-FakeVideo -Name 'Serie_9x99' -Kb 8)
    Set-Content -Path (Join-Path $ctx.Proceso 'Serie_9x99.job.json') -Value '{}' -Encoding UTF8
    New-FakeLock -Name 'Serie_9x99' -OwnerPid $PID      # este proceso hace de worker vivo
    Set-CvWorkerFile -Context $ctx -File 'Serie_9x99'
    # Ventana baja a proposito: asi caben pocas filas y el que se codifica queda fuera.
    [void](Save-CvGuiLayout -Context $ctx -Key 'cola' -Layout ([ordered]@{
        width     = 1000
        height    = 600
        maximized = $false
        split     = 300
        cols      = @(240, 90, 130, 55, 150, 70, 300, 80)
    }))
    $script:foErr   = ''
    $script:foWaits = 0
    $script:foIdx   = -1
    $script:foFit   = 0
    $script:foRows  = 0
    $script:foTop1  = -1
    $script:foSee1  = $false
    $script:foTop2  = -1
    $script:foTop3  = -1
    $script:foTopBusy = -1
    $t4 = New-Object System.Windows.Forms.Timer
    $t4.Interval = 300
    $t4.Add_Tick({
        $fs = @([System.Windows.Forms.Application]::OpenForms)
        $lvs = $(if ($fs.Count -gt 0) { @($fs[0].Controls.Find('cvQueue', $true)) } else { @() })
        if ($lvs.Count -eq 0 -or $lvs[0].Items.Count -lt 31) {
            $script:foWaits++
            if ($script:foWaits -gt 60) { $t4.Stop(); $script:foErr = 'la ventana no llego a montarse'; $fs | ForEach-Object { $_.Close() } }
            return
        }
        $t4.Stop()
        try {
            $f  = $fs[0]
            $lv = $lvs[0]
            $script:foRows = $lv.Items.Count
            for ($k = 0; $k -lt $lv.Items.Count; $k++) { if ($lv.Items[$k].Text -eq 'Serie_9x99') { $script:foIdx = $k } }
            # Cuantas filas caben: se mide de la propia lista (igual que hace la ventana).
            $bt = $lv.Items[[int]$lv.TopItem.Index].Bounds
            $script:foFit = [int][Math]::Floor(($lv.ClientSize.Height - [int]$bt.Top) / [Math]::Max(1, [int]$bt.Height))
            # 1) Al abrir: la lista se ha movido sola y la fila en curso se VE entera.
            $script:foTop1 = [int]$lv.TopItem.Index
            $rb = $lv.Items[[int]$script:foIdx].Bounds
            $script:foSee1 = ([int]$rb.Top -ge 0 -and [int]$rb.Bottom -le [int]$lv.ClientSize.Height)
            # 2) Se pone a codificar OTRO archivo, arriba del todo... pero acabo de MARCAR una fila:
            # mientras estoy usando la lista no se puede mover (si no, un Ctrl/Mayus+clic acaba
            # seleccionando lo que no era).
            Remove-Item -LiteralPath (Join-Path $ctx.Proceso 'Serie_9x99.lock') -Force -ErrorAction SilentlyContinue
            New-FakeLock -Name 'Serie_1x02' -OwnerPid $PID
            Set-CvWorkerFile -Context $ctx -File 'Serie_1x02'
            $lv.Items[[int]$script:foIdx].Selected = $true      # tocar la lista (marca $st.Touch)
            $f.Controls.Find('cvRefresh', $true)[0].PerformClick()
            $script:foTopBusy = [int]$lv.TopItem.Index
            # 3) Y en cuanto la suelto (gui.queueFollowHoldSec), se va a por el archivo nuevo.
            $esperaHasta = [datetime]::UtcNow.AddSeconds(6)
            while ([datetime]::UtcNow -lt $esperaHasta -and [int]$lv.TopItem.Index -gt 2) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            $script:foTop3 = [int]$lv.TopItem.Index
            # 4) Me voy YO al principio de la lista: el siguiente refresco NO puede devolverme.
            $lv.EnsureVisible(0)
            $f.Controls.Find('cvRefresh', $true)[0].PerformClick()
            $script:foTop2 = [int]$lv.TopItem.Index
            $f.Close()
        } catch {
            $script:foErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $t4.Start()
    [void](Show-CvConvertWindow -Context $ctx -Root $tmpRoot -CfgPath $tmpCfg -CfgName 'config.json')
    Assert-Eq   'Seguir: ventana sin excepciones' '' $script:foErr
    if ($script:foFit -ge $script:foRows) {
        Write-Skip 'Ventana: seguir al que se codifica' ("caben las {0} filas: no hay scroll que probar" -f $script:foRows)
    } else {
        Assert-True 'Seguir: el que se codifica esta abajo del todo' ($script:foIdx -ge $script:foFit)
        Assert-True 'Seguir: al abrir, la lista se ha movido sola'   ($script:foTop1 -gt 0)
        Assert-True 'Seguir: y la fila en curso se ve entera'        $script:foSee1
        Assert-Eq   'Seguir: mientras la usas, no se mueve' $script:foTop1 $script:foTopBusy
        Assert-True 'Seguir: al soltarla, va al archivo nuevo'    ($script:foTop3 -le 2)
        Assert-Eq   'Seguir: si te vas tu, no te devuelve'        0  $script:foTop2
    }
    foreach ($i in 1..30) { Remove-Item -LiteralPath (Join-Path $ctx.Original ('Serie_5x{0:d2}.mkv' -f $i)) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $ctx.Original 'Serie_9x99.mkv') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ctx.Proceso 'Serie_9x99.lock') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ctx.Proceso 'Serie_9x99.job.json') -Force -ErrorAction SilentlyContinue
}


# ================================================================================================
Write-Host "`nEditar los jobs de varias filas a la vez" -ForegroundColor Cyan
# Tres archivos con jobs DISTINTOS (cada uno con su pista de audio y sus subtitulos). Se cambia en
# bloque una sola cosa y hay que comprobar las dos mitades: que cambia en todos, y que lo de cada
# uno sigue intacto.
foreach ($i in 1..3) {
    [void](New-FakeVideo -Name ('Serie_6x0{0}' -f $i) -Kb 8)
    $recB = ConvertTo-CvJobRecord -Context $ctx -File (Join-Path $ctx.Original ('Serie_6x0{0}.mkv' -f $i)) `
        -Prof (New-CvProfile -VideoEncoder 'libx265' -Crf 28 -AudioEncoder 'aac_coder' -AudioBitrate '128k') `
        -VideoIndex 0 -Crop ('1920:800:0:14{0}' -f $i) -Resize '1280:-2' -Hdr ($i -eq 2) `
        -AudioTracks @([pscustomobject]@{ Index = $i; Is51 = $false; Sync = (0.1 * $i); Lang = 'spa'; Default = $true }) `
        -Subtitles @(@{ index = $i; forced = $false })
    Write-CvJob -Context $ctx -Name ('Serie_6x0{0}' -f $i) -Job $recB
}
$bkRows = @(@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.Name -match '^Serie_6x' })
Assert-Eq   'Bloque: los tres en cola' 3 @($bkRows | Where-Object { $_.State -eq 'queued' }).Count
# La regla de cuando es una accion EN BLOQUE: con una sola fila, no (para eso esta el editor normal).
Assert-Eq   'Bloque: con una fila no aplica' 0 @((Get-CvQueueBulkActions -Rows @($bkRows[0])).Edit).Count
Assert-Eq   'Bloque: con tres, las tres'     3 @((Get-CvQueueBulkActions -Rows $bkRows).Edit).Count
Assert-True 'Bloque: y lo dice en el menu'   ((Get-CvQueueBulkActions -Rows $bkRows).EditText -match 'los 3 jobs')
# Lo que se esta codificando NO se toca: el worker ya leyo su job.
$bkConCurso = @($bkRows + @(@(Get-CvQueueStatus -Context $ctx) | Where-Object { $_.State -eq 'working' }))
Assert-Eq   'Bloque: deja fuera lo que se codifica' 3 @((Get-CvQueueBulkActions -Rows $bkConCurso).Edit).Count

$bkRes = Set-CvJobsBulk -Context $ctx -Names @('Serie_6x01', 'Serie_6x02', 'Serie_6x03') -Changes @{ videoCopy = $true }
Assert-Eq   'Bloque: cambiados los tres' 3 ([int]$bkRes.Done)
Assert-Eq   'Bloque: ninguno fallo'      0 ([int]$bkRes.Failed)
foreach ($i in 1..3) {
    $jb = Read-CvJob -Context $ctx -Name ('Serie_6x0{0}' -f $i)
    Assert-Eq ('Bloque: {0} copia el video' -f $i)      $true ([bool]$jb.video.skip)
    Assert-Eq ('Bloque: {0} conserva su pista' -f $i)   $i    ([int]@(Get-CvJobAudioTracks $jb.audio)[0].Index)
    Assert-Eq ('Bloque: {0} conserva su retardo' -f $i) (0.1 * $i) ([double]@(Get-CvJobAudioTracks $jb.audio)[0].Sync)
    Assert-Eq ('Bloque: {0} conserva sus subtitulos' -f $i) 1 (@($jb.subtitles).Count)
    Assert-Eq ('Bloque: {0} conserva su recorte' -f $i) ('1920:800:0:14{0}' -f $i) "$($jb.video.crop)"
    Assert-Eq ('Bloque: {0} conserva su HDR' -f $i)     ($i -eq 2) ([bool]$jb.video.hdr)
}
# Un nombre que no existe se cuenta como fallo y no se lleva por delante a los demas.
$bkMal = Set-CvJobsBulk -Context $ctx -Names @('Serie_6x01', 'NoExiste_9x99') -Changes @{ crop = '' }
Assert-Eq   'Bloque: sigue con los demas' 1 ([int]$bkMal.Done)
Assert-Eq   'Bloque: y cuenta el que falla' 1 ([int]$bkMal.Failed)
Assert-Eq   'Bloque: recorte quitado' '' "$((Read-CvJob -Context $ctx -Name 'Serie_6x01').video.crop)"
Assert-Eq   'Bloque: al de al lado no le toca' '1920:800:0:142' "$((Read-CvJob -Context $ctx -Name 'Serie_6x02').video.crop)"
# Sin marcar nada no se escribe nada.
$bkNada = Set-CvJobsBulk -Context $ctx -Names @('Serie_6x02') -Changes @{}
Assert-Eq   'Bloque: sin nada marcado, no toca nada' 0 ([int]$bkNada.Done)

# --- La VENTANA de verdad: se marca 'Video -> Copiar' y se aplica (sin raton).
if (-not $sta) {
    Write-Skip 'Ventana: editar jobs en bloque' 'el host no es STA (usa -Sta)'
} elseif (-not (Initialize-CvGui)) {
    Write-Skip 'Ventana: editar jobs en bloque' 'sin entorno grafico'
} else {
    [void](Set-CvJobsBulk -Context $ctx -Names @('Serie_6x01', 'Serie_6x02', 'Serie_6x03') -Changes @{ videoCopy = $false })
    $script:bwErr   = ''
    $script:bwTry   = 0
    $script:bwApply0 = $null
    $script:bwApply1 = $null
    $script:bwList  = 0
    $script:bwMsg   = ''
    $tb = New-Object System.Windows.Forms.Timer
    $tb.Interval = 300
    $tb.Add_Tick({
        $script:bwTry++
        try {
            $w = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cvJobBulk' })
            if ($w.Count -eq 0) {
                if ($script:bwTry -gt 40) { $tb.Stop(); $script:bwErr = 'no se abrio la ventana' }
                return
            }
            $tb.Stop()
            $f = $w[0]
            $script:bwList = $f.Controls.Find('cvBulkList', $true)[0].Items.Count
            # Sin marcar nada no se puede aplicar (no habria nada que hacer).
            $script:bwApply0 = [bool]$f.Controls.Find('cvBulkApply', $true)[0].Enabled
            $cmb = $f.Controls.Find('cvBulkVal_videoCopy', $true)[0]
            $cmb.SelectedIndex = 1                                      # 'Copiar (sin recodificar)'
            $f.Controls.Find('cvBulkChk_videoCopy', $true)[0].Checked = $true
            $script:bwApply1 = [bool]$f.Controls.Find('cvBulkApply', $true)[0].Enabled
            $script:bwMsg    = "$($f.Controls.Find('cvBulkMsg', $true)[0].Text)"
            $f.Controls.Find('cvBulkApply', $true)[0].PerformClick()
        } catch {
            $tb.Stop()
            $script:bwErr = "$_"
            foreach ($fm in @([System.Windows.Forms.Application]::OpenForms)) { $fm.Close() }
        }
    })
    $tb.Start()
    $bwHecho = Show-CvJobBulkWindow -Context $ctx -Names @('Serie_6x01', 'Serie_6x02', 'Serie_6x03')
    Assert-Eq   'Ventana bloque: sin excepciones' '' $script:bwErr
    Assert-Eq   'Ventana bloque: ensena los tres archivos' 3 $script:bwList
    Assert-Eq   'Ventana bloque: sin marcar nada no deja aplicar' $false $script:bwApply0
    Assert-True 'Ventana bloque: al marcar, se puede aplicar'     $script:bwApply1
    Assert-True 'Ventana bloque: dice lo que va a cambiar'        ($script:bwMsg -match 'video -> copiar')
    Assert-True 'Ventana bloque: aplico'                          $bwHecho
    Assert-Eq   'Ventana bloque: los tres copian el video' 3 @(1..3 | Where-Object { [bool](Read-CvJob -Context $ctx -Name ('Serie_6x0{0}' -f $_)).video.skip }).Count
    Assert-Eq   'Ventana bloque: y cada uno con su pista' '1,2,3' ((@(1..3 | ForEach-Object { [int]@(Get-CvJobAudioTracks (Read-CvJob -Context $ctx -Name ('Serie_6x0{0}' -f $_)).audio)[0].Index })) -join ',')
}
foreach ($i in 1..3) {
    Remove-Item -LiteralPath (Join-Path $ctx.Original ('Serie_6x0{0}.mkv' -f $i)) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ctx.Proceso ('Serie_6x0{0}.job.json' -f $i)) -Force -ErrorAction SilentlyContinue
}

# ================================================================================================
Write-Host "`nLa lista de 'codificar solo estos' llega entera al worker" -ForegroundColor Cyan
# REGRESION de verdad: 'powershell -File' NO interpreta lo que le pasa, cada argumento llega como
# cadena literal. Con los nombres separados por comas el worker recibia UN solo nombre ('A,B,C'),
# no encontraba ninguno y se moria sin codificar nada: se veian arrancar los workers y ya. Aqui se
# abre un proceso DE VERDAD con los argumentos que arma la ventana y se mira que llegan los tres.
$onlyEco = Join-Path $tmpRoot 'eco-only.ps1'
Set-Content -Path $onlyEco -Encoding UTF8 -Value @(
    'param([string[]]$Only = @(), [switch]$WorkerOnly, [switch]$Unattended, [string]$Config = "")'
    ('Import-Module (Join-Path "{0}" "lib\WorkerCore.psm1") -Force -DisableNameChecking' -f $Root)
    '$n = @(Expand-CvOnlyList -Values $Only)'
    'Write-Output ("{0}|{1}" -f $n.Count, ($n -join ";"))'
)
$onlyNombres = @('Serie_1x01', 'Mi Serie 1x05', 'Peli_[2024], version larga')
$onlyArgv = @(Get-CvConvertWorkerArgs -Root $tmpRoot -Only $onlyNombres)
# Se cambia solo el script de destino: el resto de la linea es la que se usa de verdad.
$onlyArgv = @($onlyArgv | ForEach-Object { if ("$_" -like '*Convert.ps1*') { '"{0}"' -f $onlyEco } else { $_ } })
$onlySal = Join-Path $tmpRoot 'eco-only.txt'
[void](Start-Process -FilePath 'powershell.exe' -ArgumentList $onlyArgv -NoNewWindow -Wait -RedirectStandardOutput $onlySal)
$onlyLeido = "$(@(Get-Content -LiteralPath $onlySal -ErrorAction SilentlyContinue) -join '')".Trim()
Assert-Eq 'Only: llegan los tres nombres enteros' ("3|" + ($onlyNombres -join ';')) $onlyLeido
Remove-Item -LiteralPath $onlyEco, $onlySal -Force -ErrorAction SilentlyContinue

Remove-CvWorkerState -Context $ctx

} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
}

# ================================================================================================
$total = $script:pass + $script:fail
Write-Host ("`n{0}" -f ('=' * 48))
if ($script:fail -eq 0) {
    Write-Host ("OK  {0}/{1} casos de la cola pasados{2}." -f $script:pass, $total, $(if ($script:skip) { " ($($script:skip) saltados)" } else { '' })) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FALLO  {0}/{1} pasados, {2} fallidos." -f $script:pass, $total, $script:fail) -ForegroundColor Red
    exit 1
}
