<#
    form\GuiJobWindow.psm1 - VENTANA del editor de UN job: verlo, retocarlo o crearlo.

    Ensena lo que se va a congelar en Proceso\<nombre>.job.json: pista de video, recorte de bordes,
    escalado, pistas de audio con su idioma y su retardo, subtitulos y perfil. Lo que se elegiria
    solo sale de lib\JobCore.psm1, y el job se escribe por el mismo sitio que en consola
    (ConvertTo-CvJobRecord + Write-CvJob), asi que sale identico.

    ANALIZAR UN ARCHIVO ES LENTO y eso se nota: contar los cues de un subtitulo sin el tag
    NUMBER_OF_FRAMES DEMULTIPLEXA el fichero entero (por pista), y la deteccion de bordes son varios
    ffmpeg. Por eso la ventana se abre SIEMPRE primero, con una barra en marcha y el paso en curso
    escrito, y el analisis va despues (con DoEvents entre fases para que responda). Nunca al reves:
    abrir despues de analizar es lo que parecia que el programa se habia colgado.
#>

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
        Show-CvGuiInfo -Title (Get-CvText -Key 'prep.faltan.tit') -Message (Get-CvText -Key 'prep.faltan.msg' -Values @($ready.Reason))
        return $false
    }

    # Job NUEVO abierto de uno en uno: se pregunta el perfil, como la consola al empezar PREPARAR. No
    # se elige por nuestra cuenta: el perfil decide si se recodifica, con que encoder y a que tamano.
    # Cancelar aqui = no abrir nada. Si el job ya existe, su perfil manda (y se puede cambiar en el
    # desplegable); si viene -Draft, el recorrido ya pregunto el perfil una vez para todo el lote.
    $baseProf = $null
    if ($null -eq $Draft -and -not (Test-CvJob -Context $Context -Name $Name)) {
        $baseProf = Show-CvJobProfileDialog -Context $Context -Info (Get-CvText -Key 'job.perfil.info' -Values @($Name))
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
    $form.Text          = (Get-CvText -Key 'job.tit' -Values @($Name))
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
    $lblHead.Text      = (Get-CvText -Key 'job.analizando' -Values @($Name))
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
    $topBar.Controls.Add((& $mkLabel (Get-CvText -Key 'comun.perfil')))

    $cmbProf = New-Object System.Windows.Forms.ComboBox
    $cmbProf.DropDownStyle = 'DropDownList'
    $cmbProf.Width         = 620
    $cmbProf.Font          = (New-CvGuiFont 9)
    $cmbProf.Name          = 'cvJobProfile'
    $cmbProf.Enabled       = $false
    $topBar.Controls.Add($cmbProf)

    $btnTuneProf = New-Object System.Windows.Forms.Button
    $btnTuneProf.Text    = (Get-CvText -Key 'comun.ajustar')
    $btnTuneProf.Width   = 110
    $btnTuneProf.Height  = 26
    $btnTuneProf.Margin  = New-Object System.Windows.Forms.Padding(10, 2, 3, 3)
    $btnTuneProf.Enabled = $false
    $btnTuneProf.Name    = 'cvJobProfileTune'
    $topBar.Controls.Add($btnTuneProf)

    # ---------- Video ----------
    $gbV = New-Object System.Windows.Forms.GroupBox
    $gbV.Text = (Get-CvText -Key 'job.grupo.video')
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

    # Las filas no se escriben aqui: salen del CATALOGO (Get-CvJobVideoRows) y las dibuja
    # Add-CvGuiFormRows. Anadir un ajuste de video es anadir una fila alli.
    $vc        = Add-CvGuiFormRows -Grid $vGrid -Rows (Get-CvJobVideoRows)
    $cmbVid    = $vc['cvJobVideo']
    $chkCopy   = $vc['cvJobVideoCopy']
    $chkAnim   = $vc['cvJobAnim']
    $txtCrop   = $vc['cvJobCrop']
    $btnCrop   = $vc['cvJobCropDetect']
    $btnPrev   = $vc['cvJobCropPreview']
    $txtResize = $vc['cvJobResize']
    $lblVInfo  = $vc['cvJobVideoInfo']
    $chkKeep   = $vc['cvJobKeepOriginal']

    # ---------- Audio ----------
    $gbA = New-Object System.Windows.Forms.GroupBox
    $gbA.Text = (Get-CvText -Key 'job.grupo.audio')
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
    [void](Add-CvGuiListColumns -List $lvA -Columns (Get-CvJobAudioColumns))
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

    $ac      = Add-CvGuiBarItems -Bar $aBar -Items (Get-CvJobAudioBarItems)
    $txtLang = $ac['cvJobAudioLang']
    $txtSync = $ac['cvJobAudioSync']
    $btnDef  = $ac['cvJobAudioDefault']
    $btnPlay = $ac['cvJobAudioPlay']

    # ---------- Subtitulos ----------
    $gbS = New-Object System.Windows.Forms.GroupBox
    $gbS.Text = (Get-CvText -Key 'job.grupo.subs')
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
    [void](Add-CvGuiListColumns -List $lvS -Columns (Get-CvJobSubColumns))
    [void](Set-CvGuiListFillColumn -List $lvS -Index 0 -Min 240)
    [void](Set-CvGuiDoubleBuffered -Control $lvS)
    $sGrid.Controls.Add($lvS, 0, 0)

    $sBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $sBar.Dock          = 'Fill'
    $sBar.FlowDirection = 'LeftToRight'
    $sBar.WrapContents  = $false
    $sGrid.Controls.Add($sBar, 0, 1)

    $sc         = Add-CvGuiBarItems -Bar $sBar -Items (Get-CvJobSubBarItems)
    $chkForced  = $sc['cvJobSubForced']
    $chkSubDef  = $sc['cvJobSubDefault']
    $txtSubLang = $sc['cvJobSubLang']
    $btnSubView = $sc['cvJobSubView']
    $btnSubPlay = $sc['cvJobSubPlay']

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
    $btnCancel.Text   = (Get-CvText -Key 'comun.cancelar')
    $btnCancel.Width  = 110
    $btnCancel.Height = 30
    $btnCancel.Name   = 'cvJobCancel'
    $btnBar.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text    = (Get-CvText -Key 'job.btn.guardar')
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
                [void]$it.SubItems.Add($(if ($r.Default) { (Get-CvText -Key 'comun.si.corto') } else { '' }))
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
                $it.SubItems[4].Text = $(if ($r.Default) { (Get-CvText -Key 'comun.si.corto') } else { '' })
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
                [void]$it.SubItems.Add($(if ($r.Forced)  { (Get-CvText -Key 'comun.si.corto') } else { '' }))
                [void]$it.SubItems.Add($(if ($r.Default) { (Get-CvText -Key 'comun.si.corto') } else { '' }))
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
                $it.SubItems[3].Text = $(if ($r.Forced)  { (Get-CvText -Key 'comun.si.corto') } else { '' })
                $it.SubItems[4].Text = $(if ($r.Default) { (Get-CvText -Key 'comun.si.corto') } else { '' })
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
            $lblMsg.Text = (Get-CvText -Key 'job.msg.error' -Values @((@($v.Errors) -join '; ')))
        } elseif (@($v.Warnings).Count -gt 0) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
            $lblMsg.Text = (Get-CvText -Key 'job.msg.aviso' -Values @((@($v.Warnings) -join '; ')))
        } else {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Ok
            $lblMsg.Text = (Get-CvText -Key 'job.msg.listo' -Values @(@($d.Audio).Count, @($d.Subtitles).Count))
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
            $lblVInfo.Text = if ($v -and $v.Anamorphic) { (Get-CvText -Key 'job.anamorfico') } else { '' }
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
        $lblHead.Text = (Get-CvText -Key 'job.paso.bordes.pts')
        $bar.Visible  = $true
        $form.Cursor  = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $c = Get-CvJobCropCandidates -Context $Context -Info $st.Info -Index ([int]$st.Draft.VideoIndex)
            if (@($c.Groups).Count -eq 0) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = (Get-CvText -Key 'job.recorte.sinbordes')
            } else {
                $st.Draft.Crop = "$($c.Top)"
                $txtCrop.Text  = "$($c.Top)"
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
                $lblMsg.Text = (Get-CvText -Key 'job.recorte.ok' -Values @(
                    $c.Top, $c.TopPct, $c.Margin, $(if ($c.Reliable) { '' } else { (Get-CvText -Key 'job.recorte.nofiable.rev') }),
                    ((@($c.Groups) | ForEach-Object { "{0} ({1})" -f $_.Crop, $_.Count }) -join ' / ')))
            }
        } catch {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblMsg.Text = (Get-CvText -Key 'job.recorte.no' -Values @($_.Exception.Message))
        } finally {
            $form.Enabled = $true
            $form.Cursor  = [System.Windows.Forms.Cursors]::Default
            $bar.Visible  = $false
            $lblHead.Text = (Get-CvText -Key 'job.preparando' -Values @($Name))
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
        try { Show-AudioPreview -Context $Context -File $File -AudioPos ([int]$r.Pos) -Label (Get-CvText -Key 'jw.lbl.audio' -Values @($r.Index, $r.Lang)) -Duration (Get-MediaDuration $st.Info) }
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
            $lblMsg.Text = (Get-CvText -Key 'job.pista.nocopia' -Values @($r.Index))
            $r.Keep = $false
            & $renderSubs
            return
        }
        $r.Keep = [bool]$_.Item.Checked
        if ($r.Keep -and $r.Empty) {
            # Se deja marcar (con dropEmpty=false es lo normal), pero avisando: una pista sin un solo
            # cue no ensena nada y ademas congela la barra de progreso de ffmpeg.
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
            $lblMsg.Text = (Get-CvText -Key 'job.pista.vacia' -Values @($r.Index))
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
            $btnSubView.Text    = $(if ($r.IsText) { (Get-CvText -Key 'job.vertexto') } else { (Get-CvText -Key 'job.extraerabrir') })
            $btnSubView.Enabled = $true
            if (-not $r.IsText) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Muted
                $lblMsg.Text = (Get-CvText -Key 'job.pista.imagen' -Values @($r.Index, $r.Codec, (Get-CvSubtitleFileExt -Codec $r.Codec -Context $Context)))
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
        try { Show-SubtitlePreview -Context $Context -File $File -SubPos ([int]$r.Pos) -Label (Get-CvText -Key 'jw.lbl.sub' -Values @($r.Index, $r.Lang)) -Duration (Get-MediaDuration $st.Info) }
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
            $lblHead.Text = (Get-CvText -Key 'job.extrayendo' -Values @($r.Index))
            [System.Windows.Forms.Application]::DoEvents()
            $path = Export-CvSubtitleFile -Context $Context -File $File -Stream $r.Stream
            if ($path -eq '') {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = (Get-CvText -Key 'job.extraer.no' -Values @($r.Index, $r.Codec))
            } elseif (-not (Open-CvFileDefault -Path $path)) {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Warn
                $lblMsg.Text = (Get-CvText -Key 'job.abrir.no' -Values @([System.IO.Path]::GetExtension($path), $path))
            } else {
                $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Fore
                $lblMsg.Text = (Get-CvText -Key 'job.abierto' -Values @([System.IO.Path]::GetFileName($path)))
            }
        }
        catch { $lblMsg.Text = (Get-CvText -Key 'job.abrir.fallo' -Values @($_.Exception.Message)) }
        finally {
            $form.Enabled = $true
            $lblHead.Text = (Get-CvText -Key 'job.preparando' -Values @($Name))
        }
    })

    $btnSave.Add_Click({
        $d = ConvertTo-CvJobDraftFromRows -Draft $st.Draft -AudioRows $st.Audio -SubRows $st.Subs
        $v = Test-CvJobDraft -Draft $d
        if (-not $v.Ok) {
            $lblMsg.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblMsg.Text = (Get-CvText -Key 'job.msg.error' -Values @((@($v.Errors) -join '; ')))
            return
        }
        $lblHead.Text = (Get-CvText -Key 'job.guardando')
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
                & $say $(if ($auto) { (Get-CvText -Key 'job.paso.prescan') } else { (Get-CvText -Key 'job.paso.bordes') })
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
                    'manual' { $st.Draft.Crop = "$($dec.Crop)"; $st.CropNote = (Get-CvText -Key 'job.recorte.votado' -Values @($dec.Reason)) }
                    default  { $st.Draft.Crop = ''; $st.CropNote = "$($dec.Reason)" }
                }
            } elseif (@($c.Groups).Count -gt 0) {
                $st.Draft.Crop = "$($c.Top)"
                $st.CropNote = (Get-CvText -Key 'job.recorte.prop' -Values @(
                    $c.Top, $c.TopPct, $(if ($c.Reliable) { '' } else { (Get-CvText -Key 'job.recorte.nofiable') })))
            } else {
                $st.Draft.Crop = ''
                $st.CropNote = (Get-CvText -Key 'job.recorte.sinbordes')
            }
        } catch {
            $st.CropNote = (Get-CvText -Key 'job.recorte.fallo' -Values @($_.Exception.Message))
        }
    }

    $analyze = {
        try {
            if ($null -eq $st.Info) {
                & $say (Get-CvText -Key 'job.paso.leer' -Values @($Name))
                $st.Info = Get-MediaInfo -Context $Context -File $File
            }
            if ($null -eq $st.Info) {
                $lblHead.Text = (Get-CvText -Key 'job.noleido')
                $bar.Visible  = $false
                return
            }
            & $say (Get-CvText -Key 'job.paso.perfiles')
            $st.ProfOpts = @(Get-CvJobProfileOptions -Context $Context)
            & $say (Get-CvText -Key 'job.paso.video')
            $st.VidOpts  = @(Get-CvJobVideoOptions -Context $Context -Info $st.Info)
            & $say (Get-CvText -Key 'job.paso.audio')
            $audOpts     = @(Get-CvJobAudioOptions -Context $Context -Info $st.Info)
            # Este es el paso que puede tardar de verdad: sin el tag NUMBER_OF_FRAMES, contar los cues
            # demultiplexa el fichero entero por cada pista. Por eso se avisa de que puede tardar.
            & $say (Get-CvText -Key 'job.paso.subs')
            $subOpts     = @(Get-CvJobSubtitleOptions -Context $Context -Info $st.Info)

            if ($null -eq $st.Draft) {
                & $say (Get-CvText -Key 'job.paso.propuesta')
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
                if ($cmbVid.Items.Count -eq 0) { [void]$cmbVid.Items.Add((Get-CvText -Key 'job.sinvideo')) }
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
                $lblHead.Text = (Get-CvText -Key 'job.revisa' -Values @(($rs -join '  |  ')))
            } else {
                $lblHead.Text = (Get-CvText -Key 'job.preparando' -Values @($Name))
            }
        } catch {
            $bar.Visible = $false
            $lblHead.ForeColor = (Get-CvGuiCurrentPalette).Error
            $lblHead.Text = (Get-CvText -Key 'job.error.analizar' -Values @($_.Exception.Message))
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

Export-ModuleMember -Function *
