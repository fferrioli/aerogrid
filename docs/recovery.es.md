# Recuperar «Los espacios adaptados se superponen»

Este error corresponde a posiciones incompatibles en el mapa usado al adaptar los espacios a una sola pantalla. No significa que debas cerrar las apps ni borrar tu configuración. En versiones anteriores, un espacio oculto podía reaparecer conservando una posición adaptada que ya estaba ocupada. La actualización del mapa fallaba y el mismo problema podía repetirse después de reiniciar.

La versión corregida reconstruye las posiciones adaptadas en conflicto al cargar o recuperar el mapa, con un backup previo. Un espacio que reaparece deja de reservar su antigua posición adaptada. Las posiciones válidas de los otros espacios y sus distribuciones se conservan.

## Desbloquear una instalación anterior sin compilar

El recuperador es un script de Python 3.9+. No necesita administrador, cambiar Accessibility, firmar aplicaciones ni reinstalar el backend. No usa la red ni sube datos. No ejecuta comandos para mover o cerrar ventanas.

**Dejá AeroGrid abierto.** Desde la carpeta del repositorio actualizado:

```sh
python3 scripts/recover-spatial-map.py --apply --stop-controller
```

El script:

1. Comprueba que la estructura del estado sea compatible y que no haya una operación de ventanas pendiente.
2. Detiene únicamente los procesos verificados de la interfaz AeroGrid de tu usuario. El backend sigue funcionando.
3. Lee del backend las ventanas, las pantallas y las distribuciones actuales.
4. Conserva una copia exacta del estado anterior y copias de configuración en `~/Library/Application Support/AeroGrid/backups/spatial-recovery-…`.
5. Mantiene las posiciones adaptadas válidas y libera las conflictivas o antiguas de espacios ocultos para que se reconstruyan. Conserva los identificadores, workspaces, grupos y el historial. Actualiza el inventario y las distribuciones guardadas con la observación actual del backend.
6. Escribe el estado de forma atómica y se niega a sobrescribirlo si detecta que AeroGrid volvió a abrirse o que otro proceso lo cambió.

Los grupos adaptados que ya existían quedan protegidos para que la reapertura no los recombine desde una distribución antigua. Podés usar **Reunir grupo** si querés unirlos después. En una MacBook sin monitor externo, se conserva la agrupación actual durante esa sesión; al reconectar se restablece la adaptación habitual.

Luego abrí AeroGrid:

```sh
open "$HOME/Applications/AeroGrid.app"
```

Si el script muestra un error, conservá el mensaje. Si la interfaz quedó cerrada, podés volver a abrirla; el script no elimina apps, ventanas ni el estado anterior. Una operación pendiente o un estado de otra versión requieren otra recuperación: el script los conserva y se detiene.

## Diagnóstico sin cambios

```sh
python3 scripts/recover-spatial-map.py
```

Muestra sólo cantidades de espacios y posiciones a reconstruir. No modifica archivos ni detiene procesos. No hace falta compartir `state.json`, títulos de ventanas, configuración laboral ni capturas de tus apps para usarlo.

## Instalar la corrección permanente

El script sirve para desbloquear la build existente. Para incorporar la prevención automática, actualizá y compilá el código siguiendo [la guía de instalación local](../BUILD-ON-ANOTHER-MAC.md). Un cambio de firma de la app puede exigir renovar Accessibility como en otras actualizaciones.

El script y las pruebas automáticas no confirman por sí solos la recuperación en otra Mac. Después de abrir AeroGrid, comprobá que podés navegar, mover una ventana, reordenar un espacio y volver a abrir la app.
