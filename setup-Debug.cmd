@echo off
REM Lanzador de setup.ps1 apuntando a config.debug.json, para EDITAR/gestionar ese config de
REM depuracion (behavior.debug = true) con el editor de setup, sin tocar tu config.json normal.
REM Igual que setup.cmd pero fijando -Config al config de depuracion. Se le pueden pasar mas args.
chcp 65001 >nul
REM El config vive en config\; si vienes de una version anterior y aun lo tienes
REM en la raiz, se usa ese en vez de arrancar con los valores de fabrica.
set "CV_CFG=%~dp0config\config.debug.json"
if not exist "%CV_CFG%" if exist "%~dp0config.debug.json" set "CV_CFG=%~dp0config.debug.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\setup.ps1" -Config "%CV_CFG%" %*
echo.
pause
