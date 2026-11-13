# Fase 0 — Las apps en pantalla completa conservan su lugar

**Objetivo.** Una ventana en fullscreen nativo que sigue abierta conserva el mismo casillero (mismo ID, misma posición) a través de bloqueos, pantalla apagada y horas de inactividad, sin pasar por el Dock.

**Un PR.** Rama base: `t3/fullscreen-grid-position-analysis` (PR #3, el plan), o `main` si ya está mergeado. Causa raíz y evidencia: [`diagnostico.md`](diagnostico.md).

## Estrategia: tres defensas independientes

Cada una alcanza para evitar el síntoma; juntas cubren que una falle.

| Defensa | Qué hace | Tareas |
|---|---|---|
| **A. No mirar a ciegas** | El controlador no reconcilia con la sesión bloqueada o la pantalla apagada; el backend no da ventanas por muertas en ese estado | F0-2, F0-4, F0-5 (parte C) |
| **B. No olvidar** | El backend conserva el hogar de una ventana fullscreen que WindowServer todavía lista; ya existe el mecanismo de «ventanas diferidas» que la mantiene en el inventario | F0-5 (partes A y B), F0-6 |
| **C. No decidir con una muestra, y recordar el lugar** | El controlador exige muestras consecutivas antes de borrar o dar por salida de fullscreen, y si igual borra, guarda el lugar y lo restituye cuando la misma ventana reaparece | F0-3 |

## Cómo se verifica: forzar el estado, no esperar la causa

El bug es una reacción equivocada a una observación («la ventana no está», «no está en fullscreen»). Para comprobar el arreglo alcanza con fabricar esa observación; no hace falta bloquear la Mac durante horas ni esperar a que ocurra.

| Nivel | Cómo se fuerza | Dónde |
|---|---|---|
| Modelo | El backend falso de los tests deja de listar la ventana, o la lista una vez como «no fullscreen». Los tests se escriben primero y deben fallar contra el código actual | F0-3 |
| Backend | Tests con ventanas simuladas que se pierden estando en fullscreen | F0-5, F0-6 |
| En vivo | Un comando de diagnóstico hace que el backend instalado «deje de ver» una ventana real durante unos segundos | F0-7 |

Lo único que forzar el estado no puede responder es si el bloqueo real produce esa observación y con qué señales. Eso lo cubre un registro pasivo (F0-1) que corre durante el uso normal y **no bloquea ninguna tarea**: la defensa C funciona sea cual sea la causa de la ausencia, y la señal de bloqueo se comprueba en la aceptación con un bloqueo de 5 minutos.

## Invariantes (aceptación de la fase)

- **I1.** Una ventana fullscreen que sigue abierta conserva ID y rectángulo de su casillero tras cualquier bloqueo o apagado de pantalla.
- **I2.** Se llega a ella con el gesto o el clic en su tarjeta, sin Dock (camino existente `activate-target` para ventanas diferidas).
- **I3.** Cerrar una ventana fullscreen retira su tarjeta en ≤ 15 s. Terminar el proceso la retira en el siguiente ciclo.
- **I4.** Salir de fullscreen se refleja en el mapa en ≤ 6 s y conserva los comportamientos actuales (vuelta a la distribución original; posición elegida si la tarjeta se había movido).
- **I5.** Con la sesión bloqueada o la pantalla apagada, el mapa no cambia: `state.json` no se reescribe.
- **I6.** Todo cambio automático del mapa deja una línea en `diagnostics.log` con su motivo, sin títulos ni nombres de apps.
- **I7.** AeroSpace independiente (otro bundle ID) se comporta igual que antes.

## Orden y paralelismo

```
F0-2 ─> F0-3 ─> F0-4 ───────────┬─> F0-8 (revisión) ─> F0-9 (instalación y aceptación)
F0-5 ─> F0-6 ─> F0-7 ───────────┘
F0-1 (registro pasivo, aparte: no bloquea nada)
```

F0-2/3/4 tocan `Sources/` y `Tests/`; F0-5/6/7 tocan `vendor/AeroSpace`; F0-1 toca solo `scripts/`. Las tres líneas pueden ir en paralelo. Ninguna tarea necesita al humano hasta F0-9.

---

## F0-1 · Registro pasivo del caso real `[SUB-impl]` + `[HUM]` · tamaño S · no bloquea

**Para qué.** Capturar una ocurrencia real del problema durante el uso normal, para confirmar o corregir tres supuestos que hoy salen de leer el código. No es una prueba del arreglo (eso es F0-3 y F0-7) y ninguna tarea espera su resultado.

**Entregable.** `scripts/probe-lock.swift` (ejecutable con `swift scripts/probe-lock.swift SALIDA.jsonl [segundos]`, mismo estilo que `scripts/probe-gestures.swift`), solo lectura. Cada 10 s (configurable) arma un registro con:

- hora; claves `CGSSessionScreenIsLocked` y `kCGSSessionOnConsoleKey` de `CGSessionCopyCurrentDictionary()`; bundle ID de la app frontal;
- de `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)`: para cada ventana de capa 0, número, PID dueño y `kCGWindowIsOnscreen`;
- de `~/.local/bin/aerogrid-aerospace grid-layout status`: por ventana `id`, `pid`, `workspace`, `nativeFullscreen`; la lista de IDs de `windowHomes`; `nativeVisible`. Si el comando falla, el texto del error;
- de `grid-layout native-status`: los Spaces por pantalla.

Escribe una línea JSON solo cuando el registro difiere del anterior (sin contar la hora), más una línea de latido cada 5 min, para que una noche entera ocupe poco. Sin títulos, sin nombres de apps. La salida va a `output/` (ignorado por git). No usa APIs privadas propias ni escribe en Application Support.

**Uso `[HUM]`.** Un comando en una terminal, y a seguir trabajando: `swift scripts/probe-lock.swift output/lock.jsonl`. Sirve con el build instalado hoy (antes del arreglo, para ver el problema) y durante la aceptación (después, para ver que no ocurre). Cuando las apps fullscreen vuelvan a desaparecer, avisar al orquestador.

**Qué responde un registro con una ocurrencia real:**

| Pregunta | Si la respuesta es «no» |
|---|---|
| P1. ¿Las ventanas fullscreen desaparecen de `windows` y de `windowHomes` durante el bloqueo o el apagado? | La causa no es la descrita. La defensa C sigue valiendo (no depende de la causa); reinvestigar A y B con el registro |
| P2. Mientras tanto, ¿`CGWindowList` sigue listando esas ventanas con el mismo PID, y `native-status` sigue mostrando su Space tipo 4? | En F0-5 las ventanas retenidas no se validan contra WindowServer mientras dure el bloqueo (la poda ya corre solo con sesión desbloqueada) |
| P3. ¿`CGSSessionScreenIsLocked` refleja el bloqueo de forma fiable? ¿Y la pantalla apagada sin bloqueo? | Usar como señal la combinación que sí funcione en F0-4 y F0-5 parte C |

**Hecho cuando:** la sonda está commiteada y probada un minuto. Las respuestas se agregan al PR cuando exista un registro con una ocurrencia; si llegan después del merge y alguna es «no», se abre un ajuste.

**Verificación.** `swift scripts/probe-lock.swift output/prueba.jsonl 2` durante 20 s: produce JSON válido por línea y ninguna cadena con título o nombre de app.

---

## F0-2 · Compuerta de reconciliación `[SUB-impl]` · tamaño S

**Archivos.** Nuevo `Sources/GridCore/ReconciliationGate.swift`; nuevo `Tests/GridCoreTests/ReconciliationGateTests.swift`. Modelo a imitar: `Sources/GridCore/BackendLaunchPolicy.swift` y su test.

**Especificación.** Tipo puro, sin relojes ni APIs del sistema: el tiempo entra como parámetro.

```swift
public struct ReconciliationGate {
    public var settle: TimeInterval            // default 3
    public init(settle: TimeInterval = 3)
    /// Registra el estado observado. Devuelve true si la compuerta acaba de reabrirse
    /// (transición cerrada → abierta ya cumplido el asentamiento), una sola vez por reapertura.
    @discardableResult public mutating func update(locked: Bool, screensAsleep: Bool, at now: TimeInterval) -> Bool
    public func isOpen(at now: TimeInterval) -> Bool
    public var reason: String? { get }         // "locked", "screens-asleep", "settling" o nil
}
```

- Cerrada mientras `locked || screensAsleep`.
- Al pasar ambos a falso sigue cerrada (`reason == "settling"`) hasta `now >= instanteDeLiberación + settle`.
- Si vuelve a bloquearse durante el asentamiento, el asentamiento se reinicia en la próxima liberación.
- Estado inicial: abierta.

**Tests mínimos.** Abierta al inicio; cerrada al bloquear; cerrada con pantalla dormida aunque no esté bloqueada; asentamiento exacto en el borde; rebloqueo durante el asentamiento; `update` devuelve `true` exactamente una vez por reapertura.

**Verificación.** `swift test --filter ReconciliationGateTests`.

---

## F0-3 · Reconciliación fullscreen con confianza `[SUB-impl]` · tamaño L

La tarea central. Convierte «presente/ausente» en «presente / en duda / confirmado ausente» y agrega memoria del lugar.

**Archivos.** `Sources/GridCore/DynamicEngine.swift` (función `reconcileFullscreen`, alrededor de la línea 290, y el bloque de marcado `dormant` al final de `refresh()`), `Sources/GridCore/SpaceMap.swift`, nuevo `Tests/GridCoreTests/FullscreenResilienceTests.swift`, y adaptación de tests existentes (lista abajo). Arnés de test: `MapBackend` en `Tests/GridCoreTests/DynamicEngineTests.swift`.

### Comportamiento actual que cambia

Hoy, por cada `FullscreenLink`, una sola llamada a `reconcileFullscreen` basta para: (a) borrar vínculo y casillero si la ventana no está en `windows` y su hogar no está en `windowHomes`; (b) ejecutar el camino de salida de fullscreen si la ventana está pero con `nativeFullscreen == false`.

### Especificación

**1. Constantes con nombre** (en `DynamicEngine`):
`absenceConfirmations = 3`, `exitConfirmations = 2`, `maxFullscreenPlaces = 32`.

**2. Contadores en memoria** (no se persisten): `[WindowIdentity: (absent: Int, windowed: Int)]`. Cada llamada a `reconcileFullscreen` es una muestra.

**3. Guarda de apagón.** Si el inventario actual no tiene ninguna ventana y la observación previa (`previous`) tenía al menos una, esta muestra no es evidencia: no se incrementa ningún contador, no se borra ningún vínculo, y en `refresh()` se omite el pase que marca espacios como `dormant`. Emitir el evento `inventory-blackout`.

**4. Tabla de decisión por vínculo, en este orden:**

| Observación | Acción |
|---|---|
| Ventana presente con `nativeFullscreen == true` | Poner sus contadores en cero. Seguir con la lógica actual (separación en casillero exclusivo si pasó a compartir workspace) |
| Ausente de `windows` pero su hogar está en `windowHomes` (diferida) | Poner `absent` en cero. Conservar (comportamiento actual) |
| Presente con `nativeFullscreen == false` | `windowed += 1`. Si `windowed < exitConfirmations`: no mutar el mapa ni llamar al backend. Si llega al umbral: ejecutar el camino de salida actual, sin cambios |
| Ausente y no diferida, y el proceso dueño no vive, o el arranque del vínculo difiere del arranque actual conocido | Borrar ya por el camino actual. Sin memoria de lugar |
| Ausente y no diferida, proceso vivo | `absent += 1`. Si `absent < absenceConfirmations`: conservar. Si llega al umbral: guardar memoria de lugar (punto 6) y borrar por el camino actual |

«Arranque actual conocido» = `boot` de cualquier ventana del inventario; si el inventario está vacío, se desconoce y no cuenta como distinto.

**5. Proceso vivo: inyectable.** `DynamicEngine.init` recibe `isProcessAlive: @escaping (Int32) -> Bool` con un default del sistema (`kill(pid, 0) == 0 || errno == EPERM`). Los tests lo inyectan. No cambiar el protocolo `Backend`.

**6. Memoria de lugar.** En `SpaceMap`, campo nuevo **opcional** para no romper estados guardados:

```swift
public struct FullscreenPlace: Codable, Equatable {
    public var space: Space              // el casillero exclusivo tal como estaba (id, posición, tablero, foldedRect, nombre)
    public var manuallyEdited: Bool
    public var removedAt: Date
}
public var fullscreenPlaces: [FullscreenPlace]? = nil   // en SpaceMap
```

- Se guarda solo cuando se borra un casillero **exclusivo** (`link.spaceID != link.homeID`) por ausencia confirmada con proceso vivo. La identidad es `space.nativeWindow`.
- No forma parte de `MapCheckpoint`: Undo no la toca.
- Poda en cada `refresh()`: entradas cuyo proceso ya no vive o cuyo arranque difiere del conocido; tope `maxFullscreenPlaces`, descartando las más viejas.
- `validate()`: cada entrada tiene `nativeWindow != nil`, rectángulos válidos y como mucho una entrada por identidad.

**7. Restitución.** En el segundo bucle de `reconcileFullscreen` (ventana fullscreen sin vínculo), si existe una memoria para `window.identity`:

- el hogar se determina como hoy (espacio normal cuyo `workspace` es el de la ventana);
- el casillero exclusivo reutiliza de la memoria: `id` (si está libre), nombre, `boardID`, `preferredDisplay`, `foldedRect` y posición; `workspace` y `sourceID` salen del hogar actual, como en `exclusiveSpace`;
- si la posición recordada ya no cabe (`map.fits`), usar `SpacePlacement.nearestVacancy(near:occupied:width:height:)` desde la posición recordada, igual que hace `sync()` con los espacios que despiertan;
- el vínculo nuevo conserva `manuallyEdited` de la memoria;
- la entrada se consume;
- se crea casillero exclusivo aunque la ventana sea la única de su workspace, para no pisar la posición del hogar.

Sin memoria, el comportamiento es el actual.

**8. Eventos.** `public func consumeEvents() -> [String]`, mismo patrón que `consumeRecoveryNotice()`: buffer en memoria, tope 200, se vacía al consumir. Formato `clave=valor`, solo números y prefijos de 8 caracteres de IDs:

`fullscreen-created`, `fullscreen-doubt kind=absent|windowed count=N`, `fullscreen-removed reason=closed|process-exit|boot`, `fullscreen-exit`, `fullscreen-restored`, `inventory-blackout`, más `space-adopted`, `space-dormant` y `space-woken` en los puntos de `refresh()`/`sync()` donde hoy ocurren. Cada uno con `window=<id> pid=<pid> space=<id8>` cuando aplique.

### Tests nuevos (`FullscreenResilienceTests`)

1. La ventana y su hogar desaparecen 2 muestras y vuelven: vínculo y casillero idénticos (comparar `FullscreenLink` y `Space` completos).
2. Desaparecen ≥ 3 muestras con proceso vivo y la ventana reaparece en **otro** workspace: mismo ID de casillero, misma fila y columna, `manuallyEdited` conservado.
3. Igual que 2 pero la posición recordada fue ocupada entretanto: queda en la vacante más cercana a la recordada y el mapa valida.
4. Proceso muerto: se borra en la primera muestra; no queda memoria.
5. Una sola muestra con `nativeFullscreen == false` y vuelta a `true`: mapa idéntico y `MapBackend` no recibió ningún movimiento de ventana.
6. Salida real (2 muestras): se cumplen las aserciones de los tests existentes de salida.
7. Apagón total: `windows` vacío durante 5 muestras y vuelta: `spaces` (incluido `dormant`), `fullscreens` y `layouts` idénticos al estado previo.
8. Número de ventana reutilizado por otro PID: no restituye la memoria ajena.
9. Decodificar un `SpaceMap` guardado sin `fullscreenPlaces` sigue funcionando; codificar y decodificar es estable.
10. `consumeEvents()` devuelve los eventos esperados en los escenarios 2, 4 y 5, y ninguno contiene `appName` ni `title` de las ventanas del test.

### Reproducción primero

Los tests 1, 5 y 7 son el bug forzado: corresponden a las dos transiciones encontradas en el estado real (casillero borrado y recreado; una muestra «no fullscreen» que muda la ventana). Antes de tocar `DynamicEngine`, escribilos con el `init` actual y corrélos: **deben fallar**. Pegá esa salida en el informe. Si alguno pasa sin tocar el motor, detenete: el escenario no reproduce el bug. Después de implementar, agregales la inyección de `isProcessAlive`.

### Tests existentes a adaptar

Varios tests cambian un flag y llaman a `refresh()` **una** vez esperando efecto inmediato. Agregar un ayudante `settle(_ n: Int = 3)` que llame a `refresh()` n veces y usarlo en ellos, **sin tocar las aserciones**. Candidatos conocidos: en `DynamicEngineTests`, los que empiezan en las líneas 142, 190, 364, 403, 477 y 544; en `FullscreenDragTests`, 99 y 114. Listar en el informe cada test adaptado. Revisar también que `Sources/AeroGrid/DynamicVerification.swift` (espera por estabilidad en bucle) y `OrganizerSandbox.swift` no asuman efecto en una sola muestra; si lo asumen, informarlo en vez de cambiarlos.

**Verificación.** `swift test --filter FullscreenResilienceTests`, luego `swift test` completo.

---

## F0-4 · Conectar compuerta y registro en la app `[SUB-impl]` · tamaño M

Depende de F0-2 y de la firma `consumeEvents()` de F0-3.

**Archivos.** `Sources/AeroGrid/AppModel.swift` (`start()`, `refresh()`, `perform`, `recover()`, `writeHealth()`); test en `Tests/AeroGridTests/` si la lógica extraída lo permite.

**Especificación.**

1. `AppModel` tiene una `ReconciliationGate`. La alimentan:
   - `DistributedNotificationCenter`: `com.apple.screenIsLocked` y `com.apple.screenIsUnlocked`;
   - `NSWorkspace.shared.notificationCenter`: `screensDidSleepNotification`, `screensDidWakeNotification`, `sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification`;
   - en cada tick de `refresh()`, la lectura directa de `CGSessionCopyCurrentDictionary()` (`CGSSessionScreenIsLocked`), por si se perdió una notificación.
   Si un registro de F0-1 ya mostró otra señal más fiable, usar esa combinación.
2. En `refresh()`: con la compuerta cerrada no se llama a `engine.refresh()` ni a ninguna operación que persista el mapa. Se mantienen `launchBackend()` y la gestión de `input`. El mensaje de estado pasa a «En reposo · pantalla bloqueada» (o «pantalla apagada») y `writeHealth()` lo refleja.
3. Con la compuerta cerrada se cancela cualquier gesto en curso y se cierra el organizador, como ya hace el cambio de pantallas.
4. Cuando `update` devuelve `true` (reapertura), llamar una vez a `recover()`.
5. El `didWake → recover()` actual queda, pero pasa por la compuerta: si está cerrada o asentándose, se difiere.
6. En `perform`, después de cada trabajo, vaciar `engine.consumeEvents()` y escribir cada evento con `log("map: …")`. También registrar las transiciones de la compuerta (`gate: closed reason=locked`, `gate: open`).
7. Las acciones explícitas del usuario no se bloquean por la compuerta más allá del punto 3: con la sesión bloqueada no hay usuario.

**Tests.** La decisión «¿refresco ahora?» se extrae a una función pura testeable si hace falta; mínimo: compuerta cerrada ⇒ cero llamadas a `refresh` del motor en N ticks; reapertura ⇒ exactamente un `recover`. Reutilizar el modo de `IdlePerformanceVerification` (backend falso) si sirve.

**Verificación.** `swift test`; `swift build -c release`; `.build/release/AeroGrid --benchmark-idle output/idle.json` sigue sin publicaciones en refrescos sin cambios.

---

## F0-5 · Backend: retener ventanas fullscreen `[SUB-impl]` · tamaño M

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/tree/MacWindow.swift` (`garbageCollect`), `vendor/AeroSpace/Sources/AppBundle/tree/MacApp.swift` (`refreshAllAndGetAliveWindowIds`, `refreshAndGetAliveWindowIds`), `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift` (`gridPendingWindowHomes`, `gridDeferredNativeWindows`, `status`), `vendor/AeroSpace/Sources/AppBundleTests/GridNativeRecoveryTest.swift`. Al final: `scripts/aerospace-grid.patch` y `UPSTREAM.md`.

**Contexto.** Ya existe `gridPendingWindowHomes`: hogares de ventanas que Accesibilidad todavía no expone. `status()` los incluye en `windowHomes` mientras el proceso viva, y `gridDeferredNativeWindows()` las agrega al inventario como `nativeFullscreen` si WindowServer confirma dueño y Space. Hoy solo se llena tras un reinicio del backend (`recover-homes`). Esta tarea lo llena también cuando una ventana fullscreen se pierde por un apagón de Accesibilidad.

**Parte A — Retener en vez de olvidar.** En `MacWindow.garbageCollect`, hoy se llama siempre a `gridForgetRecoveredWindowHome(windowId)`. Nuevo comportamiento, solo si `gridOwnsBackendUI()`:

- Si la ventana estaba en un `MacosFullscreenWindowsContainer`, `skipClosedWindowsCache == false` (un cierre explícito pasa `true`) y su app no terminó: registrar un `GridWindowHome` con `id`, `pid`, arranque actual, nombre del workspace que la contenía y `floating` según el `prevParentKind` de su `layoutReason`. Hay que calcularlo **antes** de `unbindFromParent()`.
- En cualquier otro caso: olvidar, como hoy.
- En ambos casos se sigue limpiando el rastreador de anchos mínimos.

La decisión va en un tipo o función pura (entradas: estaba en fullscreen, cierre explícito, app terminada, backend propio) para poder testearla sin `MacWindow` real, igual que `GridNativeRecoveryEvidence`.

**Parte B — Poda de pendientes.** Un hogar pendiente se descarta cuando: el proceso no vive; el arranque difiere; o WindowServer no lista esa ventana con ese PID durante ≥ 10 s continuos **medidos solo con la sesión desbloqueada**. Guardar «ausente desde» por ID con `ProcessInfo.processInfo.systemUptime`. Evaluarlo donde `status()` ya recorre los pendientes. Política en tipo puro con tests. Esto hace cumplir I3 y evita tarjetas fantasma de ventanas cerradas en apps que siguen abiertas.

**Parte C — No recolectar con la sesión bloqueada.** En `refreshAndGetAliveWindowIds`, la partición vivos/muertos solo se saltea si la app frontal es `com.apple.loginwindow`. Para el backend propio, saltearla también cuando la sesión está bloqueada (`CGSessionCopyCurrentDictionary`, clave `CGSSessionScreenIsLocked`; o la señal que un registro de F0-1 haya validado). Leer la señal en el actor principal y pasarla al cierre, como ya se hace con `frontmostAppBundleId`.

**Opcional si es simple.** Mientras exista un hogar pendiente fullscreen para un workspace, no descartar `gridNativeLayoutSnapshots[workspace]`, para que la salida posterior de fullscreen vuelva al hueco original. Si complica, dejarlo anotado en el informe.

**Tests** (`GridNativeRecoveryTest`): decisión de retención en sus cuatro combinaciones relevantes; política de poda (proceso muerto, arranque distinto, ausencia menor y mayor al margen, ausencia con sesión bloqueada no cuenta); los dos tests existentes siguen pasando.

**Parche y docs.** Regenerar `scripts/aerospace-grid.patch` contra el commit fijado en `UPSTREAM.md`. El procedimiento no está escrito: **primero calibralo** regenerando el parche sin tus cambios y comprobando que coincide con el actual (salvo líneas `index`); recién después regenerá con tus cambios. Agregar un párrafo a `UPSTREAM.md` en el mismo estilo que los existentes.

**Verificación.** `(cd vendor/AeroSpace && swift test --filter GridNativeRecoveryTest)`, luego la suite completa del backend una vez.

---

## F0-6 · Backend: salida de fullscreen corroborada `[SUB-impl]` · tamaño S

Después de F0-5 (mismos archivos de parche).

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/normalizeLayoutReason.swift`, `GridNativeSpaces.swift` si hace falta un ayudante, test nuevo o existente en `AppBundleTests`, parche y `UPSTREAM.md`.

**Problema.** En `_normalizeLayoutReason`, `window.isMacosFullscreen` termina en `macApp.isMacosNativeFullscreen(...) == true`: una lectura fallida (`nil`) cuenta como «no está en fullscreen» y dispara `exitMacOsNativeUnconventionalState`.

**Especificación.** Solo si `gridOwnsBackendUI()`, y solo para ventanas cuyo padre es `MacosFullscreenWindowsContainer`: antes de ejecutar la salida, corroborar con WindowServer. Si la ventana sigue en un Space tipo 4 (`gridNativeMonitor(windowID:) != nil`), no salir en este pase. La corroboración entra por un punto inyectable (variable global o parámetro con default real) porque en tests unitarios no hay API de Spaces; `TestWindow.isMacosFullscreenForTest` ya permite simular la lectura.

No cambiar las firmas de `Window.isMacosFullscreen` ni el camino de minimizadas u ocultas.

**Tests.** Lectura en falso + corroboración «sigue en fullscreen» ⇒ la ventana permanece en el contenedor fullscreen y su `layoutReason` no cambia. Lectura en falso + corroboración negativa ⇒ sale como hoy. Con identidad de AeroSpace independiente ⇒ comportamiento original aunque la corroboración diga lo contrario.

**Verificación.** Tests de la tarea y suite del backend; parche regenerado.

---

## F0-7 · Backend: inyección de falla en vivo `[SUB-impl]` · tamaño S

Después de F0-6 (mismos archivos de parche). Es lo que permite aceptar el arreglo en un minuto, con ventanas reales, sin bloquear la Mac.

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/layout/refresh.swift` (función privada `refresh()`), `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift` (operación nueva), `vendor/AeroSpace/Sources/Common/cmdArgs/impl/GridLayoutCmdArgs.swift` (solo el texto de ayuda), test en `AppBundleTests`, parche y `UPSTREAM.md`.

**Contexto.** En `refresh()`, `MacApp.refreshAllAndGetAliveWindowIds` devuelve por app los IDs que Accesibilidad considera vivos; toda `MacWindow` que no esté en esa lista recibe `garbageCollect(skipClosedWindowsCache: false)`, y los IDs listados pasan por `MacWindow.getOrRegister`. Una ventana que Accesibilidad deja de exponer se pierde exactamente por ese camino.

**Especificación.**

1. Operación nueva de `grid-layout`: `debug-blind`, con `--data '{"windowID":N,"seconds":S,"forget":false}'`. Solo existe si `gridOwnsBackendUI()`; en AeroSpace independiente responde como cualquier operación desconocida. `seconds` entre 1 y 600; `0` cancela la ceguera de esa ventana; fuera de rango es error. Responde un JSON con la ventana y los segundos restantes.
2. Estado en memoria, en el actor principal: por ID de ventana, vencimiento (`ProcessInfo.processInfo.systemUptime`) y `forget`. Nunca se persiste; un reinicio del backend lo borra.
3. Efecto: en `refresh()`, después de obtener `mapping`, quitar de las listas los IDs con ceguera vigente. No hace falta nada más: el bucle existente los recolecta y `getOrRegister` no los ve. El filtrado va en una función pura (listas, cegueras, ahora) → (listas filtradas, cegueras vigentes) que además descarta las vencidas.
4. `forget: true` simula además que la defensa B falla: mientras dure la ceguera, esa ventana no figura en `gridPendingWindowHomes` ni en lo que devuelve `gridDeferredNativeWindows()`. Así el controlador ve lo mismo que en el bug original: ausente de `windows` y de `windowHomes`, con el proceso vivo.
5. Al vencer, la ventana vuelve por el camino normal de registro.

**Diferencia con el caso real, a dejar escrita en `UPSTREAM.md`.** Al vencer la ceguera la ventana se redescubre sola; en el caso real una fullscreen se redescubre recién al visitar su Space. El resto de la cadena es la misma.

**Invariantes.** Sin invocar la operación, ningún cambio de comportamiento. La ceguera siempre vence sola. No registra títulos ni nombres de apps.

**Tests.** Función de filtrado: ceguera vigente quita el ID; vencida no lo quita y se descarta; `forget` se conserva; cancelación con `0`. Validación de rango. Con identidad de AeroSpace independiente la operación no existe.

**Verificación.** Tests de la tarea; suite del backend; parche regenerado.

---

## F0-8 · Revisión independiente `[SUB-rev]`

**Encargo.** Diff completo de la rama contra la base + la sección **Invariantes** de este archivo + las *Reglas comunes*. Pedir bugs concretos (entrada o estado → resultado incorrecto), no opiniones de estilo. Focos a nombrar explícitamente:

- carreras entre `status` y `normalizeLayoutReason` al redescubrir una ventana (estado transitorio «presente, no fullscreen, workspace equivocado»);
- hogares pendientes que nunca se podan, o que se podan durante un bloqueo;
- compatibilidad de `SpaceMap` con estados guardados y con `MapCheckpoint`/Undo;
- cambio de pantallas (dock/undock) mientras la compuerta está cerrada, y al reabrirse;
- reinicio del backend durante el bloqueo (`backendSession` nuevo + `recover-homes`);
- números de ventana reutilizados por otro proceso;
- que algún camino siga mutando o persistiendo el mapa con la compuerta cerrada;
- que la ceguera de F0-7 pueda quedar activa para siempre, o tener efecto en AeroSpace independiente;
- fuga de títulos o nombres de apps a `diagnostics.log`.

El orquestador verifica cada hallazgo antes de actuar: un revisor también se equivoca.

---

## F0-9 · Documentación, instalación, aceptación y PR `[ORQ]` + `[HUM]`

1. **Docs.** `docs/architecture.md` (sección «Organization and recovery»: compuerta, confirmación por muestras, memoria de lugar, retención en el backend), `docs/troubleshooting.md` (sección de fullscreen: qué se ve durante el reposo, dónde mirar los eventos `map:`, cómo usar `debug-blind`), `README.md` solo si cambia un límite declarado. Tablero de `docs/plan/README.md`.
2. **Suites completas**, con salida real en el PR: `swift test`; `(cd vendor/AeroSpace && swift test)`; `python3 -m unittest discover -s Tests/InstallerTests -v` (necesita `zsh scripts/build.sh` antes).
3. **Instalación** — avisar al humano antes; es la única de la fase:
   - el humano cierra con «Salir de AeroGrid» (cierra también el backend); comprobar que no queda ningún proceso;
   - `zsh scripts/build.sh` y `python3 scripts/install.py` (hace sus propios respaldos);
   - `open "$HOME/Applications/AeroGrid.app"`; el humano re-aprueba Accesibilidad para **AeroGrid** y **AeroGrid Backend**;
   - `"$HOME/.local/bin/aerogrid" --health`: `accessibilityGranted`, `backendReady` y `gestureInputReady` en `true`.
4. **Reacomodo único `[HUM]`.** El arreglo no repara lo ya desordenado: el humano vuelve a ubicar sus tarjetas fullscreen una vez. A partir de ahí deben quedar.
5. **Aceptación en vivo por inyección `[ORQ]`**, avisando al humano y empezando por una sola ventana. El orquestador toma el ID de una ventana fullscreen de `grid-layout status` y anota, en solo lectura, el ID y el rectángulo de su casillero en `state.json`:

   | Prueba | Se espera |
   |---|---|
   | `debug-blind` 30 s, `forget: false` | La tarjeta no se mueve ni desaparece. Ningún `fullscreen-removed` en `diagnostics.log`. Mismo ID y rectángulo al terminar |
   | `debug-blind` 30 s, `forget: true` (el bug original, forzado) | En el registro: `fullscreen-doubt`, luego `fullscreen-removed reason=closed`, y `fullscreen-restored` cuando la ventana vuelve a verse: al vencer si su Space es el actual; si no, al visitarlo (Accesibilidad no lista una ventana fullscreen de otro Space). Mismo ID y rectángulo al terminar; la ventana no queda en un espacio nuevo y **ninguna otra tarjeta cambia** (ver F0-11) |
   | Repetir la segunda con dos ventanas a la vez | Ídem para ambas |

   Si la segunda prueba deja la tarjeta en otro lugar, el arreglo no funciona: no seguir con la aceptación física.

6. **Aceptación física `[HUM]`**, solo lo que la inyección no cubre:

   | Prueba | Se espera |
   |---|---|
   | Bloquear 5 min (Ctrl+Cmd+Q) y volver | I1, I2, I5. En `diagnostics.log`: `gate: closed` y `gate: open` (la señal de bloqueo funciona), ningún `fullscreen-removed` |
   | Cerrar una ventana fullscreen | I3, con `fullscreen-removed reason=closed` |
   | Salir de fullscreen en otra | I4 |
   | Uso normal de uno o dos días, noche incluida, con la sonda de F0-1 corriendo | I1. Es seguimiento: no bloquea el merge |

7. **PR.** Descripción con: la salida en rojo de la reproducción de F0-3, lista de tests agregados y adaptados, qué es simulado, qué es inyectado en vivo y qué es físico, los resultados de las dos tablas, y las respuestas de F0-1 si ya hay un registro. Merge cuando pasaron las tres pruebas de inyección y las tres primeras físicas. Si el seguimiento falla, se reabre con el registro de la sonda.

---

## F0-10 · Hallazgo de la aceptación: salida de fullscreen falsa

**Qué pasó (2026-11-13, inyección en vivo, prueba 1 de F0-9).** `debug-blind` 30 s con `forget:false` sobre una sola ventana fullscreen. El refresco completo que la operación programa sacó del contenedor fullscreen del backend a **las dos** ventanas fullscreen, también a la no cegada. El controlador registró `fullscreen-doubt kind=windowed` y, 2 s después, `fullscreen-exit` para ambas. La no cegada tenía la tarjeta movida a mano (`manuallyEdited`): el camino de salida la mudó con `moveVerified` a un workspace nuevo y convirtió su casillero en un espacio normal. macOS la sigue teniendo en fullscreen (dos Spaces tipo 4 en `native-status`).

**Causa.**
1. Para una ventana fullscreen en un Space no visible, Accesibilidad no confirma el fullscreen: `MacWindow.isMacosFullscreen` compara `Bool?` con `true`, así que un fallo de lectura AX vale `false`. La ventana no cegada sigue hoy clasificada «no fullscreen», o sea que la lectura falsa persiste.
2. F0-6 rescata esa ventana en **cada** refresco completo con `gridNativeMonitor(windowID:) != nil`. Esa consulta da `nil` ante cualquier fallo (Spaces de la pantalla, Spaces de la ventana, o el emparejamiento del display por UUID con `sortedMonitorInfos`), y un solo `nil` saca a la ventana del contenedor para siempre. Que fallara para las dos a la vez apunta a una falla común (pantallas o emparejamiento), no a cada ventana.
3. El controlador confirma la salida con dos muestras, pero las dos salen del mismo estado persistente del backend: no son evidencia independiente.

Hay además un camino lateral: una ventana fullscreen recolectada (hogar retenido) que se re-registra como `.standard` vuelve como ventana normal en `gridApplyRecoveredWindowHome`, sin consultar WindowServer.

**Principio del arreglo.** La evidencia de WindowServer solo **conserva** un fullscreen ya conocido; nunca lo **crea**. Salir de fullscreen exige evidencia positiva de un Space normal o un período acotado sin evidencia. Dos tareas en paralelo (directorios disjuntos), con el mismo contrato: cada ventana de `grid-layout status` lleva `"nativeSpace": "fullscreen" | "normal" | "unknown"`.

---

## F0-10a · Backend: evidencia nativa de tres estados `[SUB-impl]` · tamaño M

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/command/impl/GridNativeSpaces.swift`, `vendor/AeroSpace/Sources/AppBundle/normalizeLayoutReason.swift`, `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift` (`status()` y `gridApplyRecoveredWindowHome`), `vendor/AeroSpace/Sources/AppBundleTests/GridFullscreenExitTest.swift`, y si hace falta `vendor/AeroSpace/Sources/AppBundleTests/command/GridLayoutCommandTest.swift`. Parche regenerado con `scripts/regenerate-backend-patch.sh` y `UPSTREAM.md`.

**Especificación.**

1. **Clasificador puro** en `GridNativeSpaces.swift`:
   ```swift
   enum GridNativeSpaceKind: String { case fullscreen, normal, unknown }
   func gridClassifyNativeSpace(windowSpaces: [UInt64]?, displays: [GridNativeDisplay]?) -> GridNativeSpaceKind
   ```
   - `displays == nil`, `windowSpaces == nil` o vacío ⇒ `.unknown`.
   - Algún Space de la ventana que no figura en ninguna pantalla ⇒ `.unknown`.
   - Todos figuran y **todos** son tipo 4 ⇒ `.fullscreen`.
   - Todos figuran y al menos uno no es tipo 4 ⇒ `.normal` (una ventana «en todos los escritorios» no es fullscreen).
   - No depende del emparejamiento de monitores. `gridNativeMonitor(windowID:)` queda como está, solo para saber el monitor.
   - Envoltura `@MainActor func gridNativeSpaceKind(windowID: UInt32, displays: [GridNativeDisplay]?) -> GridNativeSpaceKind` que lee `AeroGridCopyWindowSpaces`. Variante sin `displays` que llama a `nativeDisplays()` una vez.

2. **Salida con evidencia positiva.** En `_normalizeLayoutReason`, rama `.macos`, el parámetro `corroborateFullscreen: (UInt32) -> Bool` pasa a `nativeSpaceKind: (UInt32) -> GridNativeSpaceKind` (default: la envoltura) más `now: TimeInterval` (default `ProcessInfo.processInfo.systemUptime`). Con backend propio, ventana en `MacosFullscreenWindowsContainer` y AX que no dice fullscreen, minimizada ni oculta:
   - `.fullscreen` ⇒ conservar.
   - `.normal` ⇒ salir por el camino actual (`exitMacOsNativeUnconventionalState`).
   - `.unknown` ⇒ conservar mientras el desconocimiento continuo de **esa** ventana dure menos de `gridFullscreenUnknownGrace = 10` s; al llegar, salir. Estado en memoria en un tipo puro (`GridFullscreenUnknownTracker`: `mutating func shouldExit(windowID:now:) -> Bool`, `clear(windowID:)`), tope de 256 entradas. Una muestra `.fullscreen` o `.normal`, o la salida, limpian la entrada de esa ventana.
   - AeroSpace independiente: sin cambios y sin consultas.

3. **Hogar recuperado.** En `gridApplyRecoveredWindowHome`, si la ventana llega `.standard` (no está en los contenedores fullscreen ni oculto), su hogar pendiente es válido (mismo arranque y PID) y la clasificación es `.fullscreen`, vincularla al `macOsNativeFullscreenWindowsContainer` del workspace del hogar con `layoutReason = .macos(prevParentKind: home.floating ? .floatingWindowsContainer : .tilingContainer)`, en lugar de vincularla como normal. Después se consume el hogar, igual que hoy. Con otra clasificación, comportamiento actual. Agregar el parámetro inyectable `nativeSpaceKind` con default, como en el punto 2.

4. **`status`.** Cada entrada de `windows` lleva `"nativeSpace"` con el valor del clasificador, y `nativeDisplays()` se llama una sola vez por `status`. Las ventanas diferidas (`gridDeferredNativeWindows`) llevan `"fullscreen"`. No se agregan títulos ni nombres a nada.

**Reproducción primero.** Antes de tocar el código, agregar a `GridFullscreenExitTest` el test `testFailedWindowServerLookupRetainsFullscreen` con la firma actual (`corroborateFullscreen` devuelve `false`, que hoy representa también una consulta fallida): ventana en el contenedor fullscreen, AX `false`, backend propio ⇒ **debe seguir** en el contenedor. Correrlo: debe fallar. Pegar la salida en rojo en el informe. Después migrarlo a la firma nueva (`.unknown`, dentro del plazo) sin cambiar sus aserciones.

**Tests a adaptar (cambio de especificación deliberado, listado acá).** `testFalseAXReadingExitsWithoutCorroboration` pasa a `testFalseAXReadingExitsOnNormalSpace` con `.normal` (la aserción de salida se mantiene). `testFalseAXReadingRetainsCorroboratedFullscreen` pasa a usar `.fullscreen`. `testStandaloneIgnoresCorroboration` queda igual: cero consultas.

**Tests nuevos.**
- Tabla del clasificador: los cinco casos del punto 1, más un Space tipo 0 junto a uno tipo 4 ⇒ `.normal`.
- `.unknown` a 0 s y a 9,9 s ⇒ conserva. A 10 s continuos ⇒ sale. Si en el medio hay un `.fullscreen`, el plazo vuelve a empezar.
- Hogar recuperado `.standard` con `.fullscreen` ⇒ contenedor fullscreen con `.macos(prevParentKind:)` según `floating`, y hogar consumido. Con `.normal` ⇒ comportamiento actual.
- Con identidad de AeroSpace independiente, el hogar recuperado y la normalización no consultan WindowServer.

**Invariantes.** Ninguna ventana sale del contenedor fullscreen del backend propio sin un `.normal` de WindowServer, salvo después de 10 s continuos de `.unknown`. La evidencia nativa nunca mete en fullscreen una ventana que no tenía un fullscreen conocido (contenedor actual u hogar retenido). AeroSpace independiente se comporta igual que antes.

**Verificación.** `swift test --filter GridFullscreenExitTest` (y la clase del hogar recuperado), suite completa del backend, parche regenerado y `git diff --stat`.

---

## F0-10b · Controlador: no confirmar una salida que WindowServer contradice `[SUB-impl]` · tamaño S

**Archivos.** `Sources/GridCore/SpaceMap.swift` (`WindowInfo`), `Sources/GridCore/DynamicEngine.swift` (`reconcileFullscreen`, rama «presente con `nativeFullscreen == false`», y constantes), `Tests/GridCoreTests/FullscreenResilienceTests.swift`.

**Especificación.**

1. `WindowInfo.nativeSpace: String?`, opcional: falta en backends viejos y en estados guardados. Va como último parámetro del `init` con default `nil`. Se decodifica de `status` sin más cambios. No se agrega a `NavigationWindowState`.
2. En `reconcileFullscreen`, para un vínculo cuya ventana está presente con `nativeFullscreen == false`:
   - `nativeSpace == "fullscreen"`: el contenedor del backend contradice a WindowServer y no es evidencia de salida. Poner `windowed` y `absent` en 0, no mutar el mapa ni llamar al backend, y seguir. Emitir `fullscreen-doubt kind=disagree window=… pid=… space=…` solo al entrar en ese estado: memoria por identidad, que se limpia cuando la ventana vuelve a `nativeFullscreen == true` o el vínculo se borra.
   - `nativeSpace == "normal"` o `nil`: comportamiento actual (`exitConfirmations = 2`).
   - Cualquier otro valor (`"unknown"`): `windowed += 1`, y la salida se confirma recién con `unknownExitConfirmations = 5` muestras. El evento de duda lleva `kind=windowed-unknown count=N`.
   - Si las muestras alternan `normal` y `unknown`, el umbral lo decide la muestra actual: `normal` con `windowed >= 2` sale, `unknown` con `windowed >= 5` sale.
3. Mientras dura el desacuerdo, el casillero exclusivo del vínculo no se marca `dormant` ni cambia. Si el pase de `dormant` del final de `refresh()` lo marcaría, excluir los vínculos en desacuerdo.

**Reproducción primero.** Agregar primero solo el campo del punto 1, escribir los tests 1 y 2 de abajo y correrlos: deben fallar. Pegar la salida en rojo en el informe. Después implementar el punto 2.

**Tests nuevos (`FullscreenResilienceTests`).**
1. El caso real: dos vínculos fullscreen, uno con la tarjeta movida a mano (`manuallyEdited`, casillero exclusivo). Durante 5 muestras el backend falso los reporta presentes con `nativeFullscreen: false` y `nativeSpace: "fullscreen"`. Resultado: `spaces`, `fullscreens` y `layouts` idénticos, `MapBackend` sin ningún movimiento ni `restore`, y un solo `fullscreen-doubt kind=disagree` por ventana.
2. Después de eso, vuelven a `nativeFullscreen: true`: mapa idéntico y sin eventos de salida.
3. Salida real con `nativeSpace: "normal"`: igual que `testRealExitRequiresTwoSamples`.
4. `"unknown"`: 4 muestras ⇒ sin salida. La 5.ª ⇒ salida por el camino actual.
5. Decodificar un `WindowInfo` sin `nativeSpace` (JSON de un backend viejo) funciona y queda `nil`.

**Invariantes.** Una salida real con evidencia `normal` se refleja en ≤ 2 muestras, igual que hoy (I4). Sin evidencia nativa (`nil`), el comportamiento es el de F0-3. Ningún evento lleva títulos ni nombres.

**Verificación.** `swift test --filter FullscreenResilienceTests`, luego `swift test` completo.

---

## F0-10 · Revisión independiente: hallazgos y destino

| # | Hallazgo | Destino |
|---|---|---|
| 1 | Durante un desacuerdo, el vínculo se conserva pero `contents()`, la navegación, la captura de `layouts` y la adopción siguen tratando la ventana como normal: la tarjeta queda vacía y no se puede navegar a ella (I2); con dos fullscreen en el mismo workspace se captura y persiste un `layout` | F0-10c |
| 2 | El plazo de `.unknown` sobrevive a la recolección y a la recuperación del hogar; una ventana que vuelve (o un número reutilizado) sale en su primera muestra `.unknown` | Arreglo chico del orquestador, con test que falla antes |
| 3 | Un hogar recuperado `.standard` → fullscreen no tiene distribución recordada si `snapshot()` la descartó mientras el contenedor estaba vacío; la salida real posterior agrega la ventana al final | Sin cambio: no es regresión (antes la ventana quedaba normal al final) y en la salida real el controlador restaura `link.original` salvo que el hogar se haya editado. Límite conocido |
| 4 | Con más de 256 ventanas `.unknown` a la vez, la expulsión de la más vieja reinicia plazos en cadena y ninguna vence | Arreglo chico del orquestador: al tope no se agrega; la ventana nueva espera lugar |

---

## F0-10c · Controlador: aplicar la evidencia nativa al leer el inventario `[SUB-impl]` · tamaño S

**Archivos.** `Sources/GridCore/DynamicEngine.swift`, `Tests/GridCoreTests/FullscreenResilienceTests.swift`.

**Problema.** F0-10b decide el desacuerdo solo dentro de `reconcileFullscreen`. El resto del motor lee `nativeFullscreen` directamente del inventario: `contents(of:)` (la tarjeta exclusiva queda vacía), `NavigationSelection` (la tarjeta deja de ser elegible), `captureVisibleLayouts` (la ventana cuenta como normal de su workspace) y la adopción de espacios.

**Especificación.**

1. **Un solo punto de lectura.** Función privada `readDesktop() throws -> Desktop` que llama a `backend.desktop()` y aplica el punto 2. Reemplazar **todas** las llamadas a `backend.desktop()` de `DynamicEngine` por `readDesktop()`. `sync(_:)` guarda el resultado ya ajustado en `observed` y `state.lastDesktop`, así que `AppModel` y `NavigationSelection` ven lo mismo.
2. **Ajuste.** Para cada ventana del inventario cuya identidad tiene vínculo en `map.fullscreens`:
   - si `nativeFullscreen == false` y `nativeSpace == "fullscreen"`: devolver una copia con `nativeFullscreen = true` y `nativeMonitor = nativeMonitor ?? monitor`; insertar la identidad en `fullscreenDisagreements` y, solo si se insertó, emitir `fullscreen-doubt kind=disagree window=… pid=… space=…`;
   - en cualquier otro caso: quitar la identidad del conjunto.
   Ventanas sin vínculo: sin cambios (la evidencia nunca crea un fullscreen). Podar el conjunto a las identidades con vínculo. Como `readDesktop()` puede llamarse varias veces por refresco, el evento sale una vez por entrada en desacuerdo.
3. **Limpieza.** En `reconcileFullscreen`, la rama `nativeSpace == "fullscreen"` de F0-10b y la exclusión de vínculos en desacuerdo del pase `dormant` quedan sin efecto, porque la ventana llega con `nativeFullscreen == true`: quitarlas. Las ramas `normal`/`nil`/`unknown` de F0-10b quedan como están.

**Reproducción primero.** Escribir los tests nuevos 1 y 2 y correrlos contra el código actual: deben fallar. Pegar la salida en rojo en el informe.

**Tests nuevos (`FullscreenResilienceTests`).**
1. Desacuerdo con un vínculo exclusivo: `contents(of:)` de la tarjeta exclusiva devuelve la ventana, la del espacio hogar no la incluye, y una `NavigationSelection` construida con `observed` considera elegible la tarjeta.
2. Dos ventanas fullscreen vinculadas al mismo workspace, ambas en desacuerdo durante 5 muestras: ninguna llamada a `snapshot`, `layouts` idéntico, sin espacios nuevos. Variante: la ventana en desacuerdo aparece en un workspace desconocido ⇒ no se adopta un espacio nuevo.
3. Ventana **sin** vínculo con `nativeFullscreen: false` y `nativeSpace: "fullscreen"`: sigue siendo normal (no se crea vínculo ni tarjeta exclusiva).
4. Los tests de F0-10b siguen en verde sin cambiar sus aserciones.

**Invariantes.** Las de F0-10b, más: durante un desacuerdo, la tarjeta del vínculo conserva su contenido y es navegable (I2), y el mapa no cambia ni se persiste por esa ventana.

**Verificación.** `swift test --filter FullscreenResilienceTests`, luego `swift test` completo.

---

## F0-11 · Hallazgo de la aceptación: la ventana que vuelve no encuentra su tarjeta

**Qué pasó (2026-11-13, inyección en vivo, prueba 2 de F0-9, ya con F0-10 instalado).** `debug-blind` 30 s con `forget:true` sobre una ventana fullscreen (A) cuya tarjeta es su propio hogar (`spaceID == homeID`). El registro fue el esperado hasta la remoción: dos `fullscreen-doubt kind=absent`, `fullscreen-removed reason=closed`, la tarjeta quedó dormida en su lugar y ninguna otra cambió. Al vencer, A no volvió: Accesibilidad no lista una ventana fullscreen de un Space que no es el actual, y `forget:true` borró el hogar que la habría reportado como diferida. Al visitar su Space, el backend la registró en el workspace con foco, que era el de otra tarjeta fullscreen (B, también hogar propio). El controlador entonces partió la tarjeta de B (B se mudó a una tarjeta derivada nueva), creó otra para A (`fullscreen-created`, no `restored`) y dejó el casillero de B vacío. La tarjeta dormida de A siguió vacía.

**Causa.**
1. La remoción con `reason=closed` solo guarda un `FullscreenPlace` si `spaceID != homeID`. Una tarjeta que es su propio hogar se queda sin la identidad de su ventana: si la ventana vuelve a otro workspace, nada la asocia con su tarjeta.
2. Ni siquiera con lugar recordado se corrige el workspace: la restauración usa el hogar del workspace donde el backend puso la ventana, que puede ser cualquiera.
3. El primer bucle de `reconcileFullscreen` procesa los vínculos antes que las ventanas que vuelven, y parte una tarjeta de hogar propio ante **cualquier** otra ventana en su workspace, también una ventana fullscreen ajena que el backend dejó ahí por error.
4. El backend no tiene cómo mover una ventana en fullscreen nativo entre workspaces: `move-window` la rechaza («Exit fullscreen before moving…»).

**Principio del arreglo.** Una ventana fullscreen que vuelve con la misma identidad vuelve a **su** tarjeta y a **su** workspace, sin importar dónde la registró el backend, y antes de que el resto de los vínculos se reconcilie. Una ventana fullscreen nunca parte la tarjeta de otra. Es la defensa C completa: no depende de que la B (hogar en el backend) haya funcionado.

**Contrato común.** Operación nueva del backend propio, con la misma identidad JSON que `move-window` (`{"id","pid","boot"}`):
```
grid-layout --workspace <destino> --data '{"id":…,"pid":…,"boot":"…"}' move-fullscreen-window
```
Del lado del controlador, `Backend.moveFullscreen(window: WindowIdentity, workspace: String) throws`. Dos tareas en paralelo (directorios disjuntos).

---

## F0-11a · Backend: mover una ventana fullscreen entre workspaces `[SUB-impl]` · tamaño S

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift`, `vendor/AeroSpace/Sources/AppBundleTests/command/GridLayoutCommandTest.swift`. Parche regenerado con `scripts/regenerate-backend-patch.sh` y `UPSTREAM.md`.

**Especificación.**
1. Operación `move-fullscreen-window`, solo con backend propio (`gridOwnsBackendUI()`); sin él, el mismo error que una operación desconocida. Decodifica `GridMoveIdentity` de `--data` y resuelve el workspace destino como `move-window`.
2. Falla sin cambiar nada si: la identidad no coincide (arranque, PID o ventana inexistente) ⇒ `Window identity changed`; la ventana no está en un `MacosFullscreenWindowsContainer` ⇒ `Window is not in native fullscreen`.
3. Si la ventana ya está en el contenedor fullscreen del destino: éxito sin cambios.
4. Si no: vincularla a `destino.macOsNativeFullscreenWindowsContainer` (`INDEX_BIND_LAST`, peso 1) conservando su `layoutReason`. No cambia el foco, no toca otras ventanas, no sale de fullscreen ni cambia Spaces de macOS, no toca hogares pendientes ni el plazo `.unknown`.
5. `shouldResetClosedWindowsCache` sigue siendo verdadero para esta operación (como `move-window`).

**Reproducción primero.** Escribir los tests y correrlos contra el código actual: deben fallar (operación desconocida). Pegar la salida en rojo.

**Tests nuevos (`GridLayoutCommandTest`).**
1. Ventana en el contenedor fullscreen del workspace `a` ⇒ queda en el contenedor fullscreen de `b`, con el mismo `layoutReason`; otra ventana de `a` (normal) no se mueve; el foco no cambia.
2. Identidad con otro PID u otro arranque ⇒ error y sin cambios.
3. Ventana normal (contenedor de mosaico) ⇒ error y sin cambios.
4. Destino igual al actual ⇒ éxito y sin cambios.
5. Sin backend propio ⇒ error de operación desconocida.

**Invariantes.** La operación nunca saca una ventana de fullscreen ni mueve una ventana normal. AeroSpace independiente no cambia.

**Verificación.** `swift test --filter GridLayoutCommandTest`, suite completa del backend, parche regenerado y `git diff --stat`.

---

## F0-11b · Controlador: la ventana que vuelve recupera su tarjeta `[SUB-impl]` · tamaño M

**Archivos.** `Sources/GridCore/Engine.swift` (protocolo `Backend`), `Sources/GridCore/DynamicEngine.swift` (`reconcileFullscreen`), `Sources/AeroGrid/Backend.swift` (`AeroSpaceBackend`), `Tests/GridCoreTests/FullscreenResilienceTests.swift`.

**Especificación.**
1. **Protocolo.** `func moveFullscreen(window: WindowIdentity, workspace: String) throws` en `Backend`, con implementación por defecto en la extensión que llama a `move(window: window.id, workspace:)` (como `moveVerified`). `AeroSpaceBackend` la implementa con `["grid-layout", "--workspace", workspace, "--data", <identidad JSON>, "move-fullscreen-window"]`, igual que `moveVerified`.
2. **Memoria también para la tarjeta que es su propio hogar.** En la remoción con proceso vivo y mismo arranque, tras `absenceConfirmations`, guardar el `FullscreenPlace` también cuando `link.spaceID == link.homeID`. El resto de la remoción no cambia (la tarjeta queda, `nativeWindow = nil`, y después dormida).
3. **Pase de retorno, al principio de `reconcileFullscreen`, antes del bucle de vínculos.** Para cada ventana con `nativeFullscreen == true`, sin vínculo en `map.fullscreens` y con un lugar recordado `p` (`p.space.nativeWindow == window.identity`):
   - destino = `p.space.workspace`; actuar solo si algún espacio del mapa tiene ese workspace y la ventana está en otro;
   - `try backend.moveFullscreen(window:workspace:)` y emitir `fullscreen-return` con `detail(window.identity, p.space.id)`;
   - si falla: emitir `fullscreen-return-failed` (mismo detalle) una sola vez por identidad hasta que un intento salga bien o el lugar desaparezca; conservar el lugar; y en el segundo bucle de **este** llamado no crear ni restaurar esa ventana (se reintenta en el próximo refresco);
   - si hubo al menos un movimiento: `sync(try readDesktop())` antes del bucle de vínculos.
4. **Restauración en su propia tarjeta.** En el segundo bucle, si `remembered?.space.id == home.id` (la ventana está de nuevo en el workspace de su propia tarjeta): `shared` se calcula solo por otras ventanas del workspace, sin el término `remembered != nil`. Si no es compartido, vincular **la tarjeta actual** en su lugar (mismo `id`, `rect` y `workspace` del mapa actual, sin tocar `sourceID`), con `nativeWindow = identidad`, `FullscreenLink(spaceID: home.id, homeID: home.id, …, manuallyEdited: remembered.manuallyEdited)`, consumir el lugar y emitir `fullscreen-restored`. Si es compartido, el camino actual.
5. **Una ventana fullscreen no parte la tarjeta de otra.** En el bucle de vínculos, la partición de una tarjeta de hogar propio cuenta solo las otras ventanas con `nativeFullscreen == false`. En el segundo bucle, si una ventana fullscreen sin vínculo no tiene hogar libre, emitir `fullscreen-unplaced` con `detail(identidad, <id de la tarjeta dueña del workspace>)` una sola vez por identidad (se olvida al vincularse o desaparecer), y seguir como hoy (sin tarjeta).

**Reproducción primero.** Escribir los tests 1 y 2 y correrlos contra el código actual: deben fallar. Pegar la salida en rojo.

**Tests nuevos (`FullscreenResilienceTests`).**
1. **El caso real.** Dos tarjetas fullscreen de hogar propio: A (ventana 1, workspace `wa`) y B (ventana 2, `wb`). La ventana 1 falta `absenceConfirmations` muestras con proceso vivo ⇒ `fullscreen-removed reason=closed`. Después reaparece fullscreen en `wb`. Resultado: el backend recibió el movimiento de 1 a `wa`; la tarjeta A tiene el mismo `id` y `rect`, `nativeWindow` 1 y no está dormida; la tarjeta B idéntica a antes; ningún espacio nuevo; eventos `fullscreen-return` y `fullscreen-restored` para A.
2. Una ventana fullscreen **sin** lugar recordado aparece en el workspace de B ⇒ B idéntica, ningún espacio nuevo, `fullscreen-unplaced` una sola vez en tres muestras.
3. Lugar exclusivo (hogar compartido con ventanas normales): la ventana vuelve en otro workspace ⇒ se mueve al workspace del hogar y se restaura en el `rect` recordado con `homeID` del hogar original.
4. Falla del movimiento (el backend falso lanza): sin cambios de mapa por esa ventana, lugar conservado, un solo `fullscreen-return-failed` en dos muestras; cuando el backend deja de fallar, se restaura como en el test 1.
5. Vuelve en su propio workspace (el backend conservó el hogar): ningún movimiento, restaurada en su tarjeta con `fullscreen-restored`.
6. Su tarjeta se borró mientras faltaba: ningún movimiento, y el comportamiento de una ventana fullscreen nueva.

**Tests existentes a adaptar.** Solo los que afirman que la remoción de una tarjeta de hogar propio deja `fullscreenPlaces` vacío o que su reingreso emite `fullscreen-created`. Listarlos por nombre en el informe; cualquier otro que falle, detenerse e informar.

**Invariantes.** Una ventana que vuelve con la misma identidad recupera su tarjeta (mismo `id`; mismo `rect` salvo que esté ocupado) y su workspace. Ninguna tarjeta cambia porque otra ventana fullscreen apareció en su workspace. Las de F0-3 y F0-10 siguen valiendo. Ningún evento lleva títulos ni nombres.

**Verificación.** `swift test --filter FullscreenResilienceTests`, luego `swift test` completo.

---

## F0-11 · Revisión independiente: hallazgos y destino

Los cinco se reprodujeron con un test que falla sobre `73d2dde`.

| # | Hallazgo | Destino |
|---|---|---|
| 1 | Mover la ventana fullscreen **enfocada** deja el foco lógico en otra ventana del workspace origen. Es justo el caso real: la ventana que vuelve es la que el usuario está mirando | F0-11d |
| 2 | Si la ventana reaparece en la lectura que precede al segundo bucle (después del pase de retorno), se restaura con el hogar del workspace equivocado y consume su memoria; ningún refresco posterior lo corrige | F0-11c |
| 3 | La ventana recordada vuelve con `nativeFullscreen: false` y `nativeSpace: "fullscreen"`: el ajuste de F0-10c solo cubre vínculos, así que cuenta como intrusa normal y parte la tarjeta ajena | F0-11c (controlador) y F0-11d (el backend acepta moverla) |
| 4 | Si el usuario borró la tarjeta mientras la ventana faltaba y la ventana vuelve a un workspace con hogar libre, la tarjeta borrada resucita con `fullscreen-restored` | F0-11c |
| 5 | Si vuelve a un workspace que el mapa no conoce, `adoptUnmappedWorkspaces` crea una tarjeta antes del retorno y queda una tarjeta dormida de más | F0-11c |
| 6 | (Del orquestador, al revisar F0-11c.) Si la ventana recordada vuelve como **normal** con evidencia positiva (`nativeSpace: "normal"`, el usuario salió de fullscreen mientras faltaba), el lugar sigue vivo y una entrada posterior a fullscreen la arrastra a la tarjeta vieja | Arreglo chico del orquestador: la poda descarta el lugar ante esa evidencia. Test `testPlaceExpiresWhenWindowReturnsAsNormalWindow`, 4 fallas antes del cambio |

Los tests del revisor (`testReview…`) son la reproducción de F0-11c y F0-11d.

---

## F0-11c · Controlador: el lugar recordado manda en todo el refresco `[SUB-impl]` · tamaño S

**Archivos.** `Sources/GridCore/DynamicEngine.swift`, `Tests/GridCoreTests/FullscreenResilienceTests.swift`.

**Especificación.**
1. **Ancla.** Un `FullscreenPlace` vale solo mientras algún espacio del mapa tiene su workspace (`place.space.workspace`). Un único helper privado devuelve el lugar válido de una identidad, y todo el motor lo usa (puntos 2 a 5 y el segundo bucle). En la poda del principio del refresco (proceso vivo y mismo arranque), descartar también los lugares sin ancla. Una tarjeta borrada por el usuario, entonces, no resucita: la ventana se comporta como una fullscreen nueva.
2. **Evidencia nativa.** En `readDesktop()`, el ajuste de F0-10c (`nativeFullscreen = true`, `nativeMonitor = nativeMonitor ?? monitor` cuando `nativeFullscreen == false` y `nativeSpace == "fullscreen"`) se aplica también a ventanas **sin vínculo con un lugar válido**. Para ellas no se emite `kind=disagree` ni se toca `fullscreenDisagreements`. Ventanas sin vínculo ni lugar: sin cambios (la evidencia sigue sin crear fullscreen).
3. **Retorno también antes del segundo bucle.** El pase de retorno pasa a ser una función privada. Se llama al principio (como ahora) y otra vez después de la `sync(try readDesktop())` que precede al segundo bucle, seguida de otra `sync` si movió algo. Los fallos de ambas llamadas se acumulan en el mismo conjunto que el segundo bucle saltea. Además, el segundo bucle no vincula una ventana con lugar válido cuyo workspace difiere del de su lugar: queda para el próximo pase.
4. **Adopción.** `adoptUnmappedWorkspaces` trata como no descubribles a las ventanas con lugar válido, igual que a las fullscreen con vínculo.

**Reproducción primero.** Copiar los cuatro tests `testReview…` del controlador (y el gancho `onDesktop` de `RestoreTrackingBackend`) desde el diff que indica el brief, sin cambiar sus aserciones, y correrlos contra el código actual: deben fallar. Pegar la salida en rojo.

**Tests.** Los cuatro de la revisión, más: una ventana **sin** lugar con `nativeFullscreen: false` y `nativeSpace: "fullscreen"` sigue siendo normal. Todos los tests de F0-3, F0-10 y F0-11b siguen en verde sin cambiar aserciones.

**Invariantes.** Las de F0-11b. Ningún lugar sin ancla se usa. La evidencia nativa solo conserva un fullscreen conocido: un vínculo o un lugar válido.

**Verificación.** `swift test --filter FullscreenResilienceTests`, luego `swift test` completo.

---

## F0-11d · Backend: el movimiento conserva el foco y acepta la evidencia nativa `[SUB-impl]` · tamaño S

**Archivos.** `vendor/AeroSpace/Sources/AppBundle/command/impl/GridLayoutCommand.swift`, `vendor/AeroSpace/Sources/AppBundleTests/command/GridLayoutCommandTest.swift`. Parche regenerado y `UPSTREAM.md`.

**Especificación.**
1. **Foco.** Si la ventana movida es la enfocada, sigue enfocada después del movimiento (el foco la acompaña al workspace destino), sin activación nativa ni cambio de Space. Si la enfocada es otra, el foco no cambia (como ya prueba F0-11a).
2. **Ventana `.standard` con evidencia nativa.** Con backend propio, si la ventana no está en un contenedor fullscreen ni de apps ocultas, su `layoutReason == .standard` y la clasificación nativa es `.fullscreen`, vincularla al contenedor fullscreen del destino con `layoutReason = .macos(prevParentKind: isFloating ? .floatingWindowsContainer : .tilingContainer)`, igual que la rama de `gridApplyRecoveredWindowHome`. Con otra clasificación, el error actual `Window is not in native fullscreen`, sin cambios. La clasificación se inyecta en los tests como en F0-10a (`nativeSpaceKind` con default a la envoltura). El controlador pide esto solo para ventanas que recuerda en fullscreen, así que la evidencia sigue sin crear un fullscreen de la nada.

**Reproducción primero.** Copiar `testReviewMoveFocusedFullscreenKeepsFocusedWindow` desde el diff que indica el brief, escribir el test del punto 2 y correrlos: deben fallar. Pegar la salida en rojo.

**Tests.** El de la revisión. Ventana `.standard` con `.fullscreen` ⇒ contenedor fullscreen del destino con `.macos(prevParentKind:)` según `floating`. Con `.normal` y con `.unknown` ⇒ error y sin cambios. Los cinco de F0-11a siguen en verde sin cambiar aserciones.

**Invariantes.** Las de F0-11a, con una sola excepción: una ventana `.standard` con evidencia `.fullscreen` sí se mueve. Nunca sale de fullscreen una ventana.

**Verificación.** `swift test --filter GridLayoutCommandTest`, suite completa del backend, parche regenerado y `git diff --stat`.

---

## F0-12 · Hallazgo de la aceptación: un choque de identidad al plegar detiene el motor

**Qué pasó (2026-11-13, prueba física 1 de F0-9, build `5f8f08e`).** Con la Mac sola (`folded: true`), el usuario abrió una ventana nueva en una app cuya tarjeta externa tenía una sola ventana. La tarjeta pasó a tener dos bloques y `foldExternalSpaces()` intentó crear la hija `derivedIdentity(sourceID: <tarjeta>, component: "block-1")`. Ese workspace (`grid-derived-…`) ya pertenecía a otra tarjeta: una tarjeta con ID UUID que en algún momento adoptó el workspace de un hijo plegado anterior (el 12/11 existía la hija con ID `derived-…`; el 13/11 el mismo workspace era de una tarjeta UUID). El pliegue lanzó `La identidad de un bloque está ocupada por otro espacio`, y como lo hace dentro de `refresh()`, **todo** el refresco abortó cada 2 s: ninguna reconciliación, y todas las acciones del organizador fallaron con el mismo error (`organize` llama primero a `refresh()`). Se destrabó al cerrar la ventana nueva.

**Causa.** Un problema local de una tarjeta (identidad ya tomada) se propaga como excepción y detiene el motor entero. El origen del choque —una tarjeta adoptada que reutiliza el workspace de un hijo plegado— queda registrado como causa conocida; esta tarea no lo cambia.

**Principio del arreglo.** Una tarjeta que no se puede plegar no se pliega, se informa una vez, y el resto del motor sigue.

---

## F0-12a · Controlador: el pliegue no detiene el refresco ante un choque de identidad `[SUB-impl]` · tamaño S

**Archivos.** `Sources/GridCore/DynamicEngine.swift` (`foldExternalSpaces`), `Tests/GridCoreTests/DynamicEngineTests.swift`.

**Especificación.**
1. En `foldExternalSpaces()`, si la identidad derivada de algún bloque (`id` o `workspace`) ya la tiene otro espacio del mapa: no lanzar. Esa fuente no se pliega en este refresco (ningún cambio de mapa, `persist`, movimiento ni `restore` por ella) y el bucle sigue con las demás fuentes.
2. Emitir `fold-skipped reason=identity-taken space=<prefijo de 8 del id de la fuente> block=<n>` una sola vez mientras dure el choque de esa fuente. La memoria (en el motor, no en el mapa) se limpia para una fuente cuando una evaluación de esa fuente no choca (no hace falta plegarla o se plegó) o la fuente ya no existe.
3. No cambia nada más: ni `derivedIdentity`, ni la adopción, ni el despliegue.

**Reproducción primero.** Escribir el test 1 y correrlo contra el código actual: debe fallar (hoy `refresh()` lanza). Pegar la salida en rojo.

**Tests nuevos (`DynamicEngineTests`, sobre el fixture de bloques paralelos).**
1. Antes de desconectar, agregar al mapa un espacio con ID UUID y el workspace de `derivedIdentity(sourceID: external.id, component: "block-1")`. Desconectar y refrescar tres veces: ningún `refresh()` lanza; la fuente no tiene familia y sus ventanas no se movieron; un solo `fold-skipped` en los tres refrescos.
2. Mismo estado con una segunda fuente externa de dos bloques sin choque: en el mismo refresco, la segunda se pliega como hoy.
3. En el estado del test 1, una acción del organizador (`createSpace`) funciona.
4. Si el espacio que choca se borra, el siguiente refresco pliega la fuente como hoy, y un choque posterior vuelve a emitir el evento.

**Invariantes.** Un choque de identidad nunca detiene `refresh()` ni `organize`. Los tests de pliegue existentes siguen en verde sin cambiar aserciones. El evento no lleva títulos ni nombres.

**Verificación.** `swift test --filter DynamicEngineTests`, luego `swift test` completo.
