@echo off
REM Lanzador de Convert-gui.ps1: la COLA de conversion en VENTANA, en vez de varias consolas.
REM Va DIRECTO al config.json de junto al programa (se pasa -Config explicito, por eso no pregunta
REM nada al abrir). Para elegir con que configuracion trabajar, usa Convert-gui-Config.cmd.
REM -Sta: WinForms necesita un hilo STA (powershell.exe ya lo es; se fija explicito).
REM -WindowStyle Hidden: oculta esta consola, que aqui solo hace de anfitriona de la ventana.
REM Los workers son procesos aparte; con la casilla "Ver las consolas" se abren a la vista.
REM chcp 65001 pone la consola en UTF-8 (el log de la sesion sale en UTF-8).
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0Convert-gui.ps1" -Config "%~dp0config.json" %*
