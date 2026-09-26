<#
    form\GuiJobBulkWindow.psm1 - VENTANA para editar EN BLOQUE los jobs de varios archivos.

    Cuarenta capitulos y quieres que todos copien el video en vez de recodificarlo: se marca lo que
    se quiere cambiar y eso -y solo eso- se escribe en todos; lo que no se marca se queda como esta
    en CADA job. Por eso solo se ofrecen los ajustes que no dependen de lo que lleve dentro cada
    archivo.

    Las filas no se escriben aqui: salen del catalogo Get-CvJobBulkFields (lib\JobCore.psm1), que es
    tambien quien aplica los cambios (Set-CvJobsBulk). Anadir un ajuste es anadirlo ahi.
#>

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
    $form.Text            = (Get-CvText -Key 'bulk.tit' -Values @($names.Count))
    $form.Name            = 'cvJobBulk'
    $form.StartPosition   = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(720, (150 + $altoGb + 96))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = (Get-CvText -Key 'bulk.cab')
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
    $gb.Text     = (Get-CvText -Key 'bulk.grupo')
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
                $val.Text     = (Get-CvText -Key 'comun.sinelegir')
                $val.Location = New-Object System.Drawing.Point(218, $y)
                $val.Size     = New-Object System.Drawing.Size(350, 24)
                $val.Font     = (New-CvGuiFont 9)
                $val.Name     = ("cvBulkVal_{0}" -f $f.Key)
                $gb.Controls.Add($val)

                $btn = New-Object System.Windows.Forms.Button
                $btn.Text     = (Get-CvText -Key 'comun.elegir')
                $btn.Location = New-Object System.Drawing.Point(576, ($y - 1))
                $btn.Size     = New-Object System.Drawing.Size(100, 26)
                $btn.Name     = 'cvBulkProfPick'
                $btn.Add_Click({
                    $p = Show-CvJobProfileDialog -Context $Context -Info (Get-CvText -Key 'bulk.perfil.info' -Values @($names.Count))
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
    $btnCancel.Text     = (Get-CvText -Key 'comun.cancelar')
    $btnCancel.Location = New-Object System.Drawing.Point(488, ($gb.Bottom + 50))
    $btnCancel.Size     = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Name     = 'cvBulkCancel'
    $btnCancel.Add_Click({ $form.Close() }.GetNewClosure())
    $form.Controls.Add($btnCancel)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text     = (Get-CvText -Key 'bulk.aplicar' -Values @($names.Count))
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
            $lblMsg.Text = (Get-CvText -Key 'bulk.marca')
            [void](Set-CvGuiRole -Control $lblMsg -Role 'Muted')
            return
        }
        if (-not $chk.Ok) {
            $lblMsg.Text = (@($chk.Errors) -join '; ')
            [void](Set-CvGuiRole -Control $lblMsg -Role 'Error')
            return
        }
        $lblMsg.Text = (Get-CvText -Key 'bulk.resumen' -Values @($names.Count, (Get-CvJobBulkSummary -Changes $ch)))
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
        Write-CvLog 'JOB' (Get-CvText -Key 'bw.cambiados' -Values @($res.Done, $names.Count, $resumen))
        if ([int]$res.Failed -gt 0) {
            Write-CvLog 'JOB' (Get-CvText -Key 'bw.nocambiados' -Values @($res.Failed, ((@($res.Errors) | Select-Object -First 5) -join ' | ')))
            Show-CvGuiInfo -Title (Get-CvText -Key 'bulk.error.tit') -Message (Get-CvText -Key 'bulk.error.msg' -Values @(
                $res.Done, $names.Count, $res.Failed, [Environment]::NewLine, ((@($res.Errors) | Select-Object -First 5) -join [Environment]::NewLine)))
        }
        $form.Close()
    }.GetNewClosure())

    & $revisar
    [void](Set-CvGuiTheme -Form $form)
    [void]$form.ShowDialog()
    $form.Dispose()
    return ([int]$st.Changed -gt 0)
}

Export-ModuleMember -Function *
