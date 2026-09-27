@echo off
REM Lanzador de Convert-gui.ps1: la COLA de conversion en VENTANA, en vez de varias consolas.
REM Va DIRECTO al config\config.json (se pasa -Config explicito, por eso no pregunta
REM nada al abrir). Para elegir con que configuracion trabajar, usa Convert-gui-Config.cmd.
REM -Sta: WinForms necesita un hilo STA (powershell.exe ya lo es; se fija explicito).
REM -WindowStyle Hidden: oculta esta consola, que aqui solo hace de anfitriona de la ventana.
REM Los workers son procesos aparte; con la casilla "Ver las consolas" se abren a la vista.
REM chcp 65001 pone la consola en UTF-8 (el log de la sesion sale en UTF-8).
chcp 65001 >nul
REM El config vive en config\; si vienes de una version anterior y aun lo tienes
REM en la raiz, se usa ese en vez de arrancar con los valores de fabrica.
set "CV_CFG=%~dp0config\config.json"
if not exist "%CV_CFG%" if exist "%~dp0config.json" set "CV_CFG=%~dp0config.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0bin\Convert-gui.ps1" -Config "%CV_CFG%" %*
