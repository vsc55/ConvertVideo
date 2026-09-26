<#
    GuiJob.psm1 - La logica de las ventanas del JOB que se puede probar SIN ventana.

    Como se ensenan las pistas de audio y de subtitulos en las listas (Get-CvJobAudioRows,
    Get-CvJobSubRows) y como se arma el borrador que se acabara escribiendo con los valores que haya
    en pantalla (ConvertTo-CvJobDraftFromRows).

    Lo que se elige y lo que se elegiria solo sale de lib\JobCore.psm1 (datos, sin interfaz), que se
    apoya en las MISMAS funciones que decide la consola. Ninguna ventana reimplementa una decision.
    Las ventanas: form\GuiJobWindow.psm1 (editor de un job), form\GuiJobBulkWindow.psm1 (editar
    varios a la vez) y form\GuiPrepareWindow.psm1 (preparar los pendientes).
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

# Las ventanas de PERFILES tienen fichero propio porque las usan TAMBIEN las de setup, que no cargan
# el pipeline de jobs: elegir el del lote en form\GuiJobProfileDialog.psm1, ajustar uno en
# form\GuiProfileEditorWindow.psm1 y gestionar los propios en form\GuiProfilesWindow.psm1.

Export-ModuleMember -Function *
