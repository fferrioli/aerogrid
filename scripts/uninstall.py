#!/usr/bin/env python3
"""Remove owned app bundles and merge out owned AeroSpace settings, preserving backups."""
import json
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from configuration import atomic_write, remove_owned_settings

HOME = pathlib.Path.home()
SUPPORT = HOME / "Library/Application Support/AeroGrid"


def main():
    manifest_path = SUPPORT / "installation.json"
    if not manifest_path.exists():
        raise SystemExit("No AeroGrid installation manifest; no files were removed.")
    manifest = json.loads(manifest_path.read_text())
    for name in ["AeroGrid", "AeroSpace"]:
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            raise SystemExit("Quit AeroGrid and AeroGrid Backend first. Your backup and data are preserved.")
    path = pathlib.Path(manifest["aerospaceConfig"])
    if path.exists():
        text = path.read_text()
        original = pathlib.Path(manifest["backup"]).read_text()
        restored = remove_owned_settings(text, original, manifest)
        atomic_write(SUPPORT / "aerospace-before-uninstall.toml", text)
        atomic_write(path, restored)
    expected = [HOME / "Applications/AeroGrid.app", HOME / "Applications/AeroGrid Backend.app"]
    for app in expected:
        if str(app) in manifest["installedApps"] and app.exists():
            shutil.rmtree(app)
    for name in ["aerogrid", "aerogrid-aerospace"]:
        link = HOME / ".local/bin" / name
        if link.is_symlink() and any(str(link.resolve()).startswith(str(app) + "/") for app in expected):
            link.unlink()
    print("Removed AeroGrid apps and owned settings. Configuration, layouts, and backups remain in " + str(SUPPORT))
    print("Your original /Applications/AeroSpace.app was preserved and can be opened again.")


if __name__ == "__main__":
    main()
