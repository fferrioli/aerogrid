# Diagnóstico (noviembre de 2026)

Contexto para el orquestador. Los subagentes no necesitan leerlo.

## Síntoma

Tras unas horas con la pantalla bloqueada o apagada, las apps en pantalla completa nativa desaparecen del mapa. Hay que abrirlas desde el Dock; reaparecen, pero en otro casillero. Ocurre a diario.

## Causa raíz

AeroGrid trata «ahora no puedo observar esta ventana» como «se cerró» (o «salió de fullscreen»), lo decide con una sola lectura y persiste el resultado.

1. **Bloqueo.** Con la pantalla bloqueada, la API de Accesibilidad deja de responder. El backend da por muertas las ventanas: `MacApp.refreshAndGetAliveWindowIds` (`vendor/AeroSpace/Sources/AppBundle/tree/MacApp.swift`) las saca de `alive` y `MacWindow.garbageCollect` llama a `gridForgetRecoveredWindowHome`, que también borra su «hogar» pendiente. La única defensa es comparar la app frontal con `com.apple.loginwindow`.
2. **El controlador sigue consultando.** `AppModel.start` programa `refresh()` cada 2 s y no hay detección de bloqueo ni de pantalla apagada (solo `didWake`/`willSleep` del sistema). Al no ver ni la ventana ni su hogar, `DynamicEngine.reconcileFullscreen` borra el vínculo y el casillero derivado y `persist()` lo guarda.
3. **Las ventanas normales vuelven; las fullscreen no.** Al desbloquear, Accesibilidad vuelve a listar las ventanas del Space actual. Una ventana fullscreen vive en su propio Space y solo se lista al visitarlo: de ahí el clic en el Dock.
4. **Lugar equivocado.** Al redescubrirla, el backend la registra como nueva en el workspace con foco (`MacWindow.getOrRegister`), y el controlador crea un casillero nuevo con `map.vacant(near: home)`. La posición elegida se perdió en el paso 2.

**Segundo modo de falla.** Una sola muestra con `nativeFullscreen == false` se toma como salida real de fullscreen. Si el vínculo estaba `manuallyEdited`, el casillero se convierte en espacio normal y la ventana se muda a un workspace nuevo (`backend.moveVerified`). Puede dispararse por el estado transitorio entre el re-registro de la ventana y `normalizeLayoutReason`, o porque `isMacosNativeFullscreen` devuelve `nil` (app que no responde) y `== true` lo convierte en `false`.

## Evidencia

| Evidencia | Tipo |
|---|---|
| En el estado guardado, una misma identidad de ventana (mismo proceso, misma ventana, mismo arranque) aparece con tres casilleros derivados distintos a lo largo del historial, sin acciones de organización entre medio. Dos ventanas distintas muestran el mismo patrón. | Observado en la instalación real |
| Una de esas transiciones conserva el ID del casillero pero cambia `homeID` a sí mismo y pone `manuallyEdited` en falso: es exactamente el resultado del segundo modo de falla. | Observado |
| Registro de energía con periodos de pantalla apagada de varias horas. | Observado |
| Los dos modos de falla reproducidos en el motor con tests temporales sobre `MapBackend`. | Simulado |
| Que el backend pierde las ventanas al bloquear. | Leído en el código (lo describe el comentario de `closedWindowsCache.swift`); **no observado en vivo**. El paquete F0-1 lo confirma. |

El arreglo anterior («Recover background fullscreen windows before AX discovery») cubre el reinicio del backend (`backendSession` distinto → `recoverWindowHomes`). El bloqueo no cambia la sesión, así que no se dispara.

## Hallazgos de arquitectura

Lo que está bien: separación `GridCore` (modelo puro) / `AeroGrid` (UI y entrada) / fork de AeroSpace detrás del comando versionado `grid-layout`; organización transaccional con rollback y Undo; identidad de ventana por (ventana, PID, arranque); 237 tests propios y unos 430 del backend.

| Hallazgo | Dónde | Se trata en |
|---|---|---|
| No existe el estado «desconocido»: presente o ausente | `DynamicEngine.reconcileFullscreen`, marcado de `dormant` al final de `refresh()` | Fase 0 |
| Sin detección de sesión bloqueada o pantalla apagada | `AppModel.start` / `refresh` | Fase 0 |
| Los cambios automáticos del mapa no dejan rastro en `diagnostics.log` | `AppModel.log` solo recibe entrada y navegación | Fase 0 |
| Sondeo por subprocesos: ~6 `grid-layout status` + un `snapshot` por espacio ocupado cada 2 s, cada uno un `Process` con directorio temporal | `DynamicEngine.refresh`, `AeroSpaceBackend.run` | Fase 1 |
| `state.json` ronda 1 MB y ~60 % es historial de Undo; se serializa y compara entero en cada ciclo | `Store.save`, `SpaceMap.undo` | Fase 1 |
| Los lugares están atados a ventanas (ID + arranque), no a apps: nada sobrevive a un reinicio | `WindowIdentity`, `LayoutSnapshot.boot` | Fase 1 |
| Espacios dormidos que no se limpian nunca; nombres técnicos visibles (`grid-space-…`) | `SpaceMap.spaces` | Fase 1 |
| `DynamicEngine` (1.113 líneas densas) mezcla reconciliación, organización, navegación y migraciones; `AppModel` tiene 23 `@Published` | — | Extraer por partes al tocar cada zona; sin reescritura global |
| Cada instalación con binario distinto reinicia el permiso de Accesibilidad (`reset_changed_adhoc_permissions` en `scripts/install.py`) | Firma ad-hoc | Fase 1 (F1-0) y Fase 3 |
| Sin teclado ni búsqueda; solo se arrastra dentro del organizador; sin miniaturas | UI | Fase 2 |
| Mensajes en español e inglés mezclados dentro de `GridCore` | `GridError` | Fase 3 |

## Puntaje de UX/UI

Criterio propio, promedio simple de 7 dimensiones (1–10) para el trabajo «armar y navegar un setup multi-app». No es una medición con usuarios.

| | Fiab. | Naveg. | Organiz. | Aprend. | Pulido | Instal. | Teclado | Total |
|---|---|---|---|---|---|---|---|---|
| Windows 11 nativo | 8 | 5 | 8 | 8 | 8 | 10 | 8 | 7,9 |
| macOS nativo | 7 | 5 | 6 | 8 | 9 | 10 | 6 | 7,3 |
| Rectangle Pro / Moom | 8 | 2 | 7 | 8 | 7 | 8 | 8 | 6,9 |
| FancyZones | 8 | 3 | 8 | 6 | 6 | 8 | 7 | 6,6 |
| AeroSpace | 6 | 6 | 4 | 3 | 3 | 7 | 10 | 5,6 |
| **AeroGrid hoy** | 3 | 9 | 8 | 6 | 6 | 3 | 1 | **5,1** |
| yabai + skhd | 6 | 6 | 4 | 2 | 3 | 3 | 10 | 4,9 |

Objetivo por fase: F0 → 5,6 (fiabilidad 6) · F1 → 6,3 (fiabilidad 9, aprendizaje 7, pulido 7) · F2 → 7,6 (teclado 8, organización 9, pulido 8) · F3 → 8,3 (instalación 7, aprendizaje 8).
