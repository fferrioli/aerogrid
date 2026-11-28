#!/usr/bin/env python3
"""Verify installed diagnostic paths against the live backend in an isolated fixture session."""
import argparse
import json
import stat
import time

from live_fixture_session import activate, command, fixture_session, native_by_monitor, status, wait_for, write_json


def history(path):
    """Rebuild backend and map tables from retained checkpoints and deltas."""
    states, rows = {}, []
    for source in (path.with_suffix(".jsonl.previous"), path):
        try:
            lines = source.read_text().splitlines()
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


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    with fixture_session(lambda desktop: next(d for d in desktop["displays"] if d["monitor"] == desktop["focusedMonitor"])) as session:
        verify(session)
    print("PASS: isolated controller recorded geometry, fullscreen attribution, fullscreen-to-normal navigation, dormant workspace placement, empty-space deletion and Undo")


def verify(session):
    path = session.directory / "diagnostics/history.jsonl"
    session.start_verifier("--fixture-observe")
    monitor, workspace = session.monitor, session.workspace

    def starting_history():
        session.check_observer()
        result = history(path)
        return result if result[0] else None

    before_session, _, _, before_rows = wait_for(starting_history, "isolated diagnostic history")
    start = before_rows[-1]["sequence"]
    target = None
    blind_marker = session.directory / "blind-window.json"

    def fixture_windows():
        return [w for w in status()["windows"] if w["pid"] == session.pid]

    def observe():
        session.check_observer()
        identifier, backend, grid, rows = history(path)
        if identifier != before_session:
            raise RuntimeError("The fixture observer restarted during the smoke")
        return backend, grid, [row for row in rows if row["session"] == identifier and row["sequence"] > start]

    def normal_samples():
        backend, _, _ = observe()
        display = next((d for d in backend.get("displays", {}).values() if d["monitor"] == monitor), {})
        members = {key: row for key, row in backend.get("windows", {}).items()
                   if row["workspace"] == display.get("visibleWorkspace")}
        if len(members) == 3 and all(w.get("frame") and w.get("nativeSpaces") for w in members.values()):
            return set(members)

    def blind_fixture(seconds):
        command("grid-layout", "--data", json.dumps({"windowID": target, "seconds": seconds, "forget": True}), "debug-blind")

    def current_native_space():
        return native_by_monitor(status())[str(monitor)]["current"]

    try:
        real = session.windows
        members = wait_for(normal_samples, "recorded window frames and native memberships")
        if len(status()["displays"]) == 1:
            verify_dormant_wake(session, real[-1])
            wait_for(normal_samples, "the fixture windows back on their original workspace")
        target = real[0]["id"]
        command("macos-native-fullscreen", "--window-id", target, "on")

        def fullscreen_samples():
            backend, grid, _ = observe()
            for cell in grid.get("cells", {}).values():
                window = cell.get("fullscreenWindow")
                if window in members and cell["kind"] == "fullscreen":
                    for space in backend.get("nativeSpaces", {}).values():
                        if space["type"] == 4 and window in space["trackedWindows"]:
                            return window, space["id"]

        window, space = wait_for(fullscreen_samples, "correlated fullscreen map card and native Space")
        def saved_cell():
            raw_map = json.loads((session.directory / "state.json").read_text())["dynamicMap"]
            identity = {key: real[0][key] for key in ("id", "pid", "boot")}
            return next((cell["id"] for cell in raw_map["spaces"] if cell.get("nativeWindow") == identity), None)

        fixture_cell = wait_for(saved_cell, "persisted isolated fullscreen card")
        session.jump(fixture_cell)

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
        activate(workspace, monitor)
        wait_for(lambda: current_native_space() != fullscreen_space, "return to the normal test desktop")
        write_json(blind_marker, target)
        blind_fixture(30)

        def unattributed_space():
            backend, _, _ = observe()
            return window not in backend.get("windows", {}) and any(
                candidate["id"] == space and candidate["occupancy"] == "unattributed"
                for candidate in backend.get("nativeSpaces", {}).values())

        wait_for(unattributed_space, "native fullscreen Space with unknown occupancy")
        blind_fixture(0)
        blind_marker.unlink()
        command("grid-layout", "--data", fullscreen_space, "native-focus")
        wait_for(fullscreen_samples, "restored fullscreen attribution")
        activate(workspace, monitor)
        wait_for(lambda: current_native_space() != fullscreen_space, "background fixture fullscreen Space")
        last_action = observe()[2][-1]["sequence"]
        session.jump(fixture_cell)
        wait_for(lambda: action_observed(last_action) and current_native_space() == fullscreen_space,
                 "frontend navigation to the recovered background fullscreen Space")
        verify_delete_fullscreen_home(session, real, target, fixture_cell, observe)
        if stat.S_IMODE(path.stat().st_mode) != 0o600 or stat.S_IMODE(path.parent.stat().st_mode) != 0o700:
            raise RuntimeError("Diagnostic history is not private")
    finally:
        if blind_marker.exists():
            blind_fixture(0)
            blind_marker.unlink()
        if target is not None and any(w["id"] == target and w["nativeFullscreen"] for w in fixture_windows()):
            command("macos-native-fullscreen", "--window-id", target, "off")


def verify_dormant_wake(session, window):
    path = session.directory / "state.json"
    workspace = session.workspace + "-laptop"
    identity = {key: window[key] for key in ("id", "pid", "boot")}

    def card(name=None):
        cells = json.loads(path.read_text())["dynamicMap"]["spaces"]
        return next(cell for cell in cells if cell["workspace"] == (name or session.workspace))

    def move(target):
        command("grid-layout", "--workspace", target, "--data", json.dumps(identity), "move-window")

    anchor = card()["foldedRect"]
    reserve = card(workspace)
    assert reserve["dormant"] and reserve["column"] == 8
    command("layout", "--window-id", window["id"], "floating")
    move(workspace)
    activate(workspace, session.monitor)
    wait_for(lambda: not card(workspace)["dormant"], "floating window to wake its reserved workspace")
    result = card(workspace)
    frame = result["foldedRect"]
    distance = abs(frame["row"] - anchor["row"]) + abs(frame["column"] - anchor["column"])
    if result["id"] != reserve["id"] or result["column"] != reserve["column"] or distance != 1 or card()["foldedRect"] != anchor:
        raise RuntimeError("A dormant workspace did not wake beside the prior card without moving it")
    if not any(w["id"] == window["id"] and w["floating"] and w["workspace"] == workspace for w in status()["windows"]):
        raise RuntimeError("The awakened card did not retain the floating window in its assigned workspace")

    activate(session.workspace, session.monitor)
    move(session.workspace)
    command("layout", "--window-id", window["id"], "tiling")
    wait_for(lambda: card(workspace)["dormant"], "the empty fixture workspace to become dormant after leaving it")


def verify_delete_fullscreen_home(session, windows, fullscreen_window, fullscreen_cell, observe):
    state_path = session.directory / "state.json"

    def space_map():
        return json.loads(state_path.read_text())["dynamicMap"]

    before = space_map()
    link = next(link for link in before["fullscreens"] if link["spaceID"] == fullscreen_cell)
    home_id = link["homeID"]
    if home_id == fullscreen_cell:
        raise RuntimeError("Expected separate fullscreen and normal fixture cards")
    card = next(cell for cell in before["spaces"] if cell["id"] == fullscreen_cell)
    other_workspace = session.workspace + "-laptop"
    for window in windows:
        if window["id"] != fullscreen_window:
            identity = {key: window[key] for key in ("id", "pid", "boot")}
            command("grid-layout", "--workspace", other_workspace, "--data", json.dumps(identity), "move-window")

    def home_is_hidden():
        current = space_map()
        return any(cell["id"] == home_id and cell.get("hiddenFullscreenHome") and cell.get("dormant")
                   for cell in current["spaces"])

    start = observe()[2][-1]["sequence"]
    write_json(session.directory / "remove-empty-space.json", home_id)
    wait_for(home_is_hidden, "the organizer action to hide the empty fullscreen home")

    def action_ok(name, after):
        return any(row["kind"] == "action" and row["sequence"] > after
                   and row["payload"]["name"] == name and row["payload"]["outcome"] == "ok" for row in observe()[2])

    wait_for(lambda: action_ok("removeEmptySpace", start), "the recorded deletion action")
    after = space_map()
    if link not in after["fullscreens"] or card not in after["spaces"]:
        raise RuntimeError("Deleting the empty card changed the fullscreen destination")
    normal = next(cell for cell in after["spaces"] if cell["workspace"] == other_workspace)
    verify_fullscreen_to_normal(session, card, normal, fullscreen_window, action_ok, observe)

    next_action = observe()[2][-1]["sequence"]
    (session.directory / "undo-organization").touch()
    wait_for(lambda: action_ok("undo", next_action), "the organizer's Undo action")
    if home_is_hidden() or link not in space_map()["fullscreens"]:
        raise RuntimeError("Undo did not recover the empty card and preserve fullscreen")


def verify_fullscreen_to_normal(session, fullscreen, normal, window, action_ok, observe):
    def rectangle(card):
        return card.get("foldedRect") if combined and card.get("foldedRect") else {
            "row": card["row"], "column": card["column"],
            "width": card.get("spanColumns", 1), "height": card.get("spanRows", 1),
        }

    combined = len(status()["displays"]) == 1
    source, target = rectangle(fullscreen), rectangle(normal)
    if target["column"] >= source["column"] + source["width"]:
        direction = "right"
    elif target["column"] + target["width"] <= source["column"]:
        direction = "left"
    elif target["row"] >= source["row"] + source["height"]:
        direction = "down"
    else:
        direction = "up"
    monitor = str(session.monitor)
    for _ in range(3):
        start = observe()[2][-1]["sequence"]
        session.jump(fullscreen["id"])
        wait_for(lambda: action_ok("openSpace", start)
                 and status().get("nativeVisible", {}).get(monitor) == window, "fixture fullscreen to become visible")
        start = observe()[2][-1]["sequence"]
        write_json(session.directory / "navigate.json", direction)
        wait_for(lambda: action_ok("navigate", start), "directional change from fullscreen to the normal workspace")
        end = time.monotonic() + 0.8
        while time.monotonic() < end:
            desktop = status()
            if desktop["visible"].get(monitor) != normal["workspace"] or monitor in desktop.get("nativeVisible", {}):
                raise RuntimeError("The gesture completed but its normal destination stopped being visible")
            time.sleep(0.1)


if __name__ == "__main__":
    main()
