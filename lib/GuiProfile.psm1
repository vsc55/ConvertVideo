<#
    GuiProfile.psm1 - Las ventanas de PERFILES (WinForms).

    Viven aparte de GuiJob.psm1 porque las usan las DOS caras: la cola (elegir y ajustar el perfil
    con el que preparar) y el setup (gestionar los perfiles propios del config). Setup no carga el
    pipeline de jobs -no lo necesita-, asi que el editor de perfiles no puede vivir en el modulo de
    los jobs.

      Show-CvJobProfileDialog    - ELEGIR el perfil con el que preparar (y desde ahi crear/borrar).
      Show-CvProfileEditorWindow - ajustar un perfil a mano y, si se quiere, GUARDARLO en el config.
      Show-CvProfilesWindow      - los perfiles propios: crear / duplicar / editar / borrar.

    Lo que se guarda, como se valida y donde se escribe NO esta aqui: son funciones de
    lib\Profile.psm1 (ConvertTo-CvProfileConfig, Test-CvProfileName, Save-CvConfigProfile,
    Remove-CvConfigProfile), las MISMAS que usa el menu de consola. La ventana solo pregunta y ensena.
#>

function Show-CvJobProfileDialog {
    <#
        Elige el PERFIL con el que preparar, igual que el menu de perfiles de la consola y con las
        MISMAS etiquetas (Get-CvJobProfileOptions -> Format-CvProfileLabel). Se pregunta UNA vez para
        todo el lote, como hace la consola al empezar PREPARAR.

        Ademas de elegir, desde aqui se MANTIENEN los perfiles propios (los de config.json, que en la
        lista salen como [config]): 'Ajustar...' permite guardar lo ajustado con un nombre, 'Nuevo...'
        parte de cero y 'Borrar' quita el marcado. Lo guardado aparece en la lista al momento -se
        relee del fichero, no del contexto- y tambien en el menu de la consola, que lee lo mismo.

        Devuelve el perfil elegido, o $null si se cancela.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Info = ''
    )
    if (-not (Initialize-CvGui)) { return $null }
    # Los perfiles propios se releen del FICHERO (no del contexto): asi uno recien guardado aparece
    # sin reiniciar la aplicacion.
    $cfgPath = "$($Context.ConfigPath)"
    $opts = @(Get-CvJobProfileOptions -Context $Context -Profiles $(if ($cfgPath) { @(Get-CvConfigProfiles -Path $cfgPath) } else { $null }))

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Perfil de codificacion'
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(720, 460)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $(if ($Info) { $Info } else { 'Perfil con el que preparar (se aplica a todos los archivos):' })
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(696, 20)
    $form.Controls.Add($lbl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location       = New-Object System.Drawing.Point(12, 36)
    $lst.Size           = New-Object System.Drawing.Size(696, 370)
    $lst.Font           = (New-CvGuiFont 9)
    $lst.IntegralHeight = $false
    $lst.Name           = 'cvProfList'
    $form.Controls.Add($lst)

    # Rehacer la lista (al arrancar y despues de crear / editar / borrar un perfil propio). -Keep es
    # el nombre del perfil que hay que dejar marcado; sin el, el PREDETERMINADO (config
    # 'defaultProfile', que se elige en setup > Perfiles), y de fabrica ese es 'Auto'.
    $fill = {
        param([string]$Keep = '')
        $propios = @(if ($cfgPath) { @(Get-CvConfigProfiles -Path $cfgPath) } else { @() })
        $script:cvProfOpts = @(Get-CvJobProfileOptions -Context $Context -Profiles $propios)
        $opts = $script:cvProfOpts
        # Se relee del FICHERO, como los perfiles: cambiarlo en setup vale sin reiniciar.
        $defKey = Get-CvDefaultProfileKey -Default $(if ($cfgPath) { Get-CvConfigDefaultProfile -Path $cfgPath } else { '' }) -Extra $propios
        $lst.BeginUpdate()
        try {
            $lst.Items.Clear()
            foreach ($o in $opts) {
                $tag = if ($o.Group -eq 'config.json') { '[config] ' } else { '' }
                # '*' delante del predeterminado, igual que en el menu de consola.
                $pre = $(if ("$($o.Key)" -eq "$defKey") { '* ' } else { '  ' })
                [void]$lst.Items.Add(("{0}{1}{2}" -f $pre, $tag, $o.Text))
            }
        } finally { $lst.EndUpdate() }
        $sel = 0
        for ($i = 0; $i -lt $opts.Count; $i++) {
            if ("$($opts[$i].Key)" -eq "$defKey") { $sel = $i }
        }
        if ("$Keep" -ne '') {
            for ($i = 0; $i -lt $opts.Count; $i++) {
                if ("$($opts[$i].Label)" -ne '' -and "$($opts[$i].Label)" -eq "$Keep") { $sel = $i; break }
            }
        }
        if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = $sel }
    }
    & $fill

    $st = @{ Prof = $null }
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Aceptar'
    $btnOk.Size     = New-Object System.Drawing.Size(120, 30)
    $btnOk.Location = New-Object System.Drawing.Point(462, 416)
    $btnOk.Name     = 'cvProfOk'
    $btnOk.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        if ($i -ge 0 -and $i -lt $opts.Count) { $st.Prof = $opts[$i].Prof }
        $form.Close()
    })
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancelar'
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(588, 416)
    $btnCancel.Name     = 'cvProfCancel'
    $btnCancel.Add_Click({ $form.Close() })
    $form.Controls.Add($btnCancel)

    # 'Ajustar...' = la opcion Custom del menu de consola: partir del perfil marcado y cambiarle lo
    # que haga falta (bitrate, encoder, ancho maximo...). Lo que salga se usa tal cual.
    $btnTune = New-Object System.Windows.Forms.Button
    $btnTune.Text     = 'Ajustar...'
    $btnTune.Size     = New-Object System.Drawing.Size(110, 30)
    $btnTune.Location = New-Object System.Drawing.Point(12, 416)
    $btnTune.Name     = 'cvProfTune'
    $btnTune.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        $base = if ($i -ge 0 -and $i -lt $opts.Count) { $opts[$i].Prof } else { $null }
        # Con -CfgPath, el editor ofrece ademas GUARDARLO con nombre; si se guarda, tambien se usa
        # aqui (que es a lo que se habia venido).
        $tuned = Show-CvProfileEditorWindow -Context $Context -Prof $base -CfgPath $cfgPath
        if ($null -ne $tuned) { $st.Prof = $tuned; $form.Close() }
    })
    $form.Controls.Add($btnTune)

    # 'Nuevo...' = crear un perfil PROPIO desde cero y dejarlo guardado en el config. Se queda
    # marcado en la lista, pero no se cierra el dialogo: crear no es elegir.
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text     = 'Nuevo...'
    $btnNew.Size     = New-Object System.Drawing.Size(110, 30)
    $btnNew.Location = New-Object System.Drawing.Point(130, 416)
    $btnNew.Name     = 'cvProfNew'
    $btnNew.Enabled  = ($cfgPath -ne '')
    $btnNew.Add_Click({
        # Para dejar marcado el que se acaba de crear: se mira que nombre hay ahora y no antes (el
        # editor devuelve el perfil, no con que nombre se guardo).
        $antes = @(@(Get-CvConfigProfiles -Path $cfgPath) | ForEach-Object { Get-CvProfileLabel $_ })
        [void](Show-CvProfileEditorWindow -Context $Context -CfgPath $cfgPath -ForSave)
        $nuevo = @(@(Get-CvConfigProfiles -Path $cfgPath) | ForEach-Object { Get-CvProfileLabel $_ } | Where-Object { $antes -notcontains $_ })
        & $fill $(if ($nuevo.Count -gt 0) { "$($nuevo[0])" } else { '' })
    })
    $form.Controls.Add($btnNew)

    # 'Borrar' solo vale para los PROPIOS: los de serie no estan en ningun fichero que se pueda tocar.
    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text     = 'Borrar'
    $btnDel.Size     = New-Object System.Drawing.Size(110, 30)
    $btnDel.Location = New-Object System.Drawing.Point(248, 416)
    $btnDel.Name     = 'cvProfDel'
    $btnDel.Enabled  = $false
    $btnDel.Add_Click({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        if ($i -lt 0 -or $i -ge $opts.Count) { return }
        $lbl = "$($opts[$i].Label)"
        if ($lbl -eq '') { return }
        if (-not (Show-CvGuiConfirm -Title 'Perfiles' -Message ("Borrar el perfil '{0}'?" -f $lbl))) { return }
        $r = Remove-CvConfigProfile -Path $cfgPath -Label $lbl
        if (-not $r.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo borrar: {0}" -f $r.Error) }
        & $fill
    })
    $form.Controls.Add($btnDel)

    # Borrar solo se enciende sobre un perfil propio.
    $lst.Add_SelectedIndexChanged({
        $opts = @($script:cvProfOpts)
        $i = $lst.SelectedIndex
        # Solo los propios CON nombre: uno escrito a mano en el config sin 'label' no se puede
        # identificar para borrarlo.
        $btnDel.Enabled = ($cfgPath -ne '') -and ($i -ge 0) -and ($i -lt $opts.Count) -and ("$($opts[$i].Label)" -ne '')
    })

    $lst.Add_DoubleClick({ $btnOk.PerformClick() })
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $st.Prof
}

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
    $form.Text            = $(if ($ForSave) { $(if ("$Name" -ne '') { "Editar el perfil '$Name'" } else { 'Perfil nuevo' }) } else { 'Ajustar el perfil de este job' })
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
    $gbV.Text     = ' Video '
    $gbV.Location = New-Object System.Drawing.Point(12, 8)
    $gbV.Size     = New-Object System.Drawing.Size(736, 296)
    $form.Controls.Add($gbV)
    $vg = & $newGrid $gbV 9

    [void](& $mkRow $vg 'Encoder de video:')
    $cbEnc = & $mkCombo $vg 'cvPeEncoder' (Get-CvVideoEncoders) "$($p.VideoEncoder)"
    [void](& $mkRow $vg 'Perfil (-profile:v):')
    $cbVProf = & $mkCombo $vg 'cvPeVProfile' (Get-CvCodecOptions -Encoder "$($p.VideoEncoder)").Profiles "$($p.VideoProfile)" '(ninguno)'
    [void](& $mkRow $vg 'Nivel (-level:v):')
    $cbVLvl = & $mkCombo $vg 'cvPeVLevel' (Get-CvCodecOptions -Encoder "$($p.VideoEncoder)").Levels "$($p.VideoLevel)" '(ninguno)'
    [void](& $mkRow $vg 'CRF (calidad constante):')
    $tbCrf = & $mkText $vg 'cvPeCrf' $p.Crf
    [void](& $mkRow $vg 'Qmin (vacio = ninguno):')
    $tbQmin = & $mkText $vg 'cvPeQmin' $p.Qmin
    [void](& $mkRow $vg 'Qmax (vacio = ninguno):')
    $tbQmax = & $mkText $vg 'cvPeQmax' $p.Qmax
    [void](& $mkRow $vg '2-pass NVENC:')
    $cbMp = & $mkCombo $vg 'cvPeMultipass' (Get-CvNvencMultipass) "$($p.Multipass)" '(el global de config)'
    [void](& $mkRow $vg 'Deteccion de bordes:')
    $cbBorder = & $mkCombo $vg 'cvPeBorder' (Get-CvDetectBorderModes) "$($p.DetectBorder)"
    [void](& $mkRow $vg 'Ancho maximo (px, solo reduce):')
    $tbMaxW = & $mkText $vg 'cvPeMaxWidth' $p.MaxWidth

    # ---------------- Escalado fijo ----------------
    $gbR = New-Object System.Windows.Forms.GroupBox
    $gbR.Text     = ' Escalado fijo '
    $gbR.Location = New-Object System.Drawing.Point(12, 310)
    $gbR.Size     = New-Object System.Drawing.Size(736, 80)
    $form.Controls.Add($gbR)
    $rg = & $newGrid $gbR 2
    [void](& $mkRow $rg 'Tamano (ej 1920:-2):')
    $tbSize = & $mkText $rg 'cvPeChangeSize' $p.ChangeSize
    [void](& $mkRow $rg '')
    $chkNoUp = New-Object System.Windows.Forms.CheckBox
    $chkNoUp.Text     = 'Solo reducir (no ampliar videos mas pequenos)'
    $chkNoUp.Dock     = 'Fill'
    $chkNoUp.Checked  = [bool]$p.NoUpscale
    $chkNoUp.Name     = 'cvPeNoUpscale'
    $rg.Controls.Add($chkNoUp)

    # ---------------- Audio ----------------
    $gbA = New-Object System.Windows.Forms.GroupBox
    $gbA.Text     = ' Audio '
    $gbA.Location = New-Object System.Drawing.Point(12, 396)
    $gbA.Size     = New-Object System.Drawing.Size(736, 170)
    $form.Controls.Add($gbA)
    $ag = & $newGrid $gbA 5

    [void](& $mkRow $ag 'Salida de audio:')
    $cbAEnc = & $mkCombo $ag 'cvPeAudioEncoder' (Get-CvAudioEncoders) "$($p.AudioEncoder)"
    [void](& $mkRow $ag 'Codec al recodificar:')
    $cbACodec = & $mkCombo $ag 'cvPeAudioCodec' (@(Get-CvAudioCodecs | Where-Object { "$($_.Value)" -ne 'copy' })) "$($p.AudioCodec)"
    [void](& $mkRow $ag 'Bitrate (ej 192k):')
    $tbABr = & $mkText $ag 'cvPeAudioBitrate' $p.AudioBitrate
    [void](& $mkRow $ag 'Frecuencia (Hz):')
    $tbAHz = & $mkText $ag 'cvPeAudioHz' $p.AudioHz
    [void](& $mkRow $ag 'Canales / downmix:')
    $chRow = New-Object System.Windows.Forms.TableLayoutPanel
    $chRow.Dock        = 'Fill'
    $chRow.ColumnCount = 2
    $chRow.RowCount    = 1
    [void]$chRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45)))
    [void]$chRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 55)))
    $ag.Controls.Add($chRow)
    $cbACh = & $mkCombo $chRow 'cvPeAudioChannels' (Get-CvAudioChannels) "$($p.AudioChannels)" '(el global)'
    $cbADm = & $mkCombo $chRow 'cvPeDownmix' (Get-CvDownmixModes) "$($p.DownmixMode)" '(el global)'

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
                $nuevo = New-CvGuiCatalogCombo -Items $pair.Items -EmptyText '(ninguno)'
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
        $lblName.Text     = 'Nombre:'
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
        $btnSave.Text     = 'Guardar como perfil'
        $btnSave.Size     = New-Object System.Drawing.Size(180, 30)
        $btnSave.Location = New-Object System.Drawing.Point(428, 579)
        $btnSave.Name     = 'cvPeSave'
        $form.Controls.Add($btnSave)

        $lblSave = New-Object System.Windows.Forms.Label
        $lblSave.Text      = ("Con nombre se guarda en {0} y sale en el menu de perfiles como uno mas." -f (Split-Path -Leaf $CfgPath))
        $lblSave.Location  = New-Object System.Drawing.Point(14, 612)
        $lblSave.Size      = New-Object System.Drawing.Size(700, 20)
        $lblSave.ForeColor = (Get-CvGuiCurrentPalette).Muted
        $form.Controls.Add($lblSave)

        $yBtn = 630
    }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = 'Vacio = sin valor (se usa el global de config.json o no se aplica la opcion).'
    $lbl.Location  = New-Object System.Drawing.Point(14, ($yBtn + 2))
    $lbl.Size      = New-Object System.Drawing.Size(480, 20)
    $lbl.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $form.Controls.Add($lbl)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Aceptar'
    $btnOk.Size     = New-Object System.Drawing.Size(120, 30)
    $btnOk.Location = New-Object System.Drawing.Point(502, $yBtn)
    $btnOk.Name     = 'cvPeOk'
    # En el gestor de perfiles no hay job donde usarlo: el unico final es guardarlo.
    $btnOk.Visible  = (-not $ForSave)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancelar'
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
            if (-not $chk.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message "$($chk.Error)"; return }
            $prof = & $build
            $r = Save-CvConfigProfile -Path $CfgPath -Prof $prof -Label $nm -Replace $Name
            if (-not $r.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo guardar: {0}" -f $r.Error); return }
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



function Show-CvProfilesWindow {
    <#
        Gestion de perfiles: los PROPIOS del config ('profiles') -crear, duplicar, editar, borrar- y
        debajo los de SERIE en solo lectura, que no se pueden tocar pero SI duplicar: partir de uno
        que ya funciona es la forma comoda de hacerse el suyo. Es el equivalente en ventana del
        submenu 'Perfiles' de setup, y escribe por las mismas funciones.

        Hasta 4.7.0 estos perfiles solo se podian escribir A MANO en config.json.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CfgPath
    )
    if (-not (Initialize-CvGui)) { return $false }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = ("Perfiles ({0})" -f (Split-Path -Leaf $CfgPath))
    $form.StartPosition = 'CenterParent'
    $form.Size          = New-Object System.Drawing.Size(880, 520)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 420)
    $form.Name          = 'cvProfiles'

    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock        = 'Fill'
    $grid.Padding     = New-Object System.Windows.Forms.Padding(10)
    $grid.ColumnCount = 1
    $grid.RowCount    = 3
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    $form.Controls.Add($grid)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock          = 'Fill'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.HideSelection = $false
    $lv.MultiSelect   = $false
    $lv.Font          = (New-CvGuiFont 9)
    $lv.Name          = 'cvProfilesList'
    [void]$lv.Columns.Add('Nombre', 240)   # cabe el '*' del predeterminado sin comerse el nombre
    [void]$lv.Columns.Add('Tipo', 90)
    [void]$lv.Columns.Add('Que hace', 520)
    # 'Que hace' se queda con lo que sobre (y de paso no queda cabecera sin columna).
    [void](Set-CvGuiListFillColumn -List $lv -Index 2 -Min 300)
    [void](Set-CvGuiDoubleBuffered -Control $lv)
    $grid.Controls.Add($lv, 0, 0)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Dock      = 'Fill'
    $lblInfo.TextAlign = 'MiddleLeft'
    $lblInfo.ForeColor = (Get-CvGuiCurrentPalette).Muted
    $lblInfo.Name      = 'cvProfilesInfo'
    $grid.Controls.Add($lblInfo, 0, 1)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Fill'
    $bar.FlowDirection = 'LeftToRight'
    $bar.WrapContents  = $false
    $grid.Controls.Add($bar, 0, 2)

    # Botones con AutoSize (un ancho fijo corta el texto en cuanto cambia la fuente o el DPI).
    $mkBtn = {
        param([string]$Text, [string]$Name, [int]$Width = 110)
        $b = New-Object System.Windows.Forms.Button
        $b.Text         = $Text
        $b.Height       = 30
        $b.AutoSize     = $true
        $b.AutoSizeMode = 'GrowAndShrink'
        $b.MinimumSize  = New-Object System.Drawing.Size($Width, 30)
        $b.Margin       = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
        $b.Name         = $Name
        $bar.Controls.Add($b)
        return $b
    }
    $btnNew   = & $mkBtn 'Nuevo...'  'cvProfilesNew'
    $btnDup   = & $mkBtn 'Duplicar'  'cvProfilesDup'
    $btnEdit  = & $mkBtn 'Editar...' 'cvProfilesEdit'
    $btnDel   = & $mkBtn 'Borrar'    'cvProfilesDel'
    $btnDef   = & $mkBtn 'Predeterminado' 'cvProfilesDef' 130
    $btnClose = & $mkBtn 'Cerrar'    'cvProfilesClose'

    $st = @{ Rows = @(); Default = 'Auto' }
    $current = {
        if ($lv.SelectedIndices.Count -eq 0) { return $null }
        $i = $lv.SelectedIndices[0]
        if ($i -lt 0 -or $i -ge @($st.Rows).Count) { return $null }
        return @($st.Rows)[$i]
    }
    $enable = {
        $r = & $current
        $propio = ($null -ne $r -and "$($r.Kind)" -eq 'propio')
        # Duplicar vale para cualquiera (incluso uno de serie: de ahi sale un perfil propio nuevo);
        # editar y borrar, solo los propios: los de serie viven en el codigo.
        $btnDup.Enabled  = ($null -ne $r)
        $btnEdit.Enabled = $propio
        $btnDel.Enabled  = $propio
        # Predeterminado: marcarlo, o quitarlo si ya lo es (entonces vuelve a serlo 'Auto', que es
        # lo de fabrica). Cualquiera vale, tambien uno de serie: elegir no es editar.
        $esDef = ($null -ne $r -and "$($r.Label)" -eq "$($st.Default)")
        $btnDef.Enabled = ($null -ne $r)
        $btnDef.Text    = $(if ($esDef) { 'Quitar predet.' } else { 'Predeterminado' })
    }
    $reload = {
        # Rehacer la lista pierde la seleccion (Items.Clear), y aqui se rehace tambien al marcar el
        # predeterminado: sin devolverla, se queda sin fila marcada y los botones se apagan solos.
        $marcada = $(if ($lv.SelectedIndices.Count -gt 0) { [int]$lv.SelectedIndices[0] } else { -1 })
        $st.Rows    = @(Get-CvProfileManagerRows -Path $CfgPath)
        $st.Default = "$(Get-CvConfigDefaultProfile -Path $CfgPath)"
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            foreach ($r in $st.Rows) {
                # '*' delante del predeterminado, como en el menu de consola y en el dialogo.
                $it = New-Object System.Windows.Forms.ListViewItem($(if ("$($r.Label)" -eq "$($st.Default)") { "* $($r.Label)" } else { "  $($r.Label)" }))
                [void]$it.SubItems.Add($(if ("$($r.Kind)" -eq 'serie') { 'de serie' } else { 'propio' }))
                [void]$it.SubItems.Add("$($r.Text)")
                # Los de serie, en gris: se ve de un vistazo que ahi no se puede escribir.
                if ("$($r.Kind)" -eq 'serie') { $it.ForeColor = (Get-CvGuiCurrentPalette).Muted }
                [void]$lv.Items.Add($it)
            }
        } finally { $lv.EndUpdate() }
        if ($marcada -ge 0 -and $marcada -lt $lv.Items.Count) { $lv.Items[$marcada].Selected = $true }
        $propios = @($st.Rows | Where-Object { "$($_.Kind)" -eq 'propio' }).Count
        $serie   = @($st.Rows).Count - $propios
        $lblInfo.Text = $(if ($propios -eq 0) {
            ('Todavia no hay perfiles propios: con "Nuevo..." creas uno, o marca uno de los {0} de serie y "Duplicar" para partir de el.   *  = {1} (el que sale marcado al preparar).' -f $serie, $st.Default)
        } else {
            ('{0} propios (salen como [config] en el menu de perfiles) y {1} de serie, que no se editan pero se duplican.   *  = {2} (el que sale marcado al preparar).' -f $propios, $serie, $st.Default)
        })
        & $enable
    }
    $lv.Add_SelectedIndexChanged({ & $enable })

    $btnNew.Add_Click({
        [void](Show-CvProfileEditorWindow -Context $Context -CfgPath $CfgPath -ForSave)
        & $reload
    })
    $btnEdit.Add_Click({
        $r = & $current
        if ($null -eq $r -or "$($r.Kind)" -ne 'propio') { return }
        [void](Show-CvProfileEditorWindow -Context $Context -Prof $r.Prof -CfgPath $CfgPath -Name $r.Label -ForSave)
        & $reload
    })
    $btnDup.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        # Sin -Name: es OTRO perfil, asi que hay que ponerle un nombre nuevo (si se repite, se avisa).
        [void](Show-CvProfileEditorWindow -Context $Context -Prof $r.Prof -CfgPath $CfgPath -ForSave)
        & $reload
    })
    $btnDel.Add_Click({
        $r = & $current
        if ($null -eq $r -or "$($r.Kind)" -ne 'propio') { return }
        if (-not (Show-CvGuiConfirm -Title 'Perfiles' -Message ("Borrar el perfil '{0}'?" -f $r.Label))) { return }
        $res = Remove-CvConfigProfile -Path $CfgPath -Label $r.Label
        if (-not $res.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo borrar: {0}" -f $res.Error) }
        & $reload
    })
    $btnDef.Add_Click({
        $r = & $current
        if ($null -eq $r) { return }
        $nuevo = $(if ("$($r.Label)" -eq "$($st.Default)") { 'Auto' } else { "$($r.Label)" })
        $res = Save-CvConfigDefaultProfile -Path $CfgPath -Label $nuevo
        if (-not $res.Ok) { Show-CvGuiInfo -Title 'Perfiles' -Message ("No se pudo guardar: {0}" -f $res.Error) }
        & $reload
    })
    $btnClose.Add_Click({ $form.Close() })
    $lv.Add_DoubleClick({
        $r = & $current
        if ($null -ne $r -and "$($r.Kind)" -eq 'serie') { $btnDup.PerformClick() } else { $btnEdit.PerformClick() }
    })

    $form.Add_Shown({ & $reload })
    $form.CancelButton = $btnClose
    # Tema de la SESION (lo fija el lanzador con lo que diga la config, y lo cambia el boton
    # "Tema" de la cola): asi una ventana que se abre DESPUES de cambiarlo sale ya con el nuevo.
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return $true
}

Export-ModuleMember -Function *
