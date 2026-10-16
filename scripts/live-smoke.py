#!/usr/bin/env python3
"""Exercise the backend using only the explicitly created GridFixture windows."""
import json
import pathlib
import subprocess
import time

CLI = pathlib.Path.home() / ".local/bin/aerogrid-aerospace"
ROOT = pathlib.Path(__file__).resolve().parents[1]


def command(*args):
    result = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def native():
    return json.loads(command("grid-layout", "native-status"))


def native_display(identity):
    return next(display for display in native() if display["id"] == identity)


def main():
    original = json.loads(command("grid-layout", "status"))
    original_native = native()
    (ROOT / "output").mkdir(exist_ok=True)
    (ROOT / "output/live-original.json").write_text(json.dumps(original, indent=2))
    fixture = []
    for line in command("list-windows", "--all", "--format", "%{window-id}|%{window-title}").splitlines():
        identity, title = line.split("|", 1)
        if title.startswith("AeroGrid Verification "):
            fixture.append(int(identity))
    if len(fixture) != 3:
        raise RuntimeError("Start dist/GridFixture first; expected three disposable windows")
    # Match the physical display explicitly; native Spaces order isn't monitor order.
    normal_displays = {display["id"] for display in original_native
                       if any(space["id"] == display["current"] and space["type"] == 0
                              for space in display["spaces"])}
    candidates = [display for display in original["displays"] if display["id"] in normal_displays]
    if not candidates:
        raise RuntimeError("Visit a normal desktop on a display before running the fixture test")
    target = next((display for display in candidates if not display["builtin"]), candidates[0])
    results = []
    full = None
    workspace = "grid-verification"
    try:
        command("move-workspace-to-monitor", "--workspace", workspace, target["monitor"])
        for window in fixture:
            command("move-node-to-workspace", "--window-id", window, workspace)
        command("grid-layout", "--workspace", workspace, "activate")
        command("grid-layout", "--workspace", workspace, "wide")
        saved = command("grid-layout", "--workspace", workspace, "snapshot")
        command("grid-layout", "--workspace", workspace, "compact")
        command("grid-layout", "--workspace", workspace, "--data", saved, "restore")
        restored = json.loads(command("grid-layout", "--workspace", workspace, "snapshot"))
        assert [n["id"] for n in restored["tree"]["children"]] == [n["id"] for n in json.loads(saved)["tree"]["children"]]
        results.append("PASS: three windows from one app, compact/wide snapshot round trip")
        base_space = native_display(target["id"])["current"]
        full = fixture[0]
        command("macos-native-fullscreen", "--window-id", full, "on")
        time.sleep(1.2)
        command("focus", "--window-id", full)
        command("grid-layout", "--workspace", workspace, "activate")
        fullscreen_space = native_display(target["id"])["current"]
        assert fullscreen_space != base_space, "Fullscreen did not create/activate its native Space"
        # A configured empty cell exercises switching away without a normal window to raise.
        command("move-workspace-to-monitor", "--workspace", "grid-verification-empty", target["monitor"])
        command("grid-layout", "--workspace", "grid-verification-empty", "activate")
        assert native_display(target["id"])["current"] == base_space, "Leaving fullscreen did not return to its normal desktop"
        command("grid-layout", "--workspace", workspace, "activate")
        actual_space = native_display(target["id"])["current"]
        assert actual_space == fullscreen_space, f"Returning selected Space {actual_space}, expected fullscreen Space {fullscreen_space}"
        results.append("PASS: native fullscreen → empty cell → same native fullscreen, without exiting it")
        command("macos-native-fullscreen", "--window-id", full, "off")
        time.sleep(1.2)
        full = None
        after_exit = json.loads(command("grid-layout", "--workspace", workspace, "snapshot"))
        assert set(n["id"] for n in after_exit["tree"]["children"]) == set(fixture)
        results.append("PASS: native fullscreen exit restores normal cell membership")
    except Exception as error:
        results.append("FAIL: " + str(error))
        raise
    finally:
        if full is not None:
            try:
                command("macos-native-fullscreen", "--window-id", full, "off")
                time.sleep(1.2)
            except Exception:
                pass
        # Restore user's focus and workspace; closing the fixture removes all test windows.
        for monitor, ws in original["visible"].items():
            try:
                command("move-workspace-to-monitor", "--workspace", ws, monitor)
                command("grid-layout", "--workspace", ws, "activate")
            except Exception as error:
                results.append("Cleanup pending: " + str(error))
        for display in original_native:
            try:
                command("grid-layout", "--data", display["current"], "native-focus")
            except Exception as error:
                results.append("Native Space recovery pending: " + str(error))
        if original.get("focusedWindow"):
            try:
                command("focus", "--window-id", original["focusedWindow"])
                command("grid-layout", "--workspace", original["visible"][str(original["focusedMonitor"])], "activate")
            except Exception as error:
                results.append("Focus recovery pending: " + str(error))
        (ROOT / "output").mkdir(exist_ok=True)
        (ROOT / "output/live-smoke.txt").write_text("\n".join(results) + "\nOriginal native Spaces: " + json.dumps(original_native) + "\n")
        print("\n".join(results))


if __name__ == "__main__":
    main()
