<#
    Tools.psm1 - Descarga y gestion de herramientas externas (ffmpeg, aacgain...).

    Estructura en disco: tools\<app>\<version>\<plataforma>. El catalogo de apps,
    versiones (con SHA256) y plataforma esta en config.json (seccion 'downloads').
    Reutiliza funciones de otros modulos (Log: Write-CvLog; Exec: Invoke-ToolCapture;
    Console: Select-FromList), todos importados en la misma sesion.
#>

# ---------- HERRAMIENTAS VERSIONADAS: tools\<app>\<version>\<plataforma> ----------

function Get-CvPlatform {
    <# Plataforma en uso segun el SO. Solo hay binarios x64; x86 queda soportado en la ruta. #>
    if ([Environment]::Is64BitOperatingSystem) { return 'x64' } else { return 'x86' }
}

function Get-CvAppDescriptor {
    <# Descriptor de descarga de una app del catalogo 'downloads' (o $null). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $apps = $Context.Downloads
    if ($apps -is [System.Collections.IDictionary] -and $apps.Contains($Name)) { return $apps[$Name] }
    if ($apps -and $apps.PSObject.Properties[$Name]) { return $apps.$Name }
    return $null
}

function ConvertTo-CvPlatform {
    <# Normaliza una etiqueta de plataforma: *64/amd64/x86_64 -> x64; *86/*32/i386 -> x86. #>
    param([string]$Label)
    $l = "$Label".ToLower()
    if ($l -match '64')        { return 'x64' }
    if ($l -match '86|32|386') { return 'x86' }
    return 'x64'
}

function Get-CvAppPlatform {
    <# Plataforma (normalizada) del binario que ofrece el descriptor de una app. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $app = Get-CvAppDescriptor -Context $Context -Name $Name
    $lbl = if ($app) { "$($app.platform)" } else { '' }
    if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = 'x64' }
    return (ConvertTo-CvPlatform $lbl)
}

function Test-CvToolSupported {
    <# True si el binario de la app puede ejecutarse en este SO (x64 exige SO de 64 bits). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    if ((Get-CvAppPlatform -Context $Context -Name $Name) -eq 'x64') { return [Environment]::Is64BitOperatingSystem }
    return $true
}

function Get-CvToolDir {
    <# Carpeta de una app/version/plataforma: tools\<app>\<version>\<plataforma-del-binario>. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version, [string]$Platform = '')
    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = Get-CvAppPlatform -Context $Context -Name $Name }
    Join-Path $Context.Root ("tools\{0}\{1}\{2}" -f $Name, $Version, $Platform)
}

function Test-CvToolInstalled {
    <# True si estan TODOS los ficheros de la app en la carpeta de esa version/plataforma. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Version, [string]$Platform = '')
    $app = Get-CvAppDescriptor -Context $Context -Name $Name
    if ($null -eq $app -or [string]::IsNullOrWhiteSpace($Version)) { return $false }
    $dir = Get-CvToolDir -Context $Context -Name $Name -Version $Version -Platform $Platform
    foreach ($f in @($app.files)) { if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { return $false } }
    return $true
}

function Get-CvInstalledVersions {
    <# Versiones realmente instaladas de una app (carpetas con todos sus ficheros). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Platform = '')
    if ($null -eq (Get-CvAppDescriptor -Context $Context -Name $Name)) { return @() }
    $base = Join-Path $Context.Root ("tools\{0}" -f $Name)
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $out = @()
    foreach ($vdir in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
        if (Test-CvToolInstalled -Context $Context -Name $Name -Version $vdir.Name -Platform $Platform) { $out += $vdir.Name }
    }
    return @($out)
}

function Confirm-CvTool {
    <# Asegura que una version esta instalada; si falta, la descarga. Devuelve $true si queda disponible. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Version, [switch]$Quiet)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if (-not (Test-CvToolSupported -Context $Context -Name $Name)) {
        if (-not $Quiet) { Write-CvLog 'GLOBAL' ("[{0}] - [NO SOPORTADO] - No hay build para la plataforma de este equipo ({1})." -f $Name.ToUpper(), (Get-CvPlatform)) }
        return $false
    }
    if (Test-CvToolInstalled -Context $Context -Name $Name -Version $Version) { return $true }
    if (-not $Quiet) { Write-CvLog 'GLOBAL' ("[{0}] - Falta la version {1}; descargando..." -f $Name.ToUpper(), $Version) }
    return (Install-CvTool -Context $Context -Name $Name -Version $Version)
}

function New-CvToolContext {
    <#
        Clona el contexto apuntando las herramientas (ffmpeg/aacgain) a las versiones dadas.
        UNICA FUENTE de los nombres de ejecutable. Se usa al crear el contexto (version
        'selected') y en el worker (version congelada en el job). La carpeta la resuelve
        Get-CvToolDir con la plataforma del propio binario.
    #>
    param([Parameter(Mandatory)]$Context, [string]$FFmpegVersion = '', [string]$AacGainVersion = '')
    $c = $Context.PSObject.Copy()
    if (-not [string]::IsNullOrWhiteSpace($FFmpegVersion)) {
        $d = Get-CvToolDir -Context $Context -Name 'ffmpeg' -Version $FFmpegVersion
        $c.FFmpeg  = Join-Path $d 'ffmpeg.exe'
        $c.FFprobe = Join-Path $d 'ffprobe.exe'
        $c.FFplay  = Join-Path $d 'ffplay.exe'
        $c.FFmpegVersion = $FFmpegVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($AacGainVersion)) {
        $d = Get-CvToolDir -Context $Context -Name 'aacgain' -Version $AacGainVersion
        $c.AacGain = Join-Path $d 'aacgain.exe'
        $c.AacGainVersion = $AacGainVersion
    }
    # mkvpropedit (limpieza de etiquetas): ruta explicita de config si se indico, si no la
    # version 'selected' descargada en tools\mkvtoolnix\<ver>\<plataforma>.
    if ($c.PSObject.Properties['MkvPropEditOverride']) {
        $ov = "$($c.MkvPropEditOverride)"
        if (-not [string]::IsNullOrWhiteSpace($ov)) {
            $c.MkvPropEdit = $ov
        } else {
            $mkvApp = Get-CvAppDescriptor -Context $Context -Name 'mkvtoolnix'
            if ($mkvApp) {
                $md = Get-CvToolDir -Context $Context -Name 'mkvtoolnix' -Version "$($mkvApp.selected)"
                $c.MkvPropEdit = Join-Path $md 'mkvpropedit.exe'
            }
        }
    }
    # mkvextract (rescate de subtitulos que ffmpeg no puede leer, p.ej. WEBVTT embebido): misma
    # version 'selected' de mkvtoolnix, misma carpeta que mkvpropedit.
    if ($c.PSObject.Properties['MkvExtract']) {
        $mkvApp2 = Get-CvAppDescriptor -Context $Context -Name 'mkvtoolnix'
        if ($mkvApp2) {
            $md2 = Get-CvToolDir -Context $Context -Name 'mkvtoolnix' -Version "$($mkvApp2.selected)"
            $c.MkvExtract = Join-Path $md2 'mkvextract.exe'
        }
    }
    return $c
}

function Get-CvToolInstalledVersion {
    <#
        Lee la version realmente instalada ejecutando la app (versionExe/versionArgs/
        versionRegex del descriptor) en la carpeta de esa version/plataforma.
        Si no se indica Version, usa la 'selected'. Devuelve '' si no se puede leer.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Version = '', [string]$Platform = '')
    $app = Get-CvAppDescriptor -Context $Context -Name $Name
    if ($null -eq $app) { return '' }
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = "$($app.selected)" }

    $exe   = "$($app.versionExe)"
    $regex = "$($app.versionRegex)"
    if ([string]::IsNullOrWhiteSpace($exe) -or [string]::IsNullOrWhiteSpace($regex)) { return '' }
    $path = Join-Path (Get-CvToolDir -Context $Context -Name $Name -Version $Version -Platform $Platform) $exe
    if (-not (Test-Path -LiteralPath $path)) { return '' }

    $vargs = @()
    if ($app.versionArgs) { $vargs = @($app.versionArgs) }
    $r = Invoke-ToolCapture -Exe $path -Arguments $vargs -Context $Context
    $text = "$($r.StdOut)`n$($r.StdErr)"
    $m = [regex]::Match($text, $regex)
    if ($m.Success) {
        if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { return $m.Groups[1].Value }
        return $m.Value
    }
    return ''
}

function Get-CvNvencFallbackCandidates {
    <#
        Versiones a PROBAR como fallback cuando $Failed no soporta NVENC: de $Available (el catalogo
        de versiones), las MENORES que $Failed por numero de version, ordenadas de MAS NUEVA a mas
        antigua (se prueban una tras otra hasta dar con una compatible). Excluye $Failed, las mas
        nuevas (no ayudarian: el fallo es "driver demasiado antiguo para este ffmpeg") y las no
        comparables. Si $Failed no es numerica, devuelve todas las numericas (desc). Funcion pura.
    #>
    param([string]$Failed, [string[]]$Available)
    $fv = $null
    [void][version]::TryParse(("$Failed" -replace '[^\d\.]', ''), [ref]$fv)
    $cands = @()
    foreach ($a in @($Available)) {
        if ("$a" -eq "$Failed") { continue }
        $av = $null
        if (-not [version]::TryParse(("$a" -replace '[^\d\.]', ''), [ref]$av)) { continue }
        if ($null -eq $fv -or $av -lt $fv) {
            $cands += [pscustomobject]@{
                Name = "$a"
                Ver  = $av
            }
        }
    }
    @($cands | Sort-Object -Property Ver -Descending | ForEach-Object { $_.Name })
}

function Select-CvToolVersion {
    <#
        Muestra el catalogo de versiones de una app (seccion 'downloads') y devuelve la
        elegida. La 'selected' del config es la opcion por defecto. Devuelve '' si se cancela.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    $app = Get-CvAppDescriptor -Context $Context -Name $Name
    if ($null -eq $app) { return '' }

    $versions = @()
    if ($app.versions -is [System.Collections.IDictionary]) { $versions = @($app.versions.Keys) }
    elseif ($app.versions) { $versions = @($app.versions.PSObject.Properties.Name) }
    # Ordenar de mas nueva a mas antigua (por numero de version; las no numericas al final).
    $versions = @($versions | Sort-Object -Descending {
        $v = $null
        if ([version]::TryParse(("$_" -replace '[^\d\.]', ''), [ref]$v)) { $v } else { [version]'0.0.0' }
    })
    if ($versions.Count -eq 0) { return "$($app.selected)" }
    if ($versions.Count -eq 1) { return "$($versions[0])" }

    $sel = "$($app.selected)"
    $defIdx = [array]::IndexOf($versions, $sel) + 1
    if ($defIdx -lt 1) { $defIdx = 1 }
    return (Select-FromList -Title ("Version de {0} a instalar:" -f $Name) -Options $versions -NoneLabel 'cancelar' -DefaultIndex $defIdx)
}

function Install-CvTool {
    <#
        Descarga e instala una app del catalogo 'downloads' del config: descarga el zip de
        la version seleccionada, verifica el SHA256 (si hay), extrae y copia los ficheros
        indicados a su carpeta destino. Generico: sirve para ffmpeg u otras apps.
        Devuelve $true si quedan todos los ficheros instalados. -NvencOk (opcional): si se pasa un
        [ref], recibe el resultado de la comprobacion NVENC de ffmpeg ($true si compatible o si no
        aplica); lo usa setup para volver a la version anterior si la nueva no soporta NVENC.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [string]$Version = '', [ref]$NvencOk = $null)
    $tag  = "[{0}]" -f $Name.ToUpper()
    $app  = Get-CvAppDescriptor -Context $Context -Name $Name
    if ($null -eq $app) { Write-CvLog 'GLOBAL' ("{0} - [ERR] - No hay descriptor de descarga para '{1}'" -f $tag, $Name); return $false }

    if (-not (Test-CvToolSupported -Context $Context -Name $Name)) {
        Write-CvLog 'GLOBAL' ("{0} - [NO SOPORTADO] - No hay build de {1} para la plataforma de este equipo ({2})." -f $tag, $Name, (Get-CvPlatform))
        return $false
    }

    # Dependencias declaradas (descriptor 'dependsOn'): se aseguran antes (cada una es otra app
    # del catalogo). P. ej. mkvtoolnix depende de 'sevenzip' (7zr) para extraer su .7z.
    foreach ($dep in @($app.dependsOn)) {
        if ([string]::IsNullOrWhiteSpace("$dep")) { continue }
        $depApp = Get-CvAppDescriptor -Context $Context -Name "$dep"
        $depVer = if ($depApp) { "$($depApp.selected)" } else { '' }
        Write-CvLog 'GLOBAL' ("{0} - Dependencia: {1} {2}" -f $tag, $dep, $depVer)
        if (-not (Confirm-CvTool -Context $Context -Name "$dep" -Version $depVer -Quiet)) {
            Write-CvLog 'GLOBAL' ("{0} - [ERR] - No se pudo obtener la dependencia '{1}'" -f $tag, $dep)
            return $false
        }
    }

    $ver = if (-not [string]::IsNullOrWhiteSpace($Version)) { $Version } else { "$($app.selected)" }
    if ([string]::IsNullOrWhiteSpace($ver)) { Write-CvLog 'GLOBAL' ("{0} - [ERR] - Version no seleccionada" -f $tag); return $false }
    $url    = ("$($app.url)")     -replace '\{version\}', $ver
    $binRel = ("$($app.binPath)") -replace '\{version\}', $ver
    $files  = @($app.files)
    $destDir = Get-CvToolDir -Context $Context -Name $Name -Version $ver

    # SHA del catalogo de versiones.
    $versions = $app.versions
    $sha = ''
    if ($versions -is [System.Collections.IDictionary]) { if ($versions.Contains($ver)) { $sha = "$($versions[$ver])" } }
    elseif ($versions -and $versions.PSObject.Properties[$ver]) { $sha = "$($versions.$ver)" }

    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $tmp = Join-Path $env:TEMP ("cv_dl_{0}_{1}" -f $Name, $ver)
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # Tipo de descarga: 'zip'/'7z' (extraen) o 'file' (ejecutable directo). Por defecto 'zip'.
    $type = "$($app.type)"; if ([string]::IsNullOrWhiteSpace($type)) { $type = 'zip' }
    $dl = Join-Path $tmp $(switch ($type) { 'zip' { 'pkg.zip' } '7z' { 'pkg.7z' } default { 'pkg.dat' } })

    Write-CvLog 'GLOBAL' ("{0} - Descargando {1} {2} (puede tardar)..." -f $tag, $Name, $ver)
    Write-CvLog 'GLOBAL' ("{0} - {1}" -f $tag, $url)
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # Descarga con reintentos (fallos de red transitorios).
    $attempts = 3
    $downloaded = $false
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dl -UseBasicParsing
            $downloaded = $true; break
        } catch {
            Write-CvLog 'GLOBAL' ("{0} - [AVISO] - Descarga fallida (intento {1}/{2}): {3}" -f $tag, $i, $attempts, $_.Exception.Message)
            if (Test-Path $dl) { Remove-Item -Force $dl -ErrorAction SilentlyContinue }
            if ($i -lt $attempts) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    $ProgressPreference = $oldPref
    if (-not $downloaded -or -not (Test-Path $dl)) {
        Write-CvLog 'GLOBAL' ("{0} - [ERR] - No se pudo descargar tras {1} intentos" -f $tag, $attempts)
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($sha)) {
        $got = (Get-FileHash -Path $dl -Algorithm SHA256).Hash
        if ($got.ToUpper() -ne $sha.Trim().ToUpper()) {
            Write-CvLog 'GLOBAL' ("{0} - [ERR] - SHA256 no coincide." -f $tag)
            Write-CvLog 'GLOBAL' ("{0} -   esperado: {1}" -f $tag, $sha)
            Write-CvLog 'GLOBAL' ("{0} -   obtenido: {1}" -f $tag, $got)
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            return $false
        }
        Write-CvLog 'GLOBAL' ("{0} - SHA256 verificado [OK]" -f $tag)
    } else {
        Write-CvLog 'GLOBAL' ("{0} - [AVISO] - Sin SHA256 para la version {1}, se omite la verificacion" -f $tag, $ver)
    }

    $ok = $true
    if ($type -eq 'file') {
        # Ejecutable directo: se copia (renombrando) al destino.
        $target = if ($files.Count -ge 1) { $files[0] } else { Split-Path $url -Leaf }
        try { Copy-Item -Force -Path $dl -Destination (Join-Path $destDir $target) }
        catch { Write-CvLog 'GLOBAL' ("{0} - [ERR] - No se pudo copiar: {1}" -f $tag, $_.Exception.Message); $ok = $false }
    } else {
        Write-CvLog 'GLOBAL' ("{0} - Extrayendo..." -f $tag)
        $extracted = $false
        if ($type -eq '7z') {
            # .7z (LZMA): se extrae con 7zr (app 'sevenzip', asegurada por dependsOn).
            $zApp = Get-CvAppDescriptor -Context $Context -Name 'sevenzip'
            $zVer = if ($zApp) { "$($zApp.selected)" } else { '' }
            $zr = Join-Path (Get-CvToolDir -Context $Context -Name 'sevenzip' -Version $zVer) '7zr.exe'
            if (-not (Test-Path -LiteralPath $zr)) {
                Write-CvLog 'GLOBAL' ("{0} - [ERR] - Falta el extractor 7z (7zr); anade 'sevenzip' a dependsOn." -f $tag)
                Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
                return $false
            }
            $r = Invoke-ToolCapture -Exe $zr -Arguments @('x', $dl, ("-o{0}" -f $tmp), '-y') -Context $Context
            $extracted = ($r.ExitCode -eq 0)
            if (-not $extracted) { Write-CvLog 'GLOBAL' ("{0} - [ERR] - 7zr devolvio codigo {1}" -f $tag, $r.ExitCode) }
        } else {
            try { Expand-Archive -Path $dl -DestinationPath $tmp -Force; $extracted = $true }
            catch { Write-CvLog 'GLOBAL' ("{0} - [ERR] - No se pudo extraer: {1}" -f $tag, $_.Exception.Message) }
        }
        if (-not $extracted) {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            return $false
        }
        # Carpeta con los binarios dentro del paquete; si no esta, se busca cada fichero.
        $bin = if ([string]::IsNullOrWhiteSpace($binRel)) { $tmp } else { Join-Path $tmp $binRel }
        foreach ($file in $files) {
            $src = Join-Path $bin $file
            if (-not (Test-Path $src)) {
                $alt = Get-ChildItem -Path $tmp -Recurse -File -Filter $file -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($alt) { $src = $alt.FullName }
            }
            if (Test-Path $src) { Copy-Item -Force -Path $src -Destination (Join-Path $destDir $file) }
            else { Write-CvLog 'GLOBAL' ("{0} - [ERR] - No se encontro {1} en el paquete" -f $tag, $file); $ok = $false }
        }
    }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

    if ($ok) {
        $iv = Get-CvToolInstalledVersion -Context $Context -Name $Name -Version $ver
        if ($iv) { Write-CvLog 'GLOBAL' ("{0} - [OK] - {1} instalado en {2} (version detectada: {3})" -f $tag, $Name, $destDir, $iv) }
        else     { Write-CvLog 'GLOBAL' ("{0} - [OK] - {1} {2} instalado en {3}" -f $tag, $Name, $ver, $destDir) }
        # Validacion de compatibilidad: para ffmpeg, comprobar que la codificacion por GPU
        # (NVENC) funciona con esta version y el driver NVIDIA de este equipo. El resultado se
        # expone por -NvencOk (si se paso) para que setup pueda volver a la version anterior.
        if ($Name -eq 'ffmpeg') {
            $nvOk = Write-CvNvencReport -Context $Context -Version $ver -Tag $tag
            if ($null -ne $NvencOk) { $NvencOk.Value = [bool]$nvOk }
        } elseif ($null -ne $NvencOk) { $NvencOk.Value = $true }
    }
    return $ok
}


function Test-CvNvenc {
    <#
        Comprueba si la codificacion por GPU NVIDIA (NVENC) funciona con una version de
        ffmpeg instalada, codificando un clip sintetico minimo. Reproduce el fallo tipico
        de "el driver no soporta la version de la API de NVENC" (ffmpeg 8 sobre drivers
        antiguos). Devuelve @{ Ok; Encoder; Causes = @(...) }.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Version)
    $exe = Join-Path (Get-CvToolDir -Context $Context -Name 'ffmpeg' -Version $Version) 'ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{
            Ok      = $false
            Encoder = ''
            Causes  = @('ffmpeg no instalado')
        }
    }
    $causes = @()
    foreach ($enc in 'hevc_nvenc','h264_nvenc') {
        $r = Invoke-ToolCapture -Exe $exe -Arguments @(
            '-hide_banner','-f','lavfi','-i','color=c=black:s=320x240:d=0.1','-c:v',$enc,'-f','null','-'
        ) -Context $Context
        if ($r.ExitCode -eq 0) {
            return [pscustomobject]@{
                Ok      = $true
                Encoder = $enc
                Causes  = @()
            }
        }
        if ($causes.Count -eq 0) { $causes = @(Get-CvNvencCause $r.StdErr) }
    }
    return [pscustomobject]@{
        Ok      = $false
        Encoder = ''
        Causes  = @($causes)
    }
}

function Get-CvNvencCause {
    <#
        Extrae de la salida de ffmpeg la(s) linea(s) que EXPLICAN el fallo de NVENC,
        ignorando el ruido de terminacion (Task finished / Terminating thread / -22 / -40)
        y quitando el prefijo "[hevc_nvenc @ 0x...] ". Devuelve hasta 2 lineas legibles.
    #>
    param([string]$StdErr)
    $lines = $StdErr -split "`r?`n"
    $cause = @($lines | Where-Object {
        $_ -match 'Driver does not support|minimum required|Cannot load|Failed loading|No capable devices|No NVENC|OpenEncodeSession|InitializeEncoder|Provided device|not supported' })
    if ($cause.Count -eq 0) {
        $cause = @($lines | Where-Object {
            $_ -match 'nvenc' -and $_ -notmatch 'Task finished|Terminating thread|Conversion failed|Error while opening encoder|Error sending frames' })
    }
    $clean = @($cause | Select-Object -First 2 | ForEach-Object { ($_ -replace '^\s*\[[^\]]*\]\s*', '').Trim() } | Where-Object { $_ })
    if ($clean.Count -eq 0) { $clean = @('la GPU o el driver no admiten NVENC con esta version.') }
    return $clean
}

function Write-CvNvencReport {
    <# Ejecuta Test-CvNvenc y escribe un veredicto claro: COMPATIBLE / NO COMPATIBLE. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Version, [string]$Tag = '[FFMPEG]')
    Write-CvLog 'GLOBAL' ("{0} - [GPU] - Comprobando compatibilidad de la codificacion por GPU (NVENC)..." -f $Tag)
    $nv = Test-CvNvenc -Context $Context -Version $Version
    if ($nv.Ok) {
        Write-Host ("[GLOBAL] {0} - [GPU] - " -f $Tag) -NoNewline
        Write-Host ' COMPATIBLE ' -ForegroundColor Black -BackgroundColor Green -NoNewline
        Write-Host (": la codificacion por GPU (NVENC) funciona ({0})." -f $nv.Encoder)
    } else {
        Write-Host ("[GLOBAL] {0} - [GPU] - " -f $Tag) -NoNewline
        Write-Host ' NO COMPATIBLE ' -ForegroundColor White -BackgroundColor Red -NoNewline
        Write-Host (": la codificacion por GPU (NVENC) no funciona con ffmpeg {0} en este equipo." -f $Version)
        $causes = @($nv.Causes)
        if ($causes.Count -gt 0) {
            Write-CvLog 'GLOBAL' ("{0} - [GPU] -   Causa:" -f $Tag)
            foreach ($c in $causes) { Write-CvLog 'GLOBAL' ("{0} - [GPU] -     {1}" -f $Tag, $c) }
        }
        Write-CvLog 'GLOBAL' ("{0} - [GPU] -   Solucion: perfil CPU (libx264/libx265), otra version de ffmpeg o actualizar el driver NVIDIA." -f $Tag)
    }
    return $nv.Ok
}

function Get-CvGpuEncoders {
    <#
        Fuente unica de los encoders por GPU NVIDIA (NVENC). Que la GPU los soporte de verdad depende
        del MODELO y del driver (p. ej. av1_nvenc solo en RTX 40+/Ada), asi que se comprueba en runtime
        con Test-CvEncoderSupported/Test-CvGpuEncoder; esta lista solo dice cuales SON GPU.
    #>
    @(
        'h264_nvenc'
        'hevc_nvenc'
        'av1_nvenc'
    )
}

# Cache de la comprobacion por-encoder de GPU (NVENC): la GPU/driver no cambian en la sesion, asi
# que cada encoder se prueba UNA vez. Clave = nombre del encoder; valor = $true/$false.
$script:CvGpuEncCache = @{}

function Reset-CvGpuEncCache {
    <# Vacia la cache de comprobacion de encoders por GPU (para tests). #>
    $script:CvGpuEncCache = @{}
}

function Test-CvGpuEncoder {
    <#
        Comprueba si un encoder por GPU (NVENC) FUNCIONA de verdad en este equipo (modelo de GPU +
        driver), codificando un clip sintetico minimo a null. Es mas PRECISO que Test-CvNvenc (que
        solo dice si NVENC va con esta version de ffmpeg): aqui se prueba EL encoder concreto, asi se
        detecta p. ej. que 'av1_nvenc' no lo soporta una GPU anterior a RTX 40 ("No capable devices
        found"). Memoiza por encoder. Devuelve $true/$false; $true si no hay ffmpeg resoluble (no
        bloquear: el fallo real ya saldria en la codificacion).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Encoder)
    if ($script:CvGpuEncCache.ContainsKey($Encoder)) { return $script:CvGpuEncCache[$Encoder] }
    $exe = "$($Context.FFmpeg)"
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { return $true }
    if ($Context.Debug) { Write-CvLog 'GLOBAL' ("[GPU] - Sondeando soporte de '{0}' en la GPU (encode sintetico)..." -f $Encoder) }
    $r = Invoke-ToolCapture -Exe $exe -Arguments @(
        '-hide_banner'
        '-f', 'lavfi'
        '-i', 'color=c=black:s=320x240:d=0.1'
        '-c:v', $Encoder
        '-f', 'null'
        '-'
    ) -Context $Context
    $ok = ($r.ExitCode -eq 0)
    $script:CvGpuEncCache[$Encoder] = $ok
    $ok
}

function Test-CvEncoderSupported {
    <#
        $true si $Encoder se puede usar en este equipo. Los de CPU (libx264/libx265/libsvtav1) y
        'copy' SIEMPRE valen; los de GPU (Get-CvGpuEncoders) se comprueban en runtime con
        Test-CvGpuEncoder (memoizado). Con $Context nulo devuelve $true (no bloquear; p. ej. tests).
    #>
    param($Context, [Parameter(Mandatory)][string]$Encoder)
    if ($Encoder -notin (Get-CvGpuEncoders)) { return $true }
    if ($null -eq $Context) { return $true }
    Test-CvGpuEncoder -Context $Context -Encoder $Encoder
}

function Get-CvGpuName {
    <#
        Nombre(s) de la(s) GPU del equipo (Win32_VideoController), para CLAVAR la cache de la sonda:
        si cambia la GPU, la clave cambia y se vuelve a sondear. Devuelve '' si no se puede leer (la
        cache entonces se invalida por ffmpeg, o se re-sondea cada vez, que es seguro).
    #>
    try {
        $names = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            ForEach-Object { "$($_.Name)".Trim() } | Where-Object { $_ })
        return ($names -join ' | ')
    } catch {
        return ''
    }
}

function Write-CvGpuCapsSummary {
    <# Resumen en el log de que encoders por GPU soporta el equipo (a partir de la cache en memoria). #>
    param([bool]$Cached = $false)
    $gpu = @(Get-CvGpuEncoders)
    $ok  = @($gpu | Where-Object { $script:CvGpuEncCache["$_"] })
    $src = if ($Cached) { ' (cache)' } else { '' }
    if ($ok.Count -eq $gpu.Count) {
        Write-CvLog 'GLOBAL' ("[GPU] - Codificacion por GPU (NVENC) disponible, incluido AV1 (av1_nvenc){0}." -f $src)
    } elseif ($ok.Count -gt 0) {
        $okTxt = ($ok | ForEach-Object { $_ -replace '_nvenc', '' }) -join ', '
        Write-CvLog 'GLOBAL' ("[GPU] - Codificacion por GPU (NVENC) disponible: {0}{1}." -f $okTxt, $src)
        if ('av1_nvenc' -notin $ok) {
            Write-CvLog 'GLOBAL' '[GPU] - AV1 por GPU (av1_nvenc) NO lo soporta esta GPU (requiere RTX 40+/Ada); para AV1 usa libsvtav1 (CPU).'
        }
    } else {
        Write-CvLog 'GLOBAL' ("[GPU] - Sin codificacion por GPU (NVENC) en este equipo{0}; usa perfiles de CPU (libx264/libx265)." -f $src)
    }
}

function Read-CvGpuCache {
    <#
        Lee la cache de la sonda de GPU de $CfgPath (nodo 'gpuCache'). Devuelve el mapa encoder->bool
        SOLO si la cache es valida para este equipo AHORA: misma version de ffmpeg ($Ffmpeg) y misma
        GPU ($Gpu) y con datos. Si no coincide o no hay, devuelve $null (=> hay que sondear).
    #>
    param([string]$CfgPath, [string]$Ffmpeg, [string]$Gpu)
    if ([string]::IsNullOrWhiteSpace($CfgPath) -or -not (Test-Path -LiteralPath $CfgPath)) { return $null }
    try {
        $raw = Read-CvConfigFile -Path $CfgPath
        $gc  = Get-CvNodeVal $raw 'gpuCache'
        if (-not $gc) { return $null }
        if ("$(Get-CvNodeVal $gc 'ffmpeg')" -ne "$Ffmpeg") { return $null }
        if ("$(Get-CvNodeVal $gc 'gpu')"    -ne "$Gpu")    { return $null }
        $enc = Get-CvNodeVal $gc 'encoders'
        if (-not $enc -or @(Get-CvNodeKeys $enc).Count -eq 0) { return $null }
        return $enc
    } catch {
        return $null
    }
}

function Save-CvGpuCache {
    <# Persiste la sonda de GPU en $CfgPath (nodo 'gpuCache' = { ffmpeg; gpu; encoders{enc->bool} }),
       conservando el resto del fichero. Silencioso si no hay ruta o falla la escritura. #>
    param([string]$CfgPath, [string]$Ffmpeg, [string]$Gpu, [Parameter(Mandatory)]$Encoders)
    if ([string]::IsNullOrWhiteSpace($CfgPath)) { return }
    try {
        $raw = if (Test-Path -LiteralPath $CfgPath) { Read-CvConfigFile -Path $CfgPath } else { [pscustomobject]@{} }
        $gc  = [pscustomobject][ordered]@{
            ffmpeg   = "$Ffmpeg"
            gpu      = "$Gpu"
            encoders = ([pscustomobject]$Encoders)
        }
        Set-CvChildLeaf -Node $raw -Key 'gpuCache' -Value $gc
        Save-CvConfigFile -Path $CfgPath -Config $raw
    } catch {
        Write-CvLog 'GLOBAL' ("[GPU] - No se pudo guardar la cache de GPU en el config: {0}" -f $_.Exception.Message)
    }
}

function Initialize-CvGpuCaps {
    <#
        Al arrancar (GLOBAL, tras cargar config y asegurar ffmpeg, antes de distinguir preparacion /
        worker): deja en $script:CvGpuEncCache que encoders por GPU (NVENC) soporta ESTE equipo, para
        validar la seleccion en los menus y en el worker (por archivo) sin repetir el sondeo. Usa una
        CACHE en config.json (nodo 'gpuCache') clavada por version de ffmpeg + GPU:
          - si la cache coincide y tiene datos -> se usa (instantaneo, no toca la GPU).
          - si cambia la version de ffmpeg o la GPU, o no hay datos -> SONDEA (Test-CvGpuEncoder) y,
            si -Persist, actualiza la cache en el config.
        -Persist ($true por defecto): escribir la cache al sondear. Las ventanas worker en PARALELO
        (WorkerOnly) llaman con -Persist:$false para NO escribir config.json a la vez (evita choques);
        leen la cache que ya dejo el proceso de preparacion y, si faltara, sondean solo en memoria.
        Devuelve la lista de encoders GPU soportados.
    #>
    param([Parameter(Mandatory)]$Context, [string]$CfgPath = '', [bool]$Persist = $true)
    $gpuEnc = @(Get-CvGpuEncoders)
    $ffVer  = "$($Context.FFmpegVersion)"
    $gpuNm  = Get-CvGpuName

    $cached = Read-CvGpuCache -CfgPath $CfgPath -Ffmpeg $ffVer -Gpu $gpuNm
    if ($cached) {
        foreach ($e in @(Get-CvNodeKeys $cached)) { $script:CvGpuEncCache["$e"] = [bool](Get-CvNodeVal $cached $e) }
        Write-CvGpuCapsSummary -Cached $true
        return @($gpuEnc | Where-Object { $script:CvGpuEncCache["$_"] })
    }

    # Sin cache valida (primera vez, o cambio de ffmpeg/GPU): sondear y (si procede) persistir.
    Write-CvLog 'GLOBAL' '[GPU] - Comprobando compatibilidad de la GPU con los encoders por GPU (una sola vez; se cachea)...'
    $map = [ordered]@{}
    foreach ($e in $gpuEnc) { $map[$e] = [bool](Test-CvGpuEncoder -Context $Context -Encoder $e) }
    if ($Persist) { Save-CvGpuCache -CfgPath $CfgPath -Ffmpeg $ffVer -Gpu $gpuNm -Encoders $map }
    Write-CvGpuCapsSummary -Cached $false
    return @($gpuEnc | Where-Object { $map[$_] })
}

function Test-CvTools {
    <# Devuelve la lista de herramientas que faltan (vacia = todo OK). #>
    param([Parameter(Mandatory)]$Context)
    $missing = @()
    foreach ($t in 'FFmpeg','FFprobe','FFplay') {
        if (-not (Test-Path $Context.$t)) { $missing += $Context.$t }
    }
    # aacgain solo es necesario si el metodo de volumen es 'aacgain'.
    if ("$($Context.VolumeMethod)".ToLower() -eq 'aacgain' -and -not (Test-Path $Context.AacGain)) {
        $missing += $Context.AacGain
    }
    return $missing
}

Export-ModuleMember -Function *
