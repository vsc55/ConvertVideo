<#
    SubtitleSRT.psm1 - Ficheros de subtitulos SubRip (.srt) EXTERNOS: lectura/codificacion, correccion
    de texto y re-sincronizacion. (Distinto de Subtitle.psm1, que trata las PISTAS de subtitulo dentro
    de un video via ffprobe.)

    Dos bloques: (1) logica PURA (sin UI) y (2) helpers INTERACTIVOS para asistentes (usan Console/Log).
    Los consume FixSyncSub.ps1 y quedan disponibles para futuras funciones del conversor (p. ej.
    arreglar/re-sincronizar un .srt antes de multiplexarlo).
    El modelo de sincronizacion es lineal: t' = A * t + B (A = escala/deriva, B = desplazamiento en s).
#>

# Regex de la linea de tiempos "HH:MM:SS,mmm --> HH:MM:SS,mmm" (admite , o . como separador de ms).
$script:CvSrtTs = '(\d{1,2}:\d{1,2}:\d{1,2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{1,2}:\d{1,2}[,\.]\d{1,3})'

function ConvertTo-CvSrtSeconds {
    <# "HH:MM:SS,mmm" / "H:MM:SS.mmm" / "MM:SS" / segundos (admite signo) -> segundos (double). $null si invalido. #>
    param([string]$Time)
    $s = "$Time".Trim() -replace ',', '.'
    if ($s -match '^(\d{1,2}):(\d{1,2}):(\d{1,2}(?:\.\d+)?)$') { return [double]$Matches[1]*3600 + [double]$Matches[2]*60 + [double]$Matches[3] }
    if ($s -match '^(\d{1,2}):(\d{1,2}(?:\.\d+)?)$')          { return [double]$Matches[1]*60 + [double]$Matches[2] }
    if ($s -match '^[+-]?\d+(\.\d+)?$')                       { return [double]($s -replace '^\+', '') }
    return $null
}

function ConvertTo-CvSrtStamp {
    <# Segundos (double) -> marca SubRip "HH:MM:SS,mmm". Usa Get-CvTimeParts (recorta a 0 los negativos). #>
    param([double]$Seconds)
    $p = Get-CvTimeParts $Seconds
    '{0:00}:{1:00}:{2:00},{3:000}' -f $p.H, $p.M, $p.S, $p.MS
}

function Read-CvSrtText {
    <# Lee un .srt detectando la codificacion (BOM UTF-8, UTF-8 sin BOM, o Windows-1252) y devuelve el texto. #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)   # valida -> lanza si no es UTF-8
        return $strict.GetString($bytes)
    } catch {
        return [Text.Encoding]::GetEncoding(1252).GetString($bytes)    # Latin-1 / Windows-1252
    }
}

function Write-CvSrtText {
    <# Escribe el texto como .srt en UTF-8 (con o sin BOM), normalizando saltos de linea a CRLF. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Path, [bool]$Bom = $false)
    $t = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $t = $t.TrimEnd() + "`r`n"
    [IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($Bom)))
}

function Get-CvSrtBlocks {
    <# Divide el texto en bloques de cue (separados por linea en blanco); solo los que tienen linea de tiempos. #>
    param([Parameter(Mandatory)][string]$Text)
    [regex]::Split($Text.Trim(), '(?:\r?\n){2,}') | Where-Object { $_ -match $script:CvSrtTs }
}

function Get-CvSrtBlockNum {
    <# Numero de cue de un bloque (primera linea), o -1 si no es un numero. Ignora un BOM inicial. #>
    param([Parameter(Mandatory)][string]$Block)
    $first = ($Block -split "\r?\n")[0]
    $first = $first.TrimStart([char]0xFEFF).Trim()
    if ($first -match '^\d+$') { return [int]$first }
    return -1
}

function Get-CvSrtCueStart {
    <# Segundo de INICIO de la cue con numero $Num (o $null si no existe). #>
    param([Parameter(Mandatory)][string[]]$Blocks, [Parameter(Mandatory)][int]$Num)
    foreach ($bk in $Blocks) {
        if ((Get-CvSrtBlockNum $bk) -eq $Num -and $bk -match $script:CvSrtTs) { return ConvertTo-CvSrtSeconds $Matches[1] }
    }
    return $null
}

function Repair-CvSrtOcr {
    <#
        Corrige el error de OCR mas comun: la 'I' mayuscula leida como 'l' minuscula, SOLO en palabras
        que (quitando las 'l') son todo mayusculas (MANSlON -> MANSION). Devuelve @{ Text; Changed }.
    #>
    param([Parameter(Mandatory)][string]$Text)
    $changed = [System.Collections.Generic.List[string]]::new()
    $out = [regex]::Replace($Text, '\p{L}+', {
        param($m)
        $w = $m.Value
        if ($w.Contains('l')) {
            $noL = $w -replace 'l', ''
            if ($noL.Length -gt 0 -and $noL -cmatch '^\p{Lu}+$') {
                $nw = $w -replace 'l', 'I'
                if ($nw -ne $w) { $changed.Add("$w -> $nw") }
                return $nw
            }
        }
        return $w
    })
    @{
        Text    = $out
        Changed = @($changed)
    }
}

function Repair-CvSrtSpacing {
    <# Quita el espacio tras los signos de apertura invertidos (! = 0xA1, ? = 0xBF). Devuelve @{ Text; Count }. #>
    param([Parameter(Mandatory)][string]$Text)
    $op1 = [char]0xA1; $op2 = [char]0xBF
    $n = ([regex]::Matches($Text, "[$op1$op2] ")).Count
    $out = $Text.Replace("$op1 ", "$op1").Replace("$op2 ", "$op2")
    @{
        Text  = $out
        Count = $n
    }
}

function Get-CvSrtLinearFit {
    <# Ajuste lineal por 2 puntos (t->real): devuelve @{ A; B } tal que real = A*t + B. $null si t1==t2. #>
    param([double]$Srt1, [double]$Real1, [double]$Srt2, [double]$Real2)
    if ($Srt1 -eq $Srt2) { return $null }
    $a = ($Real2 - $Real1) / ($Srt2 - $Srt1)
    @{
        A = $a
        B = ($Real1 - $a * $Srt1)
    }
}

function Invoke-CvSrtResync {
    <#
        Aplica t' = A*t + B a los tiempos de cada cue cuyo numero sea >= FromCue (las anteriores se
        dejan intactas). Offset constante = A 1 con el B deseado. Devuelve el texto re-sincronizado.
    #>
    param([Parameter(Mandatory)][string]$Text, [double]$A = 1.0, [double]$B = 0.0, [int]$FromCue = 1)
    $out = foreach ($bk in (Get-CvSrtBlocks $Text)) {
        $num = Get-CvSrtBlockNum $bk
        $lines = $bk -split "\r?\n"
        if ($num -ge $FromCue -and $bk -match $script:CvSrtTs) {
            $t1 = ConvertTo-CvSrtSeconds $Matches[1]; $t2 = ConvertTo-CvSrtSeconds $Matches[2]
            $lines[1] = '{0} --> {1}' -f (ConvertTo-CvSrtStamp ($A*$t1 + $B)), (ConvertTo-CvSrtStamp ($A*$t2 + $B))
        }
        ($lines -join "`r`n").TrimEnd()
    }
    ($out -join "`r`n`r`n")
}

# =================================================================================================
# Helpers INTERACTIVOS (para asistentes tipo FixSyncSub). Dependen de Console (Read-CvLine/Read-CvInt/
# Select-FromList) y Log (Write-CvLog); re-preguntan hasta un valor valido (no abortan).
# =================================================================================================

function Read-CvSrtTime {
    <# Tiempo (h:mm:ss.mmm / mm:ss / seg, admite +/-); re-pregunta si no es valido. -AllowEmpty -> $null. #>
    param([string]$Prompt, [switch]$AllowEmpty)
    while ($true) {
        $s = (Read-CvLine -Prompt $Prompt).Trim()
        if ($s -eq '' -and $AllowEmpty) { return $null }
        $v = ConvertTo-CvSrtSeconds $s
        if ($null -ne $v) { return $v }
        Write-CvLog 'SUB' (Get-CvText -Key 'srt.tiempo.mal') -Indent 5
    }
}

function Read-CvSrtCueNum {
    <# Numero de cue que EXISTA en $Blocks; re-pregunta si no. -AllowEmpty -> $null (ENTER). #>
    param([string[]]$Blocks, [string]$Prompt, [switch]$AllowEmpty)
    while ($true) {
        $n = Read-CvInt -Prompt $Prompt -AllowEmpty:$AllowEmpty
        if ($null -eq $n) { return $null }
        if ($null -ne (Get-CvSrtCueStart -Blocks $Blocks -Num $n)) { return $n }
        Write-CvLog 'SUB' (Get-CvText -Key 'srt.cue.no' -Values @($n)) -Indent 5
    }
}

function Read-CvSrtAnchor {
    <# Lee un ANCLA de sincronizacion (nº de cue + tiempo real) y la escribe en las refs $Srt/$Real. #>
    param([string[]]$Blocks, [string]$Label, [ref]$Srt, [ref]$Real)
    $n = Read-CvSrtCueNum -Blocks $Blocks -Prompt (Get-CvText -Key 'srt.cue.q' -Values @($Label))
    $cur = Get-CvSrtCueStart -Blocks $Blocks -Num $n
    Write-CvLog 'SUB' (Get-CvText -Key 'srt.cue.esta' -Values @($n, (ConvertTo-CvSrtStamp $cur))) -Indent 5
    $rt = Read-CvSrtTime -Prompt (Get-CvText -Key 'srt.cue.real')
    $Srt.Value = $cur; $Real.Value = $rt
}

function Find-CvSrtVideo {
    <# Video (mkv/mp4/...) en $Dir cuyo nombre coincide con el del .srt (o su stem sin sufijo de idioma). $null si ninguno. #>
    param([string]$Dir, [string]$SrtPath)
    $b = [IO.Path]::GetFileNameWithoutExtension($SrtPath)   # 'peli.es' o 'peli'
    $stem = $b -replace '\.[A-Za-z]{2,3}$', ''              # quita sufijo de idioma (.es/.eng)
    $vids = @(Get-CvFiles -Dir $Dir -Filters '*.mkv', '*.mp4', '*.avi', '*.mov', '*.m4v', '*.webm' -Exact |
        Where-Object { $n = [IO.Path]::GetFileNameWithoutExtension($_.Name); $n -eq $b -or $n -eq $stem })
    if ($vids.Count -ge 1) { return $vids[0].FullName }
    return $null
}

function Select-CvSrtFile {
    <# Elige un .srt: lista los de $Dir (recursivo) con Select-FromList; si no hay, pide una ruta a mano. #>
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return (Read-CvLine -Prompt (Get-CvText -Key 'srt.ruta.q')).Trim('"') }
    $subs = @(Get-CvFiles -Dir $Dir -Filters '*.srt' -Recurse -Exact)
    if ($subs.Count -eq 0) {
        Write-CvLog 'SUB' (Get-CvText -Key 'srt.nohay' -Values @($Dir)) -Indent 3
        return (Read-CvLine -Prompt (Get-CvText -Key 'srt.ruta.q')).Trim('"')
    }
    $rels = $subs | ForEach-Object { $_.FullName.Substring($Dir.Length).TrimStart('\') }
    $sel = Select-FromList -Title (Get-CvText -Key 'srt.lista' -Values @($Dir)) -Options $rels -NoneLabel (Get-CvText -Key 'srt.otra')
    if ([string]::IsNullOrEmpty($sel)) { return (Read-CvLine -Prompt (Get-CvText -Key 'srt.ruta.q')).Trim('"') }
    Join-Path $Dir $sel
}

Export-ModuleMember -Function *
