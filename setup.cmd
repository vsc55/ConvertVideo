@echo off
REM Lanzador de setup.ps1 sin tener que tocar la ExecutionPolicy del sistema.
REM Gestiona las herramientas (versiones de ffmpeg, aacgain...) y edita la configuracion.
REM Al arrancar PREGUNTA con que config*.json trabajar (ENTER = config\config.json, y ahi
REM aparece tambien config.debug.json): por eso hay un solo lanzador y no uno por config.
REM Se le pueden pasar argumentos: -Config <ruta> va directo, sin preguntar.
REM chcp 65001 pone la consola en UTF-8 para que se vean bien los cuadros (marcos).
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\setup.ps1" %*
echo.
pause
