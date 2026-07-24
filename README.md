# ConvertVideo

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
[![Release](https://img.shields.io/github/v/release/vsc55/ConvertVideo)](https://github.com/vsc55/ConvertVideo/releases)
[![Downloads](https://img.shields.io/github/downloads/vsc55/ConvertVideo/total)](https://github.com/vsc55/ConvertVideo/releases)
[![Lint](https://github.com/vsc55/ConvertVideo/actions/workflows/lint.yml/badge.svg)](https://github.com/vsc55/ConvertVideo/actions/workflows/lint.yml)
![Last Commit](https://img.shields.io/github/last-commit/vsc55/ConvertVideo)
![Code Size](https://img.shields.io/github/languages/code-size/vsc55/ConvertVideo)
![Top Language](https://img.shields.io/github/languages/top/vsc55/ConvertVideo)
![Maintenance](https://img.shields.io/maintenance/yes/2026)
![Author](https://img.shields.io/badge/author-VSC55-lightgrey)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/vsc55/ConvertVideo)
[![GitHub Stars](https://img.shields.io/github/stars/vsc55/ConvertVideo?style=social)](https://github.com/vsc55/ConvertVideo/stargazers)

Conversor/recodificador de vídeo por lotes para Windows, escrito en **PowerShell 5.1**, que usa **FFmpeg** como motor. Diseño modular en `lib\` y toda la configuración en `config.json`.

Recodifica a **MKV** (vídeo H.265/H.264 por GPU NVIDIA o CPU; audio AAC, AC-3, E-AC-3, MP3, FLAC u Opus, o copia sin recodificar), con detección y recorte de bandas negras, selección de pistas (vídeo/audio/subtítulos, con preview), corrección de sincronía, normalización de volumen y **MKV final limpio** (sin metadatos heredados ni etiquetas `DURATION`).

> La versión antigua en Batch (CMD + VBScript) se conserva en la rama **`v3.x`**.

***

## Puesta en marcha

1. Copia tus vídeos en la carpeta `Original\` (por defecto `.avi`, `.flv`, `.mp4`, `.mov`, `.mkv`; ampliable en `config.json` → `encode.extensions`).
2. Doble clic en **`Convert.cmd`**.
   - Si falta FFmpeg, se ofrece a **descargarlo** (build de [GyanD/codexffmpeg](https://github.com/GyanD/codexffmpeg), verificado con SHA256).
   - Primero **pregunta** la configuración de cada archivo; luego **codifica** sin más preguntas.
3. El resultado queda en `Convertido\<nombre>_fix.mkv`.

`Convert.cmd` solo lanza `Convert.ps1` con `-ExecutionPolicy Bypass` (no cambia la política del sistema) y pone la consola en UTF-8.

Para gestionar las herramientas (FFmpeg, aacgain, MKVToolNix, 7zr) o editar la configuración cómodamente: **`setup.cmd`**. Ambos lanzadores admiten `-Config <ruta>` para usar un fichero de configuración alterno (se **reenvía** a las ventanas worker que se abran en paralelo). Para depurar hay **`Convert-Debug.cmd`**, que usa `config.debug.json` (`debug.enabled = true`) y muestra el log detallado sin tocar tu `config.json`; y **`setup-Debug.cmd`** para editar/gestionar ese `config.debug.json` con el editor de setup.

## En qué consiste

Modelo **preparar → procesar**:

- **PREPARAR**: elige un perfil y, por cada vídeo, pregunta/detecta todo (selección de pista de vídeo si hay varias, bordes con preview en varios puntos, resize, animación, pista de audio con su idioma, sincronía, subtítulos) y lo congela en `Proceso\<nombre>.job.json`.
- **WORKER**: codifica cada preparado de forma desatendida (audio → vídeo → multiplexado) y deja el MKV en `Convertido\`.
- **Paralelo**: cuando todos tienen `.job`, puedes abrir varias ventanas de `Convert.cmd`; cada una toma archivos libres mediante un lock atómico.

## Funcionalidades

Todo es configurable en `config.json` (detalle en [ref-configuracion.md](docs/ref-configuracion.md)). Resumen por áreas:

### Vídeo

| Funcionalidad | Opciones |
|---|---|
| **Recodificación** | H.264 (`libx264` CPU / `h264_nvenc` GPU), H.265 (`libx265` / `hevc_nvenc`), AV1 (`libsvtav1` CPU / `av1_nvenc` GPU), o `copy` (sin recodificar) |
| **Perfil Auto** | Elige el mejor encoder soportado por el equipo (AV1 > H.265 > H.264, GPU antes que CPU), también como `videoEncoder: "auto"` en un perfil; filtros de solo-GPU y tope de códec |
| **Control de tasa** | CRF (CPU, 0-51) · CRF AV1 (0-63) · QP mín/máx (NVENC) |
| **Profundidad / perfil / level** | 8 o 10 bits (`main10`), perfil y level del códec |
| **2-pass NVENC** | Off · ¼ de resolución · resolución completa |
| **Tuning** | Preset por familia de encoder, `rc-lookahead`, `refs`, `tier` |
| **Detección/recorte de bandas negras** | `cropdetect` con muestreo en varios puntos + preview; por perfil: no / sí / auto |
| **Reescalado (resize)** | Ancho máximo (solo reduce) o escalado fijo (p. ej. `1920:-2`) |
| **FPS** | Forzar el fps de salida o conservar el del origen |
| **HDR → SDR (tone-mapping)** | Auto u off con `libplacebo` + curva configurable (`bt.2390`…) |
| **Vídeo anamórfico (SAR ≠ 1)** | Conservar · cuadrar por ancho · cuadrar por alto |
| **Control de calidad** | SSIM o VMAF de la salida frente al origen |
| **Animación** | `-tune animation` (libx264/libx265); PREPARAR pregunta por archivo |
| **Selección de pista de vídeo** | Menú con preview cuando hay varias pistas |

### Audio

| Funcionalidad | Opciones |
|---|---|
| **Recodificación** | AAC, AC-3, E-AC-3, MP3, FLAC, Opus, o `copy` (sin recodificar) |
| **Canales / downmix** | Estéreo / 5.1 / 7.1 como **máximo** (no hace upmix); downmix 5.1→estéreo estándar o con voz reforzada (coeficientes) |
| **Frecuencia** | Hz de salida (Opus fuerza 48000) |
| **Normalización de volumen** | Pico (`peak`) · `loudnorm` (EBU R128) · `aacgain` |
| **Sincronía A/V** | Corrección con `adelay` (1 pasada) o WAV clásico; el desfase inicial solo se compensa si la ruta pierde los timestamps; detección de audio **adelantado** con aviso y preview forzoso |
| **Multipista** | Conservar varias pistas del idioma preferido y elegir la predeterminada |
| **Selección por idioma** | Idioma preferido con *fallback* + preview; conservar (o no) el título de la pista |

### Subtítulos

| Funcionalidad | Opciones |
|---|---|
| **Selección automática** | Conserva forzados + completos del idioma preferido; clasifica por flag o por tamaño de cues; *fallback* para elegir cuáles conservar |
| **Conversión a SRT** | Lista configurable `encode.subtitles.toSrt` (por defecto `webvtt`): convierte esos subtítulos a SubRip; el WEBVTT que ffmpeg no puede leer se rescata con `mkvextract` y se convierte en la misma ejecución; los ilegibles no cubiertos se ignoran (evita que tumben la conversión) |
| **Preview / contenido** | Previsualizar con ffplay o ver el `.srt` extraído |
| **FixSyncSub** (`.srt` externos) | Re-sincronización lineal, OCR (`l`→`I`), espaciado y detección de codificación |

### Contenedor, salida y post-proceso

| Funcionalidad | Opciones |
|---|---|
| **Contenedor de salida** | MKV (recomendado) · MP4/MOV (con `+faststart`) |
| **Extensiones de entrada** | Lista configurable |
| **Adjuntos** | Conservar fuentes / carátulas / otros al multiplexar |
| **Limpieza** | Quita metadatos heredados y etiquetas `DURATION` con `mkvpropedit`; conserva los capítulos |

### Flujo y operación

| Funcionalidad | Opciones |
|---|---|
| **Preparar → worker** | Congela las decisiones en `Proceso\<nombre>.job.json` y codifica desatendido |
| **Ejecución en paralelo** | Varias ventanas con lock atómico; reintentos por archivo |
| **Progreso en vivo** | % + ETA + velocidad + bitrate + cuantizador `q` |
| **Perfiles** | de serie + propios en `config.json` + builder custom interactivo |
| **Una sola pasada** 🧪 | Audio + vídeo + multiplexado en un único ffmpeg (beta) |
| **Validación de encoders por GPU** | Sondea qué NVENC soporta la GPU real y lo cachea |
| **Timeouts de prompt** | Auto-aceptar por tipo de pregunta tras N segundos |
| **Descarga de FFmpeg** | Automática, verificada con SHA256 |
| **Modo test / debug** | Recortar la codificación a N minutos · log detallado |

## Requisitos

- Windows de 64 bits con **PowerShell 5.1** (el que trae Windows).
- FFmpeg/FFprobe/FFplay: se descargan solos a `tools\ffmpeg\<version>\<plataforma>\` (o instálalos con `setup.cmd`).
- Para los perfiles NVENC, una GPU NVIDIA compatible con la versión de FFmpeg elegida.

## Estructura

| Carpeta / fichero | Uso |
|---|---|
| `Convert.cmd` / `setup.cmd` | Lanzadores del conversor / de la utilidad de gestión. |
| `Convert-Debug.cmd` / `setup-Debug.cmd` / `config.debug.json` | Conversor / editor de setup en modo debug (log detallado), sobre `config.debug.json`. |
| `Convert.ps1` | Orquestador (clasificar / preparar / worker). |
| `setup.ps1` | Herramientas + editor de `config.json` + limpieza. |
| `config.json` | Toda la configuración. |
| `lib\` | Módulos PowerShell (`*.psm1`). |
| `Original\` | Vídeos de entrada. |
| `Proceso\` | Trabajo: `*.job.json`, `*.lock`, temporales. |
| `Convertido\` | Resultado final (`*_fix.mkv`). |
| `tools\<app>\<ver>\<plat>` | Ejecutables (FFmpeg, aacgain, mkvpropedit, 7zr). |
| `docs\` | Documentación detallada. |

## 📖 Documentación

La documentación técnica y detallada (cómo trabaja, flujos, diagramas y **los comandos exactos** que se lanzan en cada fase) está en **[`docs/`](docs/README.md)**:

- [Arquitectura](docs/ref-arquitectura.md) — módulos, contexto, fuentes de verdad.
- [Flujo de trabajo](docs/ref-flujo.md) — clasificar → preparar → worker, con diagramas.
- [Comandos de las herramientas](docs/ref-comandos.md) — ffmpeg/ffprobe/ffplay/aacgain por fase.
- [Perfiles](docs/ref-perfiles.md) — perfiles de serie, propios de `config.json` y custom.
- [Configuración](docs/ref-configuracion.md) — referencia de `config.json`.
- [Herramientas](docs/ref-herramientas.md) — versiones, plataforma, descargas y versión por job.
- [Setup](docs/ref-setup.md) — utilidad `setup` (menú, editor de config, `-Config`, debug, fallback NVENC).
- [Jobs](docs/ref-jobs.md) — formato del job, lock y temporales.
- [Pruebas](docs/ref-pruebas.md) — muestras de test, batería del pipeline y fuentes/licencias.

## Star History

<a href="https://www.star-history.com/?repos=vsc55%2FConvertVideo&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=vsc55/ConvertVideo&type=date&theme=dark&legend=top-left&sealed_token=gYf48RZjn0JBHtsRHDu34uj_Q5kwHFMSV1CS9jBqnCdRBTi17K4Xx-2F0jJRqAnUbpGFmc1L8MwFzASv1ZPcf6FaZklhbEAPoaTCLu0gKeS0_qRH6yx46kDLHA8l4qzaUVgGJPX90B_gpEeE0kVgEWUruZ_QnSzBaY9EqNemxKQpuQqGBVAejjkNA4s1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=vsc55/ConvertVideo&type=date&legend=top-left&sealed_token=gYf48RZjn0JBHtsRHDu34uj_Q5kwHFMSV1CS9jBqnCdRBTi17K4Xx-2F0jJRqAnUbpGFmc1L8MwFzASv1ZPcf6FaZklhbEAPoaTCLu0gKeS0_qRH6yx46kDLHA8l4qzaUVgGJPX90B_gpEeE0kVgEWUruZ_QnSzBaY9EqNemxKQpuQqGBVAejjkNA4s1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=vsc55/ConvertVideo&type=date&legend=top-left&sealed_token=gYf48RZjn0JBHtsRHDu34uj_Q5kwHFMSV1CS9jBqnCdRBTi17K4Xx-2F0jJRqAnUbpGFmc1L8MwFzASv1ZPcf6FaZklhbEAPoaTCLu0gKeS0_qRH6yx46kDLHA8l4qzaUVgGJPX90B_gpEeE0kVgEWUruZ_QnSzBaY9EqNemxKQpuQqGBVAejjkNA4s1" />
 </picture>
</a>