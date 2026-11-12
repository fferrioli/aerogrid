# Fase 1 — Confianza

**Objetivo.** El setup sobrevive a reinicios y relanzamientos, el usuario ve y puede deshacer lo que AeroGrid hace solo, y la app deja de sondear a ciegas. Puntaje objetivo: 6,3.

**Requisito.** Fase 0 mergeada y con la prueba de una noche superada.

A diferencia de la Fase 0, acá hay diseño por resolver. Cada bloque empieza con un **paquete de diseño `[ORQ]`** que termina en una nota de decisión (`docs/plan/decisiones/F1-n.md`, una página: opciones, elegida, por qué, modelo de datos, casos de borde) y en las fichas de implementación para subagentes, con el mismo formato que las de la Fase 0 (archivos, especificación, tests, verificación). El orquestador no delega implementación hasta que la nota existe.

Referencia visual: [`demo/proposals/ux-propuesta.html`](../../demo/proposals/ux-propuesta.html), escenas 1 (estado «en reposo»), 2 (el setup vuelve) y 5 (avisos con deshacer).

Sugerencia de PRs: F1-0 solo · F1-1+F1-2 · F1-3 · F1-4 · F1-5+F1-6.

---

## F1-0 · Firma local estable `[ORQ]` + `[HUM]` — hacer primero

**Problema.** Cada instalación con binario distinto reinicia Accesibilidad (`reset_changed_adhoc_permissions` en `scripts/install.py`), porque la firma ad-hoc identifica al binario por su hash. Todas las fases siguientes instalan varias veces.

**Propuesta.** Firmar las dos apps con un certificado de firma de código autofirmado, creado una vez en el llavero de inicio de sesión del usuario. La identidad pasa a ser el certificado, no el hash, y el permiso persiste entre recompilaciones. Es la técnica que documenta yabai para el mismo problema.

**Decisión `[HUM]`.** Requiere crear un certificado en el llavero del usuario. Hoy la documentación afirma que la actualización «nunca cambia la política de seguridad de macOS»; esto no la cambia, pero agrega un paso de configuración que el usuario debe aceptar explícitamente. Default si acepta: paso opcional y explícito (`scripts/setup-signing.py`), nunca automático; sin certificado todo sigue como hoy.

**Trabajo.**
- `[ORQ]` Prueba de concepto fuera de la instalación real: dos builds distintos firmados con el mismo certificado ⇒ mismo requisito designado (`codesign -d -r-`). Confirmar con una app de prueba que el permiso persiste antes de tocar el instalador.
- `[SUB-impl]` Instalador y worker de actualización: usar la identidad si existe; no reiniciar TCC cuando el requisito designado no cambió; tests en `Tests/InstallerTests` y `Tests/UpdateTests` (ya firman productos reales en un home temporal).
- `[ORQ]` Docs: `README.md`, `BUILD-ON-ANOTHER-MAC.md`, `docs/updates.es.md`.

**Hecho cuando:** dos instalaciones seguidas con código distinto no piden re-aprobar Accesibilidad, verificado en vivo.

---

## F1-1 · Lugares por app

**Problema.** El mapa referencia ventanas por (ID, PID, arranque) y `LayoutSnapshot` caduca con el arranque. Tras reiniciar no queda nada que restaurar.

**Diseño `[ORQ]`.** Definir:
- **Modelo.** Por espacio, una plantilla de distribución cuyas hojas son (bundle ID, ordinal entre ventanas de esa app en el espacio) en vez de IDs de ventana, más «estaba en fullscreen». Se actualiza cuando cambia la distribución real. Campo opcional y versionado en `SpaceMap`.
- **Emparejamiento.** Función pura: (ventanas actuales sin lugar, plantillas con huecos libres) → asignaciones. Reglas para varias ventanas de la misma app y para ventanas que ya estaban ubicadas.
- **Cuándo actuar.** Decisión `[HUM]`: (a) automático al aparecer la ventana, (b) solo con «Restaurar», (c) automático durante los primeros minutos tras iniciar sesión y manual después. Default propuesto: (c).
- **Precedencia.** Las reglas `on-window-detected` del `~/.aerospace.toml` del usuario mandan sobre el emparejamiento: el instalador se compromete a preservarlas.
- **Fullscreen.** Reaplicar con el comando existente `macos-native-fullscreen --window-id` solo si la plantilla lo indica y la ventana quedó ubicada.

**Implementación `[SUB-impl]`** (fichas a escribir tras el diseño): modelo y migración · emparejador puro con tests de tabla · captura de plantilla al cambiar distribución · aplicación en `refresh()` con movimientos verificados (`moveVerified`) y reversión ante fallo · eventos `place-restored`.

**Invariantes.** Reiniciar y abrir las mismas apps deja el mapa equivalente al anterior. Ninguna ventana se mueve dos veces por la misma regla. Una ventana que el usuario mueve a mano no vuelve sola a su lugar anterior.

**Aceptación física `[HUM]`.** Reinicio real de la Mac con el setup de trabajo.

---

## F1-2 · Setups con nombre

Depende de F1-1 (misma plantilla).

**Diseño `[ORQ]`.** Guardar el mapa actual como setup con nombre; aplicarlo reacomoda espacios y pide abrir las apps que faltan. UI: selector en el encabezado del organizador y en el menú de la barra. Decidir qué pasa con ventanas que no pertenecen al setup (default: quedan donde están). Undo de «aplicar setup» en un solo paso.

**Implementación.** `[SUB-impl]` almacenamiento y aplicación transaccional (reutilizar `PendingOrganization`). `[ORQ]` vistas SwiftUI.

---

## F1-3 · Estado visible y cambios automáticos con deshacer

**Diseño `[ORQ]`.**
- Tarjeta «en reposo» para ventanas fullscreen diferidas o en duda (los estados ya existen desde la Fase 0); clic = activar su Space.
- Aviso breve no modal por cada cambio automático relevante (espacio adoptado, ventana ubicada por regla, lugar restituido), con una acción: deshacer o corregir.
- Historial legible en el menú: últimos N eventos traducidos a frases.
- Qué eventos merecen aviso y cuáles solo historial: lista cerrada en la nota de decisión.

**Implementación.** `[SUB-impl]` convertir los eventos de texto de la Fase 0 en un tipo `MapEvent` con casos y datos; puntos de control de Undo para cambios automáticos, sin mezclar con el Undo de organización manual (decidir en el diseño: pila separada o etiquetada). `[ORQ]` vistas, textos y tiempos del aviso.

**Invariantes.** Ningún cambio automático visible ocurre sin evento. Deshacer un cambio automático no pisa una edición manual posterior (mismo criterio que el Undo actual).

---

## F1-4 · Menos sondeo

**Problema.** Cada 2 s: unas 6 llamadas `grid-layout status` y un `snapshot` por espacio ocupado, cada una lanzando un proceso.

**Etapas, cada una mergeable por separado:**
1. `[SUB-impl]` **Camino rápido.** Una sola llamada `status` por ciclo; si el inventario es igual al anterior (comparación semántica, ya existe para snapshots), terminar sin más llamadas ni `persist()`. Test: N ciclos sin cambios ⇒ 1 llamada por ciclo (extender `IdleRefreshTests`, que ya cuenta llamadas en `MapBackend.calls`).
2. `[ORQ]` **Exploración.** El backend fijado ya tiene suscripción a eventos (`vendor/AeroSpace/Sources/AppBundle/subscriptions.swift`, `server.swift`). Determinar qué eventos emite, si alcanzan (ventana detectada, foco, workspace) y qué habría que agregar del lado `Grid*`. Nota de decisión.
3. `[SUB-impl]` **Cliente de socket persistente** en lugar de `Process` por comando, detrás de la misma interfaz `Backend`, con el CLI como respaldo.
4. `[SUB-impl]` **Refresco por eventos** más un latido lento (10–15 s) como red de seguridad.

**Invariantes.** Latencia de navegación igual o mejor (`NavigationPerformanceTests`). La compuerta de la Fase 0 sigue mandando. `--benchmark-idle` no empeora.

---

## F1-5 · Persistencia liviana `[SUB-impl]`

- Historial de Undo a un archivo propio (`undo.json`), cargado al usarse; `state.json` sin él.
- Escribir solo cuando cambió el contenido semántico, sin leer el archivo anterior entero en cada ciclo (guardar un resumen en memoria).
- Migración: el primer arranque separa el historial y deja respaldo; un estado viejo se sigue leyendo.
- Tests: ida y vuelta, migración, archivo de Undo corrupto ⇒ se descarta el historial y el mapa se conserva.

## F1-6 · Higiene del mapa

**Diseño `[ORQ]`.** Criterio para eliminar espacios dormidos que ya no tienen sentido (sin ventanas, sin relaciones, no creados por el usuario, que no son celdas de la grilla importada) y para los nombres: nunca mostrar un nombre técnico de workspace (`grid-space-…`); derivarlo de las apps o usar «Espacio».

**Implementación `[SUB-impl]`.** Reparación idempotente con respaldo previo, mismo patrón que `repairAdaptedGeometryIfNeeded`. Las verificaciones en vivo (`--verify-dynamic-fixtures` y scripts `live-*`) usan un directorio de estado propio para que sus espacios no lleguen al mapa real.

## F1-7 · Extraer el reconciliador `[SUB-impl]`, oportunista

Al tocar `DynamicEngine` en F1-1 y F1-3, mover sin cambiar comportamiento la reconciliación de fullscreen y la de topología a archivos propios (extensiones o tipos colaboradores). Un commit de solo movimiento, con la suite en verde antes y después. No es un objetivo en sí: si no simplifica el paquete en curso, no se hace.
