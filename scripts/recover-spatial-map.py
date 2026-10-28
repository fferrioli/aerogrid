#!/usr/bin/env python3
"""Repair only stale adapted-map positions; never move windows or replace app bundles."""
import argparse
import copy
import datetime
import json
import os
import pathlib
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import uuid


def dormant(space):
    return space.get("dormant") is True and not space.get("userCreated", False) and space.get("nativeWindow") is None


def valid_rect(rect):
    return (isinstance(rect, dict)
            and all(type(rect.get(key)) is int for key in ("row", "column", "width", "height"))
            and -100000 <= rect["row"] <= 100000 and -100000 <= rect["column"] <= 100000
            and 1 <= rect["width"] <= 64 and 1 <= rect["height"] <= 64)


def overlaps(a, b):
    return (a["row"] < b["row"] + b["height"] and a["row"] + a["height"] > b["row"]
            and a["column"] < b["column"] + b["width"] and a["column"] + a["width"] > b["column"])


def repair(state):
    result = copy.deepcopy(state)
    grid = result.get("dynamicMap")
    if not isinstance(grid, dict) or grid.get("version") != 3:
        raise ValueError("Este recuperador requiere un mapa espacial de versión 3. No se modificó nada.")
    spaces = grid.get("spaces")
    if not isinstance(spaces, list) or not 1 <= len(spaces) <= 4096 or not all(isinstance(s, dict) for s in spaces):
        raise ValueError("El mapa tiene una estructura inesperada. No se modificó nada.")
    if grid.get("pending") is not None:
        raise ValueError("Hay una operación de ventanas pendiente. Este recuperador no la descarta; hace falta revisar su rollback.")
    if not all(isinstance(s.get("id"), str) and isinstance(s.get("workspace"), str) for s in spaces):
        raise ValueError("Faltan identidades de espacios. No se modificó nada.")
    if len({s["id"] for s in spaces}) != len(spaces):
        raise ValueError("Hay identidades duplicadas. No se modificó nada.")
    occupied, cleared = [], []
    for space in spaces:
        frame = space.get("foldedRect")
        if frame is None:
            continue
        if not valid_rect(frame):
            raise ValueError("Hay una posición adaptada fuera de los límites admitidos. No se modificó nada.")
        if dormant(space) or any(overlaps(frame, used) for used in occupied):
            space.pop("foldedRect", None)
            cleared.append(space["id"])
        else:
            occupied.append(frame)
    return result, cleared


def controller_running():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "AeroGrid"], capture_output=True, timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError("No se pudo comprobar si AeroGrid está cerrado. No se modificó nada.")
    return result.returncode == 0


def stop_controller():
    """Stop only owned frontend processes; keep the window engine and its live layout."""
    result = subprocess.run(["/usr/bin/pgrep", "-x", "AeroGrid"], capture_output=True, text=True, timeout=5)
    if result.returncode == 1:
        return
    if result.returncode != 0:
        raise RuntimeError("No se pudo localizar la interfaz de AeroGrid.")
    pids = [int(value) for value in result.stdout.split()]
    for pid in pids:
        info = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "comm="], capture_output=True, text=True, timeout=5)
        fields = info.stdout.strip().split(None, 1)
        if info.returncode or len(fields) != 2 or int(fields[0]) != os.getuid() or not fields[1].endswith("/AeroGrid.app/Contents/MacOS/AeroGrid"):
            raise RuntimeError("Hay un proceso AeroGrid que no se pudo verificar. Cerralo desde su menú antes de reparar.")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while controller_running() and time.monotonic() < deadline:
        time.sleep(0.05)
    if controller_running():
        raise RuntimeError("AeroGrid no terminó; no se forzó su cierre ni se modificó el estado.")


def observe_backend(directory):
    config = json.loads((directory / "config.json").read_bytes())
    cli = config.get("backendPath")
    if not isinstance(cli, str) or not pathlib.Path(cli).is_file():
        raise RuntimeError("No se encontró el cliente del backend instalado; no se modificó el estado.")
    def command(arguments):
        result = subprocess.run([cli] + arguments, capture_output=True, timeout=8)
        if result.returncode:
            raise RuntimeError("El backend no pudo confirmar el escritorio actual; no se modificó el estado.")
        return result.stdout
    desktop = json.loads(command(["grid-layout", "status"]))
    if not isinstance(desktop.get("windows"), list) or not isinstance(desktop.get("displays"), list) or not isinstance(desktop.get("visible"), dict):
        raise ValueError("El backend devolvió un inventario incompatible; no se modificó el estado.")
    layouts = {}
    workspaces = set(desktop["visible"].values()) | {w["workspace"] for w in desktop["windows"] if not w.get("nativeFullscreen", False)}
    for workspace in sorted(workspaces):
        raw = command(["grid-layout", "--workspace", workspace, "snapshot"]).decode().strip()
        parsed = json.loads(raw)
        if parsed.get("version") != 1 or not isinstance(parsed.get("tree"), dict):
            raise ValueError("El backend devolvió una distribución incompatible; no se modificó el estado.")
        layouts[workspace] = raw
    return desktop, layouts


def apply_repair(directory, running=controller_running, observation=None):
    path = directory / "state.json"
    if running():
        raise RuntimeError("Cerrá AeroGrid desde su menú antes de reparar. No se modificó nada.")
    original = path.read_bytes()
    fixed, changed = repair(json.loads(original))
    if observation is not None:
        desktop, layouts = observation
        fixed["lastDesktop"] = copy.deepcopy(desktop)
        grid = fixed["dynamicMap"]
        # Emergency recovery follows the current desktop, not older adaptation snapshots.
        for family in grid.get("families", []):
            family["manuallyEdited"] = True
        for link in grid.get("fullscreens", []):
            link["homeEdited"] = True
        compact = len(desktop["displays"]) == 1 and desktop["displays"][0].get("builtin", False)
        occupied = {window["workspace"] for window in desktop["windows"] if not window.get("nativeFullscreen", False)}
        for space in grid["spaces"]:
            if compact and space.get("preferredRole") != "builtin" and space.get("sourceID") is None and space["workspace"] in occupied:
                space["joinedWhileFolded"] = True
        for space in grid["spaces"]:
            if space.get("nativeWindow") is None and space["workspace"] in layouts:
                grid.setdefault("layouts", {})[space["id"]] = layouts[space["workspace"]]
        for display in desktop["displays"]:
            native = desktop.get("nativeVisible", {}).get(str(display["monitor"]))
            current = next((space for space in grid["spaces"] if
                (native is not None and (space.get("nativeWindow") or {}).get("id") == native)
                or (native is None and space.get("nativeWindow") is None and space["workspace"] == desktop["visible"].get(str(display["monitor"])))), None)
            if current:
                grid.setdefault("cursors", {})[display["id"]] = current["id"]
                if len(desktop["displays"]) > 1:
                    grid.setdefault("connectedCursors", {})[display["id"]] = current["id"]
    if fixed == json.loads(original):
        return None, 0
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    backup = directory / "backups" / ("spatial-recovery-" + stamp)
    backup.mkdir(parents=True, mode=0o700)
    # Retain the exact bytes, including unknown fields, before any write.
    shutil.copy2(path, backup / "state.json")
    for name in ("config.json", "control.json", "installation.json"):
        if (directory / name).exists():
            shutil.copy2(directory / name, backup / name)
    payload = (json.dumps(fixed, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".spatial-recovery-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
        if running() or path.read_bytes() != original:
            raise RuntimeError("AeroGrid se abrió o el estado cambió durante la reparación. Se conservó el archivo original.")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return backup, len(changed)


def main():
    parser = argparse.ArgumentParser(description="Reparación local de posiciones adaptadas de AeroGrid; sin red, binarios ni cambios de ventanas.")
    parser.add_argument("--apply", action="store_true", help="Aplicar con backup; requiere AeroGrid cerrado o --stop-controller")
    parser.add_argument("--stop-controller", action="store_true", help="Con --apply: cerrar sólo la interfaz, conservar el backend y releer sus ventanas/distribuciones actuales")
    parser.add_argument("--directory", type=pathlib.Path, default=pathlib.Path.home() / "Library/Application Support/AeroGrid", help="Carpeta del estado (por defecto, la instalación del usuario)")
    args = parser.parse_args()
    directory = args.directory.expanduser()
    try:
        original = json.loads((directory / "state.json").read_bytes())
        _, changes = repair(original)
        spaces = original["dynamicMap"]["spaces"]
        print("Espacios en el mapa:", len(spaces))
        print("Posiciones adaptadas para reconstruir:", len(changes))
        if args.stop_controller and not args.apply:
            raise ValueError("--stop-controller requiere --apply.")
        if args.stop_controller and directory.resolve() != (pathlib.Path.home() / "Library/Application Support/AeroGrid").resolve():
            raise ValueError("--stop-controller se usa sólo con la instalación actual del usuario.")
        if args.apply:
            observation = None
            if args.stop_controller:
                stop_controller()
                observation = observe_backend(directory)
            backup, count = apply_repair(directory, observation=observation)
            if backup is not None:
                print("Reparación aplicada:", count, "posiciones adaptadas liberadas para recalcular.")
                print("Backup:", "~/" + str(backup.relative_to(pathlib.Path.home())) if backup.is_relative_to(pathlib.Path.home()) else backup)
            else:
                print("No se encontraron posiciones adaptadas que reparar; no se cambió el estado.")
            if observation is not None:
                print("Escritorio releído del backend:", len(observation[0]["displays"]), "pantalla(s),", len(observation[0]["windows"]), "ventana(s).")
                print("Los grupos adaptados existentes quedan protegidos; podés usar Reunir grupo para unirlos después.")
            print("Se conservaron espacios, workspaces, distribución de ventanas, grupos e historial.")
            print("Abrí AeroGrid de nuevo. No hace falta reinstalar ni renovar Accessibility.")
        else:
            print("Sólo diagnóstico: ningún archivo fue modificado. Usá --apply con AeroGrid cerrado para reparar.")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        note = "Si se cerró la interfaz, podés abrir AeroGrid de nuevo; el backend y las ventanas no se eliminaron.\n" if args.stop_controller else ""
        parser.exit(1, "Error: " + str(error) + "\n" + note)


if __name__ == "__main__":
    main()
