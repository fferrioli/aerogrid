# Fase 1 — Confianza

**Objetivo.** El setup sobrevive a reinicios y relanzamientos, el usuario ve y puede deshacer lo que AeroGrid hace solo, y la app deja de sondear a ciegas. Puntaje objetivo: 6,3.

**Requisito.** Fase 0 mergeada y con la prueba de una noche superada.

A diferencia de la Fase 0, acá hay diseño por resolver. Cada bloque empieza con una **tarea de diseño `[ORQ]`** que termina en una nota de decisión (`docs/plan/decisiones/F1-n.md`, una página: opciones, elegida, por qué, modelo de datos, casos de borde) y en las fichas de implementación para subagentes, con el mismo formato que las de la Fase 0 (archivos, especificación, tests, verificación). El orquestador no delega implementación hasta que la nota existe.

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

Al tocar `DynamicEngine` en F1-1 y F1-3, mover sin cambiar comportamiento la reconciliación de fullscreen y la de topología a archivos propios (extensiones o tipos colaboradores). Un commit de solo movimiento, con la suite en verde antes y después. No es un objetivo en sí: si no simplifica la tarea en curso, no se hace.

---

## F1-0 · Fichas

Diseño en `docs/plan/decisiones/F1-0.md`. Contrato común: nombre de la identidad `AeroGrid Local Code Signing`; búsqueda con `security find-identity -p codesigning` (sin `-v`: el certificado no es de confianza y está bien), filas `N) <SHA1> "<nombre>"…` con el nombre exacto.

### F1-0a · `scripts/setup-signing.py` `[SUB-impl]` · tamaño S

**Archivos.** `scripts/setup-signing.py` (nuevo), `Tests/InstallerTests/test_setup_signing.py` (nuevo).

**Especificación.**
1. Sin argumentos: si la identidad ya existe en el llavero destino, informarlo y salir 0 sin cambios. Si no: en un `tempfile.TemporaryDirectory` con permisos 0700, generar con `/usr/bin/openssl` (ruta absoluta) una clave RSA 2048 y un certificado autofirmado de 3650 días con `basicConstraints = critical, CA:false`, `keyUsage = critical, digitalSignature`, `extendedKeyUsage = critical, codeSigning` y CN igual al nombre; exportar PKCS#12 con una contraseña aleatoria de un solo uso (`secrets`); importar con `security import <p12> -k <llavero> -P <contraseña> -T /usr/bin/codesign`. La contraseña nunca va a la salida ni a registros. Los temporales se borran siempre.
2. Llavero destino: por defecto el de inicio de sesión (`security default-keychain -d user`); `--keychain PATH` lo reemplaza (lo usan los tests).
3. Verificación final (solo con el llavero por defecto): firmar una copia de `/usr/bin/true` en un temporal con la SHA-1 de la identidad y comprobar que `codesign -d -r-` contiene `certificate leaf`. Si falla, informar y salir distinto de 0 (la identidad queda; `--remove` la borra).
4. `--status`: imprime si existe y su SHA-1; sale 0 si existe, 1 si no. `--remove`: borra la identidad (`security delete-identity -Z <sha1> <llavero>`) si existe; idempotente.
5. Mensajes en inglés, cortos; sin rutas personales salvo la del llavero. Nunca lo llaman `install.py`, `update-worker.py` ni `uninstall.py`.

**Reproducción primero.** No aplica (archivo nuevo): escribir los tests primero y verlos fallar por el script inexistente.

**Tests (`test_setup_signing.py`, con un llavero temporal creado por el test con `security create-keychain` y borrado al final; nunca el del usuario).** Crear ⇒ `find-identity -p codesigning <llavero>` lista exactamente una con el nombre; segunda ejecución ⇒ sin cambios y sigue una; `--status` 0 con la SHA-1 / 1 sin identidad; `--remove` la borra y es idempotente; ningún archivo `.pem`/`.p12` queda en el temporal; la contraseña no aparece en stdout/stderr.

**Verificación.** `python3 -m unittest discover -s Tests/InstallerTests -v`.

### F1-0b · Instalador: firmar con la identidad y reiniciar TCC solo si el DR cambió `[SUB-impl]` · tamaño S

**Archivos.** `scripts/install.py`, `Tests/InstallerTests/test_installer.py`, y `Tests/UpdateTests/test_updates.py` solo si algún test existente lo necesita.

**Especificación.**
1. `signing_identity()`: corre `security find-identity -p codesigning`, devuelve la SHA-1 si hay exactamente una fila con el nombre exacto, `None` si no hay, y lanza `RuntimeError("More than one AeroGrid signing identity; run scripts/setup-signing.py --remove and set it up again.")` si hay más de una. Se consulta una vez, antes del staging.
2. `bundle()` firma con `--sign <sha1>` si hay identidad, `--sign -` si no. Si `codesign` falla con identidad, la excepción aborta la instalación antes de `commit_install` (sin caer a ad-hoc).
3. `reset_changed_adhoc_permissions` pasa a `reset_changed_permissions`: reinicia una app si su DR actual existe, difiere del anterior **y** además hay DR anterior o el actual es `cdhash`. Así: ad-hoc ⇒ certificado reinicia una vez; certificado estable no reinicia; primera instalación ad-hoc reinicia como hoy; primera instalación con otra firma (sin DR anterior) no reinicia, como exige `testPermissionResetIsLimitedToChangedOwnedAdhocSignatures`, que sigue sin cambios salvo el nombre de la función (mantener un alias `reset_changed_adhoc_permissions` o actualizar solo la llamada).
4. La salida final agrega una línea: `Signing: AeroGrid Local Code Signing` o `Signing: ad-hoc (run scripts/setup-signing.py for permissions that survive updates)`.

**Reproducción primero.** Escribir los tests 2 y 3 y verlos fallar contra el instalador actual.

**Tests (`test_installer.py`, con `codesign` y `security` falsos en el `PATH` del subproceso cuando haga falta una identidad; el resto sigue firmando ad-hoc real como hoy).**
1. Sin identidad: igual que hoy (ad-hoc, reinicio si cambió el `cdhash`).
2. Con identidad y el mismo DR `certificate leaf` antes y después, con binarios distintos: `codesign` recibe `--sign <sha1>` y **no** se llama a `tccutil`.
3. De ad-hoc a identidad (DR cambia de `cdhash` a `certificate leaf`): `tccutil reset` para las dos apps, una vez.
4. Dos identidades con el mismo nombre: aborta sin cambiar archivos instalados.
5. `codesign` falla con identidad: aborta sin cambiar archivos instalados y sin firmar ad-hoc.

**Verificación.** `python3 -m unittest discover -s Tests/InstallerTests -v` y `… -s Tests/UpdateTests -v`.

### F1-0c · Docs y verificación en vivo `[ORQ]` + `[HUM]`

`README.md`, `BUILD-ON-ANOTHER-MAC.md`, `docs/updates.es.md`: el paso opcional, qué cambia (Accesibilidad persiste), qué no (Gatekeeper, política de seguridad), cómo quitarlo. En vivo: `setup-signing.py`, instalar (reinicia una vez y se aprueba), instalar otro build distinto ⇒ `--health` con `accessibilityGranted: true` sin aprobar de nuevo.

---

## F1-1 · Fichas

Diseño en `docs/plan/decisiones/F1-1.md`. Orden: F1-1b y F1-1c en paralelo; después F1-1a (usa los tipos de F1-1b); después F1-1d (aplicación, ventana de inicio de sesión y acción manual).

### F1-1b · Plantillas y emparejador puro `[SUB-impl]` · tamaño M

**Archivos.** `Sources/GridCore/PlaceTemplate.swift` (nuevo), `Tests/GridCoreTests/PlaceMatcherTests.swift` (nuevo). No toca `DynamicEngine` ni `SpaceMap`.

**Especificación.**
1. Tipos públicos, `Codable`/`Equatable`:
   ```swift
   public struct TemplateSlot: Codable, Hashable { public var bundleID: String; public var ordinal: Int }
   public struct TemplateNode: Codable, Equatable { public var weight: Double; public var orientation: String?; public var layout: String?; public var slot: TemplateSlot?; public var children: [TemplateNode]? }
   public struct TemplateFloating: Codable, Equatable { public var slot: TemplateSlot; public var x, y, width, height: Double }
   public struct PlaceTemplate: Codable, Equatable { public var version = 1; public var tree: TemplateNode; public var floating: [TemplateFloating]; public var fullscreen: TemplateSlot?; public var capturedAt: Date }
   ```
2. `PlaceTemplate.capture(snapshot: LayoutSnapshot, windows: [WindowInfo], now: Date) -> PlaceTemplate?`: recorre `snapshot.tree` en profundidad y después `floating`; cada hoja con ventana conocida en `windows` (por id y pid) y `bundleID` no vacío se vuelve `TemplateSlot(bundleID, ordinal)`, con ordinal = cantidad de hojas previas de ese bundle en el recorrido. Hojas sin ventana conocida o sin bundle se omiten (los contenedores que queden vacíos se podan). Sin hojas ⇒ `nil`. Conserva pesos, orientación y layout.
3. `PlaceTemplate.fullscreen(slot:capturedAt:)`: plantilla de tarjeta fullscreen (árbol raíz vacío, `fullscreen = slot`).
4. `var slots: [TemplateSlot]` en orden de recorrido (árbol, flotantes, fullscreen).
5. `func instantiate(_ assignment: [TemplateSlot: WindowIdentity], boot: String) -> LayoutSnapshot?`: produce el `LayoutSnapshot` con IDs actuales; ranuras sin ventana se omiten y los contenedores vacíos se podan; `nil` si no queda ninguna.
6. Emparejador:
   ```swift
   public struct CandidateWindow: Equatable { public var identity: WindowIdentity; public var bundleID: String; public var workspace: String }
   public struct PlaceTarget: Equatable { public var spaceID: String; public var workspace: String; public var template: PlaceTemplate }
   public struct PlaceAssignment: Equatable { public var window: WindowIdentity; public var spaceID: String; public var slot: TemplateSlot; public var fullscreen: Bool }
   public enum PlaceMatcher { public static func assign(candidates: [CandidateWindow], targets: [PlaceTarget], present: [CandidateWindow]) -> [PlaceAssignment] }
   ```
   Reglas: (a) para cada objetivo, las ventanas de `present` que **no** son candidatas y están en su workspace cubren las ranuras de su bundle en orden de ordinal; (b) una candidata que ya está en el workspace de un objetivo con ranura libre de su bundle la cubre allí (asignación sin cambio de workspace); (c) las ranuras libres restantes, ordenadas por (orden de `targets`, ordinal), se asignan por bundle a las candidatas libres ordenadas por `identity.id` ascendente; (d) una ranura `fullscreen` produce `fullscreen: true`; (e) cada ventana y cada ranura a lo sumo una vez; sobrantes sin asignar. Determinista.

**Reproducción primero.** No aplica (código nuevo): tests primero, verlos fallar por no compilar o por `fatalError` de un esqueleto.

**Tests (de tabla).** Captura: árbol con dos ventanas de la misma app y una de otra ⇒ ordinales 0,1 y 0; flotantes después del árbol; hoja sin bundle omitida y contenedor podado; `nil` sin hojas. `instantiate` ida y vuelta conserva pesos/orientación con IDs nuevos y poda ranuras faltantes. Emparejador: una app en dos espacios; dos ventanas de la misma app para un espacio con dos ranuras; más ventanas que ranuras; más ranuras que ventanas; ventana presente no candidata cubre su ranura; candidata ya en su espacio no se mueve; ranura fullscreen; orden de objetivos decide el empate; resultado idéntico al repetir.

**Verificación.** `swift test --filter PlaceMatcherTests`, luego `swift test`.

### F1-1c · Backend: marcar ventanas alcanzadas por reglas del usuario `[SUB-impl]` · tamaño S

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift` (`status()`), el test de `status` en `vendor/AeroSpace/Sources/AppBundleTests/command/GridLayoutCommandTest.swift`, y si hace falta un archivo `Grid*.swift` nuevo. Parche regenerado y `UPSTREAM.md`.

**Especificación.**
1. Con backend propio, cada ventana de `status` lleva `"ruled": true` si alguna regla `on-window-detected` de la configuración cargada la alcanza **y** su lista `run` contiene un `move-node-to-workspace`. En otro caso la clave se omite (o `false`; elegir uno y documentarlo).
2. Reusar el emparejamiento que AeroSpace usa al detectar ventanas si es síncrono; si alguna condición necesita lecturas asíncronas de AX, evaluar solo las condiciones síncronas (app-id, app-name) y tratar las demás como coincidentes (conservador: ante duda, la ventana queda en manos de la regla). Documentar la elección en `UPSTREAM.md`.
3. Ventanas diferidas: sin la clave. AeroSpace independiente: sin cambios.

**Reproducción primero.** Escribir los tests y verlos fallar (falta la clave).

**Tests.** Regla con `if.app-id` y `move-node-to-workspace` ⇒ `ruled` en esa ventana y no en otra; regla sin `move-node-to-workspace` ⇒ sin `ruled`; regla con condición de título ⇒ según la elección del punto 2.

**Verificación.** `swift test --filter GridLayoutCommandTest`, suite completa del backend, parche regenerado.

### F1-1a · Captura de plantillas en el mapa `[SUB-impl]` · tamaño M

**Archivos.** `Sources/GridCore/SpaceMap.swift` (campo), `Sources/GridCore/DynamicEngine.swift`, `Tests/GridCoreTests/PlaceTemplateCaptureTests.swift` (nuevo). Usa los tipos de `Sources/GridCore/PlaceTemplate.swift` (F1-1b, no se modifica salvo que falte algo: detenerse e informar).

**Especificación.**
1. `SpaceMap.placeTemplates: [String: PlaceTemplate]? = nil`. Un `state.json` sin el campo se decodifica igual.
2. **Captura en `captureVisibleLayouts`.** Cada vez que guarda una distribución para un espacio, deriva `PlaceTemplate.capture(snapshot:windows:now:)` con el inventario actual y aplica la regla de reemplazo:
   - plantilla nueva `nil` ⇒ conservar la anterior;
   - si hay anterior y el multiconjunto de bundles de la nueva es **subconjunto estricto** del de la anterior ⇒ conservar la anterior (contracción por cierre, típica del apagado);
   - en otro caso ⇒ reemplazar.
3. **Organización del usuario.** Después de cada `organize(...)` exitoso, reconstruir sin la regla de contracción las plantillas de los espacios cuyo contenido o distribución cambió en esa acción (comparar antes/después). Undo/redo de organización también reconstruye.
4. **Tarjeta fullscreen de hogar propio** (`nativeWindow != nil` y vínculo con `spaceID == homeID`): plantilla `PlaceTemplate.fullscreen(slot:)` con el bundle de su ventana y ordinal = posición de esa ventana entre las ventanas fullscreen de ese bundle con hogar propio, por ID ascendente. Las tarjetas fullscreen exclusivas no tienen plantilla (límite conocido: se borran al cerrar su ventana).
5. **Poda.** Al principio de `refresh()`, borrar plantillas de espacios que ya no existen.
6. No se captura nada si el inventario no tiene ventanas; no se agregan eventos; nada de títulos.

**Reproducción primero.** Tests 1 y 2 primero, en rojo.

**Tests (`PlaceTemplateCaptureTests`).**
1. Un espacio con dos ventanas de una app y una de otra: tras `refresh()`, la plantilla tiene esas ranuras y sobrevive a reconstruir el motor con un `boot` distinto.
2. Contracción por cierre: se cierra una ventana ⇒ la plantilla no cambia; una ventana nueva de otra app ⇒ se reemplaza.
3. Reordenar por organización del usuario con menos ventanas ⇒ se reemplaza (sin regla de contracción).
4. Tarjeta fullscreen de hogar propio ⇒ plantilla `fullscreen`; exclusiva ⇒ sin plantilla.
5. Borrar un espacio ⇒ su plantilla desaparece en el siguiente refresco.
6. Estado sin `placeTemplates` se decodifica; los tests existentes siguen verdes sin cambiar aserciones.

**Verificación.** `swift test --filter PlaceTemplateCaptureTests`, luego `swift test`.

### F1-1d · Aplicar lugares al iniciar sesión y con «Restaurar lugares» `[SUB-impl]` · tamaño L

**Archivos.** `Sources/GridCore/SpaceMap.swift` (`WindowInfo.ruled`, estado persistido), `Sources/GridCore/Engine.swift` (protocolo), `Sources/GridCore/DynamicEngine.swift`, `Sources/AeroGrid/Backend.swift`, `Sources/AeroGrid/LoginSession.swift` (nuevo), `Sources/AeroGrid/AppModel.swift` (solo cablear: deadline, acción externa y método público; las vistas las hace el orquestador), `Tests/GridCoreTests/PlaceRestoreTests.swift` (nuevo).

**Especificación.**
1. `WindowInfo.ruled: Bool?`, último parámetro del `init` con default `nil`; se decodifica de `status`.
2. `Backend.enterFullscreen(window: WindowIdentity) throws`, default en la extensión que no hace nada; `AeroSpaceBackend` ejecuta `macos-native-fullscreen on --window-id <id>`.
3. Estado persistido en `SpaceMap.placeRestore: PlaceRestoreState?` = `{ boot: String; restored: [WindowIdentity]; userPlaced: [WindowIdentity] }`. Si el `boot` del inventario difiere, se reemplaza por uno vacío para el arranque nuevo.
4. **Seguimiento.** El motor recuerda el workspace de cada ventana entre refrescos (en memoria). Si una ventana cambia de workspace sin que lo haya movido la restauración ni un `organize` del motor, su identidad pasa a `userPlaced`. Movimientos de `organize` también la agregan (son del usuario).
5. **Automático.** `DynamicEngine.placeRestoreDeadline: Date?` (lo fija `AppModel`) y reloj inyectable (`now: () -> Date`, default `Date.init`, parámetro del `init` con default). En `refresh()`, después de reconciliar fullscreen y antes de capturar distribuciones, si `now() < deadline`: candidatas = ventanas no `ruled`, no `nativeFullscreen`, sin vínculo fullscreen, no `restored`, no `userPlaced`. Objetivos = espacios con plantilla, en orden de `map.spaces` (los dormidos incluidos; una tarjeta fullscreen de hogar propio usa su workspace). `present` = todo el inventario. `PlaceMatcher.assign`.
6. **Aplicar cada asignación:** si la ventana está en otro workspace, `moveVerified`; agregar la identidad a `restored` (también si falla, para no reintentar); emitir `place-restored window=<id> pid=<pid> space=<prefijo 8> ordinal=<n>` o `place-restore-failed …` con el mismo detalle (sin bundle ID ni nombres). Si `fullscreen`, después del movimiento `enterFullscreen` una vez. Al terminar el lote, para cada espacio no fullscreen que recibió asignaciones: armar el mapeo ranura → ventana con las ventanas de ese workspace (por bundle, en orden de ID) y `backend.restore(workspace:snapshot:)` con `template.instantiate(…)`; si falla, registrar y seguir. Después `sync(try readDesktop())`.
7. **Manual:** `public func restorePlaces() throws -> Int` dentro de `organize("Restaurar lugares")` (un solo paso de Deshacer), sin plazo, con candidatas = ventanas no `ruled`, sin vínculo fullscreen y no `userPlaced`; devuelve la cantidad de ventanas movidas. Las identidades movidas van a `restored`.
8. `LoginSession.consoleLoginDate() -> Date?`: lee `utmpx` (`USER_PROCESS`, `ut_line == "console"`, usuario actual) y devuelve la más reciente. `AppModel` fija `placeRestoreDeadline = login + 300 s` si `now < login + 300 s`; si no, `nil`. Acción externa `restore-places` y método `restorePlaces()` que deja un mensaje con la cantidad.
9. Nada de esto corre con la compuerta cerrada (el motor no refresca entonces).

**Reproducción primero.** Tests 1 y 2 primero, en rojo.

**Tests (`PlaceRestoreTests`, con reloj y backend falsos).**
1. Arranque nuevo con plantillas guardadas: aparecen ventanas de esas apps en un workspace cualquiera dentro del plazo ⇒ quedan en sus espacios con su distribución (`restore` con IDs nuevos) y eventos `place-restored`.
2. Fuera del plazo ⇒ nada se mueve; `restorePlaces()` las mueve y un `undo()` las devuelve.
3. Una ventana restaurada que el usuario mueve después no vuelve en el siguiente refresco (ni por automático ni por manual).
4. Ventana `ruled` ⇒ nunca se mueve.
5. Falla de `moveVerified` ⇒ `place-restore-failed`, sin reintento.
6. Ranura fullscreen ⇒ `enterFullscreen` una sola vez.
7. Estado sin `placeRestore` ni `ruled` se decodifica; los tests existentes siguen verdes sin cambiar aserciones.

**Verificación.** `swift test --filter PlaceRestoreTests`, luego `swift test`; `zsh scripts/build.sh` compila la app.
