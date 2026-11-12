# Fase 2 — Velocidad

**Objetivo.** Llegar a cualquier espacio y reorganizar sin pasos intermedios. Puntaje objetivo: 7,6.

**Requisito.** Fase 1 cerrada (en particular F1-0, firma estable, y F1-4 etapa 1).

Mismo método que la Fase 1: cada bloque arranca con un paquete de diseño `[ORQ]` que deja una nota de decisión y las fichas para subagentes. Las vistas, los textos y las animaciones son del orquestador; la lógica pura y la integración con el sistema, de los subagentes.

Referencia visual: [`demo/proposals/ux-propuesta.html`](../../demo/proposals/ux-propuesta.html), escenas 3, 4 y 5.

---

## F2-1 · «Ir a…» y teclado

**Decisiones `[HUM]`.** Atajo global por defecto (propuesta: ⌥Espacio, configurable) y si se activan atajos de movimiento (⌃⌥ + flechas, ⌃⌥ + número). El backend lee los atajos del `~/.aerospace.toml` del usuario: hay que detectar conflictos y no pisarlos.

**Diseño `[ORQ]`.** Campo de búsqueda sobre el organizador; qué se busca (app, título de ventana, nombre de espacio) y en qué orden se ordenan los resultados; navegación con flechas dentro del mapa; Enter abre; Esc cierra; estado vacío. El panel es `nonactivating`: definir cómo recibe teclas sin robar el foco de forma visible.

**Implementación `[SUB-impl]`.**
- `SpaceSearch` en `GridCore`: función pura (consulta, espacios, ventanas) → resultados ordenados; tolerante a acentos y mayúsculas. Tests de tabla.
- Registro de atajos globales sin permisos nuevos (Carbon `RegisterEventHotKey`), con detección de conflicto y aviso.
- Navegación por flechas reutilizando `SpaceMap.neighbor`/`candidates`.
- Ajustes: sección de atajos.

**Invariantes.** Sin atajos configurados, nada cambia respecto de hoy. Un atajo en conflicto se informa, no se registra en silencio. Con AeroGrid en pausa, los atajos no actúan.

**Aceptación `[HUM]`.** Uso real con teclado durante una sesión de trabajo.

---

## F2-2 · Arrastrar la ventana real al mapa

**Exploración `[ORQ]` primero.** Preguntas a responder con una prueba mínima antes de diseñar:
- ¿Cómo saber que el usuario está arrastrando una ventana y cuál? El backend ya detecta manipulación con el mouse (`vendor/AeroSpace/Sources/AppBundle/mouse/moveWithMouse.swift`); evaluar exponer «ventana en arrastre» por `grid-layout status` o por evento.
- ¿El organizador puede abrirse y recibir el soltado mientras otra app tiene el arrastre? Hoy `WindowDragSurface` solo maneja arrastres internos.
- ¿Qué hace el tiling de AeroSpace con la ventana mientras se la arrastra?

Si alguna respuesta es «no se puede sin APIs nuevas», parar y consultar: es el paquete con más riesgo técnico de la fase.

**Diseño `[ORQ]`.** Zona de activación (la misma del hover actual, bajo la cámara) solo durante un arrastre; destinos: centro = apilar, borde = dividir, `+` = espacio nuevo (mismas reglas que `SpaceDrop`); cancelación al soltar fuera.

**Implementación `[SUB-impl]`.** Señal de arrastre desde el backend (detrás de `gridOwnsBackendUI()`, con parche y `UPSTREAM.md`) · apertura del organizador en modo «recibir ventana» · reutilizar `moveWindow`/`createSpaceAt` existentes, que ya son transaccionales.

**Aceptación `[HUM]`.** Física, en MacBook y en monitor externo. Los tests de modelo no alcanzan.

---

## F2-3 · Miniaturas opcionales

**Decisión `[HUM]`.** Requiere el permiso de Grabación de pantalla. Default propuesto: desactivado; se ofrece en Ajustes con explicación; sin permiso todo se ve como hoy.

**Exploración `[ORQ]`.** Con ScreenCaptureKit (macOS 14+): ¿se puede capturar una ventana de un workspace oculto (AeroSpace la mueve a una esquina) y una fullscreen en otro Space? Costo de CPU y memoria por captura. Si las ocultas no se pueden capturar, alternativa: guardar la última miniatura al salir de cada espacio.

**Implementación `[SUB-impl]`.** Proveedor de miniaturas con caché en memoria (nunca a disco), tamaño acotado, refresco al visitar y al abrir el organizador; degradación a ícono ante cualquier error. `[ORQ]` integra en `MiniLayoutView`.

**Invariantes.** Nunca se escribe una captura a disco ni a un registro. Sin permiso no hay ningún aviso repetido. `--benchmark-idle` no empeora con el organizador cerrado.

---

## F2-4 · Transición y pulido `[ORQ]`

Solo después de lo anterior. Que el cambio de espacio comunique la dirección (el mapa breve que ya aparece tras un gesto, con el cursor desplazándose de origen a destino); revisar tiempos y curvas de los avisos de F1-3; consistencia de materiales entre organizador, HUD y ajustes. Sin lógica nueva: no se delega.

Al cerrar la fase, regenerar la demo del producto (`demo/`) para que refleje lo construido.
