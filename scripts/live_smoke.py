"""Backend layout assertions run by run-live-smoke.py under the fixture interlock."""
import json

from live_fixture_session import command, native_by_monitor, status, wait_for


def verify(session):
    workspace = session.workspace
    fixture = [window["id"] for window in session.windows]
    base_space = native_by_monitor(status())[str(session.monitor)]["current"]
    results = []

    def current_space():
        return native_by_monitor(status())[str(session.monitor)]["current"]

    def layout(operation, *args, target=workspace):
        return command("grid-layout", "--workspace", target, *args, operation)

    try:
        layout("wide")
        saved = layout("snapshot")
        layout("compact")
        layout("restore", "--data", saved)
        restored = json.loads(layout("snapshot"))
        assert [n["id"] for n in restored["tree"]["children"]] == [n["id"] for n in json.loads(saved)["tree"]["children"]]
        results.append("PASS: three windows from one app, compact/wide snapshot round trip")
        full = fixture[0]
        command("macos-native-fullscreen", "--window-id", full, "on")
        fullscreen_space = wait_for(lambda: space if (space := current_space()) != base_space else None,
                                    "fixture fullscreen Space")
        command("focus", "--window-id", full)
        layout("activate")
        empty = workspace + "-empty"
        command("move-workspace-to-monitor", "--workspace", empty, session.monitor)
        layout("activate", target=empty)
        assert current_space() == base_space, "Leaving fullscreen did not return to its normal desktop"
        layout("activate")
        actual_space = current_space()
        assert actual_space == fullscreen_space, f"Returning selected Space {actual_space}, expected fullscreen Space {fullscreen_space}"
        results.append("PASS: native fullscreen → empty cell → same native fullscreen, without exiting it")
        command("macos-native-fullscreen", "--window-id", full, "off")
        wait_for(lambda: current_space() == base_space, "fixture to leave fullscreen")
        after_exit = json.loads(layout("snapshot"))
        assert set(n["id"] for n in after_exit["tree"]["children"]) == set(fixture)
        results.append("PASS: native fullscreen exit restores normal cell membership")
    except Exception as error:
        results.append("FAIL: " + str(error))
        raise
    finally:
        (session.directory / "live-smoke.txt").write_text("\n".join(results) + "\n")
        print("\n".join(results))
