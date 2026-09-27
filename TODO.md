# TODO (versión PowerShell)

## ✅ Sincronía `adelay` — PROMOCIONADA (13/07/2026)

**Estado:** ✅ VALIDADA y promocionada. El silencio de sincronía con `adelay=<ms>:all=1` en **una sola pasada** (encadenado con el volumen) es ahora el **método por defecto**: `encode.audio.syncAdelay = true` (antes la beta `test.syncAdelay`). Se conservan **los dos modos**: `true` (adelay, por defecto) y `false` (clásico WAV). Comprobado a nivel PCM (11/07: 220 vs 221 muestras para 5 ms, diff 0,023 ms, inaudible) y en uso real. Único matiz: `adelay` cuantiza a ms enteros (documentado en `docs/ref-gotchas.md`). Config `encode.audio.syncAdelay` → `Context.SyncAdelay` → rama en `Invoke-AudioRun`.

---

## Validar/afinar el downmix `dialogue` con voz reforzada (🧪 beta → estable)

**Estado:** 🧪 BETA. `encode.audio.downmixMode = "dialogue"` baja 5.1 → estéreo con un filtro `pan` que sube el central (diálogos) y baja los surrounds. **Doble llave:** solo refuerza la voz si además `test.betaDownmix = true`; si no, `dialogue` cae al downmix estándar. El worker marca el modo reforzado con `[beta]`. Al promocionar, quitar el flag `test.betaDownmix` y el `[beta]`.

**Qué falta:** solo lo que no se puede medir — **escucharlo en material real** y decidir si los diálogos destacan sin que el resto quede demasiado bajo (el "karaoke" del punto 1). Las fixtures del repo no sirven: su pista 5.1 es `anullsrc` (silencio, −91 dBFS medido). Hace falta un 5.1 de verdad.

**Ya hecho:**

- Los coeficientes son **configurables** en `encode.audio.downmixCoeffs` (`center`/`front`/`surround`), así que afinarlos no requiere tocar código.
- **Medido el 27/09/2026** (ffmpeg 8.1.2, señales sintéticas con cada canal a un nivel conocido, midiendo el `pan` que devuelve `Get-CvDownmixPan` con los coeficientes de fábrica — no una copia parecida):

  | Mezcla (FL FR FC LFE BL BR) | pico 5.1 | pico voz reforzada | pico estándar | LUFS voz − LUFS estándar |
  |---|---|---|---|---|
  | diálogo (.25 .25 .70 .10 .10 .10) | −3,1 dB | −6,9 dB | −9,5 dB | −3,8 |
  | acción (.45 .45 .35 .60 .55 .55) | −4,4 dB | −7,7 dB | −7,0 dB | −9,0 |
  | música (.70 .70 .10 .20 .35 .35) | −3,1 dB | −9,2 dB | −7,5 dB | −9,6 |
  | **todo a tope** (1 1 1 1 1 1, en fase) | **0,0 dB** | **0,0 dB** | 0,0 dB | −7,5 |
  | solo central | 0,0 dB | −6,0 dB (=0,50) | −10,7 dB (=0,29) | −3,0 |
  | solo surrounds | 0,0 dB | −16,5 dB (=0,15) | −10,7 dB (=0,29) | −13,5 |

  1. **No recorta, confirmado** (punto 2): en el peor caso posible —los seis canales a fondo y en fase— el downmix sale a **0,0 dBFS exactos**, ni un dB por encima del origen, porque los coeficientes suman 1,0. En todas las mezclas `pico voz ≤ pico 5.1`, así que la normalización `peak` (que mide en el origen) sigue siendo válida.
  2. **Cuánto destaca la voz** (punto 3, contra el downmix estándar de ffmpeg): el central sale **+4,7 dB** (0,50 frente a 0,29) y los surrounds **−5,8 dB** (0,15 frente a 0,29) → **+10,5 dB de contraste voz/ambiente** (la teoría dice 20·log10(0,5/0,15) = 10,46 dB). Es MUCHO: ahí está el riesgo de "karaoke", sobre todo en mezclas de acción.
  3. **Baja el volumen general**: entre 3,8 y 9,6 LUFS por debajo del estándar según cuánto ambiente tenga la mezcla. Con `loudnorm` detrás se recupera solo; con volumen `peak` o sin normalizar, se nota.

  Dos trampas de ffmpeg que salieron al montar la medida, por si se repite: el generador **`sine` sale a 1/8 de escala** (−18,1 dBFS medido en 8.1.2), así que para niveles exactos hay que usar `aevalsrc=sin(2*PI*f*t)`; y **`join` adivina el reparto de canales** si no se le da `map=` —con seis entradas mono coloca la tercera en FR, y la "voz sola" salía a 0,35 (el coeficiente frontal) en vez de a 0,50—.

**Decisión:** si los coeficientes por defecto convencen → promocionar (quitar el flag `test.betaDownmix` y el `[beta]`); si no, ajustar los defaults.

**Archivos:** `lib/Audio.psm1` (`$panDown`), `lib/Config.psm1`/`lib/Context.psm1` (`downmixCoeffs`), `docs/explica-audio.md`.

---

## ✅ Audio multipista (conservar varias pistas del idioma preferido) — PROMOCIONADA (13/07/2026)

**Estado:** ✅ VALIDADA y promocionada. Se retira la doble llave: la multipista la gobierna solo el toggle **`encode.audio.multiAudio`** (por defecto `true`); eliminado el flag beta `test.betaMultiAudio` y las marcas `[beta]`. Con 2+ pistas del idioma preferido se conservan varias y se elige la predeterminada (menú `Select-AudioMulti`, un temporal por pista `<name>_aN.*`, multiplex con la predeterminada primero, idioma + título por pista; `copy` también conserva el set). Verificado E2E + tests unitarios + batería. **Mejora futura opcional:** extender a **varios idiomas** (hoy solo lista las del idioma preferido).

---

## Probar AV1 por GPU `av1_nvenc` en hardware compatible (`[SIN PROBAR]`)

**Estado:** ⚠️ SIN PROBAR (ya NO es beta). El codec **AV1** llegó en v4.5.0 con dos encoders: `libsvtav1` (CPU, **validado**) y `av1_nvenc` (GPU). Se retiró el flag beta `test.betaAv1` (y `Get-CvBetaEncoders`/`Context.BetaAv1`): `av1_nvenc` **aparece siempre** en el menú `ENCODER DE VIDEO`, etiquetado **`[SIN PROBAR]`**, porque no se ha podido validar — requiere **NVIDIA RTX 40+/Ada** y la GPU de pruebas (GTX 1070) no lo soporta (`No capable devices found`). En esa GPU, la validación por GPU (`Test-CvGpuEncoder`) además lo marca `[NO SOPORTADO]` y lo salta.

**Qué falta:**
1. En una GPU **RTX 40+ (Ada o superior)** con driver reciente: crear un perfil con `av1_nvenc` y **codificar un archivo real** (8 y 10 bits, con y sin tone-mapping HDR→SDR), confirmando salida `av1` correcta y reproducible.
2. Revisar el control de tasa por GPU (`-qmin/-qmax`/multipass) y el `-pix_fmt` (`p010le` en `main10`).
3. Contrastar calidad/velocidad frente a `libsvtav1` (CPU) y `hevc_nvenc`.

**Decisión:** si va bien → quitar la etiqueta `[SIN PROBAR]` de su fila en `Get-CvVideoEncoders`. La validación por GPU (`Test-CvGpuEncoder`) seguirá protegiendo a quien no tenga hardware compatible.

**Archivos:** `lib/Profile.psm1` (`Get-CvVideoEncoders`, `Get-CvCodecOptions`, `Get-VideoArgs` rama `av1_nvenc`), `lib/Tools.psm1` (validación GPU), `docs/ref-perfiles.md`.

---

## Sistema de ejecución única (todo en un solo ffmpeg)

**Estado:** 🚦 **RC desde el 27/09/2026** (implementada en v4.5.0 como beta). La clave sale del cajón de pruebas y pasa a **`encode.onePass`**, **activada de serie**; se retira `test.betaOnePass` sin alias. `lib/OnePass.psm1` (`Test-CvOnePassEligible`/`Get-CvOnePassArgs`/`Invoke-CvOnePass`) funde audio+vídeo+multiplexado en un único ffmpeg con `-filter_complex` cuando el job es **elegible** (encode+encode, sincronía `adelay`, volumen `loudnorm` **o `peak`**, sin HDR); lo que no encaja sigue yendo por etapas sin que haya que decidir nada. Mientras esté en RC, el log lo marca **`[rc]`**.

**Por qué RC y no estable:** lleva tiempo en uso real (Javier, con la beta activada en su config) sin problemas, y la batería E2E pasa **16/16 con `libx265`** por ese camino. Lo que aún **no** ha pasado por una comprobación deliberada: subtítulos **ASS con fuentes adjuntas**, **capítulos**, **multipista** y que el **HDR→SDR** se excluya solo en material de verdad. Cuando eso se vea en uso, se quita el `[rc]` (log + ayuda de la clave) y se queda estable.

**Ojo con la batería:** hasta el 27/09/2026 el config aislado de `run-tests.ps1` se construía sobre el config **del usuario**, así que con la beta activada en él la tanda "por etapas" iba en realidad **por una pasada** y los dos modos probaban lo mismo. Ya se fija `encode.onePass` en los dos sentidos (`-OnePass` = `true`, sin él = `false`). Mismo error que el de `paths`: lo que decide el comportamiento se pone, no se hereda.

Las decisiones de diseño de abajo quedan resueltas así: (1) **convive** con el pipeline por etapas (no lo sustituye); (2) **multipista** soportada (una rama de audio por pista); (3) **error** de una pasada = falla el archivo y reintenta según la política del worker; (4) modo pruebas (`-t`) soportado, `copy` va por etapas; (5) **`peak` SÍ** entra (pasada de análisis previa barata, como el pipeline por etapas); solo **`aacgain`** queda fuera por diseño (aplica ReplayGain sobre el `.m4a` intermedio, que en una pasada no existe).

**Historial (idea validada antes de implementar):**

**Qué:** fundir las tres etapas actuales (audio → vídeo → multiplexado, cada una un proceso ffmpeg
con temporales `.m4a`/`.mka` y `.mkv`) en **una sola llamada a ffmpeg** que haga a la vez: reencodar
vídeo (con `crop`/`scale`), filtrar y recodificar audio (silencio `adelay` + normalización de volumen),
copiar/mapear subtítulos con sus disposiciones, conservar capítulos y limpiar/fijar metadatos, escribiendo
directamente `Convertido\<nombre>_fix.mkv`. Ahorraría los temporales intermedios y dos arranques de ffmpeg.

**Ya verificado (empíricamente, ffmpeg 7.1.1, sin tocar el proyecto):** un único comando con
`-filter_complex "[0:v]crop,scale[v];[0:a]adelay=<ms>:all=1,loudnorm=…[a]"`, más los `-map [v] -map [a] -map 0:s:0`,
`-map_chapters 0` y `-c:v hevc_nvenc … -c:a aac -c:s copy`, produce el MKV final correcto: vídeo HEVC
recortado/escalado (10 bits), audio AAC con el silencio inicial y el volumen normalizado, subtítulo y capítulos.
Funciona con **CPU** (`libx264`) y con **GPU** (`hevc_nvenc`): el filtro de vídeo corre en CPU y NVENC codifica.

**Límite conocido (bloqueante para el one-pass total):** el método de volumen **`peak`** (mide el pico con
`volumedetect` **antes** de codificar) y **`aacgain`** (aplica la ganancia **después** del encode) obligan a
una pasada extra por diseño. La ejecución única solo es posible con volumen **`loudnorm`** (una pasada) y
sincronía **`adelay`**. La detección de bordes (`cropdetect`) no estorba: ya se resuelve en PREPARAR y el
recorte va congelado en el job.

**Decisiones a confirmar cuando se retome:**
1. ¿Convivir con el pipeline actual (nuevo modo, p. ej. solo cuando `volume=loudnorm` y sincronía `adelay`)
   o sustituirlo? Los métodos `peak`/`aacgain` seguirían necesitando el flujo por etapas.
2. Encaje con **audio multipista** (varias pistas → varias ramas de audio en el mismo `-filter_complex`).
3. Manejo de errores y reintentos: hoy cada etapa valida por separado; en one-pass un fallo tira todo el archivo.
4. Modo pruebas (`-t`), `copy` de vídeo/audio y perfiles `copy` (¿siguen por la vía actual?).

**Archivos que tocaría:** `lib/Video.psm1` + `lib/Audio.psm1` + `lib/Multiplex.psm1` (unificar la
construcción de args en un solo comando), el worker (`Convert.ps1`) y `lib/Job.psm1` (temporales).
