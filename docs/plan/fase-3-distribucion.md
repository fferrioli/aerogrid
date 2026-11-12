# Fase 3 — Distribución y primer uso

**Objetivo.** Que instalar, actualizar y aprender AeroGrid no sea un obstáculo. Puntaje objetivo: 8,3.

**Requisito.** Fase 2 cerrada.

---

## F3-1 · Distribución firmada `[HUM]` decide, `[ORQ]` diseña

**Decisión `[HUM]`.** Dos caminos:

| | Qué implica | Resultado |
|---|---|---|
| **A. Developer ID + notarización** | Cuenta de Apple Developer (paga, anual). El actualizador deja de compilar en la Mac del usuario y pasa a descargar una versión publicada | Instalación con doble clic; sin Swift ni Python en la máquina; permisos estables. Es lo que lleva «Instalación» a 7 |
| **B. Seguir con build local** | Se mantiene F1-0 (certificado local) y el flujo actual | Sin costo; «Instalación» queda cerca de 4–5 y el objetivo global baja a ~8,0 |

Sin esta decisión no se empieza la fase.

**Si A.** `[ORQ]` rediseña el actualizador (publicación de versiones, verificación de firma antes de reemplazar, reversión) y conserva el camino de compilación local para desarrollo. `[SUB-impl]` implementa empaquetado, verificación y los tests en `Tests/UpdateTests`. Las credenciales de firma nunca entran al repo ni a los registros.

## F3-2 · Primer uso `[ORQ]` diseña

Asistente de una pantalla con el estado en vivo de cada requisito: los dos permisos de Accesibilidad (con botón que abre el panel correcto), gestos del sistema que chocan (Mission Control, App Exposé, arrastre con tres dedos; AeroGrid solo informa, no los cambia), y una práctica de «deslizá, mantené, soltá» con el modo de prueba de gestos que ya existe. `[SUB-impl]`: detección de cada requisito como funciones puras o consultables.

## F3-3 · Un idioma por configuración

`[ORQ]` define el inventario de textos y el criterio (español e inglés completos; idioma del sistema por defecto). `[SUB-impl]`: `GridError` y los mensajes de `GridCore` pasan a códigos con parámetros; las cadenas viven en la app (catálogo de cadenas). Test: ninguna cadena visible queda fuera del catálogo.

## F3-4 · Nombres y mensajes `[ORQ]`

Revisión de todos los textos visibles con el criterio de F1-6: sin nombres técnicos, errores que dicen qué pasó y qué hacer. Sin lógica: no se delega.

## F3-5 · Cierre `[ORQ]`

`README.md` (límites actuales, instalación nueva), guías en español, demo del producto regenerada, y una pasada de puntaje con el mismo criterio de `diagnostico.md` para comprobar si se llegó al objetivo. Si hay usuarios disponibles además del autor, una prueba corta de primer uso vale más que el puntaje propio.
