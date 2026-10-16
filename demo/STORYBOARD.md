# AeroGrid · demo «Opus» — storyboard

Recreación animada (motion design), 80 s, 1920×1080, 30 fps, sin audio. Etiqueta fija «Recreación animada de AeroGrid».
Historia: una persona trabaja en una tienda online ficticia. Va del código a la documentación y al chat sin buscar ventanas; después ordena su mapa para que el chat le quede a un gesto.

| Tiempo | Escena | Qué se ve | Rótulo |
|---|---|---|---|
| 0–4 s | Título | Logo 3×3, «AeroGrid», «Tus espacios de trabajo, ordenados como un mapa.» | — |
| 4–8 s | Un espacio por tarea | MacBook con Editor + Terminal; la terminal corre `npm test` | Acá: el editor y la terminal del proyecto. |
| 8–12.6 s | Mapa fijo (esquema) | La pantalla se aleja y aparecen los seis espacios en su lugar; «Estás acá» | Cada espacio tiene su lugar… |
| 12.6–19.5 s | Gesto corto · 3 dedos | Trackpad: deslizar a la derecha. El mapa asoma un instante con «Navegador» elegido; al levantar, se abre la documentación | Deslizá y pasás al espacio de al lado. |
| 19.5–27 s | Mantené y explorá | Dedos apoyados: el mapa marca Música, luego Chat. El escritorio sigue en Navegador | Dedos apoyados… / Tu escritorio no cambia mientras elegís. |
| 27–33 s | Soltá | Al levantar se abre Chat (el último destino); la persona responde | Al levantar los dedos, abrís el último destino. |
| 33–36 s | Abrir el organizador | El puntero llega al centro del borde superior (anillo de espera) y aparece «Tus espacios» | Llevá el puntero al centro del borde superior. |
| 36–46 s | Ordenar apps | Se arrastra el ícono de Navegador sobre Terminal: centro = «Apilar», borde = «Arriba»; al soltar, Editor · (Navegador / Terminal). Queda «Espacio vacío» | Soltá en el centro… / …o en un borde… |
| 46–54.5 s | Mover un espacio | Se arrastra el encabezado ⠿; «Intercambiar espacios» sobre Música; el casillero viaja con su distribución y queda debajo de Chat (↓). Tooltip «Deshacer organización» | Arrastrá el encabezado… / Ahora queda justo debajo del chat. |
| 54.5–59 s | Abrir | Clic en el editor del casillero: el escritorio coincide con el dibujo del mapa | Un clic y estás ahí… |
| 59–65 s | A un gesto | 3 dedos hacia arriba: del código al chat | El chat quedó arriba… |
| 65–74 s | Dos pantallas · 4 dedos | Monitor externo + MacBook, cada uno con su tablero; con 4 dedos cambian los dos | 3 dedos: la pantalla bajo el puntero; 4, las dos. |
| 74–80 s | Cierre | «Deslizá → Mantené → Soltá» y «Y ordenás tus apps y espacios arrastrando…» | — |

## Criterios de fidelidad
- Panel, mapa de navegación y vistas previas siguen `OrganizerView.swift`, `MiniLayoutView.swift`, `SpaceDrop.swift` y `MapPresentation.swift`: unidad 230×152, íconos (sin miniaturas), «Soltá para abrir», origen con punto, «Apilar»/«Arriba», «Intercambiar espacios», «Deshacer organización».
- Solo se arrastra dentro del organizador; nunca una ventana real del escritorio.
- El escritorio cambia únicamente al levantar los dedos o al hacer clic; el mapa del gesto no cambia escritorios.
- No aparecen AeroSpace, nombres técnicos de workspaces ni contenido real del usuario. Nombres, conversaciones y datos son ficticios.
- El cambio de espacio se muestra como un fundido corto (~0,14 s), no como un desplazamiento lateral.
- El trackpad, los rótulos, el anillo de espera y el mapa conceptual inicial son capa explicativa, no UI de la app.
