# extras

Los lanzadores que **no** son del día a día. En el raíz se quedan los cuatro que se usan a diario
(`Convert.cmd`, `Convert-gui.cmd`, `setup.cmd`, `setup-gui.cmd`); estos viven aquí para no llenarlo.

Funcionan igual desde esta carpeta: cada uno llega al programa con `..\bin\`, así que se pueden
lanzar con doble clic sin moverlos (y se les puede hacer un acceso directo donde quieras).

| Fichero | Qué hace |
|---|---|
| `Convert-gui-Config.cmd` | La **cola en ventana preguntando** con qué `config*.json` trabajar. Es `Convert-gui.cmd -AskConfig`; lo mismo se consigue **manteniendo Mayús** mientras arranca el normal (`gui.askConfigKey`). Ver [ref-cola.md](../docs/ref-cola.md). |
| `Convert-Debug.cmd` | El conversor con `config\config.debug.json` (`behavior.debug = true`): **log detallado** —comandos de ffmpeg y pasos internos— sin tocar tu `config.json`. Ese `-Config` se reenvía a las ventanas worker, así que todas corren en debug. Ver [ref-configuracion.md](../docs/ref-configuracion.md). |
| `FixSyncSub.cmd` | Arreglar y **sincronizar subtítulos `.srt` sueltos**: doble clic (te lista los de `Original\`) o arrastra un `.srt` encima. Ver [ref-fixsyncsub.md](../docs/ref-fixsyncsub.md). |
