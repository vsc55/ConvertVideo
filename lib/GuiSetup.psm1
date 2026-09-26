<#
    GuiSetup.psm1 - Lo que la ventana de setup ESCRIBE y LANZA, sin ventana de por medio.

    Los textos de cada panel (Get-CvSetupStatusText, Get-CvSetupProfilesText, Get-CvSetupGpuText)
    salen de los objetos de lib\SetupCore.psm1, que es la fuente unica que comparten la consola
    (setup.ps1) y la ventana: aqui solo cambia el RENDER.

    Y Start-CvSetupTask, que es como se lanzan las acciones LARGAS -instalar una herramienta, una
    bateria de tests-: NO se ejecutan dentro de la ventana, se abren como 'setup.ps1 -Task ...' en su
    propia consola, para ver el progreso en vivo sin congelar WinForms, que es de un solo hilo.

    Las ventanas de esta familia: form\GuiSetupWindow.psm1 y sus dialogos (form\GuiToolsWindow.psm1,
    form\GuiLogsWindow.psm1, form\GuiMaintenanceWindow.psm1, form\GuiCleanWindow.psm1,
    form\GuiConfigChooser.psm1).
#>

function Get-CvSetupStatusText {
    <#
        Informe de ESTADO como texto plano (identidad + carpetas + herramientas + Proceso + trabajo),
        a partir de los datos de SetupCore: lo mismo que pinta Show-Estado en consola, pero sin
        colores. La GPU va aparte (Get-CvSetupGpuText) porque su sonda es lenta.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$CfgPath, [bool]$IsAlt = $false)
    $L = New-Object System.Collections.Generic.List[string]
    $id = Get-CvSetupIdentity -Context $Context -CfgPath $CfgPath -IsAlt $IsAlt
    $L.Add(("{0} v{1}" -f $id.AppName, $id.Version))
    $tag = if ($id.IsAlt) { 'alterno (-Config)' } else { 'por defecto' }
    $ex  = if ($id.Exists) { '' } else { '  (no existe -> se usan los valores por defecto)' }
    $L.Add(("  config: {0}  [{1}]{2}" -f $id.CfgPath, $tag, $ex))

    $L.Add('')
    $L.Add('Directorios de trabajo:')
    foreach ($d in (Get-CvSetupDirStatus -Context $Context)) {
        $extra = if ($d.Created) { ' (creada)' } else { '' }
        $L.Add(("  {0,-12} {1}{2}" -f $d.Name, (Get-CvMark $d.Ok), $extra))
    }

    $L.Add('')
    $L.Add('Estado de las herramientas:')
    foreach ($t in (Get-CvSetupToolStatus -Context $Context)) {
        if (-not $t.Supported) {
            $L.Add((Get-CvText -Key 'setup.tool.no' -Values @((Get-CvMark $false), $t.Name, $t.Platform, $t.Selected)))
            continue
        }
        $instTxt = if (@($t.Installed).Count) { (@($t.Installed) -join ', ') } else { 'ninguna' }
        $L.Add(("  {0} {1,-10} [{2}] instaladas: {3,-22} por defecto (config): {4}" -f (Get-CvMark $t.SelectedOk), $t.Name, $t.Platform, $instTxt, $t.Selected))
    }

    $L.Add('')
    $L.Add('Carpeta Proceso:')
    $p = Get-CvSetupProcesoStatus -Context $Context
    if (-not $p.Exists) {
        $L.Add('  (no existe)')
    } else {
        $staleTxt = if ($p.Stale -gt 0) { "  ({0} caducado(s)/huerfano(s))" -f $p.Stale } else { '' }
        $L.Add(("  jobs pendientes : {0}" -f $p.Jobs))
        $L.Add(("  bloqueos        : {0}{1}" -f $p.Locks, $staleTxt))
        $L.Add(("  temporales      : {0}" -f $p.Temps))
    }

    $L.Add('')
    $L.Add('Trabajo:')
    $w = Get-CvSetupWorkStatus -Context $Context
    $L.Add(("  en Original     : {0} video(s) de entrada" -f $w.Input))
    $L.Add(("  en Convertido   : {0} convertido(s)" -f $w.Converted))
    return ($L -join [Environment]::NewLine)
}

function Get-CvSetupProfilesText {
    <# Texto del panel de salida con los perfiles PROPIOS del config (los de 'profiles'). #>
    param([Parameter(Mandatory)][string]$CfgPath)
    $rows = @(Get-CvConfigProfileRows -Path $CfgPath)
    $serie = @(Get-CvBuiltinProfileRows).Count
    $sb = New-Object System.Text.StringBuilder
    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('No hay perfiles propios guardados.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Con "Perfiles..." creas uno y aparece en el menu de perfiles al preparar,')
        [void]$sb.AppendLine('tanto en la ventana de la cola como en la consola.')
        [void]$sb.AppendLine(("Ahi estan tambien los {0} de serie: no se editan, pero se DUPLICAN para partir de ellos." -f $serie))
        return $sb.ToString()
    }
    [void]$sb.AppendLine(("{0} perfil(es) propios en {1}:" -f $rows.Count, (Split-Path -Leaf $CfgPath)))
    [void]$sb.AppendLine('')
    foreach ($r in $rows) {
        [void]$sb.AppendLine(("  {0}" -f $r.Label))
        [void]$sb.AppendLine(("      {0}" -f $r.Text))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("Y los {0} de serie, que salen en la misma ventana en solo lectura: no se editan, pero se DUPLICAN para partir de ellos." -f $serie))
    return $sb.ToString()
}

function Get-CvSetupGpuText {
    <# Sonda EN VIVO de los encoders por GPU como texto (lo mismo que Show-GpuStatus, sin badges). #>
    param([Parameter(Mandatory)]$Context)
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('Codecs por GPU (NVENC) soportados por esta grafica (comprobacion en vivo):')
    $g = Get-CvSetupGpuStatus -Context $Context
    $L.Add(("  GPU: {0}" -f $(if ($g.Gpu) { $g.Gpu } else { '(no detectada)' })))
    if (-not $g.Ready) {
        $L.Add('  [AVISO] - ffmpeg no instalado: no se puede comprobar. Instala ffmpeg primero.')
        return ($L -join [Environment]::NewLine)
    }
    foreach ($e in $g.Encoders) {
        $txt = if ($e.Ok) { 'soportado' } else { 'NO soportado' }
        $L.Add(("  {0} {1,-12} {2}" -f (Get-CvMark $e.Ok), $e.Name, $txt))
    }
    return ($L -join [Environment]::NewLine)
}

function Start-CvSetupTask {
    <#
        Lanza 'setup.ps1 -Task <...>' en su PROPIA consola (Start-Process) y devuelve sin esperar: asi
        la ventana sigue viva mientras la descarga o la bateria de tests corren con su progreso a la
        vista. -Wait espera a que termine (util para refrescar el estado justo despues).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string[]]$TaskArgs,
        [switch]$Wait
    )
    $script = Join-Path $Root 'setup.ps1'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script), '-Config', ('"{0}"' -f $CfgPath)) + $TaskArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -PassThru
    if ($Wait -and $p) { $p.WaitForExit() }
    return $p
}

Export-ModuleMember -Function *
