# Actualizar desde AeroGrid

Hacé clic derecho en el ícono de AeroGrid de la barra superior. Si hay una actualización, aparece **Actualizar AeroGrid…** y una **↑** junto al ícono.

1. Pulsá **Actualizar AeroGrid…**. La actualización se descarga y se prepara en segundo plano; podés seguir usando tus espacios.
2. En el mismo menú podés ver el progreso, abrir los detalles o **Cancelar actualización** durante la preparación.
3. Cuando termina de prepararse, AeroGrid se cierra, instala ambos componentes y vuelve a abrirse. Tus ventanas no se cierran.
4. Si macOS pide renovar Accesibilidad, habilitá **AeroGrid** y **AeroGrid Backend** y pulsá **Recuperar**.

**Buscar actualizaciones automáticamente** está activado inicialmente. Comprueba después de iniciar y cada seis horas; podés desactivarlo desde el menú y seguir buscando manualmente. La búsqueda nunca instala nada sin que pulses Actualizar.

## Qué necesita

La app descarga el código publicado en `fferrioli/aerogrid`, lo compila en esta Mac y usa el instalador que ya conserva tu configuración. Necesita internet, Swift 6.2 o posterior y Python 3.9 o posterior, las mismas herramientas usadas para la instalación inicial. Debe estar instalada en `~/Applications` con su backend incluido.

Esto permite seguir usando compilación local sin una membresía paga de Apple Developer. No desactiva Gatekeeper, cambia políticas de la empresa ni omite la autorización de Accesibilidad. Una política que también impida compilar/ejecutar apps locales puede requerir intervención de IT.

La actualización usa una carpeta aislada; no modifica tu checkout, tus cambios de código locales ni los lugares de tus espacios. Los huecos y distribuciones existentes conservan su posición.

## Si falla

- **Sin conexión o GitHub no responde:** volvé a buscar más tarde. La app actual sigue funcionando.
- **Faltan herramientas o falla la compilación:** abrí **Detalles de la actualización…**. Podés ver el registro o reintentar; la app no se cierra durante la preparación.
- **AeroGrid o el backend no terminan:** no se reemplazan archivos de una app en ejecución. Cerrá la instancia que siga abierta y volvé a intentar.
- **La instalación falla:** el instalador revierte sus cambios y el actualizador intenta volver a abrir la app conservada.
- **La preparación se interrumpió:** el menú vuelve a permitir reintentar después de abrir AeroGrid.

Los registros y backups están en `~/Library/Application Support/AeroGrid/updates`. No se envían a GitHub. Pueden contener rutas y configuración local: no publiques esa carpeta completa.

## Instalar el actualizador por primera vez

Una versión anterior no puede mostrar una función que todavía no tiene. Actualizala una sola vez con el procedimiento manual de [instalación](../BUILD-ON-ANOTHER-MAC.md) o [troubleshooting](troubleshooting.md#update). Las siguientes actualizaciones se hacen desde el menú.
