# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

ConvertVideo: batch video converter/recoder for Windows, written in **Windows PowerShell 5.1** with **FFmpeg** as the engine. Modular (`lib\*.psm1`), all configuration in `config.json`. Code comments, docs, on-screen text and commit messages are **in Spanish** — match the surrounding language.

## Commands

Target runtime is **Windows PowerShell 5.1**, not PowerShell 7 — avoid 7-only syntax. FFmpeg/ffprobe/ffplay live under `tools\ffmpeg\<version>\x64\` (auto-downloaded by `setup`), not on PATH.

- **Syntax lint** (what CI enforces — AST-parse every `.ps1`/`.psm1` except `tools\`):

  ```powershell
  Get-ChildItem -Recurse -Include *.ps1,*.psm1 -File | ? { $_.FullName -notmatch '\\tools\\' } |
    % { $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); if($e){"$($_.Name): $($e.Message)"} }
  ```

- **Unit tests** (pure functions, no ffmpeg, <1 s): `powershell -ExecutionPolicy Bypass -File test\unit-tests.ps1` (exit 0 pass / 1 fail). They are `Assert-*` calls in one script; there is no single-test flag — narrow the script to isolate.
- **Setup battery** (`SetupCore` data + the WinForms config editor, driven without a mouse; no ffmpeg): `powershell -ExecutionPolicy Bypass -Sta -File test\gui-tests.ps1`. Needs `-Sta`; the window cases SKIP (not fail) without a GUI. Run it after touching `setup*.ps1`, `SetupCore.psm1`, `GuiSetup.psm1` or `GuiConfig.psm1`.
- **Queue battery** (`WorkerCore` data + the WinForms queue window, over a seeded temp root; no ffmpeg): `powershell -ExecutionPolicy Bypass -Sta -File test\gui-convert-tests.ps1`. Same `-Sta`/SKIP rules. Run it after touching `Convert-gui.ps1`, `WorkerCore.psm1` or `GuiConvert.psm1` — and remember the worker publishes its state from `Convert.ps1`/`Exec.psm1`, so touching those needs it too.
- **E2E battery** (runs the real `Convert.ps1` worker over `test\` fixtures and verifies each output with ffprobe):
  - `powershell -ExecutionPolicy Bypass -File test\run-tests.ps1` — GPU (`hevc_nvenc`)
  - `... -Encoder libx265` — CPU/portable (no NVENC)
  - `... -OnePass` — exercise the one-pass path
  - `... -Keep` — don't delete the isolated temp work area
- **Run the app**: `Convert.cmd` (convert), `Convert-gui.cmd` (the conversion **queue in a window**: state per file, workers, live progress; goes straight to `config.json`), `Convert-gui-Config.cmd` (same window, but asks which `config*.json` to use), `setup.cmd` (tools + config editor), `setup-gui.cmd` (the same setup in a window), `FixSyncSub.cmd` (`.srt` fixer). `*-Debug.cmd` variants use `config.debug.json`. Launchers accept `-Config <path>`. `setup.ps1` also runs one action headless: `-Task install -App <app> -Version <v> [-SetDefault]` / `-Task tests -Suite unit|features|gui|cola`. `Convert.ps1 -WorkerOnly -Unattended` is the headless worker the queue window spawns: it never prompts and never pauses; add `-Only <names>` to encode just those files (the window passes the rows you picked).

Consider a change done only after verifying empirically: **AST-parse + unit-tests + the E2E battery for the path you touched** (staged and/or `-OnePass`). The batteries are the real safety net.

## Architecture

- **Model: PREPARE → WORKER** (`Convert.ps1`). Inputs come from `Original\`. PREPARE asks/detects per file (video track, black borders, resize, anamorphic, audio + language, sync, subtitles) and **freezes** it in `Proceso\<name>.job.json`. WORKER encodes unattended → `Convertido\<name>_fix.mkv`. When everything has a job, several `Convert.cmd` windows run in parallel, each claiming files via an atomic lock.

- **Two encode paths, one decision source.** The *staged* pipeline (audio → video → multiplex: 3 ffmpeg processes + temporals) and the *one-pass* beta (`test.betaOnePass`: a single ffmpeg with `-filter_complex`) both derive every decision from the SAME render spec — `Resolve-CvRenderSpec` (`Render.psm1`) — and only the EMISSION differs. The command builders are **pure and golden-tested**: `Get-CvOnePassArgs` (`OnePass.psm1`), `Get-CvMultiplexArgs`/`Get-CvSubtitleMapArgs` (`Multiplex.psm1`), `Get-CvVideoRunArgs` (`Video.psm1`), `Get-CvAudioEncodeArgs` (`Audio.psm1`). Put "what to do" in the spec, not in each emitter, and keep the two paths in sync — the golden tests (exact ffmpeg arg-string match) enforce it, so update them deliberately when args change.

- **Single sources of truth.** `Get-CvConfigDefaults` (`Config.psm1`) is the one place for every config default; `config.json` only overrides. `New-CvContext` builds `$ctx` (a read-only settings bag) from the merged config and is passed almost everywhere. `Get-CvVersion` (`Context.psm1`) is the version (bump it and its unit test together). Enum catalogs (encoders/levels/modes) are functions returning `@{ Value; Text }` — reuse them, never inline the lists.

- **Config shape.** Nested `encode.video` / `encode.audio` / `encode.subtitles` (plus root `threads`/`extensions`/`outputExtension`). Per-file choices live in the **job**, not in config. Filename prefixes drive behavior: `_` forces border detection; `TEST_` re-prepares from scratch (deletes its stale job at startup) except under `-WorkerOnly`.

- **Own profiles have one home too.** Saving/validating/deleting the user profiles of `config.json` (`profiles`) is `Profile.psm1`: `ConvertTo-CvProfileConfig` (inverse of `ConvertTo-CvProfile`, writes only what has a value so an absent key keeps falling back to `encode.*`), `Test-CvProfileName`, `Set-CvProfileInList`/`Remove-CvProfileFromList` (pure), `Save-CvConfigProfile`/`Remove-CvConfigProfile` (file). All three UIs — console setup menu, queue profile dialog, setup window — call those; none writes the JSON itself.

- **Job shape has one home.** `ConvertTo-CvJobRecord` (`JobCore.psm1`) builds the `.job.json` record; both the console PREPARE (`Convert.ps1`) and the window job editor (`GuiJob.psm1`) go through it. `JobCore` also exposes the per-file options, the automatic draft (`New-CvJobDraft`) and the autodiscover (`Get-CvJobAutoPlan`: applies what the console would decide by itself — border detection included — and reports in `Reasons` the cases where the console WOULD ask), all of which reuse the SAME decision functions the console uses (`Select-AudioStream`, `Split-CvSubtitlesByRole`, `Find-CropDetectSamples`, `Get-CvResize`) — a UI never re-implements a decision, it only lets you override it. The window flow mirrors the console: profile once, then file by file, stopping only where the console stops.

- **Two windows, same rule: data module + renderer.** `WorkerCore.psm1` answers "what is in the queue and what is each worker doing" as objects (the queue state comes from the files already on disk: job, lock, output; only the in-file progress is published by each worker to `Proceso\<pid>.worker.json`), and `GuiConvert.psm1` renders it. Neither window encodes: they spawn processes (`Convert.ps1 -WorkerOnly -Unattended`, `setup.ps1 -Task …`) because WinForms is single-threaded. Stopping is a flag workers check *between* files, never mid-encode.

- **Setup has two faces, one data source.** `setup.ps1` (console menu) and `setup-gui.ps1` (WinForms window, `GuiSetup.psm1`) both read `SetupCore.psm1`, which returns **objects** — never colored text or prompts — so each UI renders and confirms its own way. Add an action (or a test battery, catalog `Get-CvSetupTestSuites`) once there and it shows up in both. Long actions (install, test batteries) are not run inside the window: it spawns `setup.ps1 -Task …` in its own console, because WinForms is single-threaded.

- **Modules (`lib\*.psm1`).** Each does `Export-ModuleMember -Function *`; cross-module calls resolve at **call time**, so the load order in `Convert.ps1`/`setup.ps1`/the test runners doesn't gate references — but every entry point must import each module it reaches (a new module goes in **all** the `$modules` lists). Layering to respect: Config = base; Profile = pipeline (Profile may use Config, not the reverse); **Context is base and must not depend on Profile**. Generic helpers have one home each: `Io.psm1` (file IO: atomic JSON, UTF-8 no BOM), `Console.psm1` (text presentation shared by console and windows: `Get-CvProgressBar`, `Format-CvSize`/`Format-CvMb`), `Context.psm1` (time/number), `Gui.psm1` (everything common to every window — the light/dark THEME (`Get-CvGuiPalette` by role, `Set-CvGuiTheme` per window, `Set-CvGuiRole` for a message's own colour; never a hardcoded `Color::` in a window), plus the pieces that were copy-pasted per window: `Update-CvGuiLogView` (tail a log into a TextBox, repainting only when the file's stamp changed), `New-CvGuiCatalogCombo`/`Get-CvGuiComboValue` (catalog → combo keeping values in the control's `Tag`, and keeping a current value that isn't in the catalog), `Open-CvGuiPath`/`Get-CvOpenCommand` (open a file/folder/“reveal in explorer” with one error path), `New-CvGuiTabs`/`Add-CvGuiTab`/`Select-CvGuiTab` (OWN tabs: WinForms' `TabControl` paints its strip and frame light and nothing changes that — measured), and the APP ICON, drawn with GDI+ like the toolbar ones (`New-CvGuiAppBitmap` → `Get-CvGuiAppIconBytes`, a multi-size `.ico` built by hand because `Icon.Save` only writes one size; `Set-CvGuiTheme` puts it on every window)) — each `Gui*` module holds ONE window family: `GuiSetup` (the setup window + its own dialogs), `GuiConvert` (the queue), `GuiJob` (prepare walk + job editor), and the two that are shared by both faces and therefore live apart: `GuiConfig` (the config.json editor) and `GuiProfile` (choose / tune / manage profiles). A window big enough to be opened from more than one place gets its own module; splitting a SINGLE window across files does not work here (its handlers are closures over the form's locals — there are no partial classes), so what shrinks a window is extracting its PURE logic (`Format-CvQueueRow`, `Get-CvQueueStartState`, `Get-CvJobAudioRows`…), which is testable without a GUI.

- **Tools.** Versioned under `tools\<app>\<version>\<platform>`, auto-downloaded and SHA256-verified (ffmpeg, aacgain, `mkvtoolnix` → `mkvpropedit` + `mkvextract`, `7zr`). The exact version is frozen per job for reproducibility; the worker installs it if missing.

- **Manual (`manual\`).** Guía de USO con capturas (`manual\README.md` + `01…04`): qué ves en cada ventana y qué hacer. No duplica `docs\` — enlaza. Las imágenes de `manual\img\` **no se recortan a mano**: las regenera `manual\generar-capturas.ps1` (`-Sta`; abre las ventanas de verdad sobre un root temporal sembrado con las fixtures de `test\` renombradas, y `-Only cola,job,preparar,setup` limita el grupo). Si cambias una ventana, regenera su grupo y mira el PNG. El **icono y el logo** también se generan: `manual\generar-logo.ps1` vuelca a disco lo que dibuja `New-CvGuiAppBitmap` (`icon.ico` en la raíz, `manual\img\logo.png` y `logo-oscuro.png`); el dibujo se cambia en `Gui.psm1`, no en los ficheros.

- **Docs (`docs\`).** Prefix = type: `ref-` (reference), `explica-` (how/why + diagrams), `caso-` (postmortem). `explica-` docs carry mermaid diagrams for flows. Each cross-cutting fact has ONE canonical home; other docs link instead of duplicating. `docs\README.md` is the index. `docs\ref-gotchas.md` collects real bugs already hit — read it before touching those areas.

## Conventions

- **PowerShell 5.1 gotchas** (see `docs\ref-gotchas.md`): use `InvariantCulture` for any decimal that reaches ffmpeg (es-ES writes `,` and breaks filters); `[int]` rounds banker's; `[math]::Max` on mixed int/decimal misbehaves; `scale=-1` can yield odd dimensions.
- **Everything configurable, no magic numbers.** A new tunable or behavior gets a key in `Get-CvConfigDefaults` (with help text, and usually a unit test for the default) and is read via `$ctx` — never a hardcoded literal in the logic. Enforced in review (e.g. `behavior.promptTimeout.*`, `preview.syncSeconds`, `encode.subtitles.toSrt`).
- **Never hardcode real user video filenames** in code, docs or tests — use generic examples.
- **Arrays/hashtables: one value per line** (repo style — applies to return objects, config defaults, catalogs and test fixtures).
- **changelog.md**: add an entry with every change, newest first, under a `## VERSION x.y.z - dd/mm/yyyy` section. Markdown-lint warnings in `changelog.md`/`docs\` are preexisting style — do **not** "fix" them.
- **Git**: commit messages in Spanish as `type(vX.Y.Z): descripción`; do **not** add a `Co-Authored-By` trailer; `config.json`, `config.debug.json`, `Proceso\` and `tools\` are gitignored (never commit them). One logical change per commit — don't amend or squash — and ask before committing or pushing.
