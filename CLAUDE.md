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
- **E2E battery** (runs the real `Convert.ps1` worker over `test\` fixtures and verifies each output with ffprobe):
  - `powershell -ExecutionPolicy Bypass -File test\run-tests.ps1` — GPU (`hevc_nvenc`)
  - `... -Encoder libx265` — CPU/portable (no NVENC)
  - `... -OnePass` — exercise the one-pass path
  - `... -Keep` — don't delete the isolated temp work area
- **Run the app**: `Convert.cmd` (convert), `setup.cmd` (tools + config editor), `FixSyncSub.cmd` (`.srt` fixer). `*-Debug.cmd` variants use `config.debug.json`. Launchers accept `-Config <path>`.

Consider a change done only after verifying empirically: **AST-parse + unit-tests + the E2E battery for the path you touched** (staged and/or `-OnePass`). The batteries are the real safety net.

## Architecture

- **Model: PREPARE → WORKER** (`Convert.ps1`). Inputs come from `Original\`. PREPARE asks/detects per file (video track, black borders, resize, anamorphic, audio + language, sync, subtitles) and **freezes** it in `Proceso\<name>.job.json`. WORKER encodes unattended → `Convertido\<name>_fix.mkv`. When everything has a job, several `Convert.cmd` windows run in parallel, each claiming files via an atomic lock.

- **Two encode paths, one decision source.** The *staged* pipeline (audio → video → multiplex: 3 ffmpeg processes + temporals) and the *one-pass* beta (`test.betaOnePass`: a single ffmpeg with `-filter_complex`) both derive every decision from the SAME render spec — `Resolve-CvRenderSpec` (`Render.psm1`) — and only the EMISSION differs. The command builders are **pure and golden-tested**: `Get-CvOnePassArgs` (`OnePass.psm1`), `Get-CvMultiplexArgs`/`Get-CvSubtitleMapArgs` (`Multiplex.psm1`), `Get-CvVideoRunArgs` (`Video.psm1`), `Get-CvAudioEncodeArgs` (`Audio.psm1`). Put "what to do" in the spec, not in each emitter, and keep the two paths in sync — the golden tests (exact ffmpeg arg-string match) enforce it, so update them deliberately when args change.

- **Single sources of truth.** `Get-CvConfigDefaults` (`Config.psm1`) is the one place for every config default; `config.json` only overrides. `New-CvContext` builds `$ctx` (a read-only settings bag) from the merged config and is passed almost everywhere. `Get-CvVersion` (`Context.psm1`) is the version (bump it and its unit test together). Enum catalogs (encoders/levels/modes) are functions returning `@{ Value; Text }` — reuse them, never inline the lists.

- **Config shape.** Nested `encode.video` / `encode.audio` / `encode.subtitles` (plus root `threads`/`extensions`/`outputExtension`). Per-file choices live in the **job**, not in config. Filename prefixes drive behavior: `_` forces border detection; `TEST_` re-prepares from scratch (deletes its stale job at startup) except under `-WorkerOnly`.

- **Modules (`lib\*.psm1`).** Each does `Export-ModuleMember -Function *`; cross-module calls resolve at **call time**, so the load order in `Convert.ps1`/`setup.ps1`/the test runners doesn't gate references. Layering to respect: Config = base; Profile = pipeline (Profile may use Config, not the reverse); **Context is base and must not depend on Profile**.

- **Tools.** Versioned under `tools\<app>\<version>\<platform>`, auto-downloaded and SHA256-verified (ffmpeg, aacgain, `mkvtoolnix` → `mkvpropedit` + `mkvextract`, `7zr`). The exact version is frozen per job for reproducibility; the worker installs it if missing.

- **Docs (`docs\`).** Prefix = type: `ref-` (reference), `explica-` (how/why + diagrams), `caso-` (postmortem). `explica-` docs carry mermaid diagrams for flows. Each cross-cutting fact has ONE canonical home; other docs link instead of duplicating. `docs\README.md` is the index. `docs\ref-gotchas.md` collects real bugs already hit — read it before touching those areas.

## Conventions

- **PowerShell 5.1 gotchas** (see `docs\ref-gotchas.md`): use `InvariantCulture` for any decimal that reaches ffmpeg (es-ES writes `,` and breaks filters); `[int]` rounds banker's; `[math]::Max` on mixed int/decimal misbehaves; `scale=-1` can yield odd dimensions.
- **Everything configurable, no magic numbers.** A new tunable or behavior gets a key in `Get-CvConfigDefaults` (with help text, and usually a unit test for the default) and is read via `$ctx` — never a hardcoded literal in the logic. Enforced in review (e.g. `behavior.promptTimeout.*`, `preview.syncSeconds`, `encode.subtitles.toSrt`).
- **Never hardcode real user video filenames** in code, docs or tests — use generic examples.
- **Arrays/hashtables: one value per line** (repo style — applies to return objects, config defaults, catalogs and test fixtures).
- **changelog.md**: add an entry with every change, newest first, under a `## VERSION x.y.z - dd/mm/yyyy` section. Markdown-lint warnings in `changelog.md`/`docs\` are preexisting style — do **not** "fix" them.
- **Git**: commit messages in Spanish as `type(vX.Y.Z): descripción`; do **not** add a `Co-Authored-By` trailer; `config.json`, `config.debug.json`, `Proceso\` and `tools\` are gitignored (never commit them). One logical change per commit — don't amend or squash — and ask before committing or pushing.
