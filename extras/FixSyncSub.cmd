@echo off
REM Lanza FixSyncSub.ps1 con la politica de ejecucion en Bypass (no cambia la del sistema).
REM Uso: doble clic y te pide/lista los .srt de Original\, o arrastra un .srt sobre este .cmd.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\bin\FixSyncSub.ps1" "%~1"
echo.
pause
