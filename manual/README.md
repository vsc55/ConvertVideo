# Manual de uso — ConvertVideo

Cómo se usa el programa **con ventanas**: preparar las herramientas, decidir qué se le hace a cada vídeo y codificar la cola viendo el progreso. Con capturas de las pantallas de verdad.

Esto es el "qué veo y qué hago". Si lo que buscas es **cómo funciona por dentro** (flujos, comandos exactos de ffmpeg, formato del job, referencia de `config.json` clave a clave), eso vive en [`docs/`](../docs/README.md) y desde aquí se enlaza donde toca.

## El camino corto

1. Copia tus vídeos en la carpeta **`Original\`**.
2. Doble clic en **`Convert-gui.cmd`**.
3. **`Preparar pendientes`** → **`Iniciar`**.

El resultado aparece en **`Convertido\`** como `<nombre>_fix.mkv`. Todo lo demás de este manual es para cuando ese camino corto no basta: elegir pistas, recortar bandas negras, corregir la sincronía del audio, repartir el trabajo entre varios workers o averiguar por qué un archivo se ha quedado a medias.

![La cola de conversión](img/cola.png)

## Índice

| Página | Qué cuenta |
|---|---|
| [1. Primeros pasos](01-primeros-pasos.md) | Qué lanzador abrir, las carpetas de trabajo, instalar FFmpeg y compañía, y editar la configuración sin tocar el JSON a mano. |
| [2. Preparar: decidir qué se le hace a cada vídeo](02-preparar.md) | El perfil, el recorrido de *Preparar pendientes* y el editor del job (vídeo, audio, subtítulos). |
| [3. Convertir: la cola en marcha](03-convertir.md) | La ventana de la cola: columnas, estados, barra de herramientas, workers en paralelo, log en vivo y el proceso de cada archivo. |
| [4. Cuando algo no sale](04-cuando-algo-falla.md) | Archivos "sin terminar", bloqueos huérfanos, logs, limpieza de `Proceso\` y los avisos más típicos. |

## Sobre las capturas

Las imágenes de `manual\img\` **no se hacen a mano**: las genera [`generar-capturas.ps1`](generar-capturas.ps1), que abre las ventanas de verdad sobre una carpeta de trabajo de mentira y las retrata una a una.

```powershell
powershell -ExecutionPolicy Bypass -Sta -File manual\generar-capturas.ps1
powershell -ExecutionPolicy Bypass -Sta -File manual\generar-capturas.ps1 -Only cola,setup
```

Los vídeos que salen en ellas son las muestras de `test\` copiadas con nombres inventados (`Serie_1x01`…): en las capturas **no aparece material de nadie**. Al cambiar una ventana, se regenera el grupo que toque en vez de recortar pantallazos sueltos.

Las imágenes se le piden a **cada ventana** (no a la pantalla), así que se puede seguir trabajando en el equipo mientras corren. La única que necesita que no se toque nada es la del **menú contextual desplegado**, porque un menú es una ventana emergente aparte y solo se puede fotografiar de la pantalla; si en ese momento la ventana no está delante, el script avisa.
