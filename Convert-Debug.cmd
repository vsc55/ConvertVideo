@echo off
REM Lanzador de Convert.ps1 en modo DEBUG: usa config.debug.json (behavior.debug = true),
REM que muestra el log detallado (comandos de ffmpeg y pasos internos) en vez de la vista compacta.
REM Igual que Convert.cmd pero fijando -Config al config de depuracion; ese -Config se reenvia
REM tambien a las ventanas worker que se abran en paralelo, asi que todas corren en debug.
REM Se le pueden pasar mas argumentos (p. ej. -WorkerOnly), que se anaden tras el -Config.
chcp 65001 >nul
REM El config vive en config\; si vienes de una version anterior y aun lo tienes
REM en la raiz, se usa ese en vez de arrancar con los valores de fabrica.
set "CV_CFG=%~dp0config\config.debug.json"
if not exist "%CV_CFG%" if exist "%~dp0config.debug.json" set "CV_CFG=%~dp0config.debug.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\Convert.ps1" -Config "%CV_CFG%" %*
echo.
pause
