@echo off
REM Lanzador de Convert.ps1 sin tener que tocar la ExecutionPolicy del sistema.
REM chcp 65001 pone la consola en UTF-8 para que se vean bien los cuadros (marcos).
REM El tamano de la ventana, la fuente y los colores se configuran en config.json.
REM Se puede abrir en varias ventanas a la vez: cuando todos los archivos tienen su
REM .job, cada ventana entra como worker y se reparten los archivos por el lock.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\Convert.ps1" %*
echo.
pause
