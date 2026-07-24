<#
    Convert.ps1 - Conversor de video por lotes (modelo preparar/procesar).
    PowerShell 5.1, modular en lib\ (migracion del antiguo LimpiarBorde.cmd).

    FLUJO:
      - Si hay algun archivo sin .job (y sin convertir) -> FASE PREPARAR: pregunta
        la configuracion de cada archivo y escribe Proceso\<nombre>.job.json.
      - Despues, en la misma ventana -> FASE WORKER: codifica los preparados sin
        preguntar, reclamando cada archivo con un lock atomico (fichero .lock).
      - Se pueden abrir varias ventanas: cuando todos tienen .job, cada una entra
        directa como worker y se reparten los archivos por el lock.

    Regla del prefijo _: si el nombre empieza por '_', se fuerza la deteccion de bordes.
#>

[CmdletBinding()]
param(
    # Ventana de worker adicional: salta la fase PREPARAR y va directo a codificar (lo lanzan
    # las ventanas extra que se abren al elegir varios workers en paralelo).
    [switch]$WorkerOnly,
    # Fichero de configuracion a usar (por defecto config.json junto al programa). Admite ruta
    # absoluta o relativa al directorio actual. Permite tener varios perfiles de config.
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
$Lib  = Join-Path $Root 'lib'
$modules = @(
    'Log'
    'Config'
    'Context'
    'Console'
    'Exec'
    'Job'
    'Tools'
    'MediaInfo'
    'Profile'
    'Video'
    'Audio'
    'Subtitle'
    'SubtitleSRT'
    'Attachment'
    'Multiplex'
    'Render'
    'OnePass'
)
foreach ($m in $modules) {
    Import-Module (Join-Path $Lib ("{0}.psm1" -f $m)) -Force
}

# Arranque comun (config + contexto + marcas + log + apariencia + cabecera). Ver Start-CvSession.
$sess    = Start-CvSession -Root $Root -Config $Config -LogPrefix 'Convert'
$ctx     = $sess.Context
$cfgPath = $sess.ConfigPath
$cvLog   = $sess.LogFile

# Separadores de secciones (ancho comun de la UI; fuente unica en Console.psm1).
$sepLine  = Get-CvSepLine
$dashLine = Get-CvDashLine

# ---- Comprobacion de herramientas ----
# Si faltan herramientas, ofrecer descargarlas. $didInstall marca si se instalo algo.
$didInstall = $false

# ffmpeg (siempre necesario): debe existir la version 'selected'.
if (-not (Test-CvToolInstalled -Context $ctx -Name 'ffmpeg' -Version $ctx.FFmpegVersion)) {
    if (-not (Test-CvToolSupported -Context $ctx -Name 'ffmpeg')) {
        Write-Host ("ERROR: ffmpeg no tiene build para la plataforma de este equipo ({0})." -f $ctx.Platform) -ForegroundColor Red
        exit 1
    }
    Write-CvLog 'GLOBAL' ("[FFMPEG] - Falta la version {0}." -f $ctx.FFmpegVersion)
    $ffVer = Select-CvToolVersion -Context $ctx -Name 'ffmpeg'
    if (-not [string]::IsNullOrWhiteSpace($ffVer)) {
        if (Install-CvTool -Context $ctx -Name 'ffmpeg' -Version $ffVer) {
            $didInstall = $true
            $ctx = New-CvToolContext -Context $ctx -FFmpegVersion $ffVer   # usar la version instalada
        }
    } else {
        Write-CvLog 'GLOBAL' '[FFMPEG] - Descarga cancelada.'
    }
}

# aacgain (solo si el metodo de volumen es 'aacgain').
if ("$($ctx.VolumeMethod)".ToLower() -eq 'aacgain' -and -not (Test-CvToolInstalled -Context $ctx -Name 'aacgain' -Version $ctx.AacGainVersion)) {
    if (-not (Test-CvToolSupported -Context $ctx -Name 'aacgain')) {
        Write-Host ("ERROR: aacgain no tiene build para la plataforma de este equipo ({0})." -f $ctx.Platform) -ForegroundColor Red
        exit 1
    }
    Write-CvLog 'GLOBAL' ("[AACGAIN] - Falta la version {0}." -f $ctx.AacGainVersion)
    $agVer = Select-CvToolVersion -Context $ctx -Name 'aacgain'
    if (-not [string]::IsNullOrWhiteSpace($agVer)) {
        if (Install-CvTool -Context $ctx -Name 'aacgain' -Version $agVer) {
            $didInstall = $true
            $ctx = New-CvToolContext -Context $ctx -AacGainVersion $agVer
        }
    } else {
        Write-CvLog 'GLOBAL' '[AACGAIN] - Descarga cancelada.'
    }
}

# mkvtoolnix (mkvpropedit, para limpiar las etiquetas del MKV final): se asegura al arrancar
# si postprocess.stripTags esta activo y no se ha fijado una ruta propia (postprocess.mkvpropedit).
if ($ctx.StripTags -and [string]::IsNullOrWhiteSpace("$($ctx.MkvPropEditOverride)")) {
    $mkvApp = Get-CvAppDescriptor -Context $ctx -Name 'mkvtoolnix'
    $mkvSel = if ($mkvApp) { "$($mkvApp.selected)" } else { '' }
    if ($mkvSel -and (Test-CvToolSupported -Context $ctx -Name 'mkvtoolnix') -and -not (Test-CvToolInstalled -Context $ctx -Name 'mkvtoolnix' -Version $mkvSel)) {
        Write-CvLog 'GLOBAL' ("[MKVTOOLNIX] - Falta la version {0}; se descarga para limpiar las etiquetas del MKV." -f $mkvSel)
        if (Confirm-CvTool -Context $ctx -Name 'mkvtoolnix' -Version $mkvSel) { $didInstall = $true }
        else { Write-CvLog 'GLOBAL' '[MKVTOOLNIX] - [AVISO] - No disponible; el MKV final conservara las etiquetas DURATION.' }
    }
}

$missing = Test-CvTools -Context $ctx
if ($missing.Count -gt 0) {
    # Si algo falta (o una descarga fallo) se deja el error en pantalla, no se limpia.
    Write-Host 'ERROR: faltan herramientas:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}

# Si se instalo algo y todo fue bien, limpiar la pantalla para dejarla despejada.
if ($didInstall) { Clear-Host }

# Version en uso (leida de la propia app de la version seleccionada).
$ffInstalled = Get-CvToolInstalledVersion -Context $ctx -Name 'ffmpeg' -Version $ctx.FFmpegVersion
if ($ffInstalled) { Write-CvLog 'GLOBAL' ("[FFMPEG] - Version en uso: {0}" -f $ffInstalled) }
if ("$($ctx.VolumeMethod)".ToLower() -eq 'aacgain') {
    $agInstalled = Get-CvToolInstalledVersion -Context $ctx -Name 'aacgain' -Version $ctx.AacGainVersion
    if ($agInstalled) { Write-CvLog 'GLOBAL' ("[AACGAIN] - Version en uso: {0}" -f $agInstalled) }
}
# Modo pruebas activo: avisar bien visible de que la salida sera un RECORTE, no el archivo entero.
if ($ctx.TestLimit -gt 0) {
    Write-CvLog 'GLOBAL' ("[AVISO] - MODO PRUEBAS: se codifican solo los primeros {0} min de cada archivo (behavior.testMode)" -f [int]($ctx.TestLimit / 60))
}

# Detectar (con cache en config.json por version de ffmpeg + GPU) que encoders por GPU soporta este
# equipo. GLOBAL: se hace nada mas cargar config y asegurar ffmpeg, ANTES de distinguir preparacion /
# worker, para que el cache exista siempre y tanto el menu de perfiles como el worker (validacion por
# archivo) usen el resultado sin repetir el sondeo. Solo sondea si cambio ffmpeg/GPU o no habia datos.
# Las ventanas worker en paralelo (-WorkerOnly) NO persisten (leen la cache que dejo la preparacion),
# para no escribir config.json varias a la vez.
$null = Initialize-CvGpuCaps -Context $ctx -CfgPath $cfgPath -Persist (-not $WorkerOnly)

function Get-SourceFiles {
    param($Context)
    # -Exact evita el falso positivo del comodin 8.3 de Windows ('*.mp4' casando '.mp4v').
    return @(Get-CvFiles -Dir $Context.Original -Filters $Context.Extensions -Exact)
}

function Get-ProcessableFiles {
    <#
        Candidatos realmente procesables: los de Get-SourceFiles MENOS los que colisionan por
        nombre. Dos entradas con el mismo BaseName y distinta extension (peli.mp4 + peli.mkv)
        comparten job/salida/lock (todo cuelga del nombre sin extension); para no procesar el
        equivocado se IGNORAN TODOS los del grupo. -Quiet omite el aviso (lo usa el bucle del
        worker, que re-escanea en cada pasada; el aviso ya se dio al arrancar).
    #>
    param($Context, [switch]$Quiet)
    $files = @(Get-SourceFiles -Context $Context)
    $dups  = @($files | Group-Object BaseName | Where-Object { $_.Count -gt 1 })
    if ($dups.Count -gt 0) {
        if (-not $Quiet) {
            foreach ($d in $dups) {
                $exts = (@($d.Group | ForEach-Object { $_.Extension }) -join ', ')
                Write-CvLog 'GLOBAL' ("[AVISO] - Nombre duplicado en Original: '{0}' ({1}); se IGNORAN (renombra o quita uno)." -f $d.Name, $exts)
            }
        }
        $dupNames = @($dups | ForEach-Object { $_.Name })
        $files = @($files | Where-Object { $dupNames -notcontains $_.BaseName })
    }
    return $files
}

function Write-PrepareHeader {
    <# Cabecera del archivo en PREPARAR (modo normal): el nombre arriba, para que las preguntas
       interactivas (video/audio/subtitulos/bordes) queden indentadas DEBAJO y se sepa siempre
       de que archivo son. #>
    param([string]$Name)
    Write-Host ''
    Write-Host (" - {0}" -f $Name) -ForegroundColor Cyan
}

function Write-PrepareStatus {
    <#
        Estado final de PREPARAR por archivo, indentado bajo su cabecera (Write-PrepareHeader),
        como una LINEA CON ETIQUETA (no un [OK] suelto): "Preparado [OK]".
          -Warn: hubo intervencion manual (seleccion de pista de video con varias, o audio sin
                 idioma preferido) -> se resalta en amarillo con [AVISO], no como error.
        El estado va en COLOR DE TEXTO (no fondo, que en la consola de Windows se "estira" al
        redimensionar la ventana).
    #>
    param([bool]$Ok, [switch]$Warn)
    if (-not $Ok) {
        Write-Host '   No se pudo preparar ' -NoNewline; Write-Host (Get-CvMark $false) -ForegroundColor Red
        return
    }
    if ($Warn) {
        Write-Host '   Preparado (seleccion manual) ' -NoNewline; Write-Host (Get-CvMark $true) -ForegroundColor Yellow
    } else {
        Write-Host '   Preparado ' -NoNewline; Write-Host (Get-CvMark $true) -ForegroundColor Green
    }
}

# ============================================================
#  CLASIFICAR: hay algun archivo POR PREPARAR?
# ============================================================
# Candidatos: carpeta Original + extension exacta, EXCLUYENDO los que colisionan por nombre
# (mismo BaseName con distinta extension: se avisa aqui y se ignoran; ver Get-ProcessableFiles).
$files = @(Get-ProcessableFiles -Context $ctx)
if ($files.Count -eq 0) {
    Write-CvLog 'GLOBAL' ("[FIN] - No hay archivos procesables en {0}" -f $ctx.Original)
    exit 0
}

# Archivos de prueba (nombre "TEST_..."): al arrancar en PREPARAR se ELIMINA su job si ya existe, para
# que SIEMPRE se re-preparen desde cero (util al iterar la misma muestra cambiando opciones sin tener
# que borrar el .job.json a mano). NO se hace en modo -WorkerOnly: una ventana worker que lanza otra
# instancia necesita el job ya creado para codificar (borrarlo la dejaria sin trabajo).
if (-not $WorkerOnly) {
    foreach ($f in $files) {
        $tn = $f.BaseName
        if ($tn.StartsWith('TEST_', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-CvJob -Context $ctx -Name $tn)) {
            Remove-CvJob -Context $ctx -Name $tn
            Write-CvLog 'GLOBAL' ("[PREPARAR] - Archivo de prueba: job eliminado para reinicio limpio -> {0}.job.json" -f $tn)
        }
    }
}

# Bloquear el boton X de la ventana para no cerrarla por error a mitad de proceso.
# El trap garantiza reactivarlo si algo falla; tambien se reactiva al terminar bien.
if ($ctx.LockClose) { Set-CvCloseButton -Enabled $false }
trap {
    if ($ctx.LockClose) { try { Set-CvCloseButton -Enabled $true } catch {} }
    if ($cvLog) { Stop-CvLog }
    break
}

$needPrepare = $false
if (-not $WorkerOnly) {
    foreach ($f in $files) {
        $name = $f.BaseName
        if ((Test-Path -LiteralPath (Get-OutputPath $ctx $name))) { continue }   # ya convertido
        if (-not (Test-CvJob -Context $ctx -Name $name)) { $needPrepare = $true; break }
    }
}

# ============================================================
#  FASE PREPARAR
# ============================================================
if ($needPrepare) {
    $cfgProfile = Select-Profile -Extra $ctx.Profiles -Context $ctx
    if ($null -eq $cfgProfile) {
        # El usuario eligio salir (X): cierre limpio.
        Write-CvLog 'GLOBAL' '[SALIR] - Cancelado por el usuario.'
        if ($ctx.LockClose) { Set-CvCloseButton -Enabled $true }
        if ($cvLog) { Stop-CvLog }
        exit 0
    }
    # Perfil de config.json con videoEncoder: "auto" -> resolver aqui al mejor encoder del equipo
    # (con la sonda de GPU y los filtros autoGpuOnly/autoMaxCodec), conservando el resto del perfil.
    # La opcion "A" del menu ya devuelve un encoder concreto, asi que esto es no-op para ella.
    $cfgProfile = Resolve-CvProfileAuto -Context $ctx -Prof $cfgProfile
    Write-ProfileInfo -Prof $cfgProfile

    Write-CvLog 'GLOBAL' '[PREPARAR] - Generando configuracion de los archivos...'
    foreach ($f in $files) {
        $name = $f.BaseName
        if (Test-Path -LiteralPath (Get-OutputPath $ctx $name)) { continue }
        if (Test-CvJob -Context $ctx -Name $name)    { continue }

        # Cabecera del archivo ANTES de las preguntas: en modo normal el nombre va arriba para
        # que los menus/preguntas (video, audio, subtitulos, bordes, sincronia) queden debajo y
        # se sepa siempre de que archivo son; en debug la cabecera completa va mas abajo.
        if (-not $ctx.Debug) { Write-PrepareHeader -Name $name }

        $info = Get-MediaInfo -Context $ctx -File $f.FullName
        if ($null -eq $info) {
            if ($ctx.Debug) { Write-CvLog 'PREPARAR' ("[ERR] - No se pudo leer {0}" -f $name) } else { Write-PrepareStatus -Ok $false }
            continue
        }

        $forceBorder = $name.StartsWith('_')

        # Modo debug: detalle completo (cabecera + logs de cada modulo). Modo normal: los
        # modulos van en silencio (sus [INFO] solo con debug) y se resume en 1 linea al final.
        if ($ctx.Debug) {
            Write-Host ''
            Write-Host ''
            Write-Host $sepLine
            Write-CvLog 'PREPARAR' ("ARCHIVO: {0}" -f $name)
            Write-Host $sepLine
            Write-CvLog 'PREPARAR' ("[INFO] - Tamano: {0}  Duracion: {1}" -f (Get-VideoSize (Get-VideoStream $info)), (Get-DurationText $info))
            Write-Host ''
        }

        $vAsk   = Invoke-VideoAsk -Context $ctx -Prof $cfgProfile -Info $info -ForceBorder $forceBorder
        # Aviso si se COPIA el vídeo desde un contenedor problemático (p. ej. AVI): el stream-copy a MKV
        # puede fallar por timestamps. Se avisa aquí para que se sepa antes de codificar (no se bloquea).
        if ($vAsk.Skip) {
            $copyWarn = Get-CvVideoCopyRemuxWarning -Path $f.FullName
            if ($copyWarn) { Write-CvLog 'VIDEO' ("[AVISO] - {0}" -f $copyWarn) -Indent 3 }
        }
        $aAsk   = Invoke-AudioAsk -Context $ctx -Prof $cfgProfile -Info $info
        $subManual = $false
        $subSel = Select-Subtitles -Context $ctx -Info $info -Manual ([ref]$subManual)

        # Congelar el perfil + las respuestas + las versiones de herramientas en el job
        # (autosuficiente: el worker usara estas versiones y las instalara si faltan).
        $job = [ordered]@{
            file           = $f.FullName
            profile        = $cfgProfile
            ffmpegVersion  = $ctx.FFmpegVersion
            aacgainVersion = $ctx.AacGainVersion
            video          = @{
                skip   = $vAsk.Skip
                index  = $vAsk.Index
                crop   = $vAsk.Crop
                resize = $vAsk.Resize
                anim   = $vAsk.Anim
                hdr    = [bool](Test-CvHdr -Info $info -Index $(if ($null -ne $vAsk.Index) { [int]$vAsk.Index } else { -1 }))
            }
            audio          = @{
                skip   = $aAsk.Skip
                tracks = @($aAsk.Tracks | ForEach-Object {
                    @{
                        index   = $_.Index
                        is51    = $_.Is51
                        sync    = $_.Sync
                        lang    = $_.Lang
                        default = $_.Default
                    }
                })
            }
            subtitles      = @($subSel)
        }
        Write-CvJob -Context $ctx -Name $name -Job $job

        # Hubo intervencion manual si el archivo necesito CUALQUIER pregunta: seleccion de pista
        # de video/audio/subtitulo, deteccion de bordes, animacion o sincronia. Se marca [AVISO].
        $manual = ([bool]$vAsk.Manual) -or ([bool]$aAsk.Manual) -or $subManual
        if ($ctx.Debug) {
            Write-Host ''
            Write-CvLog 'PREPARAR' ("[OK] - Job creado: {0}.job.json{1}" -f $name, $(if ($manual) { ' (seleccion manual)' } else { '' }))
        } else {
            Write-PrepareStatus -Ok $true -Warn:$manual
        }
    }
    Write-CvLog 'GLOBAL' '[PREPARAR] - Configuracion completada.'

    # Preguntar cuantos workers codificaran EN PARALELO (esta ventana + N-1 ventanas nuevas).
    # Las ventanas nuevas se lanzan en modo -WorkerOnly: como ya esta todo preparado, entran
    # directas a codificar sin preguntar y se reparten los archivos por el lock.
    Write-Host ''
    $defW = [int]$ctx.Workers; if ($defW -lt 0) { $defW = 0 }
    $ans = (Read-Host ("[GLOBAL] - Workers en paralelo, contando esta ventana (ENTER = {0}, 0 = solo preparar y salir)" -f $defW)).Trim()
    $nw = $defW
    if ($ans -ne '') { $n = 0; if ([int]::TryParse($ans, [ref]$n) -and $n -ge 0) { $nw = $n } }

    if ($nw -le 0) {
        # Solo preparar: no se codifica ni se abre ningun worker. Los jobs quedan listos para
        # lanzar la conversion despues (abriendo Convert.cmd cuando se quiera).
        Write-CvLog 'GLOBAL' '[PREPARAR] - Solo preparar: los jobs quedan listos. Abre Convert.cmd cuando quieras codificar.'
        if ($ctx.LockClose) { Set-CvCloseButton -Enabled $true }
        if ($cvLog) { Stop-CvLog }
        exit 0
    }

    # No abrir mas workers que archivos por codificar (jobs pendientes sin salida). Con 1 solo
    # archivo no se abre ninguna ventana extra: se codifica en esta misma.
    $pending = @($files | Where-Object {
        (-not (Test-Path -LiteralPath (Get-OutputPath $ctx $_.BaseName))) -and (Test-CvJob -Context $ctx -Name $_.BaseName)
    }).Count
    $cap = [Math]::Max(1, $pending)
    if ($nw -gt $cap) {
        Write-CvLog 'GLOBAL' ("[WORKER] - {0} archivo(s) por codificar; se usan {1} worker(s) en vez de {2}." -f $pending, $cap, $nw)
        $nw = $cap
    }

    $extra = $nw - 1
    if ($extra -gt 0) {
        $cmdPath = Join-Path $Root 'Convert.cmd'
        # Los workers extra heredan el mismo -Config (ruta absoluta ya resuelta), solo si el
        # usuario lo indico (sin -Config cada ventana resuelve su config.json por defecto).
        $wArgs = @('-WorkerOnly')
        if (-not [string]::IsNullOrWhiteSpace($Config)) { $wArgs += @('-Config', ('"{0}"' -f $cfgPath)) }
        $opened = 0
        for ($i = 1; $i -le $extra; $i++) {
            try { Start-Process -FilePath $cmdPath -ArgumentList $wArgs -WorkingDirectory $Root | Out-Null; $opened++ }
            catch { Write-CvLog 'GLOBAL' ("[AVISO] - No se pudo abrir un worker adicional: {0}" -f $_.Exception.Message) }
        }
        Write-CvLog 'GLOBAL' ("[WORKER] - Abiertos {0} worker(s) adicional(es); {1} en paralelo." -f $opened, ($opened + 1))
    }
}

# ============================================================
#  FASE WORKER
# ============================================================
Write-Host ''
Write-CvLog 'GLOBAL' '[WORKER] - Buscando archivos preparados para codificar...'

# Reintentos: nº de fallos por archivo; a partir de $maxRetries se abandona (evita bucle
# infinito con inputs corruptos, perfiles que fallan o ffmpeg que no arranca).
$skip = New-Object 'System.Collections.Generic.HashSet[string]'
$fail = @{}
# Resultado FINAL por archivo procesado por ESTE worker (para el resumen del final). Clave = nombre;
# se sobreescribe en cada intento, asi que refleja el ultimo estado (OK si acabo bien, ERROR si no).
# Cada valor: @{ Status; Reason; Attempts; Elapsed }.
$results = [ordered]@{}
$workerSw = [System.Diagnostics.Stopwatch]::StartNew()   # tiempo total del worker (para el resumen)
$maxRetries = [int]$ctx.Retries; if ($maxRetries -lt 1) { $maxRetries = 1 }

$didAny = $true
while ($didAny) {
    $didAny = $false
    foreach ($f in (Get-ProcessableFiles -Context $ctx -Quiet)) {
        $name = $f.BaseName
        if ($skip.Contains($name)) { continue }                        # marcado como no procesable
        $out  = Get-OutputPath $ctx $name
        if (Test-Path -LiteralPath $out) { continue }                       # ya hecho
        if (-not (Test-CvJob -Context $ctx -Name $name)) { continue }  # sin preparar

        # Reclamo atomico
        if (-not (Enter-Lock -Context $ctx -Name $name)) { continue }  # lo tiene otro worker
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Write-Host ''
            Write-Host ''
            Write-Host $sepLine
            Write-CvLog 'WORKER' ("CODIFICANDO: {0}" -f $name)
            Write-Host $(if ($ctx.Debug) { $sepLine } else { $dashLine })

            $job  = Read-CvJob -Context $ctx -Name $name
            $prof = $job.profile

            # Versiones de herramientas fijadas en el job (fallback a la del contexto).
            $ffVer = "$($job.ffmpegVersion)";  if ([string]::IsNullOrWhiteSpace($ffVer)) { $ffVer = $ctx.FFmpegVersion }
            $agVer = "$($job.aacgainVersion)"; if ([string]::IsNullOrWhiteSpace($agVer)) { $agVer = $ctx.AacGainVersion }

            # Asegurar ffmpeg de la version del job (se instala si falta). Si no se puede,
            # se marca para no reintentar en bucle y se pasa al siguiente.
            if (-not (Confirm-CvTool -Context $ctx -Name 'ffmpeg' -Version $ffVer)) {
                Write-CvLog 'WORKER' ("[ERR] - No se pudo obtener ffmpeg {0}; se omite este archivo" -f $ffVer)
                $results[$name] = @{
                    Status   = 'ERROR'
                    Reason   = ("no se pudo obtener ffmpeg {0}" -f $ffVer)
                    Attempts = 1
                    Elapsed  = $null
                }
                [void]$skip.Add($name); continue
            }
            $didAny = $true
            $jctx = New-CvToolContext -Context $ctx -FFmpegVersion $ffVer -AacGainVersion $agVer
            # Adjuntar el job al contexto del worker: la seccion 'AJUSTES DEL JOB' del log de error
            # (Show-CvToolError -> Save-CvToolError) lo lee de aqui sin tener que pasarlo por cada Invoke-*.
            $jctx | Add-Member -NotePropertyName CurrentJob -NotePropertyValue $job -Force
            if ($jctx.Debug) { Write-CvLog 'WORKER' ("[INFO] - ffmpeg {0}" -f $ffVer) } else { Write-Host (" - ffmpeg {0}" -f $ffVer) }
            if ("$($jctx.VolumeMethod)".ToLower() -eq 'aacgain' -and -not (Confirm-CvTool -Context $ctx -Name 'aacgain' -Version $agVer)) {
                Write-CvLog 'WORKER' ("[AVISO] - No se pudo obtener aacgain {0}; el ajuste de volumen se omitira" -f $agVer)
            }

            $info = Get-MediaInfo -Context $jctx -File $f.FullName
            if ($null -eq $info) {
                Write-CvLog 'WORKER' '[ERR] - No se pudo leer el archivo; se descarta'
                $results[$name] = @{
                    Status   = 'ERROR'
                    Reason   = 'no se pudo leer el archivo'
                    Attempts = 1
                    Elapsed  = $null
                }
                [void]$skip.Add($name); continue
            }

            # Info del archivo (util para saber cuanto durara la codificacion).
            $vs  = Get-VideoStream $info
            $res = if ($vs) { ("Resolucion: {0}  Duracion: {1}" -f (Get-VideoSize -VideoStream $vs), (Get-DurationText $info)) } else { ("Duracion: {0}" -f (Get-DurationText $info)) }
            if ($jctx.Debug) { Write-CvLog 'WORKER' ("[INFO] - {0}" -f $res) } else { Write-Host (" - {0}" -f $res) }

            # Modo pruebas: resumen COMPLETO de las pistas del origen antes de codificar.
            if ($jctx.TestLimit -gt 0) { Write-SourceSummary -Context $jctx -File $f.FullName -Info $info }

            # Validar el encoder por GPU del job contra ESTA GPU (misma sonda que el menu, pero aqui
            # PARA CADA PROCESO): asi un job ya creado o un perfil de config.json con un encoder que la
            # GPU no soporta (p. ej. av1_nvenc en GPUs anteriores a RTX 40) falla YA con un mensaje
            # claro, en vez del error criptico de ffmpeg a mitad de la codificacion. No se reintenta.
            $vEnc = "$($prof.VideoEncoder)"
            if (-not $job.video.skip -and -not (Test-CvEncoderSupported -Context $jctx -Encoder $vEnc)) {
                Write-CvLog 'WORKER' ("[ERR] - El encoder de video '{0}' no lo soporta la GPU de este equipo; no se codifica. Usa un perfil de CPU (libx264/libx265) o, para AV1, libsvtav1 (CPU)." -f $vEnc)
                $results[$name] = @{
                    Status   = 'ERROR'
                    Reason   = ("encoder '{0}' no soportado por la GPU de este equipo" -f $vEnc)
                    Attempts = 1
                    Elapsed  = $null
                }
                [void]$skip.Add($name); continue
            }

            # ---------- CONVERSION ----------
            # Spec de render (job -> decisiones): fuente unica de las pistas de audio (canales/downmix/
            # idioma/titulo/default ya resueltos), que usan el pipeline por etapas y el resumen final.
            $spec = Resolve-CvRenderSpec -Context $jctx -Prof $prof -Job $job -Info $info
            $failReason = ''
            $ok = $false
            # Ejecucion en UNA sola pasada (BETA) si el job es elegible; si no, pipeline por etapas.
            $onePass = Test-CvOnePassEligible -Context $jctx -Job $job -Prof $prof
            if ($onePass.Ok) {
                Write-CvInfoStep $jctx 'WORKER' 'Modo una sola pasada [beta] (audio + video + multiplexado en un ffmpeg)'
                $ok = Invoke-CvOnePass -Context $jctx -Prof $prof -File $f.FullName -Info $info -Job $job -Duration (Get-MediaDuration $info)
                if (-not $ok) { $failReason = 'fallo en la ejecucion unica' }
            }
            else {
            if ($jctx.Debug -and $jctx.BetaOnePass) { Write-CvLog 'WORKER' ("[1PASS] - No aplica ({0}); se usa el pipeline por etapas" -f $onePass.Reason) }

            # ---------- AUDIO ----------
            if ($jctx.Debug) { Write-Host '' }
            $audioOk = $true
            $audioTracks = @()   # pistas para el multiplex: {Source='temp'|'copy'; File; Index; Lang; Default}
            if ($job.audio.skip) {
                # copy: no se recodifica. Con pistas elegidas (multipista beta en copy) se copian esas del
                # original; sin pistas (copy clasico) el multiplex cae a 0:a:0.
                if ($jctx.Debug) { Write-CvLog 'AUDIO' '[SKIP] - se omite recodificar (copy)' } else { Write-Host ' - Audio (copy)' }
                foreach ($t in $spec.Audio) {
                    $audioTracks += [pscustomobject]@{
                        Source  = 'copy'
                        File    = ''
                        Index   = [int]$t.Index
                        Lang    = "$($t.Lang)"
                        Default = [bool]$t.Default
                    }
                }
            }
            else {
                # Recodificar CADA pista a su temporal (<name>_aN.*). pos 0 = predeterminada (va 1a).
                $adur = Get-MediaDuration $info
                for ($ti = 0; $ti -lt $spec.Audio.Count; $ti++) {
                    $t = $spec.Audio[$ti]
                    if ($spec.Audio.Count -gt 1) { Write-CvInfoStep $jctx 'AUDIO' ("Pista {0}/{1} (idioma={2}{3})" -f ($ti + 1), $spec.Audio.Count, $t.Lang, $(if ($t.Default) { ', predeterminada' } else { '' })) }
                    # Canales de origen (para que audioChannels no haga upmix: es un maximo) ya resueltos en el spec.
                    $outA = Invoke-AudioRun -Context $jctx -Prof $prof -File $f.FullName -Sync ([double]$t.Sync) -Index ([int]$t.Index) -Is51 ([bool]$t.Is51) -Duration $adur -SourceChannels ([int]$t.SourceChannels) -Pos $ti
                    if (-not $outA) { $audioOk = $false; break }
                    $audioTracks += [pscustomobject]@{
                        Source  = 'temp'
                        File    = "$outA"
                        Index   = [int]$t.Index
                        Lang    = "$($t.Lang)"
                        Default = [bool]$t.Default
                    }
                }
            }

            # ---------- VIDEO ----------
            if ($jctx.Debug) { Write-Host '' }
            $videoOk = $true
            # Indice de la pista de video elegida (congelado en PREPARAR). Jobs antiguos sin el
            # campo -> -1, y tanto Invoke-VideoRun como Invoke-Multiplex caen a '0:v:0' como antes.
            $vIdx = if ($null -ne $job.video.index) { [int]$job.video.index } else { -1 }
            if ($job.video.skip) { if ($jctx.Debug) { Write-CvLog 'VIDEO' '[SKIP] - se omite (copy)' } else { Write-Host ' - Video (copy)' } }
            else { $videoOk = Invoke-VideoRun -Context $jctx -Prof $prof -File $f.FullName -Crop $job.video.crop -Resize $job.video.resize -Anim ([bool]$job.video.anim) -Index $vIdx -Hdr ([bool]$job.video.hdr) -Duration (Get-MediaDuration $info) }

            # ---------- MULTIPLEX ----------
            if ((-not $audioOk) -or (-not $videoOk)) {
                $failReason = if (-not $audioOk) { 'fallo en la codificacion de audio' } else { 'fallo en la codificacion de video' }
                Write-CvLog 'WORKER' ("[ERR] - {0}; no se multiplexa" -f $failReason)
                $ok = $false
            } else {
                if ($jctx.Debug) { Write-Host '' }
                $ok = Invoke-Multiplex -Context $jctx -File $f.FullName -Info $info -VideoSkipped ([bool]$job.video.skip) -AudioSkipped ([bool]$job.audio.skip) -AudioTracks $audioTracks -Subtitles $job.subtitles -VideoIndex $vIdx
                if (-not $ok) { $failReason = 'fallo en el multiplexado' }
            }
            }   # fin del pipeline por etapas (else de la ejecucion unica)

            if ($ok) {
                # limpieza de temporales (activable/desactivable con el marcador 'keep_temp')
                if ($ctx.CleanTemps) {
                    Remove-CvTemps -Context $ctx -Name $name
                } elseif ($ctx.Debug) {
                    Write-CvLog 'WORKER' '[TEMP] - Se conservan los temporales (existe marcador keep_temp)'
                }
                Remove-CvJob -Context $ctx -Name $name
                $sw.Stop()
                if ($ctx.Debug) {
                    Write-Host ''
                    Write-CvLog 'WORKER' ("[OK] - Finalizado: {0}" -f $name)
                }
                # Indice de audio de origen para el resumen: la pista predeterminada (1a de la lista);
                # con varias pistas el resumen las enumera todas de la salida (no usa este indice).
                $sumAIdx = if ($spec.Audio.Count -gt 0) { [int]$spec.Audio[0].Index } else { -1 }
                Write-ConversionSummary -Context $jctx -File $f.FullName -Info $info -Output $out -Elapsed $sw.Elapsed -Prof $prof -AudioIndex $sumAIdx

                # Control de calidad de la salida vs origen (encode.qualityCheck; no en 'copy'). Es una
                # pasada extra de ffmpeg (fuera del tiempo de conversion de arriba); fail-soft.
                if ($ctx.QualityCheck -ne 'off' -and -not $job.video.skip) {
                    # Measure-CvQuality muestra su propia linea de progreso en vivo (Invoke-ToolProgress).
                    $qScore = Measure-CvQuality -Context $jctx -Source $f.FullName -Output $out -Metric $ctx.QualityCheck
                    if ($null -ne $qScore) {
                        $qTxt = if ($ctx.QualityCheck -eq 'vmaf') { "{0} / 100" -f (Format-CvNumber $qScore) } else { "{0}  (0-1, 1 = identico)" -f (Format-CvNumber $qScore) }
                        Write-CvLog 'WORKER' ("[QC] - Calidad {0}: {1}" -f $ctx.QualityCheck.ToUpper(), $qTxt)
                    } else {
                        Write-CvLog 'WORKER' ("[QC] - No se pudo medir la calidad ({0}); se continua (vmaf requiere libvmaf en ffmpeg)." -f $ctx.QualityCheck)
                    }
                }
                $results[$name] = @{
                    Status   = 'OK'
                    Reason   = ''
                    Attempts = ([int]$fail[$name] + 1)
                    Elapsed  = $sw.Elapsed
                }
            } else {
                if (-not $failReason) { $failReason = 'no se genero la salida' }
                $results[$name] = @{
                    Status   = 'ERROR'
                    Reason   = $failReason
                    Attempts = ([int]$fail[$name] + 1)
                    Elapsed  = $null
                }
                $n = 1 + [int]$fail[$name]; $fail[$name] = $n
                Write-Host ''
                if ($n -ge $maxRetries) {
                    Write-CvLog 'WORKER' ("[ERR] - Fallo {0} intento(s), se abandona: {1}" -f $n, $name)
                    [void]$skip.Add($name)
                    # Advertencia destacada en consola (el detalle de ffmpeg, si lo hubo, ya se mostro
                    # y se guardo en logs\error_*.log via Show-CvToolError).
                    Show-CvBox -Title 'ERROR - No se pudo convertir el archivo' -Lines @($name, ("Motivo: {0}" -f $failReason), 'Detalle en logs\ (error_*.log si fallo ffmpeg).') -Color Red
                } else {
                    Write-CvLog 'WORKER' ("[ERR] - No se genero la salida (intento {0}/{1}), se reintentara: {2}" -f $n, $maxRetries, $name)
                }
            }
        }
        catch {
            # Error inesperado: no abortar todo el lote; contar el fallo y pasar al siguiente.
            $n = 1 + [int]$fail[$name]; $fail[$name] = $n
            $emsg = "$($_.Exception.Message)"
            $results[$name] = @{
                Status   = 'ERROR'
                Reason   = ("error inesperado: {0}" -f $emsg)
                Attempts = $n
                Elapsed  = $null
            }
            Write-CvLog 'WORKER' ("[ERR] - Error inesperado en {0}: {1}" -f $name, $emsg)
            if ($n -ge $maxRetries) {
                [void]$skip.Add($name)
                Show-CvBox -Title 'ERROR - No se pudo convertir el archivo' -Lines @($name, ("Motivo: error inesperado - {0}" -f $emsg)) -Color Red
            }
        }
        finally {
            Exit-Lock -Context $ctx -Name $name
        }
    }
}

Write-Host ''
Write-CvLog 'GLOBAL' '[END] - No quedan archivos libres por procesar'

# Resumen de TODO lo que ha procesado este worker (OK/ERROR + motivo de los fallos). Solo si ha
# tocado algun archivo (si no, no ensucia con un resumen vacio cuando no habia nada que hacer).
$workerSw.Stop()
$done = @($results.Keys)
if ($done.Count -gt 0) {
    $nOk  = @($done | Where-Object { $results[$_].Status -eq 'OK' }).Count
    $nErr = $done.Count - $nOk
    Write-Host ''
    Write-Host $sepLine
    Write-Host '  RESUMEN DEL WORKER'
    Write-Host $dashLine
    foreach ($n in $done) {
        $r    = $results[$n]
        $isOk = ($r.Status -eq 'OK')
        Write-Host '  ' -NoNewline
        Write-Host (Get-CvMark $isOk) -ForegroundColor $(if ($isOk) { 'Green' } else { 'Red' }) -NoNewline
        Write-Host (' ' + $n) -NoNewline
        if (-not $isOk) { Write-Host ('   -   ' + $r.Reason) -ForegroundColor Yellow -NoNewline }
        # Extra entre parentesis: tiempo (si OK) y nº de intentos (si hubo reintentos).
        $extra = @()
        if ($isOk -and $r.Elapsed) { $extra += (Format-CvEta $r.Elapsed.TotalSeconds) }
        if ([int]$r.Attempts -gt 1) { $extra += ("{0} intentos" -f [int]$r.Attempts) }
        if ($extra.Count -gt 0) { Write-Host ('   (' + ($extra -join ', ') + ')') -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
    }
    Write-Host $dashLine
    $totCol = if ($nErr -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ("  Total: {0}    OK: {1}    Errores: {2}    Tiempo: {3}" -f $done.Count, $nOk, $nErr, (Format-CvEta $workerSw.Elapsed.TotalSeconds)) -ForegroundColor $totCol
    Write-Host $sepLine
    if ($nErr -gt 0) { Write-CvLog 'GLOBAL' ("[AVISO] - {0} archivo(s) con error; revisa el resumen y logs\error_*.log" -f $nErr) }
}

# Reactivar el boton X al terminar.
if ($ctx.LockClose) { Set-CvCloseButton -Enabled $true }

# Cerrar el log de la ejecucion.
if ($cvLog) { Stop-CvLog }

# Pausa final: mantener la ventana del worker abierta para poder leer el RESUMEN antes de que se
# cierre (cada ventana en paralelo muestra el suyo). Solo si este worker proceso algo Y la entrada es
# INTERACTIVA (consola real). Con la entrada REDIRIGIDA (baterias de test, tuberias, CI) se OMITE: un
# 'Read-Host' sobre una tuberia abierta pero vacia se QUEDA BLOQUEADO esperando un ENTER que no llega
# (no devuelve EOF), asi que la bateria colgaria tras el resumen del worker.
if ((@($results.Keys).Count -gt 0) -and -not [Console]::IsInputRedirected) {
    Write-Host ''
    Read-Host 'ENTER para cerrar esta ventana' | Out-Null
}
