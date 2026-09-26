<#
    Attachment.psm1 - Seleccion de adjuntos (attachments) del original a conservar en el MKV.
    Por defecto no se conserva ninguno (postprocess.attachments.keep = false). Si se activa,
    se puede permitir/excluir por categoria: fuentes (para subtitulos ASS/SSA), caratulas y
    "otros". El multiplex mapea los elegidos por su indice.
#>

function Get-AttachmentStreams {
    param([Parameter(Mandatory)]$Info)
    @($Info.streams | Where-Object { $_.codec_type -eq 'attachment' })
}

function Get-AttachmentKind {
    <# Clasifica un adjunto: 'font' (fuente), 'cover' (imagen/caratula) u 'other'. #>
    param([Parameter(Mandatory)]$Stream)
    $mime  = "$(Get-Tag $Stream 'mimetype')".ToLower()
    $fn    = "$(Get-Tag $Stream 'filename')".ToLower()
    $codec = "$($Stream.codec_name)".ToLower()
    if ($mime -match 'font' -or $fn -match '\.(ttf|otf|ttc|woff2?|eot|pfb|pfm)$' -or $codec -match 'ttf|otf|font') { return 'font' }
    if ($mime -match '^image/' -or $fn -match 'cover|poster|thumb|banner|backdrop' -or $codec -match 'mjpeg|png|bmp|gif|webp') { return 'cover' }
    return 'other'
}

function Select-Attachments {
    <#
        Devuelve la lista de adjuntos del original a conservar segun config
        (postprocess.attachments en $Context.Attachments): interruptor maestro 'Keep' + permitir
        por categoria (Fonts / Covers / Other). Lista vacia = no conservar ninguno.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Info)
    $cfg = $Context.Attachments
    if ($null -eq $cfg -or -not $cfg.Keep) { return @() }

    $att = @(Get-AttachmentStreams -Info $Info)
    if ($att.Count -eq 0) { return @() }

    $kept = @()
    foreach ($a in $att) {
        $kind = Get-AttachmentKind $a
        $ok = switch ($kind) {
            'font'  { [bool]$cfg.Fonts }
            'cover' { [bool]$cfg.Covers }
            default { [bool]$cfg.Other }
        }
        $fn = Get-Tag $a 'filename'
        if ($ok) {
            $kept += $a
            Write-CvLog 'ATTACH' (Get-CvText -Key 'at.conservar' -Values @($fn, $kind))
        } else {
            Write-CvLog 'ATTACH' (Get-CvText -Key 'at.descartar' -Values @($fn, $kind))
        }
    }
    return $kept
}

Export-ModuleMember -Function *
