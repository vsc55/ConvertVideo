<#
    Gui.psm1 - Ventanas GUI (WinForms) del conversor.

    Separado de Console.psm1 (que es la CONSOLA de texto: menus, prompts, colores) porque esto es
    interfaz grafica: otro paradigma y con su propia dependencia (System.Windows.Forms / System.Drawing).
    Requiere hilo STA, lo normal en powershell.exe (el runtime objetivo). Cada funcion carga WinForms
    en su primera llamada (Add-Type) y es fail-soft: si no hay GUI/STA devuelve $false para que el
    llamador caiga a otra via.
#>

function Show-CvTextWindow {
    <#
        Abre una ventana con un RichTextBox de SOLO LECTURA, monoespaciado y con scroll, mostrando el
        texto dado. MODAL: bloquea hasta que se cierra (ESC o el boton cerrar). Devuelve $true si la
        mostro; $false si no se pudo (sin GUI/STA), para que el llamador use otra forma de abrir.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Text)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text          = $Title
        $form.StartPosition = 'CenterScreen'
        $form.Size          = New-Object System.Drawing.Size(800, 600)
        $rtb = New-Object System.Windows.Forms.RichTextBox
        $rtb.Dock       = 'Fill'
        $rtb.ReadOnly   = $true
        $rtb.WordWrap   = $false
        $rtb.Font       = New-Object System.Drawing.Font('Consolas', 10)
        $rtb.DetectUrls = $false
        $rtb.Text       = $Text
        $form.Controls.Add($rtb)
        # ESC cierra la ventana.
        $form.KeyPreview = $true
        $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
        [void]$form.ShowDialog()
        $form.Dispose()
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function *
