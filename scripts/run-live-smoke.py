#!/usr/bin/env python3
"""Run disposable-window checks and always relaunch the controller afterward."""
import json
import pathlib
import re
import subprocess
import sys
import time

from importlib.util import module_from_spec, spec_from_file_location

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = spec_from_file_location("live_smoke", ROOT / "scripts/live-smoke.py")
smoke = module_from_spec(spec)
spec.loader.exec_module(smoke)
APP = pathlib.Path.home() / "Applications/AeroGrid.app"


def main():
    original = json.loads(smoke.command("grid-layout", "status"))
    native = smoke.native()
    (ROOT / "output").mkdir(exist_ok=True)
    (ROOT / "output/live-before-fixture.json").write_text(json.dumps(original, indent=2))
    executable = APP / "Contents/MacOS/AeroGrid"
    processes = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "$"],
                               capture_output=True, text=True)
    fixture = None
    failures = []
    result = None
    try:
        for pid in processes.stdout.split():
            subprocess.run(["kill", "-TERM", pid], check=True)
        time.sleep(0.5)
        fixture = subprocess.Popen([str(ROOT / "dist/GridFixture")], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            titles = smoke.command("list-windows", "--all", "--format", "%{window-title}")
            if sum(title.startswith("AeroGrid Verification ") for title in titles.splitlines()) == 3:
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Fixture windows weren't discovered")
        if "--dynamic" in sys.argv:
            invocation = [str(ROOT / ".build/release/AeroGrid"), "--verify-dynamic-fixtures", str(ROOT / "output/live-dynamic.txt")]
            if "--normal-only" in sys.argv:
                invocation.append("--normal-only")
        else:
            invocation = ["python3", str(ROOT / "scripts/live-smoke.py")]
        result = subprocess.run(invocation, capture_output=True, text=True, timeout=90)
        print(result.stdout)
        if result.returncode:
            failures.append(result.stderr)
    finally:
        try:
            if fixture:
                fixture.terminate()
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait(timeout=5)
            for monitor, workspace in original["visible"].items():
                try:
                    smoke.command("move-workspace-to-monitor", "--workspace", workspace, monitor)
                    smoke.command("grid-layout", "--workspace", workspace, "activate")
                except Exception as error:
                    failures.append("Workspace recovery: " + str(error))
            for display in native:
                try:
                    smoke.command("grid-layout", "--data", display["current"], "native-focus")
                except Exception as error:
                    failures.append("Native recovery: " + str(error))
            current = json.loads(smoke.command("grid-layout", "status"))
            if any(home["id"] == original.get("focusedWindow") for home in current["windowHomes"]):
                try:
                    smoke.command("focus", "--window-id", original["focusedWindow"])
                except Exception as error:
                    failures.append("Focus recovery: " + str(error))
            assert current["visible"] == original["visible"], "Original visible workspaces weren't restored"
        finally:
            subprocess.run(["open", str(APP)], check=True)
    if failures:
        raise RuntimeError("\n".join(failures))
    if not result or result.returncode:
        raise RuntimeError("Live smoke didn't complete")


if __name__ == "__main__":
    main()
