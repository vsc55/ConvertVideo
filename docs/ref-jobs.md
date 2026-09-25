# Jobs, lock y temporales

> El job lleva `subtitleCues`: el número de líneas de **todas** las pistas de subtítulo del archivo (no solo las elegidas), para poder enseñarlas y compararlas sin volver a demultiplexar. Además, cada subtítulo elegido lleva su `Cues` cuando quien preparó ya lo sabía — el editor en ventana lo cuenta para su tabla —, para que nadie tenga que volver a demultiplexar el fichero solo para enseñarlo. `-1` = no se sabe; nadie lo cuenta solo por guardarlo.

> La **estructura** del `.job.json` tiene una sola fuente en el código: `ConvertTo-CvJobRecord` (`lib\JobCore.psm1`). La usan la consola (`Convert.ps1`, al terminar sus preguntas) y el editor en ventana ([ref-cola.md](ref-cola.md)), así que los dos escriben exactamente lo mismo.

Todo el estado de trabajo vive en `Proceso\`.

## El job (`Proceso\<nombre>.job.json`)

En PREPARAR se escribe un job **autosuficiente** por archivo: lleva el perfil congelado, las respuestas del usuario y las versiones de herramientas. El worker no depende de la config global para procesarlo.

Ejemplo:

```json
{
  "file": "D:\\...\\Original\\Video [01].mkv",
  "profile": { "VideoEncoder": "hevc_nvenc", "VideoProfile": "main10", "VideoLevel": "5", "Qmin": 1, "Qmax": 23, "Crf": null, "DetectBorder": true, "ChangeSize": "", "MaxWidth": null, "Multipass": "", "AudioEncoder": "aac_coder", "AudioCodec": "aac", "AudioBitrate": "192k", "AudioHz": 44100, "AudioChannels": null, "DownmixMode": null, "DownmixCoeffs": null },
  "ffmpegVersion": "7.1.1",
  "aacgainVersion": "2.0.0",
  "video": { "skip": false, "index": 0, "crop": "1920:800:0:140", "resize": "", "anim": false, "hdr": false, "keepOriginal": false },
  "audio": { "skip": false, "tracks": [ { "index": 2, "is51": true, "sync": 0, "lang": "spa", "default": true }, { "index": 1, "is51": false, "sync": 0, "lang": "spa", "default": false } ] },
  "subtitles": [ { "Index": 3, "Lang": "spa", "Default": false, "Forced": true } ]
}
```

| Campo | Origen | Uso en el worker |
|---|---|---|
| `file` | ruta absoluta | Entrada de ffmpeg. |
| `profile` | perfil elegido | Argumentos de codec/audio. |
| `ffmpegVersion` / `aacgainVersion` | `selected` al preparar | Versión a usar (se instala si falta). |
| `video` | `Invoke-VideoAsk` | `index` de pista de vídeo (se mapea `0:<index>`), `crop`, `resize`, `anim`, `hdr` (si el origen es HDR → tone-mapping a SDR al recodificar, ver [explica-tonemap-hdr.md](explica-tonemap-hdr.md)), o `skip` (copy). `keepOriginal`: si al terminar el vídeo recodificado ocupa **más** que el original y la imagen no se ha tocado, se tira lo codificado y se multiplexa la pista original (`encode.video.keepOriginalIfBigger` es su valor de partida; un job **antiguo** sin el campo hereda lo que diga la config, `Get-CvJobKeepOriginal`). |
| `audio` | `Invoke-AudioAsk` | `tracks[]` = pistas a incluir, la **predeterminada primero**; cada una con `index` de pista, `lang`, `sync` (silencio), `is51`, `default`. Normalmente **una** pista; con la multipista (`encode.audio.multiAudio`, por defecto; 2+ del idioma preferido) puede haber varias. `skip = true` en perfil `copy` (las `tracks` se copian del original; sin `tracks`, copy clásico `0:a:0`). El **título** de salida no se congela: el multiplex lo deja en blanco o lo copia del origen según `encode.audio.keepTitle`. **Compat**: jobs antiguos con `audio.index/is51/sync/lang` (monopista) se leen como una lista de una pista (`Get-CvJobAudioTracks`). |
| `subtitles` | `Select-Subtitles` | Pistas a mapear con idioma/disposición/título. |

### Escritura atómica

`Write-CvJob` escribe primero un `.tmp` (UTF-8 **sin BOM**) y luego lo renombra con operaciones `.NET` de **ruta literal**:

```powershell
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
if ([System.IO.File]::Exists($final)) { [System.IO.File]::Delete($final) }
[System.IO.File]::Move($tmp, $final)
```

Se usan operaciones literales porque los nombres suelen llevar **corchetes** (`[01]`, `[1080p]`…), que PowerShell interpretaría como comodines en `-Path`/`Test-Path`. Todas las funciones de job (`Test-CvJob`, `Read-CvJob`, `Remove-CvJob`) usan `-LiteralPath`.

> Las funciones van con prefijo `Cv` (`*-CvJob`) para no chocar con los cmdlets nativos de PowerShell `*-Job` (`Get-Job`, `Remove-Job`…).

## El lock (`Proceso\<nombre>.lock`)

Reclamo atómico entre workers. Se crea un fichero con `FileMode.CreateNew`, que **falla si ya existe** (mutex de una sola operación):

```powershell
$fs = [System.IO.File]::Open($lock, [FileMode]::CreateNew, [FileAccess]::Write, [FileShare]::None)
# se escribe "PID=<pid>;HOST=<equipo>" y se cierra; si Open lanza, otro worker lo tiene
```

- Solo un worker gana el archivo; los demás siguen al siguiente.
- Se libera siempre en el `finally` (`Exit-Lock` → `[IO.File]::Delete`), incluso si la codificación falla.
- **Locks huérfanos**: en el lock se guarda `PID`+equipo. Si otro worker encuentra un lock cuyo proceso dueño **ya no existe** (mismo equipo), lo considera caducado (`Test-CvLockStale`) y lo roba. En otra máquina no se puede verificar, así que no se roba.
- Es literal-safe (compatible con nombres con corchetes).

## Ficheros de control de los workers

Además del job, el lock y los temporales, en `Proceso\` viven dos ficheros que sostienen la **cola en ventana** ([ref-cola.md](ref-cola.md)):

| Fichero | Quién lo escribe | Para qué |
|---|---|---|
| `<pid>.worker.json` | cada `Convert.ps1` (siempre, también en consola) | Publica lo único que no se deduce de los ficheros: archivo en curso, paso, %, ETA y velocidad. Se borra al terminar; si queda, su worker murió (se detecta igual que un lock huérfano, por el PID). |
| `stop.flag` | la ventana (botón *Parar*) | Parada **ordenada**: los workers lo miran **entre archivos** y no reclaman más. |

Los dos se limpian con los *bloqueos* desde setup (`Get-CvProcesoPatterns -What locks`).

## Temporales (`Get-CvTempPaths`)

Durante la codificación de un archivo se generan, en `Proceso\`:

| Fichero | Lo crea | Contenido |
|---|---|---|
| `<nombre>.mkv` | `Invoke-VideoRun` | Vídeo recodificado (temporal). |
| `<nombre>.m4a` | `Invoke-AudioRun` | Audio recodificado (temporal) cuando el codec es **AAC**. |
| `<nombre>.mka` | `Invoke-AudioRun` | Audio recodificado (temporal) para codecs **no-AAC** (ac3/eac3/mp3/flac/opus); Matroska admite cualquier codec. |
| `<nombre>_concat.wav` | `Invoke-AudioRun` (si hay sincronía) | Silencio + pista, para recodificar. |
| `<nombre>.job.json.tmp` | `Write-CvJob` | Job a medio escribir (si quedó colgado). |

Todos comparten la **fuente única** `Get-CvTempPaths`, que usan tanto los que los crean (Video/Audio/Multiplex) como el que los limpia.

Al terminar bien un archivo, `Remove-CvTemps` los borra por **ruta exacta** (no comodines, para no tocar temporales de otro archivo cuyo nombre empiece igual), salvo que exista el marcador `keep_temp` (`behavior.cleanTemps = false`).

## Ciclo de vida en `Proceso\`

```mermaid
sequenceDiagram
    participant P as PREPARAR
    participant W as WORKER
    participant FS as Proceso\
    P->>FS: escribe &lt;nombre&gt;.job.json
    W->>FS: crea &lt;nombre&gt;.lock (atómico)
    W->>FS: genera .m4a / .mkv / _concat.wav
    W->>FS: (multiplex) → Convertido\&lt;nombre&gt;_fix.mkv
    W->>FS: Remove-CvTemps (borra temporales)
    W->>FS: Remove-CvJob (borra .job.json)
    W->>FS: Exit-Lock (borra .lock)
```
