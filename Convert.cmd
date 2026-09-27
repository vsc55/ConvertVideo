@echo off
REM Lanzador de Convert.ps1 sin tener que tocar la ExecutionPolicy del sistema.
REM Va DIRECTO a la configuracion de siempre. Para elegir otra: -Config <ruta>, o MANTENER
REM Mayus mientras arranca (configurable en gui.askConfigKey: shift / ctrl / any / off), que
REM saca la misma lista que setup. En modo worker (-WorkerOnly) nunca pregunta.
REM chcp 65001 pone la consola en UTF-8 para que se vean bien los cuadros (marcos).
REM El tamano de la ventana, la fuente y los colores se configuran en config.json.
REM Se puede abrir en varias ventanas a la vez: cuando todos los archivos tienen su
REM .job, cada ventana entra como worker y se reparten los archivos por el lock.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\Convert.ps1" %*
echo.
pause
