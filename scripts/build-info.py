#!/usr/bin/env python3
"""Record the source identity alongside successful release products."""
import datetime
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build_info(root=ROOT):
    revision = os.environ.get("AEROGRID_BUILD_REVISION")
    dirty = False
    if revision is None:
        top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if top.returncode == 0 and pathlib.Path(top.stdout.strip()).resolve() == root.resolve():
            revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            dirty = bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True).strip())
        elif (root / "source-version.json").is_file():
            source = json.loads((root / "source-version.json").read_text())
            revision = source.get("revision")
            dirty = source.get("dirty", False)
    if revision is not None and not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid AeroGrid source revision")
    return dict(revision=revision, dirty=dirty, builtAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), updateProtocol=1)


if __name__ == "__main__":
    path = ROOT / ".build/build-info.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(build_info(), indent=2) + "\n")
