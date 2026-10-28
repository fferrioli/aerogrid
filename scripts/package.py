#!/usr/bin/env python3
"""Package only prebuilt products, installer dependencies and public notices."""
import datetime
import hashlib
import json
import pathlib
import shutil
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def package(output):
    files = [
        ".build/release/AeroGrid",
        "vendor/AeroSpace/.build/release/AeroSpaceApp",
        "vendor/AeroSpace/.build/release/aerospace",
        "vendor/AeroSpace/docs/config-examples/default-config.toml",
        "scripts/install.py", "scripts/uninstall.py", "scripts/configuration.py", "scripts/update-worker.py",
        ".build/build-info.json",
    ]
    for name in files:
        if not (ROOT / name).is_file():
            raise FileNotFoundError(f"Missing {name}; build the release products first")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aerogrid-package-") as temporary:
        folder = pathlib.Path(temporary) / "AeroGrid-AppleSilicon"
        folder.mkdir()
        for name in files:
            destination = folder / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        shutil.copytree(ROOT / "vendor/python", folder / "vendor/python",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        shutil.copytree(ROOT / "vendor/AeroSpace/legal", folder / "Licenses/AeroSpace-third-party")
        shutil.copy2(ROOT / "vendor/AeroSpace/LICENSE.txt", folder / "Licenses/AeroSpace-MIT.txt")
        for source in (ROOT / "scripts/portable").iterdir():
            shutil.copy2(source, folder / source.name)
            if source.suffix == ".command":
                (folder / source.name).chmod(0o755)
        checksums = {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(folder.rglob("*")) if p.is_file()}
        manifest = {"builtAt": datetime.datetime.now().astimezone().isoformat(),
                    "architecture": "arm64", "minimumMacOS": "14.0", "files": checksums}
        (folder / "package-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Use a plain ZIP without extended attributes from this computer.
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(folder.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(folder.parent))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n")
    print(output)


if __name__ == "__main__":
    package(ROOT / "dist/AeroGrid-AppleSilicon.zip")
