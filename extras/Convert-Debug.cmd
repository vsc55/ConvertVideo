@echo off
REM Lanzador de Convert.ps1 en modo DEBUG: usa config.debug.json (behavior.debug = true),
REM que muestra el log detallado (comandos de ffmpeg y pasos internos) en vez de la vista compacta.
REM Igual que Convert.cmd pero fijando -Config al config de depuracion; ese -Config se reenvia
REM tambien a las ventanas worker que se abran en paralelo, asi que todas corren en debug.
REM Se le pueden pasar mas argumentos (p. ej. -WorkerOnly), que se anaden tras el -Config.
REM Vive en extras\ y no en el raiz (es una VARIANTE del lanzador normal): por eso todo va con ..\.
chcp 65001 >nul
REM El config vive en config\; si vienes de una version anterior y aun lo tienes
REM en la raiz, se usa ese en vez de arrancar con los valores de fabrica.
set "CV_CFG=%~dp0..\config\config.debug.json"
if not exist "%CV_CFG%" if exist "%~dp0..\config.debug.json" set "CV_CFG=%~dp0..\config.debug.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\bin\Convert.ps1" -Config "%CV_CFG%" %*
echo.
pause
