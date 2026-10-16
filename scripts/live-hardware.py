#!/usr/bin/env python3
"""Prepare disposable layout windows and inspect physical dock/restart checks."""
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUPPORT = pathlib.Path.home() / "Library/Application Support/AeroGrid"
RECORD = ROOT / "output/live-hardware.json"
WORKSPACE = "grid-external-2-3"
spec = spec_from_file_location("smoke", ROOT / "scripts/live-smoke.py")
smoke = module_from_spec(spec)
spec.loader.exec_module(smoke)
command = smoke.command


def desktop():
    return json.loads(command("grid-layout", "status"))


def snapshot():
    return json.loads(command("grid-layout", "--workspace", WORKSPACE, "snapshot"))


def wait_for(check, timeout=15):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (RuntimeError, subprocess.SubprocessError) as error:
            last_error = error
        time.sleep(0.3)
    raise RuntimeError("Check timed out" + (": " + str(last_error) if last_error else ""))


def prepare():
    if RECORD.exists():
        raise RuntimeError("An existing hardware fixture needs cleanup first")
    original = desktop()
    target = next(d for d in original["displays"] if not d["builtin"])
    if any(home["workspace"] == WORKSPACE for home in original["windowHomes"]):
        raise RuntimeError("The fixture cell is occupied; choose an empty cell before testing")
    fixture = subprocess.Popen([str(ROOT / "dist/GridFixture")], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    record = {"original": original, "native": smoke.native(), "fixturePID": fixture.pid,
              "workspace": WORKSPACE, "checks": []}
    RECORD.write_text(json.dumps(record, indent=2))
    def fixture_ids():
        return [home["id"] for home in desktop()["windowHomes"] if home["pid"] == fixture.pid]
    ids = wait_for(lambda: fixture_ids() if len(fixture_ids()) == 3 else None)
    command("move-workspace-to-monitor", "--workspace", WORKSPACE, target["monitor"])
    for identity in ids:
        command("move-node-to-workspace", "--window-id", identity, WORKSPACE)
    command("grid-layout", "--workspace", WORKSPACE, "activate")
    command("grid-layout", "--workspace", WORKSPACE, "wide")
    saved = snapshot()
    leaves = saved["tree"]["children"]
    assert set(node["id"] for node in leaves) == set(ids)
    # Preserve a meaningful nested, unequal layout through compact adaptation.
    saved["tree"]["children"] = [
        dict(weight=2, orientation="v", layout="tiles", children=leaves[:2]), leaves[2]]
    saved["tree"]["children"][1]["weight"] = 3
    command("grid-layout", "--workspace", WORKSPACE, "--data", json.dumps(saved), "restore")
    time.sleep(3)
    record.update(fixtureIDs=ids, wide=snapshot())
    RECORD.write_text(json.dumps(record, indent=2))
    print("Prepared three temporary windows with a nested wide layout on " + target["name"])


def restart():
    record = json.loads(RECORD.read_text())
    before = desktop()
    expected = snapshot()["tree"]
    app = pathlib.Path.home() / "Applications/AeroGrid Backend.app"
    executable = app / "Contents/MacOS/AeroSpace"
    processes = subprocess.check_output(["pgrep", "-f", "^" + re.escape(str(executable)) + "$"], text=True)
    for pid in processes.split():
        os.kill(int(pid), signal.SIGTERM)
    def stopped():
        return subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "$"],
                              capture_output=True).returncode == 1
    wait_for(stopped)
    subprocess.run(["open", str(app)], check=True)
    wait_for(lambda: desktop()["backendSession"] != before["backendSession"])
    wanted = {home["id"]: home for home in before["windowHomes"]}
    def recovered():
        actual = desktop()
        homes = {home["id"]: home for home in actual["windowHomes"]}
        return actual if actual["visible"] == before["visible"] and all(
            homes.get(identity) == home for identity, home in wanted.items()) and snapshot()["tree"] == expected else None
    after = wait_for(recovered)
    record["checks"].append({"check": "backend restart", "before": before, "after": after})
    RECORD.write_text(json.dumps(record, indent=2))
    print("PASS: backend restart restored user/fixture memberships, visible cells, and nested layout")


def inspect():
    record = json.loads(RECORD.read_text())
    state = json.loads((SUPPORT / "state.json").read_text())
    config = json.loads((SUPPORT / "config.json").read_text())
    cell = next(cell for grid in config["grids"] for cell in grid["cells"] if cell["workspace"] == WORKSPACE)
    result = {"check": "physical topology observation", "desktop": desktop(), "layout": snapshot(),
              "appliedProfile": state["appliedProfiles"].get(cell["id"]),
              "savedProfiles": {key: json.loads(value) for key, value in state["snapshots"].items()
                                if key.startswith(cell["id"] + ":")}, "cursors": state["cursors"]}
    record["checks"].append(result)
    RECORD.write_text(json.dumps(record, indent=2))
    print(json.dumps(result, indent=2))


def cleanup():
    record = json.loads(RECORD.read_text())
    pid = record["fixturePID"]
    # Verify the PID still belongs to this fixture before terminating it.
    process = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    if process.stdout.strip() == str(ROOT / "dist/GridFixture"):
        os.kill(pid, signal.SIGTERM)
    errors = []
    current = desktop()
    for display in record["original"]["displays"]:
        survivor = next((d for d in current["displays"] if d["id"] == display["id"]), None)
        if not survivor:
            continue
        try:
            workspace = record["original"]["visible"][str(display["monitor"])]
            command("move-workspace-to-monitor", "--workspace", workspace, survivor["monitor"])
            command("grid-layout", "--workspace", workspace, "activate")
        except Exception as error:
            errors.append(str(error))
    if record["original"].get("focusedWindow"):
        try:
            command("focus", "--window-id", record["original"]["focusedWindow"])
        except Exception as error:
            errors.append(str(error))
    RECORD.rename(ROOT / "output/live-hardware-completed.json")
    if errors:
        raise RuntimeError("; ".join(errors))
    print("Fixture closed; original visible cells and focus restored")


if __name__ == "__main__":
    {"prepare": prepare, "restart": restart, "inspect": inspect, "cleanup": cleanup}[sys.argv[1]]()
