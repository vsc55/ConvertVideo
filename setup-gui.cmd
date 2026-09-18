@echo off
REM Lanzador de setup-gui.ps1: el mismo setup que setup.cmd, pero en VENTANA.
REM -Sta: WinForms necesita un hilo STA (powershell.exe ya lo es por defecto; se fija explicito).
REM -WindowStyle Hidden: oculta esta consola, que aqui solo hace de anfitriona de la ventana.
REM Las acciones largas (instalar, tests) abren su PROPIA consola para ver el progreso.
REM chcp 65001 pone la consola en UTF-8 (el log de la sesion sale en UTF-8).
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0setup-gui.ps1" %*
