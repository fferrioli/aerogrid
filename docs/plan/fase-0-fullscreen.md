# Fase 0 — Las apps en pantalla completa conservan su lugar

**Objetivo.** Una ventana en fullscreen nativo que sigue abierta conserva el mismo casillero (mismo ID, misma posición) a través de bloqueos, pantalla apagada y horas de inactividad, sin pasar por el Dock.

**Un PR.** Rama base: `t3/fullscreen-grid-position-analysis` (PR #3, el plan), o `main` si ya está mergeado. Causa raíz y evidencia: [`diagnostico.md`](diagnostico.md).

## Estrategia: tres defensas independientes

Cada una alcanza para evitar el síntoma; juntas cubren que una falle.

| Defensa | Qué hace | Paquetes |
|---|---|---|
| **A. No mirar a ciegas** | El controlador no reconcilia con la sesión bloqueada o la pantalla apagada; el backend no da ventanas por muertas en ese estado | F0-2, F0-4, F0-5 (parte C) |
| **B. No olvidar** | El backend conserva el hogar de una ventana fullscreen que WindowServer todavía lista; ya existe el mecanismo de «ventanas diferidas» que la mantiene en el inventario | F0-5 (partes A y B), F0-6 |
| **C. No decidir con una muestra, y recordar el lugar** | El controlador exige muestras consecutivas antes de borrar o dar por salida de fullscreen, y si igual borra, guarda el lugar y lo restituye cuando la misma ventana reaparece | F0-3 |

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
F0-1 (sonda, con humano) ──┬─> F0-2 ─> F0-3 ─> F0-4 ──┬─> F0-7 (revisión) ─> F0-8
                           └─> F0-5 ─> F0-6 ──────────┘
```

F0-2/3/4 tocan `Sources/` y `Tests/`; F0-5/6 tocan `vendor/AeroSpace`. Las dos ramas pueden ir en paralelo. F0-1 no bloquea el arranque de F0-2 y F0-3; sí condiciona la señal de bloqueo de F0-4 y F0-5.

---

## F0-1 · Sonda de bloqueo `[ORQ]` + `[HUM]`

**Para qué.** Confirmar en la máquina real, antes de tocar código, tres supuestos que hoy salen solo de leer el código.

**Entregable.** `scripts/probe-lock.swift` (ejecutable con `swift scripts/probe-lock.swift SALIDA.jsonl`, mismo estilo que `scripts/probe-gestures.swift`), solo lectura. Cada 2 s agrega una línea JSON con:

- hora; claves `CGSSessionScreenIsLocked` y `kCGSSessionOnConsoleKey` de `CGSessionCopyCurrentDictionary()`; bundle ID de la app frontal;
- de `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)`: para cada ventana de capa 0, número, PID dueño y `kCGWindowIsOnscreen`;
- de `~/.local/bin/aerogrid-aerospace grid-layout status`: por ventana `id`, `pid`, `workspace`, `nativeFullscreen`; la lista de IDs de `windowHomes`; `nativeVisible`. Si el comando falla, el texto del error;
- de `grid-layout native-status`: los Spaces por pantalla.

Sin títulos, sin nombres de apps. La salida va a `output/` (ignorado por git). La sonda no usa APIs privadas propias ni escribe en Application Support.

**Procedimiento `[HUM]`** (build instalado actual, sin reinstalar): con al menos dos apps en fullscreen nativo ubicadas en el mapa, copiar `state.json` a `output/` como referencia; lanzar la sonda; (1) bloquear 3 min con Ctrl+Cmd+Q y desbloquear; (2) dejar que la pantalla se apague sola ≥ 10 min y volver; detener la sonda; copiar `state.json` de nuevo.

**Qué responder** (tabla en la descripción del PR):

| Pregunta | Si la respuesta es «no» |
|---|---|
| P1. ¿Las ventanas fullscreen desaparecen de `windows` y de `windowHomes` durante el bloqueo o el apagado? | La causa raíz no es la descrita: parar y reinvestigar antes de F0-5 |
| P2. Durante el bloqueo, ¿`CGWindowList` sigue listando esas ventanas con el mismo PID, y `native-status` sigue mostrando su Space tipo 4? | En F0-5 la poda de hogares pendientes corre solo con sesión desbloqueada (ya es el default); además las ventanas retenidas no se validan contra WindowServer mientras dure el bloqueo |
| P3. ¿`CGSSessionScreenIsLocked` refleja el bloqueo de forma fiable en los dos escenarios? ¿Y la pantalla apagada sin bloqueo? | Usar como señal la combinación que sí funcione; documentarla en F0-4 y F0-5 parte C |

**Hecho cuando:** la sonda está commiteada, la tabla respondida con extractos del JSONL, y las fichas F0-4/F0-5 ajustadas si P2 o P3 dieron «no».

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

El paquete central. Convierte «presente/ausente» en «presente / en duda / confirmado ausente» y agrega memoria del lugar.

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
   Si F0-1 mostró otra señal más fiable, usar esa combinación.
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

**Contexto.** Ya existe `gridPendingWindowHomes`: hogares de ventanas que Accesibilidad todavía no expone. `status()` los incluye en `windowHomes` mientras el proceso viva, y `gridDeferredNativeWindows()` las agrega al inventario como `nativeFullscreen` si WindowServer confirma dueño y Space. Hoy solo se llena tras un reinicio del backend (`recover-homes`). Este paquete lo llena también cuando una ventana fullscreen se pierde por un apagón de Accesibilidad.

**Parte A — Retener en vez de olvidar.** En `MacWindow.garbageCollect`, hoy se llama siempre a `gridForgetRecoveredWindowHome(windowId)`. Nuevo comportamiento, solo si `gridOwnsBackendUI()`:

- Si la ventana estaba en un `MacosFullscreenWindowsContainer`, `skipClosedWindowsCache == false` (un cierre explícito pasa `true`) y su app no terminó: registrar un `GridWindowHome` con `id`, `pid`, arranque actual, nombre del workspace que la contenía y `floating` según el `prevParentKind` de su `layoutReason`. Hay que calcularlo **antes** de `unbindFromParent()`.
- En cualquier otro caso: olvidar, como hoy.
- En ambos casos se sigue limpiando el rastreador de anchos mínimos.

La decisión va en un tipo o función pura (entradas: estaba en fullscreen, cierre explícito, app terminada, backend propio) para poder testearla sin `MacWindow` real, igual que `GridNativeRecoveryEvidence`.

**Parte B — Poda de pendientes.** Un hogar pendiente se descarta cuando: el proceso no vive; el arranque difiere; o WindowServer no lista esa ventana con ese PID durante ≥ 10 s continuos **medidos solo con la sesión desbloqueada**. Guardar «ausente desde» por ID con `ProcessInfo.processInfo.systemUptime`. Evaluarlo donde `status()` ya recorre los pendientes. Política en tipo puro con tests. Esto hace cumplir I3 y evita tarjetas fantasma de ventanas cerradas en apps que siguen abiertas.

**Parte C — No recolectar con la sesión bloqueada.** En `refreshAndGetAliveWindowIds`, la partición vivos/muertos solo se saltea si la app frontal es `com.apple.loginwindow`. Para el backend propio, saltearla también cuando la sesión está bloqueada (`CGSessionCopyCurrentDictionary`, clave `CGSSessionScreenIsLocked`; o la señal que F0-1 haya validado). Leer la señal en el actor principal y pasarla al cierre, como ya se hace con `frontmostAppBundleId`.

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

**Verificación.** Tests del paquete y suite del backend; parche regenerado.

---

## F0-7 · Revisión independiente `[SUB-rev]`

**Encargo.** Diff completo de la rama contra la base + la sección **Invariantes** de este archivo + las *Reglas comunes*. Pedir bugs concretos (entrada o estado → resultado incorrecto), no opiniones de estilo. Focos a nombrar explícitamente:

- carreras entre `status` y `normalizeLayoutReason` al redescubrir una ventana (estado transitorio «presente, no fullscreen, workspace equivocado»);
- hogares pendientes que nunca se podan, o que se podan durante un bloqueo;
- compatibilidad de `SpaceMap` con estados guardados y con `MapCheckpoint`/Undo;
- cambio de pantallas (dock/undock) mientras la compuerta está cerrada, y al reabrirse;
- reinicio del backend durante el bloqueo (`backendSession` nuevo + `recover-homes`);
- números de ventana reutilizados por otro proceso;
- que algún camino siga mutando o persistiendo el mapa con la compuerta cerrada;
- fuga de títulos o nombres de apps a `diagnostics.log`.

El orquestador verifica cada hallazgo antes de actuar: un revisor también se equivoca.

---

## F0-8 · Documentación, instalación, aceptación y PR `[ORQ]` + `[HUM]`

1. **Docs.** `docs/architecture.md` (sección «Organization and recovery»: compuerta, confirmación por muestras, memoria de lugar, retención en el backend), `docs/troubleshooting.md` (sección de fullscreen: qué se ve durante el reposo, dónde mirar los eventos `map:`), `README.md` solo si cambia un límite declarado. Tablero de `docs/plan/README.md`.
2. **Suites completas**, con salida real en el PR: `swift test`; `(cd vendor/AeroSpace && swift test)`; `python3 -m unittest discover -s Tests/InstallerTests -v` (necesita `zsh scripts/build.sh` antes).
3. **Instalación** — avisar al humano antes; es la única de la fase:
   - el humano cierra con «Salir de AeroGrid» (cierra también el backend); comprobar que no queda ningún proceso;
   - `zsh scripts/build.sh` y `python3 scripts/install.py` (hace sus propios respaldos);
   - `open "$HOME/Applications/AeroGrid.app"`; el humano re-aprueba Accesibilidad para **AeroGrid** y **AeroGrid Backend**;
   - `"$HOME/.local/bin/aerogrid" --health`: `accessibilityGranted`, `backendReady` y `gestureInputReady` en `true`.
4. **Reacomodo único `[HUM]`.** El arreglo no repara lo ya desordenado: el humano vuelve a ubicar sus tarjetas fullscreen una vez. A partir de ahí deben quedar.
5. **Aceptación física `[HUM]`**, con la sonda de F0-1 corriendo para tener registro:

   | Prueba | Se espera |
   |---|---|
   | Bloquear 5 min (Ctrl+Cmd+Q) y volver | I1, I2, I5. En `diagnostics.log`: `gate: closed` y `gate: open`, ningún `fullscreen-removed` |
   | Pantalla apagada ≥ 15 min y volver | Ídem |
   | Cerrar una ventana fullscreen | I3, con `fullscreen-removed reason=closed` |
   | Salir de fullscreen en otra | I4 |
   | Cerrar la tapa con monitor externo, si aplica | Sin cambios en tarjetas fullscreen de la pantalla que sigue |
   | Una noche completa | I1. Se informa al día siguiente como seguimiento; no bloquea el merge |

6. **PR.** Descripción con: respuestas de F0-1, lista de tests agregados y adaptados, qué es simulado y qué es físico, y los resultados de la tabla. Merge cuando pasaron las cinco primeras filas. Si la prueba de la noche falla, se reabre con los registros.
