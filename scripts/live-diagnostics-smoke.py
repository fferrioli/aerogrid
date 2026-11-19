#!/usr/bin/env python3
"""Opt-in verification against the running installation, with disposable GridFixture windows."""
import argparse
import json
from pathlib import Path
import stat
import subprocess
import time

HOME = Path.home()
CLI = HOME / ".local/bin/aerogrid-aerospace"
APP = HOME / ".local/bin/aerogrid"
HISTORY = HOME / "Library/Application Support/AeroGrid/diagnostics/history.jsonl"
FIXTURE = Path(__file__).resolve().parents[1] / "dist/GridFixture"


def command(executable, *args):
    result = subprocess.run([str(executable), *map(str, args)], capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise RuntimeError(f"Installed command failed ({args[0]}, status {result.returncode})")
    return result.stdout


def status():
    return json.loads(command(CLI, "grid-layout", "--data", "diagnostics", "status"))


def history():
    """Rebuild backend and map tables from retained checkpoints and deltas."""
    states, rows = {}, []
    for path in (HISTORY.with_suffix(".jsonl.previous"), HISTORY):
        try:
            lines = path.read_text().splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue  # A writer may be appending to the current file.
            if row["schema"] != 1:
                continue
            if rows and (row["session"], row["sequence"]) == (rows[-1]["session"], rows[-1]["sequence"]):
                continue
            rows.append(row)
            if row["kind"] not in ("backend", "map"):
                continue
            payload, key = row["payload"], (row["session"], row["kind"])
            if payload["mode"] == "checkpoint":
                states[key] = (row["sequence"], payload["rows"])
            elif key in states and states[key][0] == payload["base"]:
                tables = states[key][1]
                for table, keys in payload.get("removed", {}).items():
                    for item in keys:
                        tables.get(table, {}).pop(item, None)
                for table, changes in payload["rows"].items():
                    tables.setdefault(table, {}).update(changes)
                states[key] = (row["sequence"], tables)
    if not rows:
        return None, {}, {}, []
    session = rows[-1]["session"]
    return session, states.get((session, "backend"), (None, {}))[1], states.get((session, "map"), (None, {}))[1], rows


def wait_for(check, description, seconds=16):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {description}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-seconds", type=int, default=8, help="Time to select the empty test cell")
    args = parser.parse_args()
    if not FIXTURE.is_file():
        raise RuntimeError("Build dist/GridFixture first (see CONTRIBUTING.md)")
    health = json.loads(command(APP, "--health"))
    if not health.get("backendReady") or health.get("paused") or health.get("reconciliationGate") != "open":
        raise RuntimeError("Start or recover the installed app and leave reconciliation open")
    print("Select an existing empty AeroGrid cell on a normal desktop. Leave the organizer closed.", flush=True)
    time.sleep(max(0, args.prepare_seconds))
    original = status()
    monitor = original["focusedMonitor"]
    workspace = original["visible"][str(monitor)]
    native = original.get("placementDiagnostics", {}).get("nativeDisplays", [])
    if original.get("extensionVersion", 0) < 3 or not native:
        raise RuntimeError("Matching backend v3 and native Spaces observations are required")
    normal = any(display.get("monitor") == monitor and
                 any(space["id"] == display["current"] and space["type"] == 0 for space in display["spaces"])
                 for display in native)
    if not normal or str(monitor) in original.get("nativeVisible", {}) or any(w["workspace"] == workspace for w in original["windowHomes"]):
        raise RuntimeError("The focused cell must be an empty normal workspace")
    before_session, _, _, before_rows = history()
    if not before_session:
        raise RuntimeError("Enable local diagnostics in Settings before running this smoke")
    start = before_rows[-1]["sequence"]
    fixture = subprocess.Popen([str(FIXTURE)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    target = None
    blind = False

    def fixture_windows():
        return [w for w in status()["windows"] if w["pid"] == fixture.pid]

    def observe():
        session, backend, grid, rows = history()
        if session != before_session:
            raise RuntimeError("AeroGrid restarted during the smoke")
        return backend, grid, [row for row in rows if row["session"] == session and row["sequence"] > start]

    def normal_samples():
        backend, _, rows = observe()
        display = next((d for d in backend.get("displays", {}).values() if d["monitor"] == monitor), {})
        members = {key: row for key, row in backend.get("windows", {}).items()
                   if row["workspace"] == display.get("visibleWorkspace")}
        if len(members) == 3 and rows and all(w.get("frame") and w.get("nativeSpaces") for w in members.values()):
            return set(members)

    def blind_fixture(seconds):
        command(CLI, "grid-layout", "--data", json.dumps({"windowID": target, "seconds": seconds, "forget": True}), "debug-blind")

    def current_native_space():
        displays = status()["placementDiagnostics"]["nativeDisplays"]
        return next(display["current"] for display in displays if display.get("monitor") == monitor)

    try:
        real = wait_for(lambda: windows if len(windows := fixture_windows()) == 3 else None, "three fixture windows")
        if any(w["workspace"] != workspace for w in real):
            raise RuntimeError("The fixture landed outside the empty test cell")
        members = wait_for(normal_samples, "recorded window frames and native memberships")
        target = real[0]["id"]
        command(CLI, "macos-native-fullscreen", "--window-id", target, "on")

        def fullscreen_samples():
            backend, grid, _ = observe()
            for cell in grid.get("cells", {}).values():
                window = cell.get("fullscreenWindow")
                if window in members and cell["kind"] == "fullscreen":
                    for space in backend.get("nativeSpaces", {}).values():
                        if space["type"] == 4 and window in space["trackedWindows"]:
                            return window, space["id"]

        window, space = wait_for(fullscreen_samples, "correlated fullscreen map card and native Space")
        raw_map = json.loads(command(APP, "--map"))
        fixture_cell = next(cell["id"] for cell in raw_map["spaces"]
                            if cell.get("nativeWindow") == {key: real[0][key] for key in ("id", "pid", "boot")})
        command(APP, "--action", "jump", fixture_cell)

        def action_observed(after=0):
            _, _, rows = observe()
            actions = {row["operation"] for row in rows if row["kind"] == "action" and row["payload"]["name"] == "openSpace"
                       and row["sequence"] > after and row["payload"]["outcome"] == "ok" and "operation" in row}
            return any(row.get("operation") in actions and row["kind"] == "command"
                       and row["payload"]["command"] == "activate-target" for row in rows)

        wait_for(action_observed, "correlated frontend navigation and backend command")
        fullscreen_space = current_native_space()
        # A focused window can be discovered again in the backend's light session.
        # Leave the fullscreen Space in the background while testing discovery loss.
        command(CLI, "grid-layout", "--workspace", workspace, "--data", json.dumps({"monitor": monitor}), "activate-target")
        wait_for(lambda: current_native_space() != fullscreen_space, "return to the normal test desktop")
        blind_fixture(30)
        blind = True

        def unattributed_space():
            backend, _, _ = observe()
            return window not in backend.get("windows", {}) and any(
                candidate["id"] == space and candidate["occupancy"] == "unattributed"
                for candidate in backend.get("nativeSpaces", {}).values())

        wait_for(unattributed_space, "native fullscreen Space with unknown occupancy")
        blind_fixture(0)
        blind = False
        command(CLI, "grid-layout", "--data", fullscreen_space, "native-focus")
        wait_for(fullscreen_samples, "restored fullscreen attribution")
        command(CLI, "grid-layout", "--workspace", workspace, "--data", json.dumps({"monitor": monitor}), "activate-target")
        wait_for(lambda: current_native_space() != fullscreen_space, "background fixture fullscreen Space")
        last_action = observe()[2][-1]["sequence"]
        command(APP, "--action", "jump", fixture_cell)
        wait_for(lambda: action_observed(last_action) and current_native_space() == fullscreen_space,
                 "frontend navigation to the recovered background fullscreen Space")
        assert stat.S_IMODE(HISTORY.stat().st_mode) == 0o600
        assert stat.S_IMODE(HISTORY.parent.stat().st_mode) == 0o700
        print("PASS: active installation recorded normal geometry, fullscreen attribution, navigation and transient unknown occupancy")
    finally:
        try:
            if blind:
                blind_fixture(0)
            if target is not None and any(w["id"] == target and w["nativeFullscreen"] for w in fixture_windows()):
                command(CLI, "macos-native-fullscreen", "--window-id", target, "off")
        finally:
            if fixture.poll() is None:
                fixture.terminate()
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait(timeout=5)


if __name__ == "__main__":
    main()
