#!/usr/bin/env python3
"""Validate, stage, and back up the complete installation before committing it."""
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from configuration import atomic_write, prepare_config, write_json

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOME = pathlib.Path.home()
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
APPS = HOME / "Applications"
SUPPORT = HOME / "Library/Application Support/AeroGrid"
BACKUPS = SUPPORT / "backups" / STAMP


def run(*args):
    subprocess.run(args, check=True, timeout=60)


def designated_requirement(path):
    if not path.exists():
        return None
    result = subprocess.run(["codesign", "--display", "-r-", str(path)], capture_output=True, text=True, timeout=10)
    if result.returncode:
        return None
    for line in (result.stdout + result.stderr).splitlines():
        if line.startswith("# designated => "):
            return line.removeprefix("# designated => ")
    return None


def reset_changed_adhoc_permissions(previous, current):
    identities = {"AeroGrid.app": "local.AeroGrid", "AeroGrid Backend.app": "local.AeroGrid.Backend"}
    for name, identifier in identities.items():
        requirement = current.get(name)
        if requirement and requirement.startswith("cdhash ") and previous.get(name) != requirement:
            # Reset before either new app requests approval; never reset after its prompt.
            run("tccutil", "reset", "Accessibility", identifier)


def ensure_apps_stopped():
    for name, executable in [("AeroGrid", "AeroGrid"), ("AeroGrid Backend", "AeroSpace")]:
        path = APPS / f"{name}.app/Contents/MacOS/{executable}"
        found = subprocess.run(["pgrep", "-f", re.escape(str(path))], capture_output=True)
        if found.returncode == 0:
            raise RuntimeError(f"Quit {name} before installing. No installed files were changed.")


def validate_configuration(configuration):
    with tempfile.TemporaryDirectory(prefix="aerogrid-validate-") as temporary:
        path = pathlib.Path(temporary) / "config.json"
        write_json(path, configuration)
        result = subprocess.run([str(ROOT / ".build/release/AeroGrid"), "--validate-config", str(path)], capture_output=True, text=True, timeout=10)
        if result.returncode or result.stdout.strip() != "AeroGrid configuration is valid":
            raise ValueError(result.stderr.strip() or "Rebuild AeroGrid before installing; its configuration validator is unavailable.")


def bundle(directory, name, executable, identifier, source, resources):
    target = directory / f"{name}.app"
    contents = target / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(source, contents / "MacOS" / executable)
    info = dict(CFBundleIdentifier=identifier, CFBundleName=name,
                CFBundleDisplayName=name, CFBundleExecutable=executable,
                CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="0.1",
                LSUIElement=True, LSMinimumSystemVersion="14.0", NSHighResolutionCapable=True)
    if identifier == "local.AeroGrid":
        metadata = ROOT / ".build/build-info.json"
        if metadata.exists():
            build = json.loads(metadata.read_text())
            if build.get("revision") is not None and not re.fullmatch(r"[0-9a-f]{40}", build["revision"]):
                raise ValueError("Invalid build revision; run scripts/build.sh again")
            if build.get("revision"):
                info["AeroGridRevision"] = build["revision"]
            info["AeroGridSourceDirty"] = build.get("dirty", False)
            info["AeroGridBuiltAt"] = build["builtAt"]
        info["AeroGridPythonPath"] = sys.executable
        info["UTExportedTypeDeclarations"] = [dict(
            UTTypeIdentifier="local.AeroGrid.organization",
            UTTypeConformsTo=["public.data"],
            UTTypeDescription="AeroGrid organization item")]
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    for resource in resources:
        shutil.copy2(resource, contents / "Resources" / resource.name)
    run("codesign", "--force", "--deep", "--sign", "-", str(target))
    run("codesign", "--verify", "--deep", str(target))
    return target


def default_config(cli):
    grids = []
    for identity, name, role in [("laptop", "MacBook", "builtin"), ("external", "Ultrawide", "external")]:
        cells = [dict(id=str(uuid.uuid4()), row=r, column=c, name=f"{r+1},{c+1}",
                      workspace=f"grid-{identity}-{r+1}-{c+1}", profile="automatic")
                 for r in range(3) for c in range(3)]
        grids.append(dict(id=identity, name=name, displayRole=role, rows=3, columns=3, wrap=False, cells=cells))
    bindings = [dict(fingers=f, modifiers=0, direction=d, action="navigate", scope="active" if f == 3 else "all")
                for f in [3, 4] for d in ["left", "right", "up", "down"]]
    bindings += [dict(fingers=3, modifiers=4, direction=d, action=a, scope="active")
                 for d, a in [("right", "next-grid"), ("left", "previous-grid"), ("up", "next-window"), ("down", "previous-window")]]
    return dict(version=1, grids=grids, displayAssignments={}, targeting="pointer", threshold=0.055,
                invert=False, bindings=bindings, automaticLayouts=True, compactMinimumWidth=650, backendPath=str(cli))


def commit_install(staged, configuration, aerospace_path, updated, manifest, initial_config=None):
    """Keep rollback copies until every bundle, config, and launcher has committed."""
    BACKUPS.mkdir(parents=True)
    config_path = SUPPORT / "config.json"
    manifest_path = SUPPORT / "installation.json"
    files = [config_path, manifest_path]
    if aerospace_path is not None:
        files.append(aerospace_path)
    prior_files = {path: path.read_bytes() if path.exists() else None for path in files}
    for path, data in prior_files.items():
        if data is not None:
            name = "aerospace.toml" if path == aerospace_path else path.name
            shutil.copy2(path, BACKUPS / name)
    if initial_config is not None:
        # A clean Mac has no original config; retain the seed for later updates/uninstall.
        atomic_write(BACKUPS / "aerospace.toml", initial_config)
    local_bin = HOME / ".local/bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    replacements = []
    try:
        for source in staged:
            target = APPS / source.name
            previous = None
            if target.exists():
                shutil.copytree(target, BACKUPS / target.name, symlinks=True)
                previous = source.parent / (source.name + ".previous")
                target.rename(previous)
            replacements.append((target, previous))
            source.rename(target)
        write_json(config_path, configuration)
        if aerospace_path is not None:
            atomic_write(aerospace_path, updated)
        write_json(manifest_path, manifest)
        for name, target in [("aerogrid", APPS / "AeroGrid.app/Contents/MacOS/AeroGrid"), ("aerogrid-aerospace", APPS / "AeroGrid Backend.app/Contents/Resources/aerospace")]:
            link = local_bin / name
            previous = None
            if link.exists() or link.is_symlink():
                previous = staged[0].parent / (name + ".previous")
                if link.is_symlink():
                    (BACKUPS / (name + ".link")).write_text(os.readlink(link))
                else:
                    shutil.copy2(link, BACKUPS / name)
                link.rename(previous)
            replacements.append((link, previous))
            link.symlink_to(target)
    except Exception:
        for target, previous in reversed(replacements):
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.is_dir():
                shutil.rmtree(target)
            if previous is not None:
                previous.rename(target)
        for path, data in prior_files.items():
            if data is None:
                if path.exists():
                    path.unlink()
            else:
                atomic_write(path, data)
        raise


def main():
    ensure_apps_stopped()
    previous_requirements = {name: designated_requirement(APPS / name) for name in ["AeroGrid.app", "AeroGrid Backend.app"]}
    cli = APPS / "AeroGrid Backend.app/Contents/Resources/aerospace"
    config_path = SUPPORT / "config.json"
    configuration = json.loads(config_path.read_text()) if config_path.exists() else default_config(cli)
    configuration["backendPath"] = str(cli)
    validate_configuration(configuration)
    aerospace_path = HOME / ".aerospace.toml"
    if not aerospace_path.exists():
        aerospace_path = HOME / ".config/aerospace/aerospace.toml"
    initial_config = None
    if aerospace_path.exists():
        original = aerospace_path.read_text()
    else:
        aerospace_path = HOME / ".aerospace.toml"
        original = initial_config = 'config-version = 2\nstart-at-login = false\npersistent-workspaces = []\n\n[mode.main.binding]\n'
    manifest_path = SUPPORT / "installation.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else dict(aerospaceConfig=str(aerospace_path), backup=str(BACKUPS / "aerospace.toml"))
    initial_path = pathlib.Path(manifest["backup"])
    initial = initial_path.read_text() if manifest_path.exists() else original
    required = [cell["workspace"] for grid in configuration["grids"] for cell in grid["cells"]]
    updated, ownership = prepare_config(original, required, initial, manifest)
    manifest.update(ownership, installedApps=[str(APPS / "AeroGrid.app"), str(APPS / "AeroGrid Backend.app")],
                    installedConfigHash=hashlib.sha256(updated.encode()).hexdigest(), backendBundleIdentifier="local.AeroGrid.Backend")
    APPS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".aerogrid-staging-", dir=str(APPS)) as temporary:
        directory = pathlib.Path(temporary)
        backend = bundle(directory, "AeroGrid Backend", "AeroSpace", "local.AeroGrid.Backend",
                         ROOT / "vendor/AeroSpace/.build/release/AeroSpaceApp",
                         [ROOT / "vendor/AeroSpace/docs/config-examples/default-config.toml", ROOT / "vendor/AeroSpace/.build/release/aerospace"])
        app = bundle(directory, "AeroGrid", "AeroGrid", "local.AeroGrid", ROOT / ".build/release/AeroGrid", [ROOT / "scripts/update-worker.py"])
        current_requirements = {path.name: designated_requirement(path) for path in [backend, app]}
        ensure_apps_stopped()
        commit_install([backend, app], configuration, aerospace_path, updated, manifest, initial_config)
        try:
            for name in current_requirements:
                run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(APPS / name))
            reset_changed_adhoc_permissions(previous_requirements, current_requirements)
        except (subprocess.CalledProcessError, OSError) as error:
            print(f"Apps installed, but permission-record refresh failed: {error}. Remove and re-add the affected AeroGrid entry in Accessibility.", file=sys.stderr)
    print(f"Installed {APPS / 'AeroGrid.app'}\nInstalled {APPS / 'AeroGrid Backend.app'}\nConfiguration backup: {BACKUPS}")


if __name__ == "__main__":
    main()
