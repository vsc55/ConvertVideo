@echo off
REM Lo mismo que Convert-gui.cmd (la COLA de conversion en VENTANA) pero PREGUNTANDO primero con que
REM configuracion trabajar: lista los config*.json que haya junto al programa (config.json,
REM config.debug.json, ...) y deja buscar otro en disco. Es el equivalente de tener que elegir entre
REM Convert.cmd y Convert-Debug.cmd, sin cambiar de lanzador.
REM La pregunta sale justo porque aqui NO se pasa -Config; con el si (Convert-gui.cmd) va directo.
REM -Sta: WinForms necesita un hilo STA (powershell.exe ya lo es; se fija explicito).
REM -WindowStyle Hidden: oculta esta consola, que aqui solo hace de anfitriona de la ventana.
REM chcp 65001 pone la consola en UTF-8 (el log de la sesion sale en UTF-8).
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0Convert-gui.ps1" %*
