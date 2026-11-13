# Plan de trabajo de AeroGrid

Este directorio es el plan ejecutable para llevar AeroGrid de un puntaje de UX/UI de 5,1 a 8,3. Está escrito para que lo siga un agente orquestador que delega tareas cerradas a subagentes, gastando el mínimo de contexto.

| Archivo | Para qué | Quién lo lee |
|---|---|---|
| `README.md` (este) | Roles, reglas, protocolo por tarea, tablero de estado | Orquestador, siempre |
| [`diagnostico.md`](diagnostico.md) | Causa raíz del bug de fullscreen, hallazgos de arquitectura, puntajes | Orquestador, una vez |
| [`fase-0-fullscreen.md`](fase-0-fullscreen.md) | Arreglo del bug diario. Especificado al detalle | Orquestador; cada subagente recibe solo su tarea |
| [`fase-1-confianza.md`](fase-1-confianza.md) | Persistencia por app, avisos, canal de eventos | Ídem, cuando toque |
| [`fase-2-velocidad.md`](fase-2-velocidad.md) | Teclado, arrastre de ventanas reales, miniaturas | Ídem |
| [`fase-3-distribucion.md`](fase-3-distribucion.md) | Firma estable, onboarding, idioma | Ídem |
| [`../../demo/proposals/ux-propuesta.html`](../../demo/proposals/ux-propuesta.html) | Referencia visual animada de cada propuesta de UX (escenas 1–5) | Orquestador, al diseñar UI |

Las fases van en orden. No empezar una fase sin cerrar la anterior: cada una asume los invariantes de la previa.

**Vocabulario.** Una *tarea* es una unidad de trabajo con identificador (`F0-3`) que se encarga entera a un solo agente y termina en un commit. Una *fase* es un grupo de tareas que termina en un PR instalable. La *ficha* es la especificación de una tarea.

## Roles y modelos

| Rol | Modelo previsto | Hace | No hace |
|---|---|---|---|
| **Orquestador** `[ORQ]` | Opus 5.5, esfuerzo alto | Decisiones de diseño (UX/UI y de arquitectura no especificadas), preparar y lanzar las tareas, verificar lo que vuelve, integración, documentación, build/instalación, aceptación en vivo, PR | Implementar lógica ya especificada que un subagente puede hacer |
| **Subagente de implementación** `[SUB-impl]` | Sol 6.1 | Una tarea de lógica con especificación cerrada: código + tests + informe | Decidir diseño, tocar archivos fuera de la tarea, instalar, tocar el estado real del usuario |
| **Subagente de revisión** `[SUB-rev]` | Sol 6.1 | Buscar bugs en un diff contra los invariantes de la tarea | Reescribir el código; aprobar por estilo |
| **Humano** `[HUM]` | Fernando | Cerrar/abrir apps, re-aprobar Accesibilidad, pruebas físicas (bloqueo, monitor), decisiones marcadas | — |

Si el modelo previsto para subagentes no está disponible en el entorno, el orquestador lo informa al humano y espera; no lo sustituye por otro por su cuenta.

## Reglas comunes (pegar tal cual en cada encargo a un subagente)

1. Antes de modificar la implementación leé `AGENTS.md`, `CONTRIBUTING.md`, `docs/architecture.md` y `UPSTREAM.md`. No hace falta leer el resto de `docs/plan/`: tu tarea es autosuficiente.
2. Tocá solo los archivos que tu tarea lista. Si necesitás tocar otro, detenete e informalo.
3. **Nunca** leas, modifiques ni borres `~/Library/Application Support/AeroGrid`, `~/Applications/AeroGrid*.app` ni `~/.aerospace.toml`. Nunca ejecutes `scripts/install.py`, `scripts/uninstall.py` ni cierres o abras las apps instaladas. Los tests usan directorios temporales.
4. No debilites ni borres aserciones existentes para que un test pase. Si un test existente contradice la especificación, detenete e informalo con el nombre del test.
5. Los cambios en `vendor/AeroSpace` se limitan al backend propio: todo comportamiento nuevo va detrás de `gridOwnsBackendUI()` o dentro de los archivos `Grid*.swift`. AeroSpace independiente debe comportarse igual que antes.
6. Sin dependencias nuevas. `GridCore` solo usa Foundation (y CryptoKit, ya presente).
7. Los registros de diagnóstico no llevan títulos de ventana, nombres de apps ni rutas: solo IDs numéricos, prefijos de identificadores y motivos.
8. Los archivos `Sources/GridCore/DynamicEngine.swift` y `Sources/AeroGrid/AppModel.swift` tienen líneas muy largas: leelos por rangos, no enteros.
9. Validación: cambios del controlador con `swift test`; cambios del backend con `(cd vendor/AeroSpace && swift test)`. Corré primero solo tus tests (`swift test --filter <Clase>`) y la suite completa una vez al final.
10. Entregá un informe corto: archivos tocados, tests agregados o adaptados (con nombre), comandos ejecutados con su resultado literal, y cualquier desviación de la especificación. No describas lo que no verificaste como verificado.

## Protocolo por tarea (orquestador)

1. Leé la ficha de la tarea en el archivo de la fase. Resolvé primero lo marcado como **Decisión**.
2. Encargo al subagente = *Reglas comunes* + la ficha completa de la tarea, pegadas. No resumas la ficha: el resumen pierde las condiciones de borde.
3. Al volver: leé el diff vos mismo y corré los comandos de **Verificación** de la ficha. El informe del subagente no cuenta como evidencia.
4. Revisión independiente `[SUB-rev]`: pasale el diff y la sección **Invariantes**, no tus conclusiones. Arreglá vos los hallazgos chicos; reabrí la tarea solo si el hallazgo es de diseño.
5. Un commit por tarea. Actualizá el tablero de abajo en el mismo commit.
6. Un PR por fase (o por bloque indicado en la fase). Instalación en vivo: **una sola por PR**, al final; cada instalación con binario distinto obliga al humano a re-aprobar Accesibilidad para las dos apps.

### Cuándo parar y consultar al humano

- Hace falta cerrar las apps, instalar, aprobar permisos o hacer una prueba física.
- Una **Decisión** de la ficha no tiene default o el default no aplica.
- Un test existente solo pasa debilitando una aserción.
- El código real contradice la ficha (función que no existe, firma distinta, comportamiento distinto al descrito).
- Una API privada de macOS no responde como la ficha supone.

### Economía de contexto

- No rehagas el diagnóstico: está en `diagnostico.md` con las referencias de código.
- Las tareas que tocan directorios disjuntos (`Sources/GridCore` vs `vendor/AeroSpace`) pueden ir en paralelo; las que comparten archivo, en serie.
- La suite del backend es grande: corrida completa una vez por PR, no por tarea.
- Si la sesión se corta, el tablero y `git log` alcanzan para retomar: no hay otro estado.

## Definición de terminado (por fase)

- Suites en verde, con la salida real: `swift test`, `(cd vendor/AeroSpace && swift test)`, y las tres de Python de `CONTRIBUTING.md` si se tocó `scripts/`.
- `scripts/aerospace-grid.patch` regenerado si cambió `vendor/AeroSpace`, y `UPSTREAM.md` al día.
- Documentación al día (`docs/architecture.md`, `docs/troubleshooting.md`, `README.md` si cambia un límite declarado).
- Build e instalación hechas con las apps cerradas, configuración y distribuciones preservadas.
- Un bug se verifica **forzando el estado defectuoso** (un test que lo fabrica y falla antes del arreglo; una inyección en vivo si hay comando para eso), no esperando a que la causa ocurra. Las pruebas físicas quedan para lo que solo el sistema real puede responder.
- Aceptación: lo simulado, lo inyectado en vivo y lo físico informados por separado. Un test de modelo o una animación no cuentan como aceptación física.
- PR creado; merge cuando la aceptación física mínima de la fase pasó.

## Tablero de estado

Actualizar al cerrar cada tarea: estado (`pendiente`, `en curso`, `hecho`, `bloqueado`), PR y fecha.

| Tarea | Rol | Estado | PR | Fecha |
|---|---|---|---|---|
| F0-1 Registro pasivo del caso real (no bloquea) | SUB-impl + HUM | hecho (sonda); registro pendiente | | 2026-11-12 |
| F0-2 Compuerta de reconciliación | SUB-impl | hecho | | 2026-11-12 |
| F0-3 Reconciliación fullscreen con confianza | SUB-impl | hecho | | 2026-11-12 |
| F0-4 Conectar compuerta y registro en la app | SUB-impl | hecho | | 2026-11-12 |
| F0-5 Backend: retener ventanas fullscreen | SUB-impl | hecho | | 2026-11-12 |
| F0-6 Backend: salida de fullscreen corroborada | SUB-impl | hecho | | 2026-11-12 |
| F0-7 Backend: inyección de falla en vivo | SUB-impl | hecho | | 2026-11-12 |
| F0-8 Revisión independiente | SUB-rev | hecho | | 2026-11-12 |
| F0-9 Docs, instalación, aceptación, PR | ORQ + HUM | hecho | | 2026-11-13 |
| F0-10a Backend: evidencia nativa de tres estados (hallazgo de F0-9) | SUB-impl | hecho | | 2026-11-13 |
| F0-10b Controlador: no confirmar salida contradicha | SUB-impl | hecho | | 2026-11-13 |
| F0-10c Controlador: evidencia nativa al leer el inventario (revisión) | SUB-impl | hecho | | 2026-11-13 |
| F0-11a Backend: mover una ventana fullscreen entre workspaces (hallazgo de F0-9) | SUB-impl | hecho | | 2026-11-13 |
| F0-11b Controlador: la ventana que vuelve recupera su tarjeta | SUB-impl | hecho | | 2026-11-13 |
| F0-11c Controlador: el lugar recordado manda en todo el refresco (revisión) | SUB-impl | hecho | | 2026-11-13 |
| F0-11d Backend: el movimiento conserva el foco y acepta la evidencia nativa (revisión) | SUB-impl | hecho | | 2026-11-13 |
| F0-12a Controlador: el pliegue no detiene el refresco ante un choque de identidad (hallazgo de F0-9) | SUB-impl | hecho | | 2026-11-13 |
| F1-0 Firma local estable: decisión y prueba de concepto | ORQ + HUM | hecho | | 2026-11-13 |
| F1-0a `setup-signing.py` | SUB-impl | hecho | | 2026-11-13 |
| F1-0b Instalador: firma con identidad y reinicio TCC por DR | SUB-impl | hecho | | 2026-11-13 |
| F1-0c Docs y verificación en vivo | ORQ + HUM | hecho | | 2026-11-13 |
| F1-1 Lugares por app: diseño | ORQ | hecho | | 2026-11-13 |
| F1-1b Plantillas y emparejador puro | SUB-impl | hecho | | 2026-11-13 |
| F1-1c Backend: marca `ruled` | SUB-impl | hecho | | 2026-11-13 |
| F1-1a Captura de plantillas | SUB-impl | hecho | | 2026-11-13 |
| F1-1d Aplicación, ventana de inicio de sesión y «Restaurar lugares» | SUB-impl + ORQ | hecho (simulado) | | 2026-11-13 |
| F1-1 Revisión independiente | SUB-rev | en curso | | |
| F1-2 Setups con nombre: diseño | ORQ | hecho | | 2026-11-13 |
| F1-2a Setups: guardar y aplicar | SUB-impl | en curso | | |
| F1-2b Vistas de setups | ORQ | pendiente | | |
| F1-3 … F1-7 | ver fase 1 | pendiente | | |
| F2-1 … F2-4 | ver fase 2 | pendiente | | |
| F3-1 … F3-5 | ver fase 3 | pendiente | | |

## Mensaje de arranque para el orquestador

```text
Vas a ejecutar la Fase 0 del plan de AeroGrid. Leé docs/plan/README.md y docs/plan/fase-0-fullscreen.md
(diagnostico.md una vez, como contexto). Seguí el protocolo por tarea: vos diseñás, verificás, integrás
y hacés la aceptación; la lógica especificada y la revisión de bugs las delegás a subagentes Sol 6.1,
pasándoles las Reglas comunes más la ficha completa de la tarea. No necesitás nada de mí para empezar:
arrancá F0-2 y F0-5 en paralelo, y F0-1 aparte (cuando la sonda esté lista avisame y la dejo corriendo).
Trabajá sobre la rama t3/fullscreen-grid-position-analysis (o main si ya está mergeada). Una sola
instalación, al final, y avisame antes de cerrar las apps.
```
