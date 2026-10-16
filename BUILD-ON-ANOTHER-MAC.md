# Compilar AeroGrid en otra Mac sin membresía paga

La compilación local no necesita Developer ID ni la membresía del Apple Developer
Program. Normalmente permite ejecutar una app creada en esa Mac sin la excepción
para un ejecutable descargado. Una política corporativa que también limite los
binarios locales puede bloquearla igualmente; en ese caso hace falta autorización
de IT. Este procedimiento no desactiva Gatekeeper ni cambia políticas del equipo.

## 1. Comprobar las herramientas

Abrí Terminal en la Mac de destino y ejecutá:

```sh
sw_vers -productVersion
xcode-select -p
swift --version
python3 --version
```

Se necesita Swift **6.2 o posterior**, un SDK de macOS compatible y Python **3.9
o posterior**. El runtime de AeroGrid requiere macOS 14+, pero las herramientas
para compilarlo tienen sus propios requisitos: por ejemplo, Xcode 26 requiere
macOS 15.6 o posterior. Las Command Line Tools de Xcode 26 también incluyen Swift;
no hace falta instalar todo Xcode si las herramientas de línea de comandos están
disponibles para esa versión de macOS.

Si faltan las herramientas, pedí su instalación desde Terminal:

```sh
xcode-select --install
```

Terminá la instalación de Apple y repetí las comprobaciones. Si el sistema solicita
credenciales de administrador que no tenés, pedile a IT las Command Line Tools
con Swift 6.2+. Si Swift sigue siendo anterior a 6.2, puede hacer falta una
actualización compatible desde Actualización de software o el portal de descargas
de Apple. No continúes con Swift 6.0/6.1.

Referencias de Apple:
- https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/
- https://developer.apple.com/xcode/system-requirements

## 2. Obtener el código

Desde Terminal:

```sh
mkdir -p "$HOME/Developer"
cd "$HOME/Developer"
git clone https://github.com/fferrioli/aerogrid.git
cd aerogrid
```

El repositorio incluye las fuentes modificadas del backend; no necesita submódulos
ni una instalación separada de AeroSpace. No incluye configuraciones personales,
estado guardado ni aplicaciones precompiladas.

Como alternativa, `python3 scripts/package-source.py` genera un ZIP de fuentes
para transferir desde otra Mac. Extraelo y abrí esa carpeta desde Terminal antes
de continuar.

## 3. Compilar en esa misma Mac

Desde la carpeta anterior:

```sh
zsh scripts/build.sh
```

El comando compila AeroGrid, su servicio de ventanas y el cliente correspondiente.
La primera vez Swift Package Manager descarga dependencias de GitHub; se necesita
conexión y que la red de la empresa permita esas descargas. El código del backend
con las correcciones de AeroGrid ya viene incluido. La arquitectura se elige según
la Mac que compila; no estás usando los ejecutables arm64 del paquete anterior.

Si hay un error, detenete y compartí el mensaje antes de instalar. Compilar no
necesita `sudo`, una cuenta de Apple Developer ni subir el código a Apple.

## 4. Instalar y abrir

Primero cerrá AeroSpace y cualquier otro gestor de ventanas. Si está abierta una
versión previa de AeroGrid, elegí **Salir de AeroGrid** en su menú; también debe
haber terminado AeroGrid Backend. Luego ejecutá:

```sh
python3 scripts/install.py
open "$HOME/Applications/AeroGrid.app"
```

El instalador usa firma ad-hoc local, instala en tu carpeta de usuario, genera
las rutas correctas y respalda la configuración existente. En una Mac sin
configuración previa crea una mínima. No se necesita instalar AeroSpace aparte.

## 5. Dar permiso y comprobar

En Ajustes del Sistema → Privacidad y seguridad → Accesibilidad, habilitá
**AeroGrid** y **AeroGrid Backend**. Si no aparecen, agregalos con `+` desde
`~/Applications`. Después pulsá **Recover** en AeroGrid.

```sh
"$HOME/.local/bin/aerogrid" --health
```

Con AeroGrid activo, `accessibilityGranted`, `backendReady` y `gestureInputReady`
deberían ser `true`. Desactivá/remapeá los gestos nativos que entren en conflicto
en Trackpad → Más gestos. AeroGrid no cambia esas opciones automáticamente.

Si la empresa bloquea incluso los ejecutables compilados localmente, guardá el
mensaje exacto para IT: esta vía no garantiza superar controles corporativos
adicionales. La estabilidad del servicio tras autorizar y los gestos físicos de
la build más reciente siguen necesitando validación en esa Mac.

## Actualizar o desinstalar

Para actualizar: Salir de AeroGrid, reemplazar el código fuente, compilar e
instalar de nuevo. Un cambio de firma puede exigir renovar ambos permisos.

Para desinstalar, cerrá primero AeroGrid y su servicio y ejecutá:

```sh
python3 scripts/uninstall.py
```

Se conservan los datos y backups. Las configuraciones existentes recuperan sus
opciones sin las adiciones de AeroGrid. Una configuración mínima creada por el
instalador queda conservada.
