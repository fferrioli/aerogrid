import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import live_fixture_session as live


class FixtureIsolationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        home = Path(scratch.name)
        self.root = home / "cache"
        self.root.mkdir()
        self.active = self.root / "active"
        self.fixture = home / "fixture"
        self.fixture.write_text("disposable binary")
        self.live_files = {home / name: name.encode() for name in ("state.json", "config.json", "control.json", "history.jsonl")}
        for path, data in self.live_files.items():
            path.write_bytes(data)
        self.start_patch(live, "ROOT", self.root)
        self.start_patch(live, "FIXTURE", self.fixture)
        self.display = {"id": "builtin", "monitor": 1, "builtin": True}
        self.observation = {
            "extensionVersion": 3, "displays": [self.display], "visible": {"1": "original"},
            "focusedMonitor": 1, "focusedWindow": 12, "windowHomes": [dict(id=12, pid=42, boot="boot", workspace="original")],
            "backendSession": "backend", "placementDiagnostics": {
                "locked": False, "nativeDisplays": [dict(monitor=1, current=7, spaces=[dict(id=7, type=0)])],
                "workspaces": [dict(name="original", monitor=1)],
            },
        }
        self.start_patch(live, "status", return_value=self.observation)
        self.start_patch(live, "command", side_effect=self.handoff)
        self.restore = self.start_patch(live, "restore", side_effect=self.check_interlock)
        self.launch = self.start_patch(live.subprocess, "run", side_effect=self.launch_controller)
        self.start_patch(live.Session, "register_fixture")
        self.start_patch(live.Session, "reap_orphans")

    def start_patch(self, owner, attr, *args, **kwargs):
        mock = patch.object(owner, attr, *args, **kwargs)
        self.addCleanup(mock.stop)
        return mock.start()

    def handoff(self, mode, **_):
        self.assertEqual(mode, "--fixture-handoff")
        run = self.active.resolve(strict=True)
        (run / "handoff-request").rename(run / "handoff-started")
        (run / "handoff-ready").touch()
        return "123"

    def choose_display(self, _):
        return self.display

    def check_interlock(self, original):
        self.assertTrue(self.active.is_symlink())
        fd = os.open(self.root, os.O_RDONLY)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        finally:
            os.close(fd)
        self.assertEqual(original, live.capture(self.observation))

    def launch_controller(self, args, **_):
        self.assertEqual(args[:2], ["/usr/bin/open", "-g"])
        self.assertFalse(self.active.is_symlink())
        fd = os.open(self.root, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        finally:
            os.close(fd)
        for path, expected in self.live_files.items():
            self.assertEqual(path.read_bytes(), expected)

    def test_failed_activation_restores_before_restarting_production(self):
        def fail_activation(workspace, monitor):
            self.assertTrue(workspace.startswith("grid-fixture-run-"))
            self.assertEqual(monitor, 1)
            self.assertTrue((self.active / "original.json").exists())
            raise RuntimeError("Injected setup failure")

        with patch.object(live, "activate", side_effect=fail_activation):
            with self.assertRaisesRegex(RuntimeError, "Injected setup failure"):
                with live.fixture_session(self.choose_display):
                    self.fail("Setup must stop before verification")
        self.restore.assert_called_once()
        self.launch.assert_called_once()

    def test_interrupt_during_verification_restores_before_restarting_production(self):
        with patch.object(live, "activate"):
            with self.assertRaises(KeyboardInterrupt):
                with live.fixture_session(self.choose_display) as session:
                    self.assertEqual(session.directory.stat().st_mode & 0o777, 0o700)
                    signal.raise_signal(signal.SIGTERM)
        self.restore.assert_called_once()
        self.launch.assert_called_once()

    def test_handoff_retries_before_controller_is_ready(self):
        def handoff_after_startup(mode, **kwargs):
            if command.call_count == 1:
                return "123"
            return self.handoff(mode, **kwargs)

        with patch.object(live, "command", side_effect=handoff_after_startup) as command:
            with patch.object(live, "activate"), patch.object(live.time, "sleep"):
                with live.fixture_session(self.choose_display):
                    self.assertEqual(command.call_count, 2)
        self.restore.assert_called_once()
        self.launch.assert_called_once()

    def test_occupied_fixture_workspace_keeps_production_blocked_after_restore(self):
        with patch.object(live, "activate"):
            with self.assertRaisesRegex(RuntimeError, "A window remains in a fixture workspace"):
                with live.fixture_session(self.choose_display) as session:
                    live.write_json(session.directory / "fixture-workspaces.json", ["grid-space-fixture-block"])
                    self.observation["windowHomes"].append(dict(id=13, pid=44, boot="boot", workspace="grid-space-fixture-block"))
        self.restore.assert_called_once()
        self.launch.assert_not_called()
        self.observation["windowHomes"].pop()
        live.recover()
        self.launch.assert_called_once()

    def test_failed_restore_keeps_the_controller_blocked_until_explicit_recovery(self):
        self.restore.side_effect = RuntimeError("Native restore failed")
        with patch.object(live, "activate"):
            with self.assertRaisesRegex(RuntimeError, "Native restore failed"):
                with live.fixture_session(self.choose_display):
                    pass
        self.launch.assert_not_called()
        original = json.loads((self.active / "original.json").read_text())
        self.assertEqual(original["visible"], {"1": "original"})
        self.restore.side_effect = self.check_interlock
        live.recover()
        self.assertEqual(self.restore.call_count, 2)
        self.launch.assert_called_once()


class DesktopRestoreTests(unittest.TestCase):
    def test_remaps_physical_displays_and_restores_native_and_real_focus(self):
        focused = dict(id=12, pid=42, boot="boot", workspace="original")
        original = dict(displays={"1": "builtin"}, visible={"1": "original"}, native={"1": 7},
                        focusedMonitor=1, focused=focused, focusWasFrontmost=True)
        observed = {
            "displays": [dict(id="builtin", monitor=2)], "visible": {"2": "fixture"},
            "focusedMonitor": 2, "focusedWindow": 12, "windowHomes": [focused],
            "placementDiagnostics": {"nativeDisplays": [dict(monitor=2, current=9)],
                                     "frontmostMatchesFocusedWindowOwner": False},
        }
        calls = []

        def command(*args):
            calls.append(args)
            if args[-1] == "activate-target":
                observed["visible"] = {"2": "original"}
                self.assertEqual(json.loads(args[-2]), {"monitor": 2})
            elif args[-1] == "native-focus":
                observed["placementDiagnostics"]["nativeDisplays"][0]["current"] = 7
            elif args[0] == "focus":
                observed["placementDiagnostics"]["frontmostMatchesFocusedWindowOwner"] = True

        with patch.object(live, "status", return_value=observed), patch.object(live, "command", side_effect=command):
            live.restore(original)
        self.assertEqual([call[-1] for call in calls], ["activate-target", "native-focus", 12])


if __name__ == "__main__":
    unittest.main()
