#!/usr/bin/env python3
"""Create a source snapshot without binaries, caches or user runtime data."""
import hashlib
import json
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUDED = {".git", ".build", ".swiftpm", "__pycache__", ".DS_Store", ".idea", ".bundle", "build", "qa"}


def main():
    output = ROOT / "dist/AeroGrid-Source.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    roots = ["Package.swift", ".gitignore", "Sources", "Tests", "scripts",
             "vendor/AeroSpace", "vendor/SwipeAeroSpace", "vendor/python",
             "README.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md",
             "docs", "demo", "UPSTREAM.md", "BUILD-ON-ANOTHER-MAC.md"]
    files = []
    for name in roots:
        source = ROOT / name
        candidates = source.rglob("*") if source.is_dir() else [source]
        for path in candidates:
            relative = path.relative_to(ROOT)
            if any(part in EXCLUDED for part in relative.parts) or path.suffix == ".pyc":
                continue
            if path.is_file():
                files.append(path)
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(files)}
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(files):
            archive.write(path, pathlib.Path("AeroGrid-Source") / path.relative_to(ROOT))
        archive.writestr("AeroGrid-Source/source-manifest.json", json.dumps(hashes, indent=2) + "\n")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".zip.sha256").write_text(f"{digest}  {output.name}\n")
    print(output)


if __name__ == "__main__":
    main()
