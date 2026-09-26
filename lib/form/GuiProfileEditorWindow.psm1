<#
    form\GuiProfileEditorWindow.psm1 - VENTANA de ajustar un perfil (y guardarlo como tuyo).

    Encoder, calidad, preset, escalado, audio... con los catalogos de siempre (funciones que
    devuelven @{ Value; Text }, nunca listas escritas a mano). Validar, guardar y borrar es
    lib\Profile.psm1, igual que en la consola y en la ventana de setup.
#>

function Show-CvProfileEditorWindow {
    <#
        Ajusta A MANO los valores de un perfil (el equivalente en ventana de la opcion "Custom" del
        menu de perfiles de la consola): encoder de video, profile/level, control de tasa, multipass,
        deteccion de bordes, escalado, y la salida de audio (codec, bitrate, Hz, canales, downmix).

        Dos finales, y por eso hay dos botones:
          - ACEPTAR usa el perfil en ESE job y nada mas (lo de siempre: partir de una plantilla y
            cambiarle una cosa para este lote).
          - GUARDAR COMO PERFIL lo escribe ademas en el config ('profiles') con un nombre, y desde
            ese momento sale en el menu de perfiles como uno mas, en consola y en ventana. Solo
            aparece si quien abre la ventana dice DONDE guardarlo (-CfgPath).

        Todas las listas salen de los catalogos del repo (Get-CvVideoEncoders, Get-CvCodecOptions,
        Get-CvNvencMultipass, Get-CvDetectBorderModes, Get-CvAudioEncoders, Get-CvAudioCodecs,
        Get-CvAudioChannels, Get-CvDownmixModes): aqui no se re-enumera nada.

        Devuelve el perfil resultante, o $null si se cancela.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        $Prof = $null,
        # Fichero de configuracion donde se puede GUARDAR el perfil. Vacio = no se ofrece guardar
        # (la ventana se queda como estaba: ajustar para este job y ya).
        [string]$CfgPath = '',
        # Nombre actual, cuando se edita uno YA guardado: se propone, y renombrarse a si mismo no
        # cuenta como duplicado.
        [string]$Name = '',
        # Gestor de perfiles: ahi no hay ningun job, asi que el unico final posible es GUARDAR.
        [switch]$ForSave
    )
    if (-not (Initialize-CvGui)) { return $null }
    $p = if ($Prof) { $Prof } else { New-CvProfile }

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $(if ($ForSave) {
        $(if ("$Name" -ne '') { Get-CvText -Key 'pe.tit.editar' -Values @($Name) } else { Get-CvText -Key 'pe.tit.nuevo' })
    } else { Get-CvText -Key 'pe.tit.ajustar' })
    $form.StartPosition   = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(760, $(if ($CfgPath) { 672 } else { 622 }))

    # Estado: por cada desplegable se guardan los VALORES en paralelo a los textos, para no tener que
    # volver a parsear la etiqueta (y para conservar el tipo real, p. ej. $false/$true/'auto').
    $st = @{
        Result  = $null
        Saved   = ''      # nombre con el que se guardo en el config (vacio = no se guardo)
        Loading = $false
    }

    # Desplegable de catalogo: lo monta New-CvGuiCatalogCombo (Gui.psm1), que guarda los VALORES
    # en el Tag del control -con su tipo- y anade el valor actual si no esta en el catalogo. Aqui
    # solo se coloca en la rejilla.
    $mkCombo = {
        param($Parent, [string]$Name, $Items, $Current, [string]$EmptyText = '')
        $cb = New-CvGuiCatalogCombo -Items $Items -Current $Current -EmptyText $EmptyText -Name $Name
        $cb.Dock = 'Fill'
        $Parent.Controls.Add($cb)
        return $cb
    }
    $mkText = {
        param($Parent, [string]$Name, $Value)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Dock = 'Fill'
        $tb.Font = (New-CvGuiFont 9)
        $tb.Name = $Name
        $tb.Text = $(if ($null -ne $Value) { "$Value" } else { '' })
        $Parent.Controls.Add($tb)
        return $tb
    }
    $mkRow = {
        param($Grid, [string]$Text)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $Text
        $l.Dock      = 'Fill'
        $l.TextAlign = 'MiddleLeft'
        $Grid.Controls.Add($l)
        return $l
    }
    $newGrid = {
        param($Parent, [int]$Rows)
        $g = New-Object System.Windows.Forms.TableLayoutPanel
        $g.Dock        = 'Fill'
        $g.Padding     = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
        $g.ColumnCount = 2
        $g.RowCount    = $Rows
        [void]$g.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))
        [void]$g.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        for ($i = 0; $i -lt $Rows; $i++) { [void]$g.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28))) }
        $Parent.Controls.Add($g)
        return $g
    }

    # ---------------- Video ----------------
    $gbV = New-Object System.Windows.Forms.GroupBox
    $gbV.Text     = (Get-CvText -Key 'pe.grupo.video')
    $gbV.Location = New-Object System.Drawing.Point(12, 8)
    $gbV.Size     = New-Object System.Drawing.Size(736, 296)
    $form.Controls.Add($gbV)
    $vg = & $newGrid $gbV 9

    [void](& $mkRow $vg (Get-CvText -Key 'pe.encoder'))
    $cbEnc = & $mkCombo $vg 'cvPeEncoder' (Get-CvVideoEncoders) "$($p.VideoEncoder)"
    [void](& $mkRow $vg (Get-CvText -Key 'pe.perfil'))
    $cbVProf = & $mkCombo $vg 'cvPeVProfile' (Get-CvCodecOptions -Encoder "$($p.VideoEncoder)").Profiles "$($p.VideoProfile)" (Get-CvText -Key 'comun.ninguno')
    [void](& $mkRow $vg (Get-CvText -Key 'pe.nivel'))
    $cbVLvl = & $mkCombo $vg 'cvPeVLevel' (Get-CvCodecOptions -Encoder "$($p.VideoEncoder)").Levels "$($p.VideoLevel)" (Get-CvText -Key 'comun.ninguno')
    [void](& $mkRow $vg (Get-CvText -Key 'pe.crf'))
    $tbCrf = & $mkText $vg 'cvPeCrf' $p.Crf
    [void](& $mkRow $vg (Get-CvText -Key 'pe.qmin'))
    $tbQmin = & $mkText $vg 'cvPeQmin' $p.Qmin
    [void](& $mkRow $vg (Get-CvText -Key 'pe.qmax'))
    $tbQmax = & $mkText $vg 'cvPeQmax' $p.Qmax
    [void](& $mkRow $vg (Get-CvText -Key 'pe.multipass'))
    $cbMp = & $mkCombo $vg 'cvPeMultipass' (Get-CvNvencMultipass) "$($p.Multipass)" (Get-CvText -Key 'comun.elglobalcfg')
    [void](& $mkRow $vg (Get-CvText -Key 'pe.bordes'))
    $cbBorder = & $mkCombo $vg 'cvPeBorder' (Get-CvDetectBorderModes) "$($p.DetectBorder)"
    [void](& $mkRow $vg (Get-CvText -Key 'pe.anchomax'))
    $tbMaxW = & $mkText $vg 'cvPeMaxWidth' $p.MaxWidth

    # ---------------- Escalado fijo ----------------
    $gbR = New-Object System.Windows.Forms.GroupBox
    $gbR.Text     = (Get-CvText -Key 'pe.grupo.escala')
    $gbR.Location = New-Object System.Drawing.Point(12, 310)
    $gbR.Size     = New-Object System.Drawing.Size(736, 80)
    $form.Controls.Add($gbR)
    $rg = & $newGrid $gbR 2
    [void](& $mkRow $rg (Get-CvText -Key 'pe.tamano'))
    $tbSize = & $mkText $rg 'cvPeChangeSize' $p.ChangeSize
    [void](& $mkRow $rg '')
    $chkNoUp = New-Object System.Windows.Forms.CheckBox
    $chkNoUp.Text     = (Get-CvText -Key 'pe.soloreducir')
    $chkNoUp.Dock     = 'Fill'
    $chkNoUp.Checked  = [bool]$p.NoUpscale
    $chkNoUp.Name     = 'cvPeNoUpscale'
    $rg.Controls.Add($chkNoUp)

    # ---------------- Audio ----------------
    $gbA = New-Object System.Windows.Forms.GroupBox
    $gbA.Text     = (Get-CvText -Key 'pe.grupo.audio')
    $gbA.Location = New-Object System.Drawing.Point(12, 396)
    $gbA.Size     = New-Object System.Drawing.Size(736, 170)
    $form.Controls.Add($gbA)
    $ag = & $newGrid $gbA 5

    [void](& $mkRow $ag (Get-CvText -Key 'pe.audio.salida'))
    $cbAEnc = & $mkCombo $ag 'cvPeAudioEncoder' (Get-CvAudioEncoders) "$($p.AudioEncoder)"
    [void](& $mkRow $ag (Get-CvText -Key 'pe.audio.codec'))
    $cbACodec = & $mkCombo $ag 'cvPeAudioCodec' (@(Get-CvAudioCodecs | Where-Object { "$($_.Value)" -ne 'copy' })) "$($p.AudioCodec)"
    [void](& $mkRow $ag (Get-CvText -Key 'pe.audio.bitrate'))
    $tbABr = & $mkText $ag 'cvPeAudioBitrate' $p.AudioBitrate
    [void](& $mkRow $ag (Get-CvText -Key 'pe.audio.hz'))
    $tbAHz = & $mkText $ag 'cvPeAudioHz' $p.AudioHz
    [void](& $mkRow $ag (Get-CvText -Key 'pe.audio.canales'))
    $chRow = New-Object System.Windows.Forms.TableLayoutPanel
    $chRow.Dock        = 'Fill'
    $chRow.ColumnCount = 2
    $chRow.RowCount    = 1
    [void]$chRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45)))
    [void]$chRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 55)))
    $ag.Controls.Add($chRow)
    $cbACh = & $mkCombo $chRow 'cvPeAudioChannels' (Get-CvAudioChannels) "$($p.AudioChannels)" (Get-CvText -Key 'comun.elglobal')
    $cbADm = & $mkCombo $chRow 'cvPeDownmix' (Get-CvDownmixModes) "$($p.DownmixMode)" (Get-CvText -Key 'comun.elglobal')

    # Al cambiar de encoder, perfil y nivel son OTROS (H.264 / H.265 / AV1 no comparten valores).
    $cbEnc.Add_SelectedIndexChanged({
        if ($st.Loading) { return }
        $enc = "$(Get-CvGuiComboValue -Combo $cbEnc)"
        $st.Loading = $true
        try {
            $co = Get-CvCodecOptions -Encoder $enc
            foreach ($pair in @(
                @{ Cb = $cbVProf; Items = $co.Profiles }
                @{ Cb = $cbVLvl;  Items = $co.Levels }
            )) {
                # Un combo nuevo en memoria solo para copiarle las entradas y su Tag: asi la lista y
                # los valores se rellenan por el MISMO sitio que al abrir la ventana.
                $nuevo = New-CvGuiCatalogCombo -Items $pair.Items -EmptyText (Get-CvText -Key 'comun.ninguno')
                $cb = $pair.Cb
                $cb.Items.Clear()
                foreach ($it in @($nuevo.Items)) { [void]$cb.Items.Add($it) }
                $cb.Tag = @($nuevo.Tag)
                $cb.SelectedIndex = 0
                $nuevo.Dispose()
            }
        } finally { $st.Loading = $false }
    })

    # Fila de GUARDAR (solo si se ha dicho donde): nombre + boton. Va encima de Aceptar/Cancelar,
    # en el orden en que se decide: primero QUE perfil es, luego que hago con el.
    $yBtn = 580
    $tbName = $null
    $btnSave = $null
    if ($CfgPath) {
        $lblName = New-Object System.Windows.Forms.Label
        $lblName.Text     = (Get-CvText -Key 'pe.nombre')
        $lblName.Location = New-Object System.Drawing.Point(14, 584)
        $lblName.Size     = New-Object System.Drawing.Size(70, 20)
        $form.Controls.Add($lblName)

        $tbName = New-Object System.Windows.Forms.TextBox
        $tbName.Location = New-Object System.Drawing.Point(84, 581)
        $tbName.Size     = New-Object System.Drawing.Size(330, 24)
        $tbName.Font     = (New-CvGuiFont 9)
        $tbName.Text     = "$Name"
        $tbName.Name     = 'cvPeName'
        $form.Controls.Add($tbName)

        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text     = (Get-CvText -Key 'pe.guardar')
        $btnSave.Size     = New-Object System.Drawing.Size(180, 30)
        $btnSave.Location = New-Object System.Drawing.Point(428, 579)
        $btnSave.Name     = 'cvPeSave'
        $form.Controls.Add($btnSave)

        $lblSave = New-Object System.Windows.Forms.Label
        $lblSave.Text      = (Get-CvText -Key 'pe.guardar.info' -Values @((Split-Path -Leaf $CfgPath)))
        $lblSave.Location  = New-Object System.Drawing.Point(14, 612)
        $lblSave.Size      = New-Object System.Drawing.Size(700, 20)
        $lblSave.ForeColor = (Get-CvGuiCurrentPalette).Muted
        $form.Controls.Add($lblSave)

        $yBtn = 630
    }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = (Get-CvText -Key 'pe.vacio')
    $lbl.Location  = New-Object System.Drawing.Point(14, ($yBtn + 2))
    $lbl.Size      = New-Object System.Drawing.Size(480, 20)
    $lbl.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $form.Controls.Add($lbl)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = (Get-CvText -Key 'comun.aceptar')
    $btnOk.Size     = New-Object System.Drawing.Size(120, 30)
    $btnOk.Location = New-Object System.Drawing.Point(502, $yBtn)
    $btnOk.Name     = 'cvPeOk'
    # En el gestor de perfiles no hay job donde usarlo: el unico final es guardarlo.
    $btnOk.Visible  = (-not $ForSave)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = (Get-CvText -Key 'comun.cancelar')
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(628, $yBtn)
    $btnCancel.Name     = 'cvPeCancel'
    $form.Controls.Add($btnCancel)

    $intOrNull = {
        param([string]$Text)
        $t = "$Text".Trim()
        if ($t -eq '') { return $null }
        $n = 0
        if ([int]::TryParse($t, [ref]$n)) { return $n }
        return $null
    }

    # El perfil se arma en UN solo sitio, porque ahora lo piden dos botones (usar aqui / guardar).
    # New-CvProfile es la FUENTE de la estructura del perfil: se arma con el, no a mano.
    $build = {
        New-CvProfile `
            -VideoEncoder "$(Get-CvGuiComboValue -Combo $cbEnc)" `
            -VideoProfile "$(Get-CvGuiComboValue -Combo $cbVProf)" `
            -VideoLevel   "$(Get-CvGuiComboValue -Combo $cbVLvl)" `
            -Qmin (& $intOrNull $tbQmin.Text) `
            -Qmax (& $intOrNull $tbQmax.Text) `
            -Crf  (& $intOrNull $tbCrf.Text) `
            -DetectBorder (Get-CvGuiComboValue -Combo $cbBorder) `
            -ChangeSize $tbSize.Text.Trim() `
            -NoUpscale ([bool]$chkNoUp.Checked) `
            -MaxWidth (& $intOrNull $tbMaxW.Text) `
            -Multipass "$(Get-CvGuiComboValue -Combo $cbMp)" `
            -AudioEncoder "$(Get-CvGuiComboValue -Combo $cbAEnc)" `
            -AudioCodec   "$(Get-CvGuiComboValue -Combo $cbACodec)" `
            -AudioBitrate $tbABr.Text.Trim() `
            -AudioHz ([int](& $intOrNull $tbAHz.Text)) `
            -AudioChannels (& $intOrNull "$(Get-CvGuiComboValue -Combo $cbACh)") `
            -DownmixMode $(if ("$(Get-CvGuiComboValue -Combo $cbADm)") { "$(Get-CvGuiComboValue -Combo $cbADm)" } else { $null }) `
            -DownmixCoeffs $p.DownmixCoeffs
    }

    $btnOk.Add_Click({
        $st.Result = & $build
        $form.Close()
    })
    if ($CfgPath) {
        $btnSave.Add_Click({
            $nm  = "$($tbName.Text)".Trim()
            $chk = Test-CvProfileName -Name $nm -Existing (Get-CvConfigProfiles -Path $CfgPath) -Allow $Name
            if (-not $chk.Ok) { Show-CvGuiInfo -Title (Get-CvText -Key 'perfiles.tit') -Message "$($chk.Error)"; return }
            $prof = & $build
            $r = Save-CvConfigProfile -Path $CfgPath -Prof $prof -Label $nm -Replace $Name
            if (-not $r.Ok) { Show-CvGuiInfo -Title (Get-CvText -Key 'perfiles.tit') -Message (Get-CvText -Key 'perfiles.guardar.no' -Values @($r.Error)); return }
            $st.Result = $prof
            $st.Saved  = "$($r.Label)"
            $form.Close()
        })
    }
    $btnCancel.Add_Click({ $form.Close() })
    # El ENTER hace lo que es el final natural de la ventana en cada caso.
    $form.AcceptButton = $(if ($ForSave -and $CfgPath) { $btnSave } else { $btnOk })
    $form.CancelButton = $btnCancel

    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Result
}

Export-ModuleMember -Function *
