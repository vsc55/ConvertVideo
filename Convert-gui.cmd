@echo off
REM Lanzador de Convert-gui.ps1: la COLA de conversion en VENTANA, en vez de varias consolas.
REM Va DIRECTO a la configuracion de siempre, sin preguntar nada al abrir. Para elegir otra:
REM Convert-gui-Config.cmd, o MANTENER Mayus mientras arranca esta (configurable en
REM gui.askConfigKey: shift / ctrl / any / off). Con -Config <ruta> va directo a esa y punto.
REM -Sta: WinForms necesita un hilo STA (powershell.exe ya lo es; se fija explicito).
REM -WindowStyle Hidden: oculta esta consola, que aqui solo hace de anfitriona de la ventana.
REM Los workers son procesos aparte; con la casilla "Ver las consolas" se abren a la vista.
REM chcp 65001 pone la consola en UTF-8 (el log de la sesion sale en UTF-8).
chcp 65001 >nul
REM Cual es "la de siempre" lo decide el script (config\config.json, y el de la raiz si vienes
REM de una version anterior): aqui no se repite esa regla.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0bin\Convert-gui.ps1" %*
