#!/usr/bin/env python3
"""Verify physical dock/undock and optionally backend restart in a disposable session."""
import argparse
import json
import os
import signal
import subprocess

from live_fixture_session import APP, activate, command, fixture_session, status, wait_for, write_json


def choose_display(desktop):
    if desktop["windowHomes"]:
        raise RuntimeError("Use a disposable macOS account with no managed windows for physical topology checks")
    displays = desktop["displays"]
    if len(displays) != 2 or not any(d["builtin"] for d in displays):
        raise RuntimeError("Start on a Mac with the built-in and external displays connected")
    return next(d for d in displays if not d["builtin"])


def verify(session, restart):
    ws = session.workspace
    ids = {w["id"] for w in session.windows}

    def snapshot():
        return json.loads(command("grid-layout", "--workspace", ws, "snapshot"))

    command("grid-layout", "--workspace", ws, "wide")
    saved = snapshot()
    leaves = saved["tree"]["children"]
    if {node["id"] for node in leaves} != ids:
        raise RuntimeError("Expected three tiled fixture windows")
    saved["tree"]["children"] = [dict(weight=2, orientation="v", layout="tiles", children=leaves[:2]), leaves[2]]
    saved["tree"]["children"][1]["weight"] = 3
    command("grid-layout", "--workspace", ws, "--data", json.dumps(saved), "restore")
    activate(ws, session.monitor)
    reference = snapshot()["tree"]
    session.start_verifier("--fixture-observe")

    def map_if(check):
        session.check_observer()
        path = session.directory / "state.json"
        if path.exists():
            grid = json.loads(path.read_text())["dynamicMap"]
            if grid.get("initialized") and not grid.get("pending") and check(grid):
                return grid

    wait_for(lambda: map_if(lambda grid: not grid["folded"]), "isolated wide map")
    if restart:
        before = status()
        if any(w["pid"] != session.pid for w in before["windowHomes"]):
            raise RuntimeError("A non-fixture window appeared. Backend restart cancelled")
        backend = APP.with_name("AeroGrid Backend.app")
        executable = backend / "Contents/MacOS/AeroSpace"
        processes = subprocess.check_output(["/bin/ps", "-axww", "-o", "pid=,command="], text=True)
        pids = [int(line.strip().split(maxsplit=1)[0]) for line in processes.splitlines()
                if line.strip().split(maxsplit=1)[-1] == str(executable)]
        if len(pids) != 1:
            raise RuntimeError("Expected exactly one installed backend process")
        pid = pids[0]
        os.kill(pid, signal.SIGTERM)

        def stopped():
            try:
                os.kill(pid, 0)
                return False
            except ProcessLookupError:
                return True

        try:
            wait_for(stopped, "owned backend exit")
        finally:
            subprocess.run(["/usr/bin/open", "-g", str(backend)], check=True, timeout=8)

        def recovered():
            try:
                actual = status()
                return (actual["backendSession"] != before["backendSession"]
                        and actual["windowHomes"] == before["windowHomes"] and snapshot()["tree"] == reference)
            except (RuntimeError, subprocess.SubprocessError):
                return False

        wait_for(recovered, "fixture homes and layout after backend restart")
        print("PASS: backend restart restored the isolated fixture layout", flush=True)
    print("Disconnect the external display now.", flush=True)
    compact = wait_for(lambda: map_if(lambda grid: grid["folded"] and grid["families"]), "physical undock and fold", seconds=90)
    print("Reconnect the original external display now.", flush=True)
    wide = wait_for(lambda: map_if(lambda grid: not grid["folded"] and not grid["families"]),
                    "physical reconnect and reunion", seconds=90)
    if snapshot()["tree"] != reference:
        raise RuntimeError("The fixture's original desktop layout was not restored")
    write_json(session.directory / "hardware.json", {"compact": compact, "wide": wide})
    print("PASS: physical disconnect and reconnect preserved the fixture arrangement")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restart-backend", action="store_true", help="Also verify recovery from a backend restart")
    args = parser.parse_args()
    with fixture_session(choose_display, allow_backend_restart=args.restart_backend) as session:
        verify(session, args.restart_backend)


if __name__ == "__main__":
    main()
