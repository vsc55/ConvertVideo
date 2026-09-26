<#
    Video.psm1 - Fase ASK (deteccion de bordes / resize / animacion) y fase RUN (codificacion).
    Espejo de process_video.cmd.
#>

function Find-CropDetect {
    <#
        Escanea un tramo del video con cropdetect y devuelve el recorte mas frecuente
        (formato W:H:X:Y) o $null si no se detecta nada.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [int]$Start = -1, [int]$Duration = -1, [int]$Index = -1
    )
    if ($Start -lt 0)    { $Start = [int]$Context.BorderStart }
    if ($Duration -lt 0) { $Duration = [int]$Context.BorderDur }
    $stop = $Start + $Duration
    Write-CvLog 'VIDEO' ("[BORDE] - [SCAN] - Analizando bordes ({0}s desde el segundo {1})..." -f $Duration, $Start) -Indent 3
    # Si se indica -Index, analizar ESA pista (no la primera): importa con varias pistas de video.
    $mapArg = if ($Index -ge 0) { @('-map', ("0:{0}" -f $Index)) } else { @() }
    $r = Invoke-ToolCapture -Exe $Context.FFmpeg -Arguments (@(
        '-hide_banner','-ss', "$Start", '-to', "$stop", '-i', $File
    ) + $mapArg + @('-vf','cropdetect','-f','null','-')) -Context $Context
    $cropMatches = [regex]::Matches($r.StdErr, 'crop=(\d+:\d+:\d+:\d+)')
    if ($cropMatches.Count -eq 0) { return $null }
    # La ULTIMA linea, no la mas repetida: cropdetect ACUMULA dentro de la ventana analizada -la caja
    # de contenido solo crece- asi que la ultima es la que cubre todo lo que se ha visto en ese tramo.
    # La mas repetida sesga hacia el plano que mas dure (un plano oscuro de 3 s deja su caja pequena
    # repetida 70 veces), y era lo que hacia que un tramo con una escena oscura al principio
    # devolviera un recorte que se comia imagen.
    return $cropMatches[$cropMatches.Count - 1].Groups[1].Value
}

function Test-CvCropSignificant {
    <#
        PURO. Un recorte detectado, es una BARRA de verdad o solo el ruido de borde que cropdetect
        quita casi siempre? Se compara cuanto reduce (ancho o alto, lo que mas) contra -MinPct
        (encode.video.border.minCropPct). Ojo con los tipos: '1 - w/iw' con enteros da 0 ENTERO y
        [math]::Max(int, decimal) truncaria el otro termino, asi que se castea a [double].
    #>
    param([string]$Crop, [int]$Width, [int]$Height, [double]$MinPct)
    if ($Width -le 0 -or $Height -le 0) { return $false }
    $q = "$Crop" -split ':'
    if ($q.Count -lt 2) { return $false }
    $cw = 0; $ch = 0
    if (-not [int]::TryParse($q[0], [ref]$cw)) { return $false }
    if (-not [int]::TryParse($q[1], [ref]$ch)) { return $false }
    $red = [math]::Max([double](1 - $cw / $Width), [double](1 - $ch / $Height)) * 100
    return ($red -ge $MinPct)
}

function Get-CvOutputSize {
    <#
        PURO. Tamano que va a tener la imagen FINAL: se parte del de origen, se aplica el recorte y
        despues el reescalado, que es el orden en que los encadena el filtro (Get-CvVideoFilterChain).
        Sirve para CONTARLO -el resumen dice 'queda 1920x960'-, no para construir el filtro.

        El reescalado admite lo mismo que 'scale=': 'W:H' fijo, o '-1'/'-2' en un eje = automatico
        conservando el aspecto ('-2' ademas obliga a par, que es lo que piden casi todos los codecs).
        Se ignora lo que venga tras una coma ('1920:800,setsar=1'): eso ya no es tamano.

        Devuelve @{ Width; Height; CropWidth; CropHeight; Left; Top; Right; Bottom; Cropped; Scaled },
        todo 0/false si no se sabe el tamano de origen.
    #>
    param(
        [int]$Width,
        [int]$Height,
        [string]$Crop = '',
        [string]$Resize = ''
    )
    $r = @{
        Width      = 0
        Height     = 0
        CropWidth  = 0
        CropHeight = 0
        Left       = 0
        Top        = 0
        Right      = 0
        Bottom     = 0
        Cropped    = $false
        Scaled     = $false
    }
    if ($Width -le 0 -or $Height -le 0) { return $r }
    $w = $Width
    $h = $Height
    if ("$Crop".Trim() -match '^(\d+):(\d+):(\d+):(\d+)$') {
        $cw = [int]$Matches[1]; $ch = [int]$Matches[2]; $cx = [int]$Matches[3]; $cy = [int]$Matches[4]
        if ($cw -gt 0 -and $ch -gt 0 -and ($cw + $cx) -le $Width -and ($ch + $cy) -le $Height) {
            $r.CropWidth  = $cw
            $r.CropHeight = $ch
            $r.Left       = $cx
            $r.Top        = $cy
            $r.Right      = $Width  - $cw - $cx
            $r.Bottom     = $Height - $ch - $cy
            $r.Cropped    = ($cw -ne $Width -or $ch -ne $Height)
            $w = $cw
            $h = $ch
        }
    }
    $spec = (("$Resize" -split ',')[0]).Trim()
    if ($spec -ne '') {
        $p = $spec -split ':'
        if ($p.Count -ge 2) {
            $tw = 0; $th = 0
            [void][int]::TryParse($p[0].Trim(), [ref]$tw)
            [void][int]::TryParse($p[1].Trim(), [ref]$th)
            # <= 0 = token automatico ('-1'/'-2') o expresion: esa dimension la marca el aspecto.
            # OJO con el redondeo: '-2' no trunca, redondea al PAR MAS CERCANO (1920x1080 a '-2:480'
            # da 854, no 852). Se calcula sobre el valor exacto en double; '-1' redondea al entero.
            $par = {
                param([double]$Exact, [bool]$Even)
                if ($Even) { return ([int][math]::Round($Exact / 2.0, [System.MidpointRounding]::AwayFromZero)) * 2 }
                return [int][math]::Round($Exact, [System.MidpointRounding]::AwayFromZero)
            }
            if ($tw -gt 0 -and $th -gt 0) {
                $w = $tw; $h = $th
            } elseif ($tw -gt 0) {
                $h = [Math]::Max(2, (& $par (($h * $tw) / [double]$w) ($p[1].Trim() -eq '-2'))); $w = $tw
            } elseif ($th -gt 0) {
                $w = [Math]::Max(2, (& $par (($w * $th) / [double]$h) ($p[0].Trim() -eq '-2'))); $h = $th
            }
            $r.Scaled = ($w -ne $(if ($r.CropWidth -gt 0) { $r.CropWidth } else { $Width }) -or
                         $h -ne $(if ($r.CropHeight -gt 0) { $r.CropHeight } else { $Height }))
        }
    }
    $r.Width  = $w
    $r.Height = $h
    return $r
}

function Format-CvCropCut {
    <#
        PURO. El recorte contado en PIXELES y por lados ('quita 60px arriba y 60px abajo'), que es lo
        que se entiende de un vistazo; el 'W:H:X:Y' del filtro no dice cuanto se va por cada lado.
        '' si no se quita nada.
    #>
    param(
        [int]$Left   = 0,
        [int]$Top    = 0,
        [int]$Right  = 0,
        [int]$Bottom = 0
    )
    # Barras simetricas (el caso normal): se dice una vez y se nombra lo que son.
    if ($Top -gt 0 -and $Top -eq $Bottom -and $Left -eq 0 -and $Right -eq 0) {
        return (Get-CvText -Key 'crop.horiz' -Values @($Top))
    }
    if ($Left -gt 0 -and $Left -eq $Right -and $Top -eq 0 -and $Bottom -eq 0) {
        return (Get-CvText -Key 'crop.vert' -Values @($Left))
    }
    $bits = @()
    if ($Top    -gt 0) { $bits += (Get-CvText -Key 'crop.arriba' -Values @($Top)) }
    if ($Bottom -gt 0) { $bits += (Get-CvText -Key 'crop.abajo'  -Values @($Bottom)) }
    if ($Left   -gt 0) { $bits += (Get-CvText -Key 'crop.izq'    -Values @($Left)) }
    if ($Right  -gt 0) { $bits += (Get-CvText -Key 'crop.der'    -Values @($Right)) }
    if ($bits.Count -eq 0) { return '' }
    return (Get-CvText -Key 'crop.quita' -Values @(($bits -join (Get-CvText -Key 'crop.y'))))
}

function Merge-CvCropBoxes {
    <#
        PURO. Convierte los recortes detectados en VARIOS puntos del video en UNO solo, que es el que
        se puede aplicar sin comerse imagen. Tres pasos, y cada uno arregla un error real:

        1. UNION. Una barra negra es lo que esta negro en TODOS los puntos; si en un punto la imagen
           llega mas lejos, ahi hay contenido. Por eso se toma la caja que ENGLOBA a todas y no la mas
           votada: con votos, dos planos oscuros ganaban a la unica muestra que veia el fotograma
           entero, y el recorte resultante cortaba imagen (o no se aplicaba ninguno).
        2. SIMETRIA. Las barras de un letterbox/pillarbox son simetricas: si un lado dice 94px y el
           opuesto 2px, la diferencia es contenido oscuro de un plano, no barra. Se toma el MENOR de
           cada par, que es lo conservador.
        3. RUIDO POR EJE. cropdetect casi siempre quita unos pixeles de borde sucio. Si lo que se
           quitaria en un eje no llega a -MinPct, ese eje no se toca (el otro puede si recortarse).

        -Boxes son cadenas 'W:H:X:Y'. Devuelve 'W:H:X:Y' (o '' si no hay nada que recortar).
    #>
    param(
        $Boxes,
        [int]$Width,
        [int]$Height,
        [double]$MinPct = 2
    )
    if ($Width -le 0 -or $Height -le 0) { return '' }
    $x1 = $Width; $y1 = $Height; $x2 = 0; $y2 = 0
    $n = 0
    foreach ($b in @($Boxes)) {
        if ("$b" -notmatch '^(\d+):(\d+):(\d+):(\d+)$') { continue }
        $w = [int]$Matches[1]; $h = [int]$Matches[2]; $x = [int]$Matches[3]; $y = [int]$Matches[4]
        if ($w -le 0 -or $h -le 0 -or ($x + $w) -gt $Width -or ($y + $h) -gt $Height) { continue }
        $n++
        if ($x -lt $x1) { $x1 = $x }
        if ($y -lt $y1) { $y1 = $y }
        if (($x + $w) -gt $x2) { $x2 = $x + $w }
        if (($y + $h) -gt $y2) { $y2 = $y + $h }
    }
    if ($n -eq 0) { return '' }
    # Simetria: de cada par de margenes opuestos, el menor.
    $left = [Math]::Min($x1, $Width  - $x2)
    $top  = [Math]::Min($y1, $Height - $y2)
    if ($left -lt 0) { $left = 0 }
    if ($top  -lt 0) { $top  = 0 }
    # Ruido por eje: lo que no llegue al minimo, no se recorta en ese eje.
    if ((200.0 * $left / $Width)  -lt $MinPct) { $left = 0 }
    if ((200.0 * $top  / $Height) -lt $MinPct) { $top  = 0 }
    if ($left -eq 0 -and $top -eq 0) { return '' }
    $cw = $Width  - (2 * $left)
    $ch = $Height - (2 * $top)
    if ($cw -le 0 -or $ch -le 0) { return '' }
    return ("{0}:{1}:{2}:{3}" -f $cw, $ch, $left, $top)
}

function Resolve-CvCropAutoDecision {
    <#
        PURO. LA decision del modo AUTO de bordes a partir de los votos de Find-CropDetectSamples:
        hay barras y se recortan, no las hay, o la evidencia es ambigua y lo tiene que ver una
        persona. FUENTE UNICA: la usan la consola (Resolve-VideoChoices) y la ventana
        (Get-CvJobAutoPlan), que antes tenian la formula escrita cada una por su lado.

        Devuelve @{ Decision = 'crop'|'none'|'manual'; Crop; Reason }.

        Como se decide (y por que): los puntos NO se votan, se COMBINAN (Merge-CvCropBoxes: union de
        las cajas + simetria + ruido por eje). Una barra es lo que esta negro en TODOS los puntos, asi
        que la mayoria es el criterio equivocado: en un episodio real, dos planos oscuros ganaban por
        votos a la unica muestra que veia el fotograma entero y el resultado era no recortar nada -o
        peor, recortar la caja de un plano oscuro y comerse imagen-.

        Lo unico que se deja para una persona es el recorte DESPROPORCIONADO (-MaxCropPct): quitar mas
        de eso no es un letterbox normal (un 2.39:1 dentro de 16:9 se lleva ~22% del alto; un 4:3
        dentro de 16:9, un 25% del ancho), y casi siempre significa que ningun punto llego a ver un
        plano a pantalla completa. Se propone, pero se pide confirmacion.
    #>
    param(
        $Groups,
        [int]$Width,
        [int]$Height,
        [double]$MinCropPct = 2,
        [int]$MaxCropPct    = 40
    )
    $g = @($Groups)
    if ($g.Count -eq 0) {
        return @{ Decision = 'none'; Crop = ''; Reason = 'Sin bordes detectados: no se recorta' }
    }
    $crop = Merge-CvCropBoxes -Boxes @($g | ForEach-Object { "$($_.Crop)" }) -Width $Width -Height $Height -MinPct $MinCropPct
    if ("$crop" -eq '') {
        return @{ Decision = 'none'; Crop = ''; Reason = 'Sin barras (lo detectado es ruido de borde): no se recorta' }
    }
    $q  = "$crop" -split ':'
    $cw = [int]$q[0]; $chh = [int]$q[1]
    $redW = [int][math]::Round(100.0 * ($Width  - $cw)  / $Width)
    $redH = [int][math]::Round(100.0 * ($Height - $chh) / $Height)
    $que  = @()
    if ($redH -gt 0) { $que += ("{0}% de alto" -f $redH) }
    if ($redW -gt 0) { $que += ("{0}% de ancho" -f $redW) }
    if ($redW -gt $MaxCropPct -or $redH -gt $MaxCropPct) {
        return @{
            Decision = 'manual'
            Crop     = "$crop"
            Reason   = ("Recorte {0} muy grande ({1}, mas del {2}%): confirmalo antes de aplicarlo" -f $crop, ($que -join ' y '), $MaxCropPct)
        }
    }
    return @{
        Decision = 'crop'
        Crop     = "$crop"
        Reason   = ("Barras detectadas: recorte {0} (quita {1}; {2} punto(s) analizados)" -f $crop, ($que -join ' y '), @($g).Count)
    }
}

function Find-CropDetectSamples {
    <#
        Escanea bordes en VARIOS puntos repartidos del video y agrupa los recortes por "votos".
        Cada punto escanea $Duration segundos (NO se reparte: N puntos = N escaneos de $Duration),
        desde $Start hasta cerca del final. Devuelve:
          @{ Groups = @( @{Crop; Count} ordenados por votos desc ); Samples }
        Con 1 punto o duracion desconocida, cae al escaneo unico clasico.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [int]$Start = -1, [int]$Duration = -1, [double]$VideoDuration = 0, [int]$Index = -1, [int]$Samples = -1
    )
    if ($Start -lt 0)    { $Start = [int]$Context.BorderStart }
    if ($Duration -lt 0) { $Duration = [int]$Context.BorderDur }
    if ($Samples -lt 1)  { $Samples = [int]$Context.BorderSamples }
    if ($Samples -lt 1)  { $Samples = 1 }
    # Si el video es mas corto que el inicio configurado, llevar el inicio dentro del contenido.
    $Start = Get-CvSafeStart -Start $Start -Duration $VideoDuration -Window 5

    if ($Samples -le 1 -or $VideoDuration -le 0) {
        $c = Find-CropDetect -Context $Context -File $File -Start $Start -Duration $Duration -Index $Index
        $g = if ($c) {
            @([pscustomobject]@{
                Crop  = $c
                Count = 1
            })
        } else { @() }
        return [pscustomobject]@{
            Groups  = $g
            Samples = 1
        }
    }

    $win = [Math]::Max(5, [int]$Duration)                       # cada punto escanea $Duration (no se reparte)
    $lastStart = [Math]::Max($Start, [int]($VideoDuration - $win - 1))
    $crops = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $p = [int]($Start + ($lastStart - $Start) * $i / ($Samples - 1))
        $c = Find-CropDetect -Context $Context -File $File -Start $p -Duration $win -Index $Index
        if ($c) { $crops += $c }
    }
    $groups = @($crops | Group-Object | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{
            Crop  = $_.Name
            Count = $_.Count
        }
    })
    return [pscustomobject]@{
        Groups  = $groups
        Samples = $Samples
    }
}

function Get-CvPlayerCommand {
    <#
        PURO. Con que se abre un video para VERLO entero (no una preview de PREPARAR): devuelve
        @{ Mode; Exe; Args; Shell } segun el modo pedido (preview.player) y lo que hay a mano.

          start    -> lo abre el ASOCIADO de Windows (Shell = $true; el 'Exe' es el propio fichero).
                      Es el modo por defecto: cada uno ya tiene su reproductor puesto, con sus
                      atajos y su historial, y no hay que configurar nada.
          ffplay   -> el ffplay de tools\\. Siempre esta (lo instala el propio programa), asi que es
                      el PLAN B cuando no hay asociacion o el .exe externo no existe.
          external -> el reproductor de preview.playerExe (VLC, MPC-HC...). Si esa ruta no existe se
                      cae a ffplay -y si tampoco, al asociado-: nunca se lanza un exe que no esta.

        Separado del lanzamiento para poder probar la DECISION sin abrir nada.
    #>
    param(
        [string]$Mode   = 'start',
        [string]$Exe    = '',
        [string]$FFplay = '',
        [Parameter(Mandatory)][string]$File
    )
    $m  = "$Mode".ToLower()
    if ($m -eq '') { $m = 'start' }
    $ff = "$FFplay"
    $ffOk = ($ff -ne '') -and (Test-Path -LiteralPath $ff)

    if ($m -eq 'external') {
        $ex = "$Exe".Trim('"').Trim()
        if ($ex -ne '' -and (Test-Path -LiteralPath $ex)) {
            return @{
                Mode  = 'external'
                Exe   = $ex
                Args  = @($File)
                Shell = $false
            }
        }
        $m = $(if ($ffOk) { 'ffplay' } else { 'start' })   # el externo no esta: no se lanza a ciegas
    }
    if ($m -eq 'ffplay') {
        if ($ffOk) {
            # Sin -autoexit: aqui se viene a VER el archivo, no a echarle un vistazo; se cierra con
            # q/ESC o con la X. -window_title para distinguir el original del convertido de un vistazo.
            return @{
                Mode  = 'ffplay'
                Exe   = $ff
                Args  = @(
                    '-hide_banner'
                    '-loglevel'
                    'error'
                    '-window_title'
                    ([System.IO.Path]::GetFileName($File))
                    $File
                )
                Shell = $false
            }
        }
        $m = 'start'
    }
    return @{
        Mode  = 'start'
        Exe   = $File
        Args  = @()
        Shell = $true
    }
}

function Start-CvVideoPlayer {
    <#
        Abre un video para verlo, con lo que diga preview.player. NO ESPERA a que se cierre: quien
        llama es una ventana (la cola) y bloquearla mientras se ve una pelicula no tendria ningun
        sentido -y ademas dejaria la cola sin refrescar-.

        Devuelve @{ Ok; Mode; Error }. No lanza: un reproductor que no arranca no puede tumbar la
        aplicacion, se cuenta y ya.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$File
    )
    if (-not (Test-Path -LiteralPath $File)) {
        return @{ Ok = $false; Mode = ''; Error = ("No existe el archivo: {0}" -f $File) }
    }
    $cmd = Get-CvPlayerCommand -Mode "$($Context.PreviewPlayer)" -Exe "$($Context.PreviewPlayerExe)" `
        -FFplay "$($Context.FFplay)" -File $File
    try {
        if ([bool]$cmd.Shell) {
            # UseShellExecute: es lo que resuelve la asociacion de Windows (con -FilePath a secas,
            # .NET intentaria EJECUTAR el .mkv). Si no hay programa asociado, Start-Process lanza.
            [void](Start-Process -FilePath "$($cmd.Exe)" -ErrorAction Stop)
        } else {
            [void](Start-Process -FilePath "$($cmd.Exe)" -ArgumentList @($cmd.Args) -ErrorAction Stop)
        }
        return @{ Ok = $true; Mode = "$($cmd.Mode)"; Error = '' }
    } catch {
        # El asociado ha fallado (extension sin programa): se intenta con el ffplay de tools antes
        # de darse por vencido, que es el que seguro esta.
        if ("$($cmd.Mode)" -eq 'start' -and "$($Context.FFplay)" -ne '' -and (Test-Path -LiteralPath "$($Context.FFplay)")) {
            try {
                $alt = Get-CvPlayerCommand -Mode 'ffplay' -FFplay "$($Context.FFplay)" -File $File
                [void](Start-Process -FilePath "$($alt.Exe)" -ArgumentList @($alt.Args) -ErrorAction Stop)
                return @{ Ok = $true; Mode = 'ffplay'; Error = '' }
            } catch { }
        }
        return @{ Ok = $false; Mode = "$($cmd.Mode)"; Error = "$($_.Exception.Message)" }
    }
}

function Show-Preview {
    <#
        Reproduce el video con FFplay para revisarlo visualmente. Si se pasa -Crop, aplica el filtro
        de recorte. Por defecto desde el principio y sin limite (preview.start/seconds); se cierra
        con autoexit al acabar o antes con q/ESC.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [string]$Crop = '', [int]$VideoPos = -1, [int]$Seconds = -1, [double]$Duration = 0
    )
    $title = 'ORIGINAL'
    $extra = @()
    # Si se indica -VideoPos, reproducir ESA pista de video (posicion entre las de video).
    if ($VideoPos -ge 0) { $extra += @('-vst', ("v:{0}" -f $VideoPos)) }
    if ($Crop) { $extra += @('-vf', "crop=$Crop"); $title = "RECORTADO $Crop" }
    Write-CvLog 'VIDEO' ("[BORDE] - [TEST] - Reproduciendo: {0}  (se cierra solo o pulsa ESC)" -f $title)
    Invoke-CvPreview -Context $Context -File $File -ExtraArgs $extra -Label $title -Seconds $Seconds -Duration $Duration
}

function Show-VideoPreview {
    <#
        Reproduce una pista de VIDEO concreta con FFplay para revisarla (por defecto desde el
        principio y sin limite; inicio/duracion configurables en preview.start/seconds).
        -VideoPos: posicion 0-based entre las pistas de video (se selecciona con '-vst v:N').
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [int]$VideoPos, [string]$Label = 'VIDEO', [int]$Start = -1, [int]$Seconds = -1, [double]$Duration = 0
    )
    Write-CvLog 'VIDEO' ("[TEST] - Reproduciendo {0}; se cierra solo o pulsa ESC/Q" -f $Label) -Indent 3
    Invoke-CvPreview -Context $Context -File $File -ExtraArgs @('-vst', ("v:{0}" -f $VideoPos)) -Label $Label -Start $Start -Seconds $Seconds -Duration $Duration
}

function Select-VideoInteractive {
    <#
        Menu para elegir pista de video cuando hay 2+ pistas reales. Permite REPRODUCIR cada
        una ('P N') para confirmar cual es antes de elegirla. Devuelve el stream elegido.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$VideoStreams, [int]$DefaultIndex
    )
    $streams = @($VideoStreams)
    $vdur    = Get-MediaDuration $Info
    $to      = Get-CvPromptTimeout $Context 'video'   # auto-aceptar por inactividad (0 = off)
    $chosen  = $null
    while ($null -eq $chosen) {
        $lines = @()
        foreach ($s in $streams) {
            $lang  = Get-Tag $s 'language'; $title = Get-Tag $s 'title'
            $mark  = ' '; if ([int]$s.index -eq $DefaultIndex) { $mark = '*' }
            $titleTxt = ''; if ($title) { $titleTxt = "'$title'" }
            $lines += ("{0} [{1}] {2}x{3} codec={4} idioma={5} {6}" -f $mark, $s.index, $s.width, $s.height, $s.codec_name, $lang, $titleTxt)
        }
        Show-Menu -Title 'SELECCIONAR PISTA DE VIDEO [* = por defecto]:' -Lines $lines -Indent 3
        $a = (Read-CvMenuLine ("   [VIDEO] - Indice / 'P N'=reproducir (opc. seg inicio: 'P N 300') [{0}]" -f $DefaultIndex) $to).Trim()
        if ($a -eq '') { $a = "$DefaultIndex" }

        $play = ConvertFrom-CvPlayCommand $a
        if ($play) {
            $match = $streams | Where-Object { [int]$_.index -eq $play.Index } | Select-Object -First 1
            if ($match) { Show-VideoPreview -Context $Context -File $File -VideoPos (Get-VideoStreamPos -Info $Info -Index $play.Index) -Label ("PISTA {0}" -f $play.Index) -Start $play.Start -Duration $vdur }
            else { Write-Host '   Indice no valido.' -ForegroundColor Yellow }
            continue
        }

        $n = 0
        if ([int]::TryParse($a, [ref]$n)) {
            $match = $streams | Where-Object { [int]$_.index -eq $n } | Select-Object -First 1
            if ($match) {
                $ok = (Read-CvMenuLine ("   Usar la pista {0}? (ENTER=si / N=volver a la lista)" -f $n) $to).Trim()
                if ($ok -match '^[Nn]$') { continue }
                $chosen = $match; continue
            }
        }
        Write-Host '   Indice no valido.' -ForegroundColor Yellow
    }
    Write-Host ''
    return $chosen
}

function Invoke-CvAnamorphicAsk {
    <#
        Pregunta interactiva en PREPARAR al detectar video ANAMORFICO (SAR != 1: el tamaño almacenado
        no es el que se ve). Devuelve el modo elegido ('keep' | 'square' | 'squareheight'), preseleccionando
        el configurado ($Context.Anamorphic): ENTER (o expirar el timeout 'anamorphic') lo acepta. Solo
        se llama al RECODIFICAR (en copy no se puede cambiar el SAR sin recodificar).
    #>
    param([Parameter(Mandatory)]$Context, [int]$Width, [int]$Height, [string]$Sar)
    $dw   = Get-CvDisplayWidth -Width $Width -Sar $Sar
    $cur  = "$($Context.Anamorphic)".ToLower()
    $num = @{
        '1' = 'keep'
        '2' = 'square'
        '3' = 'squareheight'
    }
    $rev = @{
        'keep'         = '1'
        'square'       = '2'
        'squareheight' = '3'
    }
    $lbl = @{
        'keep'         = 'mantener SAR'
        'square'       = 'cuadrar por ancho'
        'squareheight' = 'cuadrar por alto'
    }
    $defN = if ($rev.ContainsKey($cur)) { $rev[$cur] } else { '2' }
    Write-CvLog 'VIDEO' ("[ANAMORFICO] - Almacena {0}x{1} pero SE VE a {2}x{1} (SAR {3}); el tamano real no es el que reporta el contenedor." -f $Width, $Height, $dw, $Sar) -Indent 3
    $prompt = "   [VIDEO] [ANAMORFICO] - [1] mantener SAR / [2] cuadrar por ancho / [3] cuadrar por alto  [ENTER={0}={1}]" -f $defN, $lbl[$num[$defN]]
    $ans = (Read-CvLine -Prompt $prompt -TimeoutSec (Get-CvPromptTimeout $Context 'anamorphic') -TimeoutDefault $defN).Trim()
    Write-Host ''
    if (-not $ans) { $ans = $defN }
    if ($num.ContainsKey($ans)) { return $num[$ans] }
    return $cur
}

function Invoke-VideoAsk {
    <#
        Hace las preguntas/detecciones de video y devuelve un objeto:
        @{ Skip; Crop; Resize; Anim }
        $ForceBorder fuerza la deteccion (regla del prefijo '_').
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)]$Info,
        [bool]$ForceBorder = $false
    )
    $res = [ordered]@{
        Skip   = $false
        Index  = -1
        Crop   = ''
        Resize = ''
        Anim   = $false
        Manual = $false
    }

    # ---- Seleccion de pista de video ----
    # Se elige SIEMPRE (aunque sea copy) para congelar el indice y usarlo tanto al copiar como
    # al codificar/multiplexar; asi nunca se cuela una caratula ni una pista equivocada.
    $vids = @(Get-VideoStreams -Info $Info)
    if ($vids.Count -eq 0) {
        if ($Context.Debug) { Write-CvLog 'VIDEO' '[SKIP] - No se ha detectado pista de video' }
        $res.Skip = $true
        return [pscustomobject]$res
    }
    $vstream = $vids[0]
    if ($vids.Count -gt 1) {
        # 2+ pistas de video reales: avisar y preguntar cual usar (con reproduccion para confirmar).
        Write-CvLog 'VIDEO' ("[AVISO] - Se han detectado {0} pistas de video; elige cual usar manualmente." -f $vids.Count) -Indent 3
        $vstream = Select-VideoInteractive -Context $Context -File $Info.format.filename -Info $Info -VideoStreams $vids -DefaultIndex ([int]$vids[0].index)
        $res.Manual = $true   # hubo seleccion manual de pista de video
    }
    $res.Index = [int]$vstream.index
    $vpos      = Get-VideoStreamPos -Info $Info -Index $res.Index

    # Video ANAMORFICO (SAR != 1: el tamaño almacenado no es el que se ve). Se detecta SIEMPRE.
    $vW = [int]$vstream.width; $vH = [int]$vstream.height; $vSar = "$($vstream.sample_aspect_ratio)"
    $isAnam   = ($vW -gt 0 -and (Get-CvDisplayWidth -Width $vW -Sar $vSar) -ne $vW)
    $anamMode = "$($Context.Anamorphic)"

    if ($Prof.VideoEncoder -eq 'copy') {
        # En copy no se recodifica: no se puede cambiar el SAR. Solo avisar del tamaño real.
        if ($isAnam) {
            $w = Get-CvAnamorphicWarning -Width $vW -Height $vH -Sar $vSar -Anamorphic $anamMode
            Write-CvLog 'VIDEO' ("[AVISO] - {0} (copy: la pista se copia sin cambios)" -f $w) -Indent 3
        }
        if ($Context.Debug) { Write-CvLog 'VIDEO' '[SKIP] - Se copiara la pista de video' }
        $res.Skip = $true
        return [pscustomobject]$res
    }

    # Recodificando: si es anamorfico, preguntar que hacer (default = lo configurado en encode.anamorphic).
    if ($isAnam) {
        $anamMode = Invoke-CvAnamorphicAsk -Context $Context -Width $vW -Height $vH -Sar $vSar
        $res.Manual = $true
    }

    # ---- Deteccion de bordes ----
    # Modo por perfil: $false (nunca) | $true (siempre, interactivo) | 'auto' (pre-escaneo rapido que
    # decide si hay barras: si son claras las aplica solo; si es ambiguo pasa al modo interactivo).
    $dbv        = "$($Prof.DetectBorder)".ToLower()
    $borderOn   = ($dbv -eq 'true')
    $borderAuto = ($dbv -eq 'auto')
    if ($ForceBorder) {
        $borderOn = $true; $borderAuto = $false
        Write-CvLog 'VIDEO' '[BORDE] - Prefijo _ : se fuerza la deteccion de bordes' -Indent 3
    }
    if ($borderOn -or $borderAuto) {
        # Duracion del video (para repartir los puntos de escaneo entre inicio y final).
        $vdur  = Get-MediaDuration $Info
        $start = [int]$Context.BorderStart
        $dur   = [int]$Context.BorderDur
        $runInteractive = $borderOn

        if ($borderAuto) {
            # AUTO: pre-escaneo rapido (border.autoSamples/autoDuration), sin preguntar. Decide:
            #  - reduccion < border.minCropPct % -> ruido de borde, NO hay barras -> no recorta;
            #  - barras con mayoria fiable (mismo voto que el modo normal) -> aplica el recorte solo;
            #  - ambiguo (sin mayoria) -> pasa al modo interactivo (menu).
            Write-CvLog 'VIDEO' '[BORDE] - [AUTO] - Comprobando si hay barras negras...' -Indent 3
            $ag = @((Find-CropDetectSamples -Context $Context -File $Info.format.filename -Start $start -Duration ([int]$Context.BorderAutoDuration) -VideoDuration $vdur -Index $res.Index -Samples ([int]$Context.BorderAutoSamples)).Groups)
            # La decision es de Resolve-CvCropAutoDecision (fuente unica, la misma que usa la ventana).
            $dec = Resolve-CvCropAutoDecision -Groups $ag -Width ([int]$vstream.width) -Height ([int]$vstream.height) `
                -MinCropPct ([double]$Context.BorderMinCropPct) -MaxCropPct ([int]$Context.BorderAutoMaxCropPct)
            Write-CvLog 'VIDEO' ("[BORDE] - [AUTO] - {0}" -f $dec.Reason) -Indent 3
            switch ("$($dec.Decision)") {
                'crop'  { $res.Crop = "$($dec.Crop)" }
                'none'  { $res.Crop = '' }
                default { $runInteractive = $true }   # ambiguo: lo ve una persona, como siempre
            }
        }

      if ($runInteractive) {
        $res.Manual = $true   # la deteccion de bordes hace preguntas interactivas
        $done  = $false
        # Nº de muestras (puntos de escaneo) ANTES de escanear: por defecto el configurado, editable.
        $samples = Read-IntOrDefault '   Numero de muestras (puntos de escaneo)' ([int]$Context.BorderSamples) -TimeoutSec (Get-CvPromptTimeout $Context 'border')

        while (-not $done) {
            # Escaneo en varios puntos; agrupa recortes por votos.
            $groups = @((Find-CropDetectSamples -Context $Context -File $Info.format.filename -Start $start -Duration $dur -VideoDuration $vdur -Index $res.Index -Samples $samples).Groups)

            if ($groups.Count -eq 0) {
                Write-CvLog 'VIDEO' '[BORDE] - No se detectaron bordes en este tramo' -Indent 3
                $a = (Read-CvLine -Prompt '   [VIDEO] [BORDE] - [R] reintentar con otro tramo / [ENTER] continuar sin recorte' -TimeoutSec (Get-CvPromptTimeout $Context 'border')).Trim()
                if ($a -match '^[Rr]') {
                    $start   = Read-IntOrDefault '   Segundo de inicio del scan' $start -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                    $dur     = Read-IntOrDefault '   Duracion total del scan (seg)' $dur -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                    $samples = Read-IntOrDefault '   Numero de muestras (puntos de escaneo)' $samples -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                    continue
                }
                $res.Crop = ''; $done = $true; continue
            }

            # ¿Hay ganador claro por votos? Los grupos vienen ordenados por votos desc. El mas
            # votado se acepta AUTOMATICAMENTE si (a) alcanza el % 'border.autoAcceptPct' de los
            # puntos que detectaron borde Y (b) supera al 2o por al menos 'autoAcceptMinMargin'
            # votos. El % descarta atipicos (escena oscura, creditos con otro encuadre); el margen
            # evita auto-aceptar con evidencia debil cuando hay pocas muestras (2/3=67% pero 1 de
            # margen -> pregunta). Si no se cumplen ambas, se muestra el menu para elegir a mano.
            $tot    = ($groups | Measure-Object -Property Count -Sum).Sum
            $topPct = if ($tot -gt 0) { [int][math]::Round(100 * $groups[0].Count / $tot) } else { 0 }
            $margin = $groups[0].Count - $(if ($groups.Count -ge 2) { $groups[1].Count } else { 0 })
            $autoWin = ($groups.Count -eq 1) -or (($topPct -ge $Context.BorderAutoAcceptPct) -and ($margin -ge $Context.BorderAutoAcceptMargin))

            if ($autoWin) {
                if ($groups.Count -eq 1) {
                    $extra = if ($groups[0].Count -gt 1) { " (coincide en $($groups[0].Count) puntos)" } else { '' }
                    Write-CvLog 'VIDEO' ("[BORDE] - Recorte detectado: {0}{1}" -f $groups[0].Crop, $extra) -Indent 3
                } else {
                    $disc = (@($groups | Select-Object -Skip 1 | ForEach-Object { "{0} ({1})" -f $_.Crop, $_.Count }) -join ', ')
                    Write-CvLog 'VIDEO' ("[BORDE] - Recorte por mayoria: {0} ({1}/{2} puntos, {3}%, +{4}); descartado(s): {5}" -f $groups[0].Crop, $groups[0].Count, $tot, $topPct, $margin, $disc) -Indent 3
                }
            } else {
                $lst = ($groups | ForEach-Object { "{0} ({1})" -f $_.Crop, $_.Count }) -join ' / '
                Write-CvLog 'VIDEO' ("[AVISO] - Bordes sin mayoria fiable ({0}%/margen +{1}; min {2}%/+{3}): {4}" -f $topPct, $margin, $Context.BorderAutoAcceptPct, $Context.BorderAutoAcceptMargin, $lst) -Indent 3
            }

            # Seleccion/preview sobre los recortes YA detectados (no re-escanea salvo re-detectar).
            $reScan = $false
            while (-not $done -and -not $reScan) {
                $crop = $null
                if ($autoWin) {
                    $crop = $groups[0].Crop
                } else {
                    # Numero alineado a la derecha (Get-CvMenuNumWidth) para que las etiquetas queden
                    # en columna con indices de 1 y 2+ cifras; 'M'/'R'/'0' se alinean igual.
                    $numW  = Get-CvMenuNumWidth $groups.Count
                    $lines = @()
                    for ($gi = 0; $gi -lt $groups.Count; $gi++) { $lines += ("{0}. {1}  ({2} voto(s))" -f (("$($gi + 1)").PadLeft($numW)), $groups[$gi].Crop, $groups[$gi].Count) }
                    $extra = @(
                        '',
                        ('{0}. Valor manual'          -f ('M'.PadLeft($numW))),
                        ('{0}. Reescanear (otro tramo)' -f ('R'.PadLeft($numW))),
                        ('{0}. Sin recorte'           -f ('0'.PadLeft($numW)))
                    )
                    Show-Menu -Title 'RECORTES DETECTADOS (elige cual probar) [por votos]:' -Lines ($lines + $extra) -Indent 3
                    $sel = (Read-Host '   [VIDEO] [BORDE] - Opcion').Trim()
                    if ($sel -match '^0$') { $res.Crop = ''; $done = $true; continue }
                    if ($sel -match '^[Rr]$') {
                        $start   = Read-IntOrDefault '   Segundo de inicio del scan' $start -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $dur     = Read-IntOrDefault '   Duracion total del scan (seg)' $dur -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $samples = Read-IntOrDefault '   Numero de muestras (puntos de escaneo)' $samples -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $reScan = $true; continue
                    }
                    if ($sel -match '^[Mm]$') { $crop = '__MANUAL__' }
                    else {
                        $gi = 0
                        if ([int]::TryParse($sel, [ref]$gi) -and $gi -ge 1 -and $gi -le $groups.Count) { $crop = $groups[$gi - 1].Crop }
                        else { Write-Host '   Opcion no valida.' -ForegroundColor Yellow; continue }
                    }
                }

                # Opcion "M" del menu de varios: pedir valor manual, previsualizar y confirmar.
                if ($crop -eq '__MANUAL__') {
                    $manual = (Read-Host '   Nuevo recorte en formato W:H:X:Y').Trim()
                    if ($manual -eq '') { continue }
                    Show-Preview -Context $Context -File $Info.format.filename -Crop $manual -VideoPos $vpos -Duration $vdur
                    $ok = (Read-Host ("   Usar {0}? (ENTER=si / N=volver)" -f $manual)).Trim()
                    if ($ok -match '^[Nn]$') { continue }
                    $res.Crop = $manual; $done = $true; continue
                }

                # Preview del candidato (original + recorte) y confirmacion.
                Show-Preview -Context $Context -File $Info.format.filename -VideoPos $vpos -Duration $vdur
                Show-Preview -Context $Context -File $Info.format.filename -Crop $crop -VideoPos $vpos -Duration $vdur
                $volver = if ($autoWin) { 'volver a detectar' } else { 'volver al menu' }
                $a = (Read-CvLine -Prompt ("   [VIDEO] [BORDE] - [ENTER/S] usar / [N] {0} / [M] manual / [0] sin recorte" -f $volver) -TimeoutSec (Get-CvPromptTimeout $Context 'border')).Trim()
                if ($a -eq '' -or $a -match '^[SsYy]$') { $res.Crop = $crop; $done = $true }
                elseif ($a -match '^0$') { $res.Crop = ''; $done = $true }
                elseif ($a -match '^[Mm]$') {
                    $manual = (Read-Host ("   Nuevo recorte en formato W:H:X:Y [{0}]" -f $crop)).Trim()
                    if ($manual -eq '') { $manual = $crop }
                    Show-Preview -Context $Context -File $Info.format.filename -Crop $manual -VideoPos $vpos -Duration $vdur
                    $ok = (Read-Host ("   Usar {0}? (ENTER=si / N=volver)" -f $manual)).Trim()
                    if ($ok -match '^[Nn]$') { continue }
                    $res.Crop = $manual; $done = $true
                }
                else {
                    # [N]: si hubo auto-aceptacion, re-escanear (otro tramo); con menu, volver al menu.
                    if ($autoWin) {
                        $start   = Read-IntOrDefault '   Segundo de inicio del scan' $start -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $dur     = Read-IntOrDefault '   Duracion total del scan (seg)' $dur -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $samples = Read-IntOrDefault '   Numero de muestras (puntos de escaneo)' $samples -TimeoutSec (Get-CvPromptTimeout $Context 'border')
                        $reScan = $true
                    }
                }
            }
        }
        Write-Host ''
      }
    }

    # ---- Resize (se puede combinar con recorte: se aplica crop y luego scale) ----
    # ChangeSize aplica un escalado fijo (valor literal 'W:H'). Con NoUpscale, SOLO reduce: si el origen
    # ya es <= el destino, no se reescala (no se amplia). MaxWidth reduce solo HACIA ABAJO: se decide
    # AQUI comparando el ancho de origen; si es mayor se reescala a ese ancho ('W:-2' = mantiene
    # aspecto y altura par), y si ya es <= no se reescala (Resize vacio). ChangeSize tiene prioridad.
    if ($Prof.ChangeSize) {
        if ([bool]$Prof.NoUpscale) {
            $sw = [int]$vstream.width
            $sh = [int]$vstream.height
            $cs = Get-CvChangeSizeResize -ChangeSize $Prof.ChangeSize -Width $sw -Height $sh
            if ($cs) { $res.Resize = $cs }
            else { Write-CvLog 'VIDEO' ("[RESIZE] - Origen {0}x{1} <= destino ({2}): no se amplia, se mantiene el tamaño original." -f $sw, $sh, $Prof.ChangeSize) -Indent 3 }
        } else {
            $res.Resize = $Prof.ChangeSize
        }
    } else {
        # Reescalado por ancho maximo y/o tratamiento anamorfico (Get-CvResize). Se compara contra el
        # ancho MOSTRADO (display = almacenado x SAR): en video anamorfico (SAR != 1) el que importa es
        # el que se ve. Con Anamorphic 'square'/'squareheight' se cuadra a pixeles cuadrados (setsar=1)
        # aunque no haya maxWidth; con 'keep' solo se capa por maxWidth conservando el SAR del origen.
        $mw   = if ($null -ne $Prof.MaxWidth -and [int]$Prof.MaxWidth -gt 0) { [int]$Prof.MaxWidth } else { 0 }
        $sw   = [int]$vstream.width
        $sh   = [int]$vstream.height
        $sar  = "$($vstream.sample_aspect_ratio)"
        $dw   = Get-CvDisplayWidth -Width $sw -Sar $sar
        $anam = $anamMode   # modo elegido en la pregunta anamorfica (o el configurado si no se pregunto)
        $rz   = Get-CvResize -Width $sw -Height $sh -Sar $sar -MaxWidth $mw -Anamorphic $anam
        if ($rz) {
            $res.Resize = $rz
            if ($rz -match 'setsar=1') {
                Write-CvLog 'VIDEO' ("[RESIZE] - Anamorfico ({0}): SAR {1} (mostrado {2}x{3}) -> pixeles cuadrados {4}." -f $anam, $sar, $dw, $sh, $rz) -Indent 3
            } elseif ($dw -ne $sw) {
                Write-CvLog 'VIDEO' ("[RESIZE] - Anamorfico: ancho mostrado {0}px (almacenado {1}px, SAR {2}) > {3}px: se reescala a {4}." -f $dw, $sw, $sar, $mw, $rz) -Indent 3
            } else {
                Write-CvLog 'VIDEO' ("[RESIZE] - Origen {0}px de ancho > {1}px: se reescala a {2}." -f $sw, $mw, $rz) -Indent 3
            }
        } elseif ($Context.Debug -and $mw -gt 0) {
            Write-CvLog 'VIDEO' ("[RESIZE] - Ancho mostrado {0}px <= {1}px: no se reescala." -f $dw, $mw)
        }
    }
    if ($res.Resize -and $Context.Debug) {
        if ($res.Crop -ne '') { Write-CvLog 'VIDEO' ("[RESIZE] - Se aplicara recorte {0} y luego escalado {1}" -f $res.Crop, $res.Resize) }
        else                  { Write-CvLog 'VIDEO' ("[RESIZE] - Escalado a {0}" -f $res.Resize) }
    }

    # ---- Animacion (solo libx264/libx265; -tune animation) ----
    $animEncoders = @(
        'libx264'
        'libx265'
    )
    if ($Prof.VideoEncoder -in $animEncoders) {
        $a = (Read-CvLine -Prompt '   [VIDEO] - Es un video de animacion? (s/N)' -TimeoutSec (Get-CvPromptTimeout $Context 'animation')).Trim()
        $res.Anim = ($a -match '^[SsYy]')
        $res.Manual = $true   # se pregunto por animacion (intervencion manual)
        Write-Host ''
    }

    return [pscustomobject]$res
}

function Get-VideoArgs {
    <# Construye el array de argumentos ffmpeg de la parte de codec/opciones de video. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof, [bool]$Anim = $false)
    $a = @()
    $enc = $Prof.VideoEncoder
    $qmin = $Prof.Qmin; $qmax = $Prof.Qmax
    $constqp = ($null -ne $qmin -and $null -ne $qmax -and "$qmin" -eq "$qmax")
    # -r solo si encode.forceFps (por defecto). Si no, se conserva el fps de origen (sin -r).
    $fpsArg = if ($Context.ForceFps) { @('-r',"$($Context.Fps)") } else { @() }
    # 2-pass de NVENC (-multipass); solo encoders NVENC. El perfil ('Multipass') tiene prioridad;
    # si el perfil no lo fija ('' ), se usa el global 'encode.multipass' (Context.Multipass).
    $mp = if ("$($Prof.Multipass)" -ne '') { "$($Prof.Multipass)".ToLower() } else { "$($Context.Multipass)" }
    $mpArg = if ($mp -in (Get-CvMultipass2Pass)) { @('-multipass',$mp) } else { @() }

    # Tuning del encoder (preset por familia, rc-lookahead NVENC, refs x26x, tier hevc): fuente unica
    # encode.video.tuning via el Context. Si el Context no lo trae (contextos sinteticos de test), se
    # cae a los defaults de config, para no hardcodear los valores aqui.
    $tune        = (Get-CvConfigDefaults).encode.video.tuning
    $presetNvenc = if ("$($Context.PresetNvenc)")    { "$($Context.PresetNvenc)" }    else { "$($tune.presetNvenc)" }
    $presetX26x  = if ("$($Context.PresetX26x)")     { "$($Context.PresetX26x)" }     else { "$($tune.presetX26x)" }
    $presetSvt   = if ("$($Context.PresetSvtav1)")   { "$($Context.PresetSvtav1)" }   else { "$($tune.presetSvtav1)" }
    $presetAv1N  = if ("$($Context.PresetAv1Nvenc)") { "$($Context.PresetAv1Nvenc)" } else { "$($tune.presetAv1Nvenc)" }
    $rcLook      = if ("$($Context.RcLookahead)" -ne '') { "$($Context.RcLookahead)" } else { "$($tune.rcLookahead)" }
    $refs        = if ("$($Context.Refs)" -ne '')        { "$($Context.Refs)" }        else { "$($tune.refs)" }
    $tier        = if ("$($Context.Tier)")               { "$($Context.Tier)" }        else { "$($tune.tier)" }

    switch ($enc) {
        'hevc_nvenc' {
            $a += @('-c:v','hevc_nvenc','-tier',$tier)
            if ($Prof.VideoProfile -eq 'main10') { $a += @('-pix_fmt','p010le') } else { $a += @('-pix_fmt','yuv420p') }
            $a += @('-preset',$presetNvenc)
            if ($Prof.VideoProfile) { $a += @('-profile:v',$Prof.VideoProfile) }
            if ($Prof.VideoLevel)   { $a += @('-level:v',"$($Prof.VideoLevel)") }
            if ($constqp) { $a += @('-rc','constqp','-qp',"$qmax") }
            else {
                if ($null -ne $qmin) { $a += @('-qmin',"$qmin") }
                if ($null -ne $qmax) { $a += @('-qmax',"$qmax") }
            }
            # NOTA: NVENC no admite -refs (muchas GPUs fallan con "No capable devices found").
            $a += @('-rc-lookahead:v',$rcLook) + $mpArg + $fpsArg + @('-movflags','+faststart')
        }
        'h264_nvenc' {
            $a += @('-c:v','h264_nvenc','-pix_fmt','yuv420p','-preset',$presetNvenc)
            if ($Prof.VideoProfile) { $a += @('-profile:v',$Prof.VideoProfile) }
            if ($Prof.VideoLevel)   { $a += @('-level:v',"$($Prof.VideoLevel)") }
            if ($constqp) { $a += @('-rc','constqp','-qp',"$qmax") }
            else {
                if ($null -ne $qmin) { $a += @('-qmin',"$qmin") }
                if ($null -ne $qmax) { $a += @('-qmax',"$qmax") }
            }
            $a += @('-rc-lookahead:v',$rcLook) + $mpArg + $fpsArg + @('-movflags','+faststart')
        }
        'libx264' {
            # pix_fmt segun profundidad: perfil de 10 bits (high10) -> yuv420p10le; si no, 8 bits. OJO:
            # emitir -profile:v high10 con -pix_fmt yuv420p (8 bits) hace que x264 IGNORE el perfil (sale
            # 8 bits / perfil equivocado); el pix_fmt debe casar con el perfil.
            $px = if ($Prof.VideoProfile -in @('high10','main10')) { 'yuv420p10le' } else { 'yuv420p' }
            $a += @('-c:v','libx264','-pix_fmt',$px)
            if ($null -ne $Prof.Crf) { $a += @('-crf',"$($Prof.Crf)") }
            $a += @('-preset',$presetX26x)
            if ($Prof.VideoProfile) { $a += @('-profile:v',$Prof.VideoProfile) }
            if ($Prof.VideoLevel)   { $a += @('-level:v',"$($Prof.VideoLevel)") }
            if ($Anim) { $a += @('-tune','animation') }
            $a += @('-refs',$refs) + $fpsArg + @('-movflags','+faststart')
        }
        'libx265' {
            # pix_fmt segun profundidad: perfil main10 -> yuv420p10le; si no, 8 bits. Emitir -profile:v
            # main10 con -pix_fmt yuv420p (8 bits) hace que x265 IGNORE el perfil (sale "Main", 8 bits).
            $px = if ($Prof.VideoProfile -in @('main10','high10')) { 'yuv420p10le' } else { 'yuv420p' }
            $a += @('-c:v','libx265','-pix_fmt',$px)
            if ($null -ne $Prof.Crf) { $a += @('-crf',"$($Prof.Crf)") }
            $a += @('-preset',$presetX26x)
            if ($Prof.VideoProfile) { $a += @('-profile:v',$Prof.VideoProfile) }
            if ($Prof.VideoLevel)   { $a += @('-level:v',"$($Prof.VideoLevel)") }
            if ($Anim) { $a += @('-tune','animation') }
            $a += @('-refs',$refs) + $fpsArg + @('-movflags','+faststart')
        }
        'libsvtav1' {
            # SVT-AV1 (CPU). CRF 0-63 (mayor = menos calidad); preset 0-13 (menor = mas lento/mejor).
            # 10 bits = yuv420p10le. No usa -profile:v/-level:v ni -refs.
            $a += @('-c:v','libsvtav1')
            if ($Prof.VideoProfile -eq 'main10') { $a += @('-pix_fmt','yuv420p10le') } else { $a += @('-pix_fmt','yuv420p') }
            if ($null -ne $Prof.Crf) { $a += @('-crf',"$($Prof.Crf)") }
            $a += @('-preset',$presetSvt) + $fpsArg
        }
        'av1_nvenc' {
            # AV1 por NVENC (GPU NVIDIA RTX 40+). Estructura como los demas NVENC: preset pN, constqp o
            # qmin/qmax, lookahead y multipass. 10 bits = p010le. AV1 NVENC no usa -tier/-profile:v/-level:v.
            $a += @('-c:v','av1_nvenc')
            if ($Prof.VideoProfile -eq 'main10') { $a += @('-pix_fmt','p010le') } else { $a += @('-pix_fmt','yuv420p') }
            $a += @('-preset',$presetAv1N)
            if ($constqp) { $a += @('-rc','constqp','-qp',"$qmax") }
            else {
                if ($null -ne $qmin) { $a += @('-qmin',"$qmin") }
                if ($null -ne $qmax) { $a += @('-qmax',"$qmax") }
            }
            $a += @('-rc-lookahead:v',$rcLook) + $mpArg + $fpsArg + @('-movflags','+faststart')
        }
    }
    return ,$a
}

function Get-CvTonemapFormat {
    <#
        Pixel format del tone-mapping HDR->SDR con perfil main10 (10 bits): 'p010le' en los encoders
        NVENC/HEVC (hevc_nvenc/libx265/av1_nvenc) y 'yuv420p10le' en SVT-AV1 (libsvtav1); 'yuv420p'
        (8 bits) en el resto.
    #>
    param([string]$VideoProfile, [string]$VideoEncoder)
    $p010Encoders = @(
        'hevc_nvenc'
        'libx265'
        'av1_nvenc'
    )
    if ("$VideoProfile" -eq 'main10') {
        if ($VideoEncoder -in $p010Encoders)  { return 'p010le' }
        if ($VideoEncoder -eq 'libsvtav1')    { return 'yuv420p10le' }
    }
    return 'yuv420p'
}

function Get-CvVideoCopyRemuxWarning {
    <#
        Aviso (texto o '') cuando COPIAR el vídeo (stream-copy, sin recodificar) de este contenedor a MKV
        es propenso a fallar. Caso conocido: AVI —el vídeo H.264/HEVC en AVI suele traer timestamps que el
        muxer de Matroska rechaza al copiar (ffmpeg aborta con "Error muxing a packet / -22")—. PURA (solo
        mira la extensión). El llamador la usa únicamente cuando el vídeo va en modo copy.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $risky = @('.avi')
    $ext = [System.IO.Path]::GetExtension("$Path").ToLower()
    if ($ext -in $risky) {
        return ("Copiar el video de un contenedor {0} a MKV sin recodificar puede fallar (timestamps); si falla, usa un perfil que RECODIFIQUE el video." -f $ext.TrimStart('.').ToUpper())
    }
    return ''
}

function Get-CvVideoFilterChain {
    <#
        Cadena de filtros de video (-vf) en ORDEN: crop -> scale -> (tonemap libplacebo + format).
        El tonemap va DESPUES del reescalado. Devuelve un array de filtros (vacio si no hay ninguno);
        el llamador lo une con ','. Funcion PURA (sin logging): los avisos de reescalado/tonemap los
        emite el llamador. -Fmt = pixel format del tonemap (Get-CvTonemapFormat).
    #>
    param([string]$Crop = '', [string]$Resize = '', [bool]$Tonemap = $false, [string]$Fmt = 'yuv420p', [string]$TonemapCurve = 'bt.2390')
    $vf = @()
    if ($Crop)   { $vf += "crop=$Crop" }
    if ($Resize) { $vf += "scale=$Resize" }
    if ($Tonemap) {
        $curve = if ("$TonemapCurve" -ne '') { "$TonemapCurve" } else { 'bt.2390' }
        $vf += ("libplacebo=tonemapping={0}:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" -f $curve)
        $vf += "format=$Fmt"
    }
    return ,$vf
}

function Get-CvOutputFps {
    <#
        Fps que tendra la SALIDA: el forzado por config ('-r encode.video.fps') si encode.video.forceFps,
        o el del ORIGEN si no (sin '-r' ffmpeg conserva el del fichero). Devuelve [double] (0 = no se
        sabe). Lo usa la linea de progreso para estimar el avance por frames cuando ffmpeg no da
        out_time (ver Resolve-CvProgressSeconds), asi que tiene que ser el fps de SALIDA: 'frame=' del
        '-progress' cuenta frames YA codificados, no los leidos del origen.
    #>
    param([Parameter(Mandatory)]$Context, $Info = $null)
    if ($Context.ForceFps) {
        $f = ConvertTo-InvDouble "$($Context.Fps)"   # config: '23.976' (invariante, nunca coma)
        if ($null -ne $f -and $f -gt 0) { return [double]$f }
    }
    if ($null -ne $Info) { return (Get-CvMediaFps -Info $Info) }
    return 0.0
}

function Get-CvVideoRunArgs {
    <#
        Construye (PURO: sin ejecutar ni tocar disco) el array de argumentos ffmpeg de la codificacion de
        VIDEO a su temporal. crop -> scale -> (tonemap HDR->SDR, si el origen es HDR y tonemapHdr != off) +
        args del encoder (Get-VideoArgs) + mapeo de la pista elegida (0:<Index>, o 0:v:0 si -1). Golden-testeable.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$OutTmp,
        [string]$Crop = '', [string]$Resize = '', [bool]$Anim = $false, [int]$Index = -1, [bool]$Hdr = $false
    )
    $tonemap = $Hdr -and ("$($Context.TonemapHdr)".ToLower() -ne 'off')
    $fmt = Get-CvTonemapFormat -VideoProfile $Prof.VideoProfile -VideoEncoder $Prof.VideoEncoder
    $vf  = Get-CvVideoFilterChain -Crop $Crop -Resize $Resize -Tonemap $tonemap -Fmt $fmt -TonemapCurve "$($Context.TonemapCurve)"
    $ffArgs = @('-hide_banner','-y')
    if ($tonemap) { $ffArgs += @('-init_hw_device','vulkan') }   # necesario para el filtro libplacebo
    $ffArgs += @('-threads',"$($Context.Threads)",'-i',$File,'-an','-sn','-map_chapters','-1')
    $ffArgs += @('-metadata','title=', '-metadata:s:v','title=', '-metadata:s:v','language=und')
    if ($vf.Count -gt 0) { $ffArgs += @('-vf', ($vf -join ',')) }
    $ffArgs += (Get-VideoArgs -Context $Context -Prof $Prof -Anim $Anim)
    # Etiquetar la salida como SDR BT.709 (el tonemap ya convirtio el contenido).
    if ($tonemap) { $ffArgs += @('-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv') }
    # Mapear explicitamente la PISTA DE VIDEO elegida por su indice absoluto ('0:<Index>'), no el primer
    # stream (0:0) ni '0:v:0' (que incluiria una caratula si va antes). Sin -Index (jobs antiguos) -> '0:v:0'.
    $vmap = if ($Index -ge 0) { "0:$Index" } else { '0:v:0' }
    # Modo pruebas: limitar la salida a los primeros TestLimit segundos (-t como opcion de salida).
    if ($Context.TestLimit -gt 0) { $ffArgs += @('-t',"$($Context.TestLimit)") }
    $ffArgs += @('-map',$vmap,'-f','matroska',$OutTmp)
    return ,$ffArgs
}

function Get-CvVideoStreamBytes {
    <#
        PURO. Cuanto ocupa la PISTA de video de un archivo, sin leer el fichero entero (que en un
        video de varios GB no es una opcion). Se mira, en este orden:

          1. el tag NUMBER_OF_BYTES de la pista (lo escribe mkvmerge, asi que la mayoria de los MKV
             lo traen) - exacto;
          2. su bit_rate por la duracion (MP4, AVI y casi todo lo que no sea MKV lo traen) - bueno;
          3. el tag BPS (MKV sin NUMBER_OF_BYTES) por la duracion;
          4. si no hay nada, el TAMANO DEL ARCHIVO como cota superior: la pista de video nunca ocupa
             mas que el fichero que la contiene, asi que comparar contra el es CONSERVADOR (se dira
             que no compensa solo en los casos flagrantes, nunca de mas).

        Devuelve @{ Bytes; From } con From = tag|bitrate|bps|archivo|'' (para poder contarlo en el log).
    #>
    param(
        $Info,
        [int]$Index = -1,
        [long]$FileBytes = 0
    )
    $nada = @{
        Bytes = 0L
        From  = ''
    }
    if ($null -eq $Info) { return $nada }
    $vs = @(Get-VideoStreams -Info $Info)
    if ($vs.Count -eq 0) { return $nada }
    $v = $vs[0]
    if ($Index -ge 0) {
        $m = @($vs | Where-Object { [int]$_.index -eq $Index })
        if ($m.Count -gt 0) { $v = $m[0] }
    }
    $dur = [double](Get-MediaDuration $Info)
    if ($dur -le 0) { $dur = [double]"$($v.duration)" }
    $tag = ''
    $bps = ''
    if ($v.PSObject.Properties['tags'] -and $null -ne $v.tags) {
        foreach ($p in @($v.tags.PSObject.Properties)) {
            $n = "$($p.Name)".ToUpper()
            if ($n -eq 'NUMBER_OF_BYTES' -or $n -like 'NUMBER_OF_BYTES-*') { if ($tag -eq '') { $tag = "$($p.Value)" } }
            if ($n -eq 'BPS' -or $n -like 'BPS-*')                         { if ($bps -eq '') { $bps = "$($p.Value)" } }
        }
    }
    $n = 0L
    if ($tag -ne '' -and [long]::TryParse($tag, [ref]$n) -and $n -gt 0) {
        return @{
            Bytes = $n
            From  = 'tag'
        }
    }
    $br = 0L
    if ([long]::TryParse("$($v.bit_rate)", [ref]$br) -and $br -gt 0 -and $dur -gt 0) {
        return @{
            Bytes = [long]($br * $dur / 8)
            From  = 'bitrate'
        }
    }
    $br = 0L
    if ($bps -ne '' -and [long]::TryParse($bps, [ref]$br) -and $br -gt 0 -and $dur -gt 0) {
        return @{
            Bytes = [long]($br * $dur / 8)
            From  = 'bps'
        }
    }
    if ($FileBytes -gt 0) {
        return @{
            Bytes = [long]$FileBytes
            From  = 'archivo'
        }
    }
    return $nada
}

function Test-CvResizeNoop {
    <#
        PURO. $true si el escalado pedido deja la imagen DEL MISMO TAMANO (o no hay escalado). Pasa a
        menudo: un perfil con ChangeSize '1920:-2' sobre un video que YA es de 1920 pide un
        'scale=1920:-2' que no escala nada. Sin las medidas del origen (-SrcWidth/-SrcHeight) no se
        puede saber, asi que cualquier escalado cuenta como cambio.

        La comparacion va con el tamano ALMACENADO, que es sobre el que trabaja el filtro scale.
    #>
    param([string]$Resize = '', [int]$SrcWidth = 0, [int]$SrcHeight = 0)
    $r = "$Resize".Trim()
    if ($r -eq '') { return $true }
    if ($SrcWidth -le 0 -or $SrcHeight -le 0) { return $false }
    if ($r -notmatch '^(-?\d+):(-?\d+)$') { return $false }
    $w = [int]$Matches[1]
    $h = [int]$Matches[2]
    if ($w -lt 0 -and $h -lt 0) { return $false }                     # nada fijo: no se sabe
    if ($w -gt 0 -and $w -ne $SrcWidth)  { return $false }
    if ($h -gt 0 -and $h -ne $SrcHeight) { return $false }
    # Con el lado automatico (-1/-2) el calculado sale del otro, que ya es el del origen; solo puede
    # salir distinto si hay que redondearlo a par y el original era impar.
    if ($h -lt 0 -and ($SrcHeight % 2) -ne 0) { return $false }
    if ($w -lt 0 -and ($SrcWidth  % 2) -ne 0) { return $false }
    return $true
}

function Test-CvCropNoop {
    <# PURO. $true si el recorte pedido deja la imagen entera (o no hay recorte). #>
    param([string]$Crop = '', [int]$SrcWidth = 0, [int]$SrcHeight = 0)
    $c = "$Crop".Trim()
    if ($c -eq '') { return $true }
    if ($SrcWidth -le 0 -or $SrcHeight -le 0) { return $false }
    if ($c -notmatch '^(\d+):(\d+):(\d+):(\d+)$') { return $false }
    return ([int]$Matches[1] -eq $SrcWidth -and [int]$Matches[2] -eq $SrcHeight -and [int]$Matches[3] -eq 0 -and [int]$Matches[4] -eq 0)
}

function Get-CvVideoPictureState {
    <#
        PURO. Si la codificacion CAMBIA la imagen o solo la vuelve a comprimir, y que la cambia.
        Mientras no se toque la imagen, la pista ORIGINAL sirve de sustituto si lo recodificado sale
        mas grande; en cuanto cambia (recorte, escalado, tone-mapping HDR o un fps distinto) ya no,
        porque la salida tenia que verse de otra manera.

        Lo que NO cuenta como cambio, y por eso se miran las medidas del origen:
          - un escalado que deja el mismo tamano (ChangeSize 1920:-2 sobre un video de 1920);
          - un recorte que abarca el fotograma entero;
          - forzar un fps que ya es el del origen. OJO: encode.video.forceFps viene PUESTO de serie,
            asi que mirar el flag descartaria casi todos los archivos; lo que cuenta es que el fps de
            SALIDA sea distinto del de ORIGEN (0 en cualquiera de los dos = no se sabe, no cuenta).

        Devuelve @{ Untouched; Reason } (Reason = que la cambia, para poder contarlo en el log).
    #>
    param(
        [string]$Crop = '',
        [string]$Resize = '',
        [bool]$Hdr = $false,
        [string]$TonemapHdr = 'off',
        [double]$SrcFps = 0,
        [double]$OutFps = 0,
        [int]$SrcWidth = 0,
        [int]$SrcHeight = 0,
        # Diferencia de fps que ya no se considera la misma cadencia (23.976 escrito de dos maneras
        # no puede contar como cambio).
        [double]$FpsTolerance = 0.01
    )
    $cambia = @()
    if (-not (Test-CvCropNoop   -Crop $Crop     -SrcWidth $SrcWidth -SrcHeight $SrcHeight)) { $cambia += ("recorte {0}" -f "$Crop".Trim()) }
    if (-not (Test-CvResizeNoop -Resize $Resize -SrcWidth $SrcWidth -SrcHeight $SrcHeight)) { $cambia += ("escalado {0}" -f "$Resize".Trim()) }
    if ($Hdr -and ("$TonemapHdr".ToLower() -ne 'off')) { $cambia += 'tone-mapping HDR->SDR' }
    if ($SrcFps -gt 0 -and $OutFps -gt 0 -and [Math]::Abs($SrcFps - $OutFps) -gt $FpsTolerance) {
        $cambia += ("fps {0} -> {1}" -f (Format-CvNumber ([math]::Round($SrcFps, 3))), (Format-CvNumber ([math]::Round($OutFps, 3))))
    }
    return @{
        Untouched = ($cambia.Count -eq 0)
        Reason    = ($cambia -join ', ')
    }
}

function Get-CvVideoKeepPlan {
    <#
        PURO. Si toca quedarse con la pista de video ORIGINAL en vez de la recien codificada.

        Se compara lo que ha salido con lo que habia: si engorda (o no ahorra lo suficiente, -Ratio)
        y la imagen no se ha tocado (-Untouched), recodificar no ha servido de nada y el original es
        mejor en todo -mas pequeno y sin perdida-. El audio, los subtitulos y los capitulos ya estan
        hechos: solo cambia de donde sale el video al multiplexar.

        Devuelve @{ UseOriginal; Reason }.
    #>
    param(
        [long]$EncodedBytes = 0,
        [long]$OriginalBytes = 0,
        [bool]$Untouched = $true,
        [bool]$Enabled = $false,
        [double]$Ratio = 1.0
    )
    if (-not $Enabled) {
        return @{
            UseOriginal = $false
            Reason      = ''
        }
    }
    if (-not $Untouched) {
        return @{
            UseOriginal = $false
            Reason      = 'la imagen cambia (recorte, escalado, tone-mapping o fps forzado): el original no sirve de sustituto'
        }
    }
    if ($EncodedBytes -le 0 -or $OriginalBytes -le 0) {
        return @{
            UseOriginal = $false
            Reason      = 'no se sabe cuanto ocupa alguna de las dos pistas'
        }
    }
    $limite = [double]$OriginalBytes * $(if ($Ratio -gt 0) { [double]$Ratio } else { 1.0 })
    if ([double]$EncodedBytes -le $limite) {
        return @{
            UseOriginal = $false
            Reason      = ''
        }
    }
    return @{
        UseOriginal = $true
        Reason      = ("recodificar no compensa: {0} frente a {1} del original" -f (Format-CvSize -Kb ([long]($EncodedBytes / 1024))), (Format-CvSize -Kb ([long]($OriginalBytes / 1024))))
    }
}

function Invoke-VideoRun {
    <# Codifica el video usando la config del job. Devuelve $true si crea la salida temporal. #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Prof,
        [Parameter(Mandatory)][string]$File,
        [string]$Crop = '', [string]$Resize = '', [bool]$Anim = $false, [int]$Index = -1, [bool]$Hdr = $false,
        # Duracion del video en segundos (para el % y ETA del progreso). 0 = desconocida (sin %/ETA).
        [double]$Duration = 0,
        # Fps de SALIDA (Get-CvOutputFps): red de seguridad del progreso si ffmpeg no da out_time.
        [double]$Fps = 0
    )
    $name = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $outTmp = (Get-CvTempPaths -Context $Context -Name $name).Video
    if (Test-Path -LiteralPath $outTmp) { Remove-Item -Force -LiteralPath $outTmp -ErrorAction SilentlyContinue }

    # Avisos del worker (el comando lo construye Get-CvVideoRunArgs, puro). Tone-mapping HDR->SDR: solo
    # si el origen es HDR y encode.tonemapHdr != 'off' (BT.2020/PQ|HLG -> BT.709 SDR con libplacebo).
    $tonemap = $Hdr -and ("$($Context.TonemapHdr)".ToLower() -ne 'off')
    if ($Resize) {
        $rzTxt = "a $Resize"
        if ($Resize -match '^(\d+):(-?\d+)$') { $rzTxt = if ([int]$Matches[2] -lt 0) { "a {0}px de ancho" -f $Matches[1] } else { "a {0}x{1}" -f $Matches[1], $Matches[2] } }
        Write-CvInfoStep $Context 'VIDEO' ("Reescalando $rzTxt")
    }
    if ($tonemap) { Write-CvInfoStep $Context 'VIDEO' 'Tone-mapping HDR -> SDR (BT.709)' }

    $ffArgs = Get-CvVideoRunArgs -Context $Context -Prof $Prof -File $File -OutTmp $outTmp -Crop $Crop -Resize $Resize -Anim $Anim -Index $Index -Hdr $Hdr

    # Progreso inline (% + ETA) si esta activo y sabemos la duracion; si no, ventana aparte + ✓.
    # Total = duracion del video (acotada a TestLimit en modo pruebas). Ambos caminos dejan la linea
    # "abierta" para que Stop-CvStep la cierre con OK/ERROR.
    $global:CvLastToolError = $null   # el modo progreso lo rellena; se vuelca al log si ffmpeg falla
    if ($Context.Progress -and -not $Context.Debug -and $Duration -gt 0) {
        $total = if ($Context.TestLimit -gt 0) { [math]::Min([double]$Duration, [double]$Context.TestLimit) } else { [double]$Duration }
        $code = Invoke-ToolProgress -Exe $Context.FFmpeg -Arguments $ffArgs -Context $Context -Label 'Procesando Video...' -TotalSeconds $total -Fps $Fps -ShowQ
    } else {
        Start-CvStep $Context 'VIDEO' 'Procesando Video...'
        $code = Invoke-ToolShow -Exe $Context.FFmpeg -Arguments $ffArgs -Context $Context
    }
    if ($code -ne 0) {
        Stop-CvStep $Context 'VIDEO' $false -FailMsg ("[ERR] - ffmpeg devolvio codigo {0}" -f $code)
        Show-CvToolError -Context $Context -Category 'VIDEO' -Name $name -Tool 'ffmpeg-video'
        if (Test-Path -LiteralPath $outTmp) { Remove-Item -Force -LiteralPath $outTmp -ErrorAction SilentlyContinue }
        return $false
    }
    $vOk = ((Test-Path -LiteralPath $outTmp) -and ((Get-Item -LiteralPath $outTmp).Length -gt 0))
    Stop-CvStep $Context 'VIDEO' $vOk -FailMsg '[ERR] - la salida de video quedo vacia'
    return $vOk
}

function Get-CvQualityLavfi {
    <#
        Filtro -lavfi para medir la calidad de la SALIDA (input 0) frente al ORIGEN (input 1). Normaliza
        ambos a yuv420p y escala la referencia (origen) al tamaño de la salida (scale2ref), para que
        ssim/libvmaf comparen aunque hubo resize/crop o distinta profundidad de bits (p. ej. main10). La
        alineacion temporal (fps distinto por forceFps) la resuelve el framesync de la propia metrica,
        asi que NO se usa el filtro 'fps' (que ademas dispara una asercion en ffmpeg 7.1 con 2 inputs).
        $Metric: 'vmaf' -> libvmaf; cualquier otro -> ssim.
    #>
    param([string]$Metric)
    $m = if ("$Metric".ToLower() -eq 'vmaf') { 'libvmaf' } else { 'ssim' }
    "[0:v]format=yuv420p[d0];[1:v]format=yuv420p[r0];[r0][d0]scale2ref[ref][dist];[dist][ref]$m"
}

function Get-CvQualityScore {
    <# Extrae la puntuacion de la salida de ffmpeg del filtro de calidad. ssim -> el valor 'All:'
       (0..1); vmaf -> 'VMAF score:' (0..100). Devuelve [double] (invariante) o $null si no aparece. #>
    param([string]$Metric, [string]$Text)
    $rx = if ("$Metric".ToLower() -eq 'vmaf') { 'VMAF score:\s*([0-9]+(?:\.[0-9]+)?)' } else { '\bAll:\s*([0-9]+(?:\.[0-9]+)?)' }
    $mm = [regex]::Match("$Text", $rx)
    if ($mm.Success) { return [double]::Parse($mm.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    $null
}

function Measure-CvQuality {
    <#
        Mide la calidad de $Output frente a $Source con $Metric (ssim|vmaf), decodificando ambos en una
        pasada extra de ffmpeg. Muestra PROGRESO EN VIVO (% + ETA + velocidad) via Invoke-ToolProgress:
        como decodifica los dos videos enteros puede tardar, asi el usuario ve que avanza. La salida va
        a NUL (no a stdout) para no chocar con '-progress pipe:1'; la puntuacion la imprime el filtro por
        stderr, que Invoke-ToolProgress deja en $global:CvLastToolError. Devuelve la puntuacion [double]
        o $null si no se puede medir (metrica 'off', sin ffmpeg, ficheros ausentes, ffmpeg falla —p. ej.
        libvmaf no disponible—). FAIL-SOFT: nunca lanza; el llamador decide que hacer con $null.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Output, [string]$Metric = 'off')
    if ("$Metric".ToLower() -in @('', 'off')) { return $null }
    $exe = "$($Context.FFmpeg)"
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { return $null }
    if (-not (Test-Path -LiteralPath $Output) -or -not (Test-Path -LiteralPath $Source)) { return $null }
    $lavfi = Get-CvQualityLavfi -Metric $Metric
    # Duracion para el % + ETA: la comparativa acaba con el video mas corto (normalmente la salida).
    $total = 0.0
    try { $total = [double](Get-MediaDuration (Get-MediaInfo -Context $Context -File $Output)) } catch {}
    $code = Invoke-ToolProgress -Exe $exe -Arguments @(
        '-i', $Output
        '-i', $Source
        '-lavfi', $lavfi
        '-an'
        '-f', 'null'
        'NUL'
    ) -Context $Context -Label ("Analizando calidad ({0})..." -f "$Metric".ToUpper()) -TotalSeconds $total
    Write-Host ''   # cerrar la linea viva de progreso antes de que el llamador registre el resultado
    if ($code -ne 0) { return $null }
    Get-CvQualityScore -Metric $Metric -Text "$($global:CvLastToolError)"
}

Export-ModuleMember -Function *
