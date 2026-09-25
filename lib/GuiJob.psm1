<#
    GuiJob.psm1 - Preparar los jobs en VENTANA (WinForms).

    Dos caminos, los mismos que en consola:

      PREPARAR PENDIENTES (Show-CvPrepareWindow) - el flujo normal, calcado al de la consola: se
        elige el PERFIL una vez para todo el lote y despues se recorre archivo por archivo haciendo
        el AUTODISCOVER (Get-CvJobAutoPlan). Lo que la consola resolveria sola se guarda solo; solo
        se para a preguntar en los MISMOS casos en que preguntaria la consola (varias pistas de
        video, varias -o ninguna- del idioma preferido, subtitulos sin idioma preferido, bordes que
        hay que confirmar), y entonces abre el editor de abajo ya relleno y diciendo por que.

      EDITOR DE UN JOB (Show-CvJobWindow) - ver y retocar el job de un archivo concreto (o crearlo).

    Lo que se ensena y lo que se elegiria solo sale de lib\JobCore.psm1 (datos, sin interfaz), que se
    apoya en las MISMAS funciones que decide la consola (Select-AudioStream, Split-CvSubtitlesByRole,
    Find-CropDetectSamples, Get-CvResize...). La ventana no reimplementa ninguna decision. Y el job
    se escribe por el mismo sitio (ConvertTo-CvJobRecord + Write-CvJob), asi que sale identico.

    ANALIZAR UN ARCHIVO ES LENTO y eso se nota: contar los cues de un subtitulo sin el tag
    NUMBER_OF_FRAMES DEMULTIPLEXA el fichero entero (por pista), y la deteccion de bordes son varios
    ffmpeg. Por eso aqui la ventana se abre SIEMPRE primero, con una barra en marcha y el paso en
    curso escrito, y el analisis va despues (con DoEvents entre fases para que la ventana responda).
    Nunca al reves: abrir despues de analizar es lo que parecia que el programa se habia colgado.
#>

function Get-CvJobAudioRows {
    <#
        PURO. Filas de la tabla de audio: cruza las pistas del archivo (Get-CvJobAudioOptions) con lo
        elegido en el borrador, para saber cuales van marcadas, con que idioma, sincronia y cual es la
        predeterminada. Separado de la ventana para poder probarlo sin abrirla.
    #>
    param($Options, $Tracks)
    $byIdx = @{}
    foreach ($t in @($Tracks)) { $byIdx[[int]$t.Index] = $t }
    $out = @()
    foreach ($o in @($Options)) {
        $t = $byIdx[[int]$o.Index]
        $out += [pscustomobject]@{
            Index    = [int]$o.Index
            Pos      = [int]$o.Pos
            Text     = "$($o.Text)"
            Channels = [int]$o.Channels
            Is51     = [bool]$o.Is51
            Codec    = "$($o.Codec)"
            Keep     = ($null -ne $t)
            Lang     = $(if ($t) { "$($t.Lang)" } else { "$($o.Lang)" })
            Sync     = $(if ($t) { [double]$t.Sync } else { 0.0 })
            Default  = [bool]($t -and $t.Default)
        }
    }
    return @($out)
}

function Get-CvJobSubRows {
    <#
        PURO. Filas de la tabla de subtitulos: pistas del archivo cruzadas con las elegidas en el
        borrador (marcadas, y con que papel: forzado / predeterminado).
    #>
    param($Options, $Selected)
    $byIdx = @{}
    foreach ($s in @($Selected)) { $byIdx[[int]$s.Index] = $s }
    $out = @()
    foreach ($o in @($Options)) {
        $s = $byIdx[[int]$o.Index]
        $out += [pscustomobject]@{
            Index   = [int]$o.Index
            Pos     = [int]$o.Pos
            Text    = "$($o.Text)"
            Lang    = $(if ($s) { "$($s.Lang)" } else { "$($o.Lang)" })
            Codec   = "$($o.Codec)"
            Cues    = [int]$o.Cues
            Usable  = [bool]$o.Usable
            IsText  = [bool]$o.IsText
            Empty   = [bool]$o.Empty
            Action  = "$($o.Action)"
            Keep    = ($null -ne $s)
            Forced  = [bool]($s -and $s.Forced)
            Default = [bool]($s -and $s.Default)
            Stream  = $o.Stream
        }
    }
    return @($out)
}

function ConvertTo-CvJobDraftFromRows {
    <#
        PURO. Rehace el borrador con lo que hay en las tablas: las pistas de audio MARCADAS (la
        predeterminada primero, como la congela la consola) y los subtitulos marcados (forzados
        primero). Es lo que se guarda.
    #>
    param($Draft, $AudioRows, $SubRows)
    $keep = @(@($AudioRows) | Where-Object { $_.Keep })
    $tracks = @()
    foreach ($r in @($keep | Where-Object { $_.Default })) {
        $tracks += [pscustomobject]@{
            Index   = [int]$r.Index
            Is51    = [bool]$r.Is51
            Sync    = [double]$r.Sync
            Lang    = "$($r.Lang)"
            Default = $true
        }
    }
    foreach ($r in @($keep | Where-Object { -not $_.Default })) {
        $tracks += [pscustomobject]@{
            Index   = [int]$r.Index
            Is51    = [bool]$r.Is51
            Sync    = [double]$r.Sync
            Lang    = "$($r.Lang)"
            Default = $false
        }
    }
    $subs = @()
    # -Cues: la tabla ya sabe cuantas lineas tiene cada subtitulo, asi que se guarda en el job y el
    # resumen de la cola no tiene que volver a contarlas (que es lo lento).
    foreach ($r in @(@($SubRows) | Where-Object { $_.Keep -and $_.Forced })) {
        $subs += (ConvertTo-SubSel $r.Stream -Forced $true -Default ([bool]$r.Default) -Action "$($r.Action)" -Lang "$($r.Lang)" -Cues ([int]$r.Cues))
    }
    foreach ($r in @(@($SubRows) | Where-Object { $_.Keep -and -not $_.Forced })) {
        $subs += (ConvertTo-SubSel $r.Stream -Forced $false -Default ([bool]$r.Default) -Action "$($r.Action)" -Lang "$($r.Lang)" -Cues ([int]$r.Cues))
    }
    # Lineas de TODAS las pistas (la tabla ya las tiene), para que el resumen ensene tambien las de
    # las descartadas sin volver a leer el fichero.
    $cueMap = @{}
    foreach ($r in @($SubRows)) { if ([int]$r.Cues -ge 0) { $cueMap["$($r.Index)"] = [int]$r.Cues } }

    [pscustomobject]@{
        Name       = "$($Draft.Name)"
        File       = "$($Draft.File)"
        Prof       = $Draft.Prof
        SubCues    = $cueMap
        VideoSkip  = [bool]$Draft.VideoSkip
        VideoIndex = [int]$Draft.VideoIndex
        Crop       = "$($Draft.Crop)"
        Resize     = "$($Draft.Resize)"
        Anim       = [bool]$Draft.Anim
        # Lo que no se toca en las tablas pero SI viaja en el borrador: si no se copia aqui, se
        # pierde al guardar (el HDR ya decidido y la opcion de quedarse con el video original).
        Hdr          = $(if ($Draft.PSObject.Properties['Hdr']) { [bool]$Draft.Hdr } else { $false })
        KeepOriginal = $(if ($Draft.PSObject.Properties['KeepOriginal']) { [bool]$Draft.KeepOriginal } else { $false })
        AudioSkip  = [bool]$Draft.AudioSkip
        Audio      = @($tracks)
        Subtitles  = @($subs)
    }
}

# El editor de perfiles (Show-CvProfileEditorWindow) y el gestor de perfiles propios viven ahora en
# lib\GuiProfile.psm1: los usan TAMBIEN las ventanas de setup, que no cargan el pipeline de jobs.

# El dialogo para ELEGIR perfil (Show-CvJobProfileDialog) vive en lib\GuiProfile.psm1, con el resto
# de ventanas de perfiles (ajustar uno, y gestionar los propios del config).

function Show-CvJobWindow {
    <#
        Editor del job de UN archivo. -Name es el nombre base (el mismo que identifica su job y su
        salida). Si ya tiene .job.json se carga para editarlo; si no, se PREGUNTA el perfil (igual que
        hace la consola antes de preparar) y se parte del borrador automatico con ese perfil. Con
        -Draft/-Info (los que trae Get-CvJobAutoPlan) NO se pregunta ni se analiza nada -el recorrido
        de Show-CvPrepareWindow ya pregunto el perfil una vez para todo el lote-, y -Reasons son los
        motivos por los que se para a preguntar, que se ensenan arriba.

        La ventana se abre ANTES de analizar y va diciendo por donde va (ver la cabecera del modulo).

        Devuelve $true si se guardo el job.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$File,
        $Draft = $null,
        $Info = $null,
        $Reasons = @()
    )
    if (-not (Initialize-CvGui)) { return $false }

    # Sin las herramientas no hay nada que analizar: se dice claro (que version falta y cuales hay)
    # en vez de dejar que reviente el primer ffprobe con un "no se encuentra el archivo".
    $ready = Test-CvConvertReady -Context $Context
    if (-not $ready.Ok) {
        Show-CvGuiInfo -Title 'Faltan herramientas' -Message ("No se puede preparar: {0}" -f $ready.Reason)
        return $false
    }

    # Job NUEVO abierto de uno en uno: se pregunta el perfil, como la consola al empezar PREPARAR. No
    # se elige por nuestra cuenta: el perfil decide si se recodifica, con que encoder y a que tamano.
    # Cancelar aqui = no abrir nada. Si el job ya existe, su perfil manda (y se puede cambiar en el
    # desplegable); si viene -Draft, el recorrido ya pregunto el perfil una vez para todo el lote.
    $baseProf = $null
    if ($null -eq $Draft -and -not (Test-CvJob -Context $Context -Name $Name)) {
        $baseProf = Show-CvJobProfileDialog -Context $Context -Info ("Perfil con el que preparar {0}:" -f $Name)
        if ($null -eq $baseProf) { return $false }
    }

    $st = @{
        BaseProf = $baseProf
        Draft    = $Draft
        Info     = $Info
        Audio    = @()
        Subs     = @()
        VidOpts  = @()
        ProfOpts = @()
        Saved    = $false
        CropScan = $null      # bordes ya escaneados (el escaneo NO depende del perfil: se reutiliza)
        CropKind = ''         # con que parametros se escaneo: 'auto' (pre-escaneo) o 'full'
        CropNote = ''         # que se decidio con esos bordes, para contarlo abajo
        SyncNotes = @()       # retardos de audio detectados (se aplican y se cuentan, como en consola)
        Loading  = $true      # arranca cargando: los manejadores no tocan nada hasta que se llene
        Closing  = $false
        Ready    = $false
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("Preparar: {0}" -f $Name)
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(1000, 820)
    $form.MinimumSize   = New-Object System.Drawing.Size(820, 640)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 7
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))   # estado / motivos
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))   # perfil
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 158)))  # video
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))    # audio
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))    # subtitulos
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))   # mensaje
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))   # botones
    $form.Controls.Add($grid)

    # ---------- Estado del analisis / motivos ----------
    $head = New-Object System.Windows.Forms.TableLayoutPanel
    $head.Dock        = 'Fill'
    $head.ColumnCount = 1
    $head.RowCount    = 2
    [void]$head.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$head.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$head.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 14)))
    $grid.Controls.Add($head, 0, 0)

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Dock      = 'Fill'
    $lblHead.TextAlign = 'MiddleLeft'
    $lblHead.Name      = 'cvJobHead'
    $lblHead.Text      = ("Analizando {0}..." -f $Name)
    $head.Controls.Add($lblHead, 0, 0)

    # Barra PINTADA (New-CvGuiProgressPanel) y no la del sistema: esa la dibuja Windows e ignora los
    # colores, asi que en modo oscuro se queda como una franja clara. Esta se mueve sola (-Marquee)
    # mientras se analiza el archivo.
    $bar = New-CvGuiProgressPanel -Marquee -Name 'cvJobBusy'
    $bar.Dock = 'Fill'
    $head.Controls.Add($bar, 0, 1)

    # ---------- Perfil ----------
    $topBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $topBar.Dock          = 'Fill'
    $topBar.FlowDirection = 'LeftToRight'
    $topBar.WrapContents  = $false
    $grid.Controls.Add($topBar, 0, 1)

    $mkLabel = {
        param([string]$Text)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $Text
        $l.AutoSize  = $true
        $l.Anchor    = 'Left'
        $l.Margin    = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
        return $l
    }
    $topBar.Controls.Add((& $mkLabel 'Perfil:'))

    $cmbProf = New-Object System.Windows.Forms.ComboBox
    $cmbProf.DropDownStyle = 'DropDownList'
    $cmbProf.Width         = 620
    $cmbProf.Font          = (New-CvGuiFont 9)
    $cmbProf.Name          = 'cvJobProfile'
    $cmbProf.Enabled       = $false
    $topBar.Controls.Add($cmbProf)

    $btnTuneProf = New-Object System.Windows.Forms.Button
    $btnTuneProf.Text    = 'Ajustar...'
    $btnTuneProf.Width   = 110
    $btnTuneProf.Height  = 26
    $btnTuneProf.Margin  = New-Object System.Windows.Forms.Padding(10, 2, 3, 3)
    $btnTuneProf.Enabled = $false
    $btnTuneProf.Name    = 'cvJobProfileTune'
    $topBar.Controls.Add($btnTuneProf)

    # ---------- Video ----------
    $gbV = New-Object System.Windows.Forms.GroupBox
    $gbV.Text = ' Video '
    $gbV.Dock = 'Fill'
    $grid.Controls.Add($gbV, 0, 2)

    $vGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $vGrid.Dock        = 'Fill'
    $vGrid.Padding     = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $vGrid.ColumnCount = 4
    $vGrid.RowCount    = 4
    [void]$vGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
    [void]$vGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$vGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
    [void]$vGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    $gbV.Controls.Add($vGrid)

    $vGrid.Controls.Add((& $mkLabel 'Pista:'), 0, 0)
    $cmbVid = New-Object System.Windows.Forms.ComboBox
    $cmbVid.DropDownStyle = 'DropDownList'
    $cmbVid.Dock          = 'Fill'
    $cmbVid.Font          = (New-CvGuiFont 9)
    $cmbVid.Name          = 'cvJobVideo'
    $vGrid.Controls.Add($cmbVid, 1, 0)

    $chkCopy = New-Object System.Windows.Forms.CheckBox
    $chkCopy.Text     = 'Copiar (sin recodificar)'
    $chkCopy.AutoSize = $true
    $chkCopy.Margin   = New-Object System.Windows.Forms.Padding(6, 6, 3, 3)
    $chkCopy.Name     = 'cvJobVideoCopy'
    $vGrid.Controls.Add($chkCopy, 2, 0)

    $chkAnim = New-Object System.Windows.Forms.CheckBox
    $chkAnim.Text     = 'Animacion'
    $chkAnim.AutoSize = $true
    $chkAnim.Margin   = New-Object System.Windows.Forms.Padding(6, 6, 3, 3)
    $chkAnim.Name     = 'cvJobAnim'
    $vGrid.Controls.Add($chkAnim, 3, 0)

    $vGrid.Controls.Add((& $mkLabel 'Recorte:'), 0, 1)
    $txtCrop = New-Object System.Windows.Forms.TextBox
    $txtCrop.Dock = 'Fill'
    $txtCrop.Font = (New-CvGuiFont 9)
    $txtCrop.Name = 'cvJobCrop'
    $vGrid.Controls.Add($txtCrop, 1, 1)

    $btnCrop = New-Object System.Windows.Forms.Button
    $btnCrop.Text = 'Detectar bordes'
    $btnCrop.Dock = 'Fill'
    $btnCrop.Name = 'cvJobCropDetect'
    $vGrid.Controls.Add($btnCrop, 2, 1)

    $btnPrev = New-Object System.Windows.Forms.Button
    $btnPrev.Text = 'Ver recorte'
    $btnPrev.Dock = 'Fill'
    $btnPrev.Name = 'cvJobCropPreview'
    $vGrid.Controls.Add($btnPrev, 3, 1)

    $vGrid.Controls.Add((& $mkLabel 'Escalado:'), 0, 2)
    $txtResize = New-Object System.Windows.Forms.TextBox
    $txtResize.Dock = 'Fill'
    $txtResize.Font = (New-CvGuiFont 9)
    $txtResize.Name = 'cvJobResize'
    $vGrid.Controls.Add($txtResize, 1, 2)

    $lblVInfo = & $mkLabel ''
    $lblVInfo.Name = 'cvJobVideoInfo'
    $vGrid.Controls.Add($lblVInfo, 2, 2)
    $vGrid.SetColumnSpan($lblVInfo, 2)

    # Recodificar no siempre compensa: si la pista recodificada sale MAS GRANDE que la original y la
    # imagen no se toca, se puede dejar la original. Viene marcado segun encode.video, y aqui se
    # decide para ESTE archivo (se congela en su job).
    $chkKeep = New-Object System.Windows.Forms.CheckBox
    $chkKeep.Text     = 'Si el video recodificado engorda, quedarse con el original'
    $chkKeep.AutoSize = $true
    $chkKeep.Margin   = New-Object System.Windows.Forms.Padding(6, 6, 3, 3)
    $chkKeep.Name     = 'cvJobKeepOriginal'
    $vGrid.Controls.Add($chkKeep, 1, 3)
    $vGrid.SetColumnSpan($chkKeep, 3)

    # ---------- Audio ----------
    $gbA = New-Object System.Windows.Forms.GroupBox
    $gbA.Text = ' Audio  (marca las pistas a conservar) '
    $gbA.Dock = 'Fill'
    $grid.Controls.Add($gbA, 0, 3)

    $aGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $aGrid.Dock        = 'Fill'
    $aGrid.Padding     = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $aGrid.ColumnCount = 1
    $aGrid.RowCount    = 2
    [void]$aGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$aGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$aGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $gbA.Controls.Add($aGrid)

    $lvA = New-Object System.Windows.Forms.ListView
    $lvA.Dock          = 'Fill'
    $lvA.View          = 'Details'
    $lvA.CheckBoxes    = $true
    $lvA.FullRowSelect = $true
    $lvA.GridLines     = $true
    $lvA.HideSelection = $false
    $lvA.MultiSelect   = $false
    $lvA.Font          = (New-CvGuiFont 9)
    $lvA.Name          = 'cvJobAudio'
    foreach ($c in @(
        @{ T = 'Pista';    W = 330 }
        @{ T = 'Idioma';   W = 70  }
        @{ T = 'Canales';  W = 70  }
        @{ T = 'Codec';    W = 90  }
        @{ T = 'Predet.';  W = 70  }
        @{ T = 'Sync (s)'; W = 80  }
    )) { [void]$lvA.Columns.Add($c.T, $c.W) }
    # 'Pista' se queda con lo que sobre: es la que lleva el texto largo, y asi no queda un trozo de
    # cabecera sin columna (que el sistema pinta claro y no hay forma de oscurecer).
    [void](Set-CvGuiListFillColumn -List $lvA -Index 0 -Min 240)
    [void](Set-CvGuiDoubleBuffered -Control $lvA)
    $aGrid.Controls.Add($lvA, 0, 0)

    $aBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $aBar.Dock          = 'Fill'
    $aBar.FlowDirection = 'LeftToRight'
    $aBar.WrapContents  = $false
    $aGrid.Controls.Add($aBar, 0, 1)

    $aBar.Controls.Add((& $mkLabel 'Idioma:'))
    $txtLang = New-Object System.Windows.Forms.TextBox
    $txtLang.Width = 60
    $txtLang.Font  = (New-CvGuiFont 9)
    $txtLang.Name  = 'cvJobAudioLang'
    $aBar.Controls.Add($txtLang)

    $aBar.Controls.Add((& $mkLabel 'Sync (s):'))
    $txtSync = New-Object System.Windows.Forms.TextBox
    $txtSync.Width = 70
    $txtSync.Font  = (New-CvGuiFont 9)
    $txtSync.Name  = 'cvJobAudioSync'
    $aBar.Controls.Add($txtSync)

    $btnDef = New-Object System.Windows.Forms.Button
    $btnDef.Text   = 'Marcar como predeterminada'
    $btnDef.Width  = 210
    $btnDef.Height = 26
    $btnDef.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 3)
    $btnDef.Name   = 'cvJobAudioDefault'
    $aBar.Controls.Add($btnDef)

    $btnPlay = New-Object System.Windows.Forms.Button
    $btnPlay.Text   = 'Escuchar'
    $btnPlay.Width  = 100
    $btnPlay.Height = 26
    $btnPlay.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
    $btnPlay.Name   = 'cvJobAudioPlay'
    $aBar.Controls.Add($btnPlay)

    # ---------- Subtitulos ----------
    $gbS = New-Object System.Windows.Forms.GroupBox
    $gbS.Text = ' Subtitulos  (marca los que se conservan) '
    $gbS.Dock = 'Fill'
    $grid.Controls.Add($gbS, 0, 4)

    $sGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $sGrid.Dock        = 'Fill'
    $sGrid.Padding     = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $sGrid.ColumnCount = 1
    $sGrid.RowCount    = 2
    [void]$sGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$sGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$sGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $gbS.Controls.Add($sGrid)

    $lvS = New-Object System.Windows.Forms.ListView
    $lvS.Dock          = 'Fill'
    $lvS.View          = 'Details'
    $lvS.CheckBoxes    = $true
    $lvS.FullRowSelect = $true
    $lvS.GridLines     = $true
    $lvS.HideSelection = $false
    $lvS.MultiSelect   = $false
    $lvS.Font          = (New-CvGuiFont 9)
    $lvS.Name          = 'cvJobSubs'
    foreach ($c in @(
        @{ T = 'Pista';   W = 380 }
        @{ T = 'Idioma';  W = 70  }
        @{ T = 'Cues';    W = 70  }
        @{ T = 'Forzado'; W = 80  }
        @{ T = 'Predet.'; W = 80  }
    )) { [void]$lvS.Columns.Add($c.T, $c.W) }
    [void](Set-CvGuiListFillColumn -List $lvS -Index 0 -Min 240)
    [void](Set-CvGuiDoubleBuffered -Control $lvS)
    $sGrid.Controls.Add($lvS, 0, 0)

    $sBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $sBar.Dock          = 'Fill'
    $sBar.FlowDirection = 'LeftToRight'
    $sBar.WrapContents  = $false
    $sGrid.Controls.Add($sBar, 0, 1)

    $chkForced = New-Object System.Windows.Forms.CheckBox
    $chkForced.Text     = 'Forzado'
    $chkForced.AutoSize = $true
    $chkForced.Margin   = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
    $chkForced.Name     = 'cvJobSubForced'
    $sBar.Controls.Add($chkForced)

    $chkSubDef = New-Object System.Windows.Forms.CheckBox
    $chkSubDef.Text     = 'Predeterminado'
    $chkSubDef.AutoSize = $true
    $chkSubDef.Margin   = New-Object System.Windows.Forms.Padding(12, 7, 3, 3)
    $chkSubDef.Name     = 'cvJobSubDefault'
    $sBar.Controls.Add($chkSubDef)

    $sBar.Controls.Add((& $mkLabel 'Idioma:'))
    $txtSubLang = New-Object System.Windows.Forms.TextBox
    $txtSubLang.Width = 60
    $txtSubLang.Font  = (New-CvGuiFont 9)
    $txtSubLang.Name  = 'cvJobSubLang'
    $sBar.Controls.Add($txtSubLang)

    $btnSubView = New-Object System.Windows.Forms.Button
    $btnSubView.Text   = 'Ver texto'
    $btnSubView.Width  = 110
    $btnSubView.Height = 26
    $btnSubView.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 3)
    $btnSubView.Name   = 'cvJobSubView'
    $sBar.Controls.Add($btnSubView)

    # Los subtitulos de IMAGEN (PGS, VobSub) no tienen texto que ensenar -son mapas de bits-, pero SI
    # se pueden ver reproduciendo el video con ellos encima (ffplay -sst), que es como se distingue
    # un 'normal' de un SDH o de unos forzados. Vale para cualquier pista, de texto o de imagen.
    $btnSubPlay = New-Object System.Windows.Forms.Button
    $btnSubPlay.Text   = 'Reproducir con este'
    $btnSubPlay.Width  = 150
    $btnSubPlay.Height = 26
    $btnSubPlay.Margin = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
    $btnSubPlay.Name   = 'cvJobSubPlay'
    $sBar.Controls.Add($btnSubPlay)

    # ---------- Pie ----------
    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Dock         = 'Fill'
    $lblMsg.TextAlign    = 'MiddleLeft'
    $lblMsg.AutoEllipsis = $true
    $lblMsg.Name         = 'cvJobMsg'
    $grid.Controls.Add($lblMsg, 0, 5)

    $btnBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnBar.Dock          = 'Fill'
    $btnBar.FlowDirection = 'RightToLeft'
    $btnBar.WrapContents  = $false
    $grid.Controls.Add($btnBar, 0, 6)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text   = 'Cancelar'
    $btnCancel.Width  = 110
    $btnCancel.Height = 30
    $btnCancel.Name   = 'cvJobCancel'
    $btnBar.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text    = 'Guardar job'
    $btnSave.Width   = 120
    $btnSave.Height  = 30
    $btnSave.Margin  = New-Object System.Windows.Forms.Padding(8, 3, 3, 3)
    $btnSave.Enabled = $false
    $btnSave.Name    = 'cvJobSave'
    $btnBar.Controls.Add($btnSave)

    # ---------- Render y edicion ----------
    # El MODELO son $st.Audio / $st.Subs; las listas son solo su pintura.
    #
    # OJO con el ciclo de vida del ListView: las filas se CREAN una vez (build) y despues solo se
    # ACTUALIZAN en su sitio (render). Reconstruirlas con Items.Clear() desde un manejador -y
    # ItemChecked lo es- deja la tabla interna del control inconsistente y al cerrar la ventana
    # .NET revienta con NullReferenceException en ListView.OnHandleDestroyed.
    $buildAudio = {
        $st.Loading = $true
        try {
            $lvA.Items.Clear()
            foreach ($r in @($st.Audio)) {
                $it = New-Object System.Windows.Forms.ListViewItem("$($r.Text)")
                [void]$it.SubItems.Add("$($r.Lang)")
                [void]$it.SubItems.Add("$($r.Channels)")
                [void]$it.SubItems.Add("$($r.Codec)")
                [void]$it.SubItems.Add($(if ($r.Default) { 'si' } else { '' }))
                [void]$it.SubItems.Add((Format-CvNumber $r.Sync))
                $it.Checked = [bool]$r.Keep
                [void]$lvA.Items.Add($it)
            }
        } finally { $st.Loading = $false }
    }
    $renderAudio = {
        if ($st.Closing) { return }
        $st.Loading = $true
        try {
            for ($i = 0; $i -lt $lvA.Items.Count -and $i -lt @($st.Audio).Count; $i++) {
                $r  = @($st.Audio)[$i]
                $it = $lvA.Items[$i]
                $it.SubItems[1].Text = "$($r.Lang)"
                $it.SubItems[2].Text = "$($r.Channels)"
                $it.SubItems[3].Text = "$($r.Codec)"
                $it.SubItems[4].Text = $(if ($r.Default) { 'si' } else { '' })
                $it.SubItems[5].Text = (Format-CvNumber $r.Sync)
                if ($it.Checked -ne [bool]$r.Keep) { $it.Checked = [bool]$r.Keep }
            }
        } finally { $st.Loading = $false }
    }
    $buildSubs = {
        $st.Loading = $true
        try {
            $lvS.Items.Clear()
            foreach ($r in @($st.Subs)) {
                $it = New-Object System.Windows.Forms.ListViewItem("$($r.Text)")
                [void]$it.SubItems.Add("$($r.Lang)")
                [void]$it.SubItems.Add($(if ($r.Cues -ge 0) { "$($r.Cues)" } else { '?' }))
                [void]$it.SubItems.Add($(if ($r.Forced)  { 'si' } else { '' }))
                [void]$it.SubItems.Add($(if ($r.Default) { 'si' } else { '' }))
                $it.Checked = [bool]$r.Keep
                [void]$lvS.Items.Add($it)
            }
        } finally { $st.Loading = $false }
    }
    $renderSubs = {
        if ($st.Closing) { return }
        $st.Loading = $true
        try {
            for ($i = 0; $i -lt $lvS.Items.Count -and $i -lt @($st.Subs).Count; $i++) {
                $r  = @($st.Subs)[$i]
                $it = $lvS.Items[$i]
                $it.SubItems[1].Text = "$($r.Lang)"
                $it.SubItems[2].Text = $(if ($r.Cues -ge 0) { "$($r.Cues)" } else { '?' })
                $it.SubItems[3].Text = $(if ($r.Forced)  { 'si' } else { '' })
                $it.SubItems[4].Text = $(if ($r.Default) { 'si' } else { '' })
                if ($it.Checked -ne [bool]$r.Keep) { $it.Checked = [bool]$r.Keep }
            }
        } finally { $st.Loading = $false }
    }

    $curA = { if ($lvA.SelectedIndices.Count -eq 0) { return $null }; $i = $lvA.SelectedIndices[0]; if ($i -lt 0 -or $i -ge @($st.Audio).Count) { return $null }; return @($st.Audio)[$i] }
    $curS = { if ($lvS.SelectedIndices.Count -eq 0) { return $null }; $i = $lvS.SelectedIndices[0]; if ($i -lt 0 -or $i -ge @($st.Subs).Count)  { return $null }; return @($st.Subs)[$i] }

    # Deja en el pie lo que dice la validacion. Nunca modal: un dialogo aqui dejaria la bateria de
    # tests colgada esperando un clic (misma regla que en gui-tests.ps1).
    $validate = {
        if (-not $st.Ready) { return }
        $d = ConvertTo-CvJobDraftFromRows -Draft $st.Draft -AudioRows $st.Audio -SubRows $st.Subs
        $v = Test-CvJobDraft -Draft $d
        if (@($v.Errors).Count -gt 0) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblMsg.Text = ('ERROR: ' + (@($v.Errors) -join '; '))
        } elseif (@($v.Warnings).Count -gt 0) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
            $lblMsg.Text = ('Aviso: ' + (@($v.Warnings) -join '; '))
        } else {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Ok
            $lblMsg.Text = ("Listo para guardar ({0} pista(s) de audio, {1} subtitulo(s))." -f @($d.Audio).Count, @($d.Subtitles).Count)
        }
        $btnSave.Enabled = [bool]$v.Ok
    }

    $syncVideoControls = {
        $st.Loading = $true
        try {
            $txtCrop.Text    = "$($st.Draft.Crop)"
            $txtResize.Text  = "$($st.Draft.Resize)"
            $chkAnim.Checked = [bool]$st.Draft.Anim
            $chkCopy.Checked = [bool]$st.Draft.VideoSkip
            $chkKeep.Checked = [bool]$st.Draft.KeepOriginal
            # Con el video en copy no hay nada que recodificar, asi que no hay nada que comparar.
            $chkKeep.Enabled = (-not [bool]$st.Draft.VideoSkip)
            $vo = @($st.VidOpts)
            $i = 0
            for ($k = 0; $k -lt $vo.Count; $k++) { if ([int]$vo[$k].Index -eq [int]$st.Draft.VideoIndex) { $i = $k } }
            if ($cmbVid.Items.Count -gt 0) { $cmbVid.SelectedIndex = $i }
            $v = if ($vo.Count -gt 0) { $vo[$i] } else { $null }
            $lblVInfo.Text = if ($v -and $v.Anamorphic) { 'anamorfico' } else { '' }
            # En copy la pista se copia tal cual: no hay recorte, ni escalado, ni tune de animacion.
            $canEdit = -not [bool]$st.Draft.VideoSkip
            $txtCrop.Enabled   = $canEdit
            $txtResize.Enabled = $canEdit
            $chkAnim.Enabled   = $canEdit
            $btnCrop.Enabled   = $canEdit
        } finally { $st.Loading = $false }
    }

    # ---- Manejadores ----
    $cmbProf.Add_SelectedIndexChanged({
        if ($st.Loading -or $st.Closing) { return }
        $po = @($st.ProfOpts)
        $i = $cmbProf.SelectedIndex
        if ($i -lt 0 -or $i -ge $po.Count) { return }
        # Cambiar de perfil rehace lo que DEPENDE del perfil (copy de video/audio, escalado, animacion)
        # sin tirar lo que se haya marcado a mano en las tablas.
        $p = $po[$i].Prof
        $nd = New-CvJobDraft -Context $Context -Prof $p -Info $st.Info -File $File
        $st.Draft.Prof      = $p
        $st.Draft.VideoSkip = $nd.VideoSkip
        $st.Draft.AudioSkip = $nd.AudioSkip
        $st.Draft.Resize    = $nd.Resize
        $st.Draft.Anim      = $nd.Anim
        # El recorte tambien depende del perfil (AUTO-BORDE): se aplica al cambiarlo. El escaneo solo
        # se hace la primera vez -no depende del perfil-, asi que cambiar de perfil no vuelve a leer
        # el video salvo que se pase de pre-escaneo a escaneo completo.
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { & $autoCrop $p } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        & $syncVideoControls
        & $validate
        if ("$($st.CropNote)" -ne '') {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
            $lblMsg.Text = "$($st.CropNote)"
        }
    })
    # Ajustar el perfil de ESTE job: se parte del que tenga y se cambia lo que haga falta. El perfil
    # resultante no suele estar en el catalogo, asi que entra en el desplegable como entrada propia.
    $btnTuneProf.Add_Click({
        if (-not $st.Ready) { return }
        $tuned = Show-CvProfileEditorWindow -Context $Context -Prof $st.Draft.Prof
        if ($null -eq $tuned) { return }
        $nd = New-CvJobDraft -Context $Context -Prof $tuned -Info $st.Info -File $File
        $st.Draft.Prof      = $tuned
        $st.Draft.VideoSkip = $nd.VideoSkip
        $st.Draft.AudioSkip = $nd.AudioSkip
        $st.Draft.Resize    = $nd.Resize
        $st.Draft.Anim      = $nd.Anim
        $lblTuned = Format-CvProfileLabel -Prof $tuned
        $own = [pscustomobject]@{
            Key    = 'job'
            Text   = ("(el de este job) {0}" -f $lblTuned)
            Group  = 'job'
            Prof   = $tuned
            IsAuto = $false
        }
        # Fuera la entrada 'job' anterior (si la habia) y dentro la nueva, seleccionada.
        $st.ProfOpts = @(@($own) + @(@($st.ProfOpts) | Where-Object { $_.Group -ne 'job' }))
        $st.Loading = $true
        try {
            $cmbProf.Items.Clear()
            foreach ($q in @($st.ProfOpts)) {
                $tag = if ($q.Group -eq 'config.json') { '[config] ' } else { '' }
                [void]$cmbProf.Items.Add(("{0}{1}" -f $tag, $q.Text))
            }
            $cmbProf.SelectedIndex = 0
        } finally { $st.Loading = $false }
        # Si el perfil ajustado pide bordes, se aplican igual que al cambiarlo en el desplegable.
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { & $autoCrop $tuned } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        & $syncVideoControls
        & $validate
        if ("$($st.CropNote)" -ne '') {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
            $lblMsg.Text = "$($st.CropNote)"
        }
    })
    $cmbVid.Add_SelectedIndexChanged({
        if ($st.Loading -or $st.Closing) { return }
        $vo = @($st.VidOpts)
        $i = $cmbVid.SelectedIndex
        if ($i -ge 0 -and $i -lt $vo.Count) { $st.Draft.VideoIndex = [int]$vo[$i].Index }
        & $validate
    })
    $chkCopy.Add_CheckedChanged({
        if ($st.Loading -or $st.Closing) { return }
        $st.Draft.VideoSkip = $chkCopy.Checked
        & $syncVideoControls
        & $validate
    })
    $chkAnim.Add_CheckedChanged({ if (-not ($st.Loading -or $st.Closing)) { $st.Draft.Anim = $chkAnim.Checked } })
    $chkKeep.Add_CheckedChanged({ if (-not ($st.Loading -or $st.Closing)) { $st.Draft.KeepOriginal = $chkKeep.Checked } })
    $txtCrop.Add_TextChanged({   if (-not ($st.Loading -or $st.Closing)) { $st.Draft.Crop = $txtCrop.Text.Trim(); & $validate } })
    $txtResize.Add_TextChanged({ if (-not ($st.Loading -or $st.Closing)) { $st.Draft.Resize = $txtResize.Text.Trim() } })

    $btnCrop.Add_Click({
        # Escaneo REAL de bordes (varios ffmpeg): se avisa arriba y se bloquea la ventana con el
        # cursor de espera, en vez de fingir que sigue viva.
        $lblHead.Text = 'Detectando bordes negros (varios puntos del video)...'
        $bar.Visible  = $true
        $form.Cursor  = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $c = Get-CvJobCropCandidates -Context $Context -Info $st.Info -Index ([int]$st.Draft.VideoIndex)
            if (@($c.Groups).Count -eq 0) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = 'No se han detectado bordes negros en el tramo analizado.'
            } else {
                $st.Draft.Crop = "$($c.Top)"
                $txtCrop.Text  = "$($c.Top)"
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
                $lblMsg.Text = ("Recorte {0} ({1}% de los puntos, margen +{2}){3}. Candidatos: {4}" -f `
                    $c.Top, $c.TopPct, $c.Margin, $(if ($c.Reliable) { '' } else { ' - SIN mayoria fiable, revisalo' }), `
                    ((@($c.Groups) | ForEach-Object { "{0} ({1})" -f $_.Crop, $_.Count }) -join ' / '))
            }
        } catch {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblMsg.Text = ("No se pudo analizar: {0}" -f $_.Exception.Message)
        } finally {
            $form.Enabled = $true
            $form.Cursor  = [System.Windows.Forms.Cursors]::Default
            $bar.Visible  = $false
            $lblHead.Text = ("Preparando {0}" -f $Name)
        }
    })
    $btnPrev.Add_Click({
        $vo = @($st.VidOpts)
        $pos = 0
        for ($k = 0; $k -lt $vo.Count; $k++) { if ([int]$vo[$k].Index -eq [int]$st.Draft.VideoIndex) { $pos = [int]$vo[$k].Pos } }
        $form.Enabled = $false
        try { Show-Preview -Context $Context -File $File -Crop "$($st.Draft.Crop)" -VideoPos $pos -Duration (Get-MediaDuration $st.Info) }
        catch { $lblMsg.Text = ("No se pudo reproducir: {0}" -f $_.Exception.Message) }
        finally { $form.Enabled = $true }
    })

    $lvA.Add_ItemChecked({
        if ($st.Loading -or $st.Closing) { return }
        $i = $_.Item.Index
        if ($i -lt 0 -or $i -ge @($st.Audio).Count) { return }
        @($st.Audio)[$i].Keep = [bool]$_.Item.Checked
        # Sin predeterminada no hay job valido: al marcar la primera, se marca sola.
        $keep = @(@($st.Audio) | Where-Object { $_.Keep })
        if ($keep.Count -gt 0 -and @($keep | Where-Object { $_.Default }).Count -eq 0) { $keep[0].Default = $true }
        foreach ($r in @($st.Audio)) { if (-not $r.Keep) { $r.Default = $false } }
        & $renderAudio
        & $validate
    })
    $lvA.Add_SelectedIndexChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curA
        if ($null -eq $r) { return }
        $st.Loading = $true
        try { $txtLang.Text = "$($r.Lang)"; $txtSync.Text = (Format-CvNumber $r.Sync) } finally { $st.Loading = $false }
    })
    # Los campos de texto actualizan el MODELO al teclear (asi lo que se guarda esta siempre al dia,
    # sin depender de salir del campo) y la lista se repinta al SALIR, para no reconstruirla en cada tecla.
    $txtLang.Add_TextChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curA
        if ($null -eq $r) { return }
        $r.Lang = $txtLang.Text.Trim().ToLower()
        & $validate
    })
    $txtLang.Add_Leave({ if (-not ($st.Loading -or $st.Closing)) { & $renderAudio } })
    $txtSync.Add_TextChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curA
        if ($null -eq $r) { return }
        # Decimal independiente del locale: se admite coma (lo natural al teclear en es-ES) y se
        # guarda como numero; al job llega ya numerico, no como texto con coma.
        $v = ConvertTo-InvDouble (($txtSync.Text.Trim()) -replace ',', '.')
        if ($null -ne $v) { $r.Sync = [double]$v }
    })
    $txtSync.Add_Leave({ if (-not ($st.Loading -or $st.Closing)) { & $renderAudio } })
    $btnDef.Add_Click({
        $r = & $curA
        if ($null -eq $r) { return }
        foreach ($x in @($st.Audio)) { $x.Default = $false }
        $r.Default = $true
        $r.Keep    = $true
        & $renderAudio
        & $validate
    })
    $btnPlay.Add_Click({
        $r = & $curA
        if ($null -eq $r) { return }
        $form.Enabled = $false
        try { Show-AudioPreview -Context $Context -File $File -AudioPos ([int]$r.Pos) -Label ("AUDIO [{0}] {1}" -f $r.Index, $r.Lang) -Duration (Get-MediaDuration $st.Info) }
        catch { $lblMsg.Text = ("No se pudo reproducir: {0}" -f $_.Exception.Message) }
        finally { $form.Enabled = $true }
    })

    $lvS.Add_ItemChecked({
        if ($st.Loading -or $st.Closing) { return }
        $i = $_.Item.Index
        if ($i -lt 0 -or $i -ge @($st.Subs).Count) { return }
        $r = @($st.Subs)[$i]
        # Un subtitulo que no se puede leer (codec ilegible) no se puede conservar: se desmarca solo.
        if ($_.Item.Checked -and -not $r.Usable) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
            $lblMsg.Text = ("La pista {0} tiene un codec que no se puede copiar ni convertir; no se conserva." -f $r.Index)
            $r.Keep = $false
            & $renderSubs
            return
        }
        $r.Keep = [bool]$_.Item.Checked
        if ($r.Keep -and $r.Empty) {
            # Se deja marcar (con dropEmpty=false es lo normal), pero avisando: una pista sin un solo
            # cue no ensena nada y ademas congela la barra de progreso de ffmpeg.
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
            $lblMsg.Text = ("La pista {0} esta VACIA (0 cues): no se vera nada y puede dejar la barra de progreso clavada en 0%." -f $r.Index)
            return
        }
        & $validate
    })
    $lvS.Add_SelectedIndexChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curS
        if ($null -eq $r) { return }
        $st.Loading = $true
        try {
            $chkForced.Checked = [bool]$r.Forced
            $chkSubDef.Checked = [bool]$r.Default
            $txtSubLang.Text   = "$($r.Lang)"
            # Las pistas de IMAGEN (PGS, VobSub) no tienen texto que ensenar -son mapas de bits-, pero
            # SI se pueden SACAR a su formato (.sup / .idx) y abrir con el programa asociado, que es
            # quien las lee (y hace OCR). El boton lo dice: 'Ver texto' o 'Extraer y abrir'.
            $btnSubView.Text    = $(if ($r.IsText) { 'Ver texto' } else { 'Extraer y abrir' })
            $btnSubView.Enabled = $true
            if (-not $r.IsText) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Muted
                $lblMsg.Text = ("La pista {0} es de imagen ({1}): no hay texto, pero se puede extraer a '{2}' y abrir con el programa asociado." -f $r.Index, $r.Codec, (Get-CvSubtitleFileExt -Codec $r.Codec -Context $Context))
            }
        } finally { $st.Loading = $false }
    })
    $chkForced.Add_CheckedChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curS
        if ($null -eq $r) { return }
        $r.Forced = $chkForced.Checked
        & $renderSubs
    })
    $chkSubDef.Add_CheckedChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curS
        if ($null -eq $r) { return }
        $r.Default = $chkSubDef.Checked
        & $renderSubs
    })
    $txtSubLang.Add_TextChanged({
        if ($st.Loading -or $st.Closing) { return }
        $r = & $curS
        if ($null -eq $r) { return }
        $r.Lang = $txtSubLang.Text.Trim().ToLower()
    })
    $txtSubLang.Add_Leave({ if (-not ($st.Loading -or $st.Closing)) { & $renderSubs } })
    $btnSubPlay.Add_Click({
        $r = & $curS
        if ($null -eq $r) { return }
        $form.Enabled = $false
        try { Show-SubtitlePreview -Context $Context -File $File -SubPos ([int]$r.Pos) -Label ("SUB [{0}] {1}" -f $r.Index, $r.Lang) -Duration (Get-MediaDuration $st.Info) }
        catch { $lblMsg.Text = ("No se pudo reproducir: {0}" -f $_.Exception.Message) }
        finally { $form.Enabled = $true }
    })
    $btnSubView.Add_Click({
        $r = & $curS
        if ($null -eq $r) { return }
        $form.Enabled = $false
        try {
            if ($r.IsText) {
                # Texto: el visor de siempre (respeta preview.subtitleEditor: ventana / asociado / exe).
                Show-SubtitleContent -Context $Context -File $File -Stream $r.Stream
                return
            }
            # Imagen: se saca el fichero y lo abre Windows con su programa. Aqui se hace paso a paso
            # -en vez de delegar en Show-SubtitleContent- para poder CONTAR que ha pasado en el pie:
            # sus avisos van al log, que con la ventana no se ve.
            $lblHead.Text = ("Extrayendo la pista {0}..." -f $r.Index)
            [System.Windows.Forms.Application]::DoEvents()
            $path = Export-CvSubtitleFile -Context $Context -File $File -Stream $r.Stream
            if ($path -eq '') {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = ("No se ha podido extraer la pista {0} ({1}). Prueba 'Reproducir con este' para verla." -f $r.Index, $r.Codec)
            } elseif (-not (Open-CvFileDefault -Path $path)) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = ("Windows no tiene programa asociado a '{0}'. El fichero esta en: {1}" -f [System.IO.Path]::GetExtension($path), $path)
            } else {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
                $lblMsg.Text = ("Abierto {0} con el programa asociado de Windows." -f [System.IO.Path]::GetFileName($path))
            }
        }
        catch { $lblMsg.Text = ("No se pudo abrir el subtitulo: {0}" -f $_.Exception.Message) }
        finally {
            $form.Enabled = $true
            $lblHead.Text = ("Preparando {0}" -f $Name)
        }
    })

    $btnSave.Add_Click({
        $d = ConvertTo-CvJobDraftFromRows -Draft $st.Draft -AudioRows $st.Audio -SubRows $st.Subs
        $v = Test-CvJobDraft -Draft $d
        if (-not $v.Ok) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblMsg.Text = ('ERROR: ' + (@($v.Errors) -join '; '))
            return
        }
        $lblHead.Text = 'Guardando el job...'
        [System.Windows.Forms.Application]::DoEvents()
        [void](Save-CvJobDraft -Context $Context -Draft $d -Info $st.Info)
        $st.Saved = $true
        $form.Close()
    })
    $btnCancel.Add_Click({ $form.Close() })

    # ---------- Analisis (con la ventana YA abierta) ----------
    $say = {
        param([string]$Text)
        $lblHead.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
    # BORDES SEGUN EL PERFIL, lo mismo que hace la consola al preparar (Invoke-VideoAsk) y el
    # recorrido de 'Preparar pendientes' (Get-CvJobAutoPlan). Sin esto, abrir el job de UNO EN UNO con
    # un perfil AUTO-BORDE dejaba el recorte VACIO: la deteccion solo corria en el recorrido, y aqui
    # habia que acordarse de pulsar 'Detectar bordes' a mano.
    #   - 'auto'  -> pre-escaneo rapido y decide Resolve-CvCropAutoDecision (la misma funcion que la
    #                consola); si sale ambiguo se PROPONE el mas votado y se dice que se revise.
    #   - 'true'  -> escaneo completo y se propone el mas votado (la consola tambien lo confirma).
    #   - prefijo '_' en el nombre -> fuerza la deteccion, como en consola.
    # El escaneo no depende del perfil, asi que se guarda y cambiar de perfil no vuelve a escanear.
    $autoCrop = {
        param($Prof)
        $st.CropNote = ''
        if ($null -eq $st.Draft -or $null -eq $st.Info -or [bool]$st.Draft.VideoSkip) { return }
        $dbv   = "$($Prof.DetectBorder)".ToLower()
        $force = "$Name".StartsWith('_')
        $on    = ($dbv -eq 'true') -or $force
        $auto  = ($dbv -eq 'auto') -and -not $force
        if (-not ($on -or $auto)) { return }
        $kind = if ($auto) { 'auto' } else { 'full' }
        try {
            if ($null -eq $st.CropScan -or $st.CropKind -ne $kind) {
                & $say $(if ($auto) { 'Comprobando si hay barras negras (pre-escaneo)...' } else { 'Detectando bordes negros (varios puntos)...' })
                $st.CropScan = $(if ($auto) {
                    Get-CvJobCropCandidates -Context $Context -Info $st.Info -Index ([int]$st.Draft.VideoIndex) `
                        -Duration ([int]$Context.BorderAutoDuration) -Samples ([int]$Context.BorderAutoSamples)
                } else {
                    Get-CvJobCropCandidates -Context $Context -Info $st.Info -Index ([int]$st.Draft.VideoIndex)
                })
                $st.CropKind = $kind
            }
            $c  = $st.CropScan
            $vs = @(Get-VideoStreams -Info $st.Info | Where-Object { [int]$_.index -eq [int]$st.Draft.VideoIndex })
            $vw = if ($vs.Count -gt 0) { [int]$vs[0].width }  else { 0 }
            $vh = if ($vs.Count -gt 0) { [int]$vs[0].height } else { 0 }
            if ($auto) {
                $dec = Resolve-CvCropAutoDecision -Groups @($c.Groups) -Width $vw -Height $vh `
                    -MinCropPct ([double]$Context.BorderMinCropPct) -MaxCropPct ([int]$Context.BorderAutoMaxCropPct)
                switch ("$($dec.Decision)") {
                    'crop'   { $st.Draft.Crop = "$($dec.Crop)"; $st.CropNote = "$($dec.Reason)" }
                    'manual' { $st.Draft.Crop = "$($dec.Crop)"; $st.CropNote = ("{0}. Se propone el mas votado: revisalo con 'Ver recorte'." -f $dec.Reason) }
                    default  { $st.Draft.Crop = ''; $st.CropNote = "$($dec.Reason)" }
                }
            } elseif (@($c.Groups).Count -gt 0) {
                $st.Draft.Crop = "$($c.Top)"
                $st.CropNote = ("Recorte propuesto {0} ({1}% de los puntos){2}. Revisalo con 'Ver recorte'." -f `
                    $c.Top, $c.TopPct, $(if ($c.Reliable) { '' } else { ' - SIN mayoria fiable' }))
            } else {
                $st.Draft.Crop = ''
                $st.CropNote = 'No se han detectado bordes negros en el tramo analizado.'
            }
        } catch {
            $st.CropNote = ("No se pudieron detectar los bordes: {0}" -f $_.Exception.Message)
        }
    }

    $analyze = {
        try {
            if ($null -eq $st.Info) {
                & $say ("Leyendo {0} (ffprobe)..." -f $Name)
                $st.Info = Get-MediaInfo -Context $Context -File $File
            }
            if ($null -eq $st.Info) {
                $lblHead.Text = 'No se pudo leer el archivo (ffprobe).'
                $bar.Visible  = $false
                return
            }
            & $say 'Perfiles disponibles...'
            $st.ProfOpts = @(Get-CvJobProfileOptions -Context $Context)
            & $say 'Pistas de video...'
            $st.VidOpts  = @(Get-CvJobVideoOptions -Context $Context -Info $st.Info)
            & $say 'Pistas de audio...'
            $audOpts     = @(Get-CvJobAudioOptions -Context $Context -Info $st.Info)
            # Este es el paso que puede tardar de verdad: sin el tag NUMBER_OF_FRAMES, contar los cues
            # demultiplexa el fichero entero por cada pista. Por eso se avisa de que puede tardar.
            & $say 'Subtitulos (contando cues; en ficheros grandes puede tardar)...'
            $subOpts     = @(Get-CvJobSubtitleOptions -Context $Context -Info $st.Info)

            if ($null -eq $st.Draft) {
                & $say 'Preparando la propuesta...'
                if (Test-CvJob -Context $Context -Name $Name) {
                    $st.Draft = Read-CvJobDraft -Context $Context -Name $Name
                } else {
                    $base = $st.BaseProf
                    if ($null -eq $base) {
                        $auto = @($st.ProfOpts | Where-Object { $_.IsAuto })
                        $base = if ($auto.Count -gt 0) { $auto[0].Prof } else { $st.ProfOpts[0].Prof }
                    }
                    $st.Draft = New-CvJobDraft -Context $Context -Prof $base -Info $st.Info -File $File
                    # Job NUEVO: si el perfil pide bordes, se detectan AHORA (con la barra en marcha),
                    # no se deja el recorte vacio. Un job que YA existe trae su recorte congelado y no
                    # se toca: eso se decidio al prepararlo.
                    & $autoCrop $st.Draft.Prof
                    # Y la sincronia del audio, igual que en consola (se aplica y se cuenta abajo).
                    $st.SyncNotes = @(Set-CvJobDraftAudioSync -Context $Context -Draft $st.Draft -Info $st.Info -OnStep $say)
                }
            }
            $st.Audio = @(Get-CvJobAudioRows -Options $audOpts -Tracks $st.Draft.Audio)
            $st.Subs  = @(Get-CvJobSubRows  -Options $subOpts -Selected $st.Draft.Subtitles)

            # El perfil del job puede NO estar en el catalogo: 'Auto' se guarda YA RESUELTO al mejor
            # encoder de este equipo (p. ej. av1/M10/CRF30), y un perfil de config.json puede haberse
            # editado despues. Si no casa con ninguna entrada, se anade la SUYA -la primera- en vez de
            # caer en el indice 0: si no, el desplegable ensenaba el primero del catalogo (COPY) y
            # guardar convertia el job a copy sin querer.
            $lblProf = Format-CvProfileLabel -Prof $st.Draft.Prof
            $i = -1
            for ($k = 0; $k -lt @($st.ProfOpts).Count; $k++) {
                if ((Format-CvProfileLabel -Prof @($st.ProfOpts)[$k].Prof) -eq $lblProf) { $i = $k; break }
            }
            if ($i -lt 0) {
                $own = [pscustomobject]@{
                    Key    = 'job'
                    Text   = ("(el de este job) {0}" -f $lblProf)
                    Group  = 'job'
                    Prof   = $st.Draft.Prof
                    IsAuto = $false
                }
                $st.ProfOpts = @(@($own) + @($st.ProfOpts))
                $i = 0
            }

            # Rellenar los controles (todo bajo Loading: no son ediciones del usuario).
            $st.Loading = $true
            try {
                $cmbProf.Items.Clear()
                foreach ($p in @($st.ProfOpts)) {
                    $tag = switch ($p.Group) {
                        'config.json' { '[config] ' }
                        'job'         { '' }
                        default       { '' }
                    }
                    [void]$cmbProf.Items.Add(("{0}{1}" -f $tag, $p.Text))
                }
                if ($cmbProf.Items.Count -gt 0) { $cmbProf.SelectedIndex = $i }
                $cmbVid.Items.Clear()
                foreach ($v in @($st.VidOpts)) { [void]$cmbVid.Items.Add($v.Text) }
                if ($cmbVid.Items.Count -eq 0) { [void]$cmbVid.Items.Add('(el archivo no tiene pista de video)') }
            } finally { $st.Loading = $false }

            $cmbProf.Enabled = $true
            $btnTuneProf.Enabled = $true
            & $syncVideoControls
            & $buildAudio
            & $buildSubs
            $st.Ready = $true
            & $validate
            # Lo que se ha decidido solo -bordes y sincronia- manda sobre el 'listo para guardar' de
            # $validate: es informacion nueva que el usuario no ha pedido y tiene que ver.
            $avisos = @()
            if ("$($st.CropNote)" -ne '') { $avisos += "$($st.CropNote)" }
            foreach ($n in @($st.SyncNotes)) { if ("$n" -ne '') { $avisos += "$n" } }
            if ($avisos.Count -gt 0) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
                $lblMsg.Text = ($avisos -join '   |   ')
            }

            # Cabecera: por que se ha parado a preguntar (si venimos del recorrido) o el nombre.
            $bar.Visible = $false
            $rs = @($Reasons)
            if ($rs.Count -gt 0) {
                $lblHead.ForeColor = [System.Drawing.Color]::DarkBlue
                $lblHead.Text = ('Revisa: ' + ($rs -join '  |  '))
            } else {
                $lblHead.Text = ("Preparando {0}" -f $Name)
            }
        } catch {
            $bar.Visible = $false
            $lblHead.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblHead.Text = ("Error al analizar: {0}" -f $_.Exception.Message)
        }
    }

    # El analisis arranca con la ventana YA visible (Shown), no antes: asi no hay espera a ciegas.
    $form.Add_Shown({ & $analyze })
    $form.Add_FormClosing({ $st.Closing = $true })

    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return [bool]$st.Saved
}

function Show-CvJobBulkWindow {
    <#
        Editar EN BLOQUE los jobs de -Names: se marca lo que se quiere cambiar y eso -y solo eso- se
        escribe en todos. Lo que no se marca se queda como esta en CADA job (su pista de audio, sus
        subtitulos, su retardo, su recorte), que es justo lo que no se puede hacer abriendo los jobs
        de uno en uno.

        Solo salen los ajustes que no dependen de lo que tenga dentro cada archivo
        (Get-CvJobBulkFields); no se analiza ningun archivo, asi que es instantaneo aunque sean 40.

        Devuelve $true si se cambio algun job.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string[]]$Names = @()
    )
    if (-not (Initialize-CvGui)) { return $false }
    $names = @($Names)
    if ($names.Count -eq 0) { return $false }

    $st = @{
        Prof    = $null
        Changed = 0
    }

    # El alto sale del CATALOGO (una fila por ajuste), no de un numero a ojo: anadir un ajuste no
    # puede dejar la ultima fila fuera de la caja ni los botones fuera de la ventana.
    $altoGb = 26 + (48 * @(Get-CvJobBulkFields).Count)

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = ("Editar {0} jobs a la vez" -f $names.Count)
    $form.Name            = 'cvJobBulk'
    $form.StartPosition   = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(720, (150 + $altoGb + 96))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = 'Se cambiara SOLO lo que marques; el resto de cada job (pistas de audio, subtitulos, retardo, recorte) se queda como esta.'
    $lbl.Location = New-Object System.Drawing.Point(12, 10)
    $lbl.Size     = New-Object System.Drawing.Size(696, 34)
    $form.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location       = New-Object System.Drawing.Point(12, 46)
    $lst.Size           = New-Object System.Drawing.Size(696, 96)
    $lst.Font           = (New-CvGuiFont 9)
    $lst.IntegralHeight = $false
    $lst.SelectionMode  = 'None'
    $lst.Name           = 'cvBulkList'
    foreach ($n in $names) { [void]$lst.Items.Add($n) }
    $form.Controls.Add($lst)

    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text     = ' Cambiar '
    $gb.Location = New-Object System.Drawing.Point(12, 150)
    $gb.Size     = New-Object System.Drawing.Size(696, $altoGb)
    $form.Controls.Add($gb)

    # Una fila por ajuste: [x] que cambiar + con que. El catalogo manda (Get-CvJobBulkFields), asi
    # que anadir un ajuste es anadirlo alli.
    $campos = @(Get-CvJobBulkFields)
    $ctrl = @{}     # clave -> @{ Chk; Val }
    $y = 26
    foreach ($f in $campos) {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text     = "$($f.Text)"
        $chk.Location = New-Object System.Drawing.Point(12, ($y + 2))
        $chk.Size     = New-Object System.Drawing.Size(205, 22)
        $chk.Name     = ("cvBulkChk_{0}" -f $f.Key)
        $gb.Controls.Add($chk)

        $val = $null
        switch ("$($f.Kind)") {
            'profile' {
                $val = New-Object System.Windows.Forms.TextBox
                $val.ReadOnly = $true
                $val.Text     = '(sin elegir)'
                $val.Location = New-Object System.Drawing.Point(218, $y)
                $val.Size     = New-Object System.Drawing.Size(350, 24)
                $val.Font     = (New-CvGuiFont 9)
                $val.Name     = ("cvBulkVal_{0}" -f $f.Key)
                $gb.Controls.Add($val)

                $btn = New-Object System.Windows.Forms.Button
                $btn.Text     = 'Elegir...'
                $btn.Location = New-Object System.Drawing.Point(576, ($y - 1))
                $btn.Size     = New-Object System.Drawing.Size(100, 26)
                $btn.Name     = 'cvBulkProfPick'
                $btn.Add_Click({
                    $p = Show-CvJobProfileDialog -Context $Context -Info ("Perfil para los {0} jobs elegidos:" -f $names.Count)
                    if ($null -eq $p) { return }
                    $st.Prof = $p
                    $ctrl['prof'].Val.Text = (Format-CvProfileLabel -Prof $p)
                    $ctrl['prof'].Chk.Checked = $true
                }.GetNewClosure())
                $gb.Controls.Add($btn)
            }
            'bool' {
                $val = New-Object System.Windows.Forms.ComboBox
                $val.DropDownStyle = 'DropDownList'
                $val.Location = New-Object System.Drawing.Point(218, $y)
                $val.Size     = New-Object System.Drawing.Size(350, 24)
                $val.Font     = (New-CvGuiFont 9)
                $val.Name     = ("cvBulkVal_{0}" -f $f.Key)
                [void]$val.Items.Add("$($f.Off)")
                [void]$val.Items.Add("$($f.On)")
                $val.SelectedIndex = 0
                $gb.Controls.Add($val)
            }
            default {
                # El texto se queda mas corto para que la PISTA (que forma tiene el valor) quepa a su
                # derecha en una linea: cortada no dice nada.
                $val = New-Object System.Windows.Forms.TextBox
                $val.Location = New-Object System.Drawing.Point(218, $y)
                $val.Size     = New-Object System.Drawing.Size(250, 24)
                $val.Font     = (New-CvGuiFont 9)
                $val.Name     = ("cvBulkVal_{0}" -f $f.Key)
                $gb.Controls.Add($val)

                $hint = New-Object System.Windows.Forms.Label
                $hint.Text      = "$($f.Hint)"
                $hint.Location  = New-Object System.Drawing.Point(476, ($y + 5))
                $hint.Size      = New-Object System.Drawing.Size(210, 16)
                $hint.Font      = (New-CvGuiFont 8)
                $gb.Controls.Add($hint)
                [void](Set-CvGuiRole -Control $hint -Role 'Muted')
            }
        }
        $ayuda = New-Object System.Windows.Forms.Label
        $ayuda.Text     = "$($f.Help)"
        $ayuda.Location = New-Object System.Drawing.Point(218, ($y + 25))
        $ayuda.Size     = New-Object System.Drawing.Size(458, 16)
        $ayuda.Font     = (New-CvGuiFont 8)
        $ayuda.AutoEllipsis = $true
        $gb.Controls.Add($ayuda)
        [void](Set-CvGuiRole -Control $ayuda -Role 'Muted')

        $ctrl["$($f.Key)"] = @{
            Chk  = $chk
            Val  = $val
            Kind = "$($f.Kind)"
        }
        $y += 48
    }

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Location     = New-Object System.Drawing.Point(12, ($gb.Bottom + 8))
    $lblMsg.Size         = New-Object System.Drawing.Size(696, 34)
    $lblMsg.Name         = 'cvBulkMsg'
    $form.Controls.Add($lblMsg)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(488, ($gb.Bottom + 50))
    $btnCancel.Size     = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Name     = 'cvBulkCancel'
    $btnCancel.Add_Click({ $form.Close() }.GetNewClosure())
    $form.Controls.Add($btnCancel)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text     = ("Aplicar a los {0}" -f $names.Count)
    $btnApply.Location = New-Object System.Drawing.Point(596, ($gb.Bottom + 50))
    $btnApply.Size     = New-Object System.Drawing.Size(112, 30)
    $btnApply.Enabled  = $false
    $btnApply.Name     = 'cvBulkApply'
    $form.Controls.Add($btnApply)

    # Lo que se va a aplicar, leido de los controles: solo las filas MARCADAS.
    $leer = {
        $ch = @{}
        foreach ($f in $campos) {
            $c = $ctrl["$($f.Key)"]
            if (-not $c.Chk.Checked) { continue }
            switch ("$($f.Kind)") {
                'profile' { $ch['prof'] = $st.Prof }
                'bool'    { $ch["$($f.Key)"] = ([int]$c.Val.SelectedIndex -eq 1) }
                default   { $ch["$($f.Key)"] = "$($c.Val.Text)".Trim() }
            }
        }
        return $ch
    }
    # Aplicar se enciende en cuanto hay algo que aplicar, y el aviso dice por que no.
    $revisar = {
        $ch  = & $leer
        $chk = Test-CvJobBulkChanges -Changes $ch
        $btnApply.Enabled = [bool]$chk.Ok
        if ($ch.Count -eq 0) {
            $lblMsg.Text = 'Marca lo que quieras cambiar en los jobs elegidos.'
            [void](Set-CvGuiRole -Control $lblMsg -Role 'Muted')
            return
        }
        if (-not $chk.Ok) {
            $lblMsg.Text = (@($chk.Errors) -join '; ')
            [void](Set-CvGuiRole -Control $lblMsg -Role 'Error')
            return
        }
        $lblMsg.Text = ("Se cambiara en los {0}: {1}" -f $names.Count, (Get-CvJobBulkSummary -Changes $ch))
        [void](Set-CvGuiRole -Control $lblMsg -Role 'Muted')
    }
    foreach ($k in @($ctrl.Keys)) {
        $c = $ctrl[$k]
        $c.Chk.Add_CheckedChanged({ & $revisar }.GetNewClosure())
        if ($c.Kind -eq 'bool') { $c.Val.Add_SelectedIndexChanged({ & $revisar }.GetNewClosure()) }
        elseif ($c.Kind -ne 'profile') { $c.Val.Add_TextChanged({ & $revisar }.GetNewClosure()) }
    }

    $btnApply.Add_Click({
        $ch = & $leer
        $chk = Test-CvJobBulkChanges -Changes $ch
        if (-not $chk.Ok) { & $revisar; return }
        $resumen = Get-CvJobBulkSummary -Changes $ch
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $res = Set-CvJobsBulk -Context $Context -Names $names -Changes $ch
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        $st.Changed = [int]$res.Done
        Write-CvLog 'JOB' ("[BLOQUE] - {0} job(s) cambiados de {1}: {2}" -f $res.Done, $names.Count, $resumen)
        if ([int]$res.Failed -gt 0) {
            Write-CvLog 'JOB' ("[ERROR] - {0} job(s) no se pudieron cambiar: {1}" -f $res.Failed, ((@($res.Errors) | Select-Object -First 5) -join ' | '))
            Show-CvGuiInfo -Title 'Editar en bloque' -Message ("Cambiados {0} de {1}. No se pudieron cambiar {2}:{3}{4}" -f `
                $res.Done, $names.Count, $res.Failed, [Environment]::NewLine, ((@($res.Errors) | Select-Object -First 5) -join [Environment]::NewLine))
        }
        $form.Close()
    }.GetNewClosure())

    & $revisar
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return ([int]$st.Changed -gt 0)
}

function Show-CvPrepareWindow {
    <#
        PREPARAR PENDIENTES, como en consola: se elige el PERFIL una vez y se recorren los archivos
        haciendo el autodiscover. Lo que se resuelve solo se guarda solo; donde la consola
        preguntaria, se abre el editor ya relleno con el motivo escrito.

        -Files: @({ Name; Path }) de los archivos a preparar (los 'sin preparar' de la cola).
        Devuelve cuantos jobs han quedado escritos.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Files
    )
    if (-not (Initialize-CvGui)) { return 0 }
    $items = @($Files)
    if ($items.Count -eq 0) { return 0 }

    # Igual que al lanzar workers: sin ffmpeg/ffprobe no se puede analizar nada, y es mejor decirlo
    # una vez al principio que dejar una fila con una excepcion cruda por cada archivo.
    $ready = Test-CvConvertReady -Context $Context
    if (-not $ready.Ok) {
        Show-CvGuiInfo -Title 'Faltan herramientas' -Message ("No se puede preparar: {0}" -f $ready.Reason)
        return 0
    }

    # 1) El perfil, UNA vez para todo el lote (igual que al empezar PREPARAR en consola).
    $prof = Show-CvJobProfileDialog -Context $Context -Info ("Perfil con el que preparar los {0} archivo(s) pendientes:" -f $items.Count)
    if ($null -eq $prof) { return 0 }

    $st = @{
        Index   = 0
        Done    = 0
        Manual  = 0
        Skipped = 0
        Failed  = 0
        Cancel  = $false
        Running = $true
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Preparar pendientes'
    $form.StartPosition = 'CenterScreen'
    $form.Size          = New-Object System.Drawing.Size(900, 520)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 400)

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 4
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    $form.Controls.Add($grid)

    $lblProf = New-Object System.Windows.Forms.Label
    $lblProf.Dock      = 'Fill'
    $lblProf.TextAlign = 'MiddleLeft'
    $lblProf.Text      = ("Perfil: {0}" -f (Format-CvProfileLabel -Prof $prof))
    $lblProf.Name      = 'cvPrepProfile'
    $grid.Controls.Add($lblProf, 0, 0)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.Font          = (New-CvGuiFont 9)
    $lv.Name          = 'cvPrepList'
    [void]$lv.Columns.Add('Archivo', 360)
    [void]$lv.Columns.Add('Estado', 130)
    # Bordes: en que archivos ha entrado el recorte y con que tamano quedan, sin tener que abrir nada.
    [void]$lv.Columns.Add('Bordes / tamano', 150)
    [void]$lv.Columns.Add('Detalle', 300)
    [void](Set-CvGuiDoubleBuffered -Control $lv)
    foreach ($f in $items) {
        $it = New-Object System.Windows.Forms.ListViewItem("$($f.Name)")
        [void]$it.SubItems.Add('pendiente')
        [void]$it.SubItems.Add('')
        [void]$it.SubItems.Add('')
        [void]$lv.Items.Add($it)
    }
    $grid.Controls.Add($lv, 0, 1)

    $lblSt = New-Object System.Windows.Forms.Label
    $lblSt.Dock      = 'Fill'
    $lblSt.TextAlign = 'MiddleLeft'
    $lblSt.Name      = 'cvPrepStatus'
    $grid.Controls.Add($lblSt, 0, 2)

    $foot = New-Object System.Windows.Forms.TableLayoutPanel
    $foot.Dock        = 'Fill'
    $foot.ColumnCount = 2
    $foot.RowCount    = 1
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$foot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    $grid.Controls.Add($foot, 0, 3)

    # Barra pintada, por lo mismo que la del editor: la del sistema no se puede oscurecer.
    $prog = New-CvGuiProgressPanel -Name 'cvPrepProgress'
    $prog.Dock   = 'Fill'
    $prog.Margin = New-Object System.Windows.Forms.Padding(3, 8, 12, 8)
    $foot.Controls.Add($prog, 0, 0)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text   = 'Cancelar'
    $btnClose.Height = 30
    $btnClose.Dock   = 'Fill'
    $btnClose.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 7)
    $btnClose.Name   = 'cvPrepClose'
    $foot.Controls.Add($btnClose, 1, 0)

    $setRow = {
        param([int]$i, [string]$Estado, [string]$Detalle, [string]$Bordes = $null)
        if ($i -lt 0 -or $i -ge $lv.Items.Count) { return }
        $lv.Items[$i].SubItems[1].Text = $Estado
        # $null = no se toca (el estado cambia varias veces por archivo y los bordes solo una).
        if ($null -ne $Bordes) { $lv.Items[$i].SubItems[2].Text = $Bordes }
        $lv.Items[$i].SubItems[3].Text = $Detalle
        $lv.Items[$i].EnsureVisible()
    }
    # Que poner en la columna de bordes de un archivo ya analizado (texto puro: Format-CvJobBorderCell).
    $borderCell = {
        param($Draft, $Info)
        if ($null -eq $Draft -or $null -eq $Info) { return '' }
        if ([bool]$Draft.VideoSkip) { return '' }   # en copy no se toca la imagen
        $vs = @(Get-VideoStreams -Info $Info | Where-Object { [int]$_.index -eq [int]$Draft.VideoIndex })
        if ($vs.Count -eq 0) { return '' }
        $dbv = "$($Draft.Prof.DetectBorder)".ToLower()
        Format-CvJobBorderCell -Crop "$($Draft.Crop)" -Resize "$($Draft.Resize)" `
            -Width ([int]$vs[0].width) -Height ([int]$vs[0].height) `
            -Detect ($dbv -eq 'auto' -or $dbv -eq 'true')
    }
    $say = {
        param([string]$Text)
        $lblSt.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnClose.Add_Click({
        if ($st.Running) { $st.Cancel = $true; $lblSt.Text = 'Cancelando al terminar el archivo en curso...' }
        else { $form.Close() }
    })

    # Un archivo por tick: asi la ventana se pinta y responde entre archivos, y el bucle no bloquea
    # WinForms de principio a fin. Dentro de un archivo el analisis SI bloquea (ffprobe/ffmpeg), por
    # eso cada fase escribe antes lo que va a hacer (DoEvents en $say).
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60
    $timer.Add_Tick({
        $timer.Stop()
        if ($st.Cancel -or $st.Index -ge $items.Count) {
            $st.Running = $false
            $btnClose.Text = 'Cerrar'
            [void](Set-CvGuiProgressValue -Bar $prog -Percent 100)
            $lblSt.Text = ("Hecho: {0} preparado(s) ({1} con revision), {2} omitido(s), {3} con error{4}." -f `
                $st.Done, $st.Manual, $st.Skipped, $st.Failed, $(if ($st.Cancel) { ' - cancelado' } else { '' }))
            return
        }

        $i = $st.Index
        $f = $items[$i]
        & $setRow $i 'analizando...' ''
        & $say ("[{0}/{1}] {2}: leyendo el archivo (ffprobe)..." -f ($i + 1), $items.Count, $f.Name)

        try {
            $info = Get-MediaInfo -Context $Context -File $f.Path
            if ($null -eq $info) {
                $st.Failed++
                & $setRow $i 'error' 'no se pudo leer (ffprobe)'
            } else {
                # Regla del prefijo '_': fuerza la deteccion de bordes, igual que en consola.
                $force = "$($f.Name)".StartsWith('_')
                $plan = Get-CvJobAutoPlan -Context $Context -Prof $prof -Info $info -File $f.Path -ForceBorder $force -OnStep {
                    param($t)
                    & $say ("[{0}/{1}] {2}: {3}" -f ($i + 1), $items.Count, $f.Name, $t)
                }
                if (-not $plan.Manual) {
                    [void](Save-CvJobDraft -Context $Context -Draft $plan.Draft -Info $info)
                    $st.Done++
                    # 'Notes' = lo que se ha decidido solo y conviene contar (p. ej. el retardo de
                    # audio detectado); no obliga a revisar, pero tiene que verse.
                    $det = 'automatico'
                    if (@($plan.Notes).Count -gt 0) { $det = ("automatico - {0}" -f (@($plan.Notes) -join ' | ')) }
                    & $setRow $i 'preparado' $det (& $borderCell $plan.Draft $info)
                } else {
                    & $setRow $i 'revisar...' (@($plan.Reasons) -join ' | ') (& $borderCell $plan.Draft $info)
                    & $say ("[{0}/{1}] {2}: necesita una decision" -f ($i + 1), $items.Count, $f.Name)
                    $saved = Show-CvJobWindow -Context $Context -Name $f.Name -File $f.Path -Draft $plan.Draft -Info $info -Reasons $plan.Reasons
                    if ($saved) {
                        $st.Done++; $st.Manual++
                        # Lo que se haya guardado MANDA sobre lo que proponia el borrador: en la
                        # ventana se puede cambiar el recorte, quitarlo o poner otro escalado.
                        $final = $plan.Draft
                        try { $final = Read-CvJobDraft -Context $Context -Name $f.Name } catch { }
                        & $setRow $i 'preparado' 'revisado a mano' (& $borderCell $final $info)
                    } else {
                        $st.Skipped++
                        & $setRow $i 'omitido' (@($plan.Reasons) -join ' | ')
                    }
                }
            }
        } catch {
            $st.Failed++
            & $setRow $i 'error' "$($_.Exception.Message)"
        }

        $st.Index++
        [void](Set-CvGuiProgressValue -Bar $prog -Percent $(if ($items.Count -gt 0) { [int](100 * [Math]::Min($items.Count, $st.Index) / $items.Count) } else { 0 }))
        $timer.Start()
    })

    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosing({ $timer.Stop() })
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return [int]$st.Done
}

Export-ModuleMember -Function *
