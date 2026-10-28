#!/usr/bin/env python3
"""Build an explicitly selected public revision; install only after app handoff.

No sudo, TCC bypass, downloaded executables, or edits to an existing checkout.
The installed controller starts this worker and watches its private status file.
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "fferrioli/aerogrid"
MAX_ARCHIVE = 160 * 1024 * 1024
MAX_EXPANDED = 600 * 1024 * 1024


class Cancelled(Exception):
    pass


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def status(job, phase, message):
    write_json(job / "status.json", dict(phase=phase, message=message, workerPID=os.getpid()))


def check_cancel(job):
    if (job / "cancel").exists():
        raise Cancelled()


def run_command(args, job, cwd=None, env=None, timeout=1800, cancellable=True):
    with (job / "build.log").open("ab") as log:
        process = subprocess.Popen(args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if cancellable:
                    check_cancel(job)
                if cancellable and time.monotonic() >= deadline:
                    raise RuntimeError("La operación superó su tiempo máximo. La instalación anterior se conserva.")
                time.sleep(0.2)
            if process.returncode:
                raise RuntimeError("No se pudo completar la preparación. Consultá el registro de la actualización.")
        except BaseException:
            if not cancellable:
                # Never interrupt the installer's bundle/config commit. Its
                # external commands have their own bounded timeouts.
                process.wait()
            elif process.poll() is None:
                # This session contains only our build/installer children.
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise


class GitHubRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        parsed = urllib.parse.urlparse(new_url)
        if parsed.scheme != "https" or parsed.hostname not in {"github.com", "codeload.github.com", "api.github.com"}:
            raise RuntimeError("El servidor devolvió una descarga inesperada.")
        return super().redirect_request(request, file, code, message, headers, new_url)


def download_archive(revision, destination, job):
    request = urllib.request.Request(f"https://codeload.github.com/{REPOSITORY}/zip/{revision}", headers={"User-Agent": "AeroGrid-Updater"})
    opener = urllib.request.build_opener(GitHubRedirects())
    total = 0
    deadline = time.monotonic() + 180
    with opener.open(request, timeout=30) as response, destination.open("wb") as output:
        while True:
            check_cancel(job)
            data = response.read(512 * 1024)
            if not data:
                break
            total += len(data)
            if total > MAX_ARCHIVE or time.monotonic() > deadline:
                raise RuntimeError("La descarga excede el límite permitido.")
            output.write(data)


def extract_archive(archive, destination, revision):
    prefix = f"aerogrid-{revision}"
    destination.mkdir()
    links = []
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if len(members) > 30000 or sum(item.file_size for item in members) > MAX_EXPANDED:
            raise ValueError("Archivo de actualización demasiado grande")
        for item in members:
            relative = pathlib.PurePosixPath(item.filename)
            if relative.is_absolute() or ".." in relative.parts or "\\" in item.filename or not relative.parts or relative.parts[0] != prefix:
                raise ValueError("Ruta no válida en la actualización")
            path = destination.joinpath(*relative.parts)
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                if len(relative.parts) == 1 or item.file_size > 4096:
                    raise ValueError("Enlace demasiado grande")
                links.append((path, source.read(item).decode("utf-8")))
            elif item.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                if stat.S_IFMT(mode) not in {0, stat.S_IFREG}:
                    raise ValueError("Tipo de archivo inesperado")
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.open(item) as data, path.open("xb") as output:
                    shutil.copyfileobj(data, output)
                path.chmod(0o755 if mode & 0o111 else 0o644)
    root = destination / prefix
    resolved_root = root.resolve()
    # Source includes three upstream links. Create them only after all writes,
    # then validate their resolved destinations, including chains of links.
    for path, target in links:
        parent_inside = path.parent.resolve().is_relative_to(resolved_root)
        target_inside = (path.parent / target).resolve().is_relative_to(resolved_root)
        if pathlib.PurePosixPath(target).is_absolute() or not parent_inside or not target_inside:
            raise ValueError("Enlace fuera del código de la actualización")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
    for path, _ in links:
        if not path.resolve().is_relative_to(resolved_root):
            raise ValueError("Enlace fuera del código de la actualización")
    for required in ["Package.swift", "scripts/build.sh", "scripts/install.py", "scripts/update-worker.py"]:
        if not (root / required).is_file():
            raise ValueError("La actualización está incompleta")
    return root


def running_bundles(home):
    for app, executable in [("AeroGrid", "AeroGrid"), ("AeroGrid Backend", "AeroSpace")]:
        path = home / f"Applications/{app}.app/Contents/MacOS/{executable}"
        result = subprocess.run(["/usr/bin/pgrep", "-f", re.escape(str(path))], capture_output=True, timeout=5)
        if result.returncode == 0:
            return True
        if result.returncode != 1:
            raise RuntimeError("No se pudo comprobar que AeroGrid terminó. No se instalará la actualización.")
    return False


def verify_controller(pid, home):
    if not isinstance(pid, int) or pid <= 1:
        raise ValueError("Proceso de AeroGrid inválido")
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "comm="], capture_output=True, text=True, timeout=5)
    fields = result.stdout.strip().split(maxsplit=1)
    expected = (home / "Applications/AeroGrid.app/Contents/MacOS/AeroGrid").resolve()
    if result.returncode or len(fields) != 2 or fields[0] != str(os.getuid()) or pathlib.Path(fields[1]).resolve() != expected:
        raise ValueError("La actualización no fue iniciada por AeroGrid instalado")


def await_handoff(job, home, timeout=900):
    deadline = time.monotonic() + timeout
    while not (job / "install").exists():
        check_cancel(job)
        if time.monotonic() > deadline:
            raise RuntimeError("AeroGrid no confirmó la instalación. No se modificaron las apps.")
        time.sleep(0.2)
    # No cancellations once the UI has requested the atomic installation.
    deadline = time.monotonic() + 60
    while running_bundles(home):
        if time.monotonic() > deadline:
            raise RuntimeError("AeroGrid o su backend siguen abiertos. No se modificaron las apps.")
        time.sleep(0.2)


def backup_state(home, job):
    backup = job / "backup"
    backup.mkdir(mode=0o700)
    support = home / "Library/Application Support/AeroGrid"
    for name in ["state.json", "config.json", "control.json", "installation.json"]:
        path = support / name
        if path.exists():
            shutil.copy2(path, backup / name)


def update(job, home):
    if sys.version_info < (3, 9):
        raise RuntimeError("Se necesita Python 3.9 o posterior para preparar la actualización.")
    request = json.loads((job / "request.json").read_text())
    revision = request.get("revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Revisión de actualización inválida")
    verify_controller(request.get("controllerPID"), home)
    status(job, "preparing", "Comprobando las herramientas…")
    tools = subprocess.run(["/usr/bin/xcrun", "swift", "--version"], capture_output=True, text=True, timeout=30)
    version = re.search(r"Swift version (\d+)\.(\d+)", tools.stdout)
    if tools.returncode or version is None or tuple(map(int, version.groups())) < (6, 2):
        raise RuntimeError("Se necesita Swift 6.2 o posterior. Instalá o actualizá las herramientas de Xcode para continuar.")
    status(job, "downloading", "Descargando actualización…")
    archive = job / "source.zip"
    download_archive(revision, archive, job)
    root = extract_archive(archive, job / "source", revision)
    check_cancel(job)
    status(job, "building", "Preparando AeroGrid en esta Mac…")
    environment = dict(os.environ, AEROGRID_BUILD_REVISION=revision)
    run_command(["/bin/zsh", "scripts/build.sh"], job, cwd=root, env=environment)
    info = json.loads((root / ".build/build-info.json").read_text())
    if info.get("revision") != revision or info.get("dirty"):
        raise RuntimeError("La compilación no corresponde a la actualización elegida.")
    config = home / "Library/Application Support/AeroGrid/config.json"
    run_command([str(root / ".build/release/AeroGrid"), "--validate-config", str(config)], job, timeout=30)
    status(job, "ready", "Lista para instalar y reiniciar…")
    try:
        await_handoff(job, home)
        backup_state(home, job)
        status(job, "installing", "Instalando y reiniciando AeroGrid…")
        run_command([sys.executable, "scripts/install.py"], job, cwd=root, timeout=120, cancellable=False)
    except Cancelled:
        raise
    except Exception:
        # Reopen the preserved controller even if a stuck backend prevented the
        # handoff. `open` also safely reuses an already running controller.
        subprocess.run(["/usr/bin/open", str(home / "Applications/AeroGrid.app")], timeout=15)
        raise
    status(job, "complete", "AeroGrid se actualizó correctamente")
    subprocess.run(["/usr/bin/open", str(home / "Applications/AeroGrid.app")], check=True, timeout=15)
    # Large source/build files are disposable. Keep status, private log, and backup.
    shutil.rmtree(job / "source", ignore_errors=True)
    archive.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", type=pathlib.Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    home = pathlib.Path.home()
    job = args.job.resolve()
    updates = (home / "Library/Application Support/AeroGrid/updates").resolve()
    if job.parent != updates or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", job.name):
        raise ValueError("Carpeta de actualización inválida")
    try:
        update(job, home)
    except Cancelled:
        status(job, "cancelled", "Actualización cancelada; seguís usando la versión anterior")
        shutil.rmtree(job / "source", ignore_errors=True)
        (job / "source.zip").unlink(missing_ok=True)
    except Exception as error:
        status(job, "failed", str(error))
        # Never send build logs, local paths, configuration or app titles remotely.
        with (job / "build.log").open("a") as log:
            log.write(f"\nUpdate failed: {error}\n")
        shutil.rmtree(job / "source", ignore_errors=True)
        (job / "source.zip").unlink(missing_ok=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
