import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch
import types
import os
import signal
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("spatial_recovery", ROOT / "scripts/recover-spatial-map.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


def rect(row=0, column=0):
    return dict(row=row, column=column, width=1, height=1)


def state():
    return dict(customField="keep", dynamicMap=dict(version=3, spaces=[
        dict(id="first", workspace="first", row=0, column=0, preferredRole="builtin", foldedRect=rect()),
        dict(id="conflict", workspace="second", row=1, column=0, preferredRole="builtin", foldedRect=rect()),
        dict(id="dormant", workspace="third", row=2, column=0, preferredRole="external", dormant=True, foldedRect=rect(1)),
        dict(id="valid", workspace="fourth", row=3, column=0, preferredRole="external", foldedRect=rect(3)),
    ], families=[dict(sourceID="first", childIDs=["first", "conflict"])], layouts={"first": "saved layout"}, undo=[dict(custom="keep")]))


class SpatialRecoveryTests(unittest.TestCase):
    def testOnlyAdaptedPositionsChangeAndInputIsUntouched(self):
        original = state()
        fixed, changed = recovery.repair(original)
        self.assertEqual(changed, ["conflict", "dormant"])
        self.assertEqual(original, state())
        for before, after in zip(original["dynamicMap"]["spaces"], fixed["dynamicMap"]["spaces"]):
            stripped = copy.deepcopy(before)
            if before["id"] in changed:
                stripped.pop("foldedRect")
            self.assertEqual(after, stripped)
        self.assertEqual(fixed["dynamicMap"]["layouts"], original["dynamicMap"]["layouts"])
        self.assertEqual(fixed["dynamicMap"]["undo"], original["dynamicMap"]["undo"])
        self.assertEqual(fixed["dynamicMap"]["families"], original["dynamicMap"]["families"])
        self.assertEqual(fixed["customField"], "keep")
        self.assertEqual(recovery.repair(fixed), (fixed, []))

    def testUserCreatedAndFullscreenSpacesAreNotTreatedAsDormant(self):
        original = state()
        original["dynamicMap"]["spaces"] = [
            dict(id="created", workspace="one", dormant=True, userCreated=True, foldedRect=rect()),
            dict(id="native", workspace="two", dormant=True, nativeWindow=dict(id=1), foldedRect=rect(1)),
        ]
        self.assertEqual(recovery.repair(original), (original, []))

    def testPendingOrUnsupportedStateIsRefused(self):
        for field, value in [("pending", dict(before={})), ("version", 4)]:
            original = state()
            original["dynamicMap"][field] = value
            with self.assertRaises(ValueError):
                recovery.repair(original)

    def testApplyBacksUpExactBytesAndLeavesConfigurationUnchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            payload = json.dumps(state(), separators=(",", ":")).encode()
            (directory / "state.json").write_bytes(payload)
            (directory / "config.json").write_text("unchanged")
            backup, count = recovery.apply_repair(directory, running=lambda: False)
            self.assertEqual(count, 2)
            self.assertEqual((backup / "state.json").read_bytes(), payload)
            self.assertEqual((directory / "config.json").read_text(), "unchanged")
            self.assertEqual(recovery.repair(json.loads((directory / "state.json").read_bytes()))[1], [])
            self.assertEqual(recovery.apply_repair(directory, running=lambda: False), (None, 0))

    def testRunningControllerPreventsAnyWrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            payload = json.dumps(state()).encode()
            (directory / "state.json").write_bytes(payload)
            with self.assertRaises(RuntimeError):
                recovery.apply_repair(directory, running=lambda: True)
            self.assertEqual((directory / "state.json").read_bytes(), payload)
            self.assertFalse((directory / "backups").exists())

    def testReopenedControllerPreservesOriginalAndBackup(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            payload = json.dumps(state()).encode()
            (directory / "state.json").write_bytes(payload)
            calls = iter([False, True])
            with self.assertRaises(RuntimeError):
                recovery.apply_repair(directory, running=lambda: next(calls))
            self.assertEqual((directory / "state.json").read_bytes(), payload)
            self.assertEqual(len(list((directory / "backups").glob("*/state.json"))), 1)
            self.assertEqual(list(directory.glob(".spatial-recovery-*")), [])

    def testConcurrentStateEditIsNotOverwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            (directory / "state.json").write_text(json.dumps(state()))
            calls = 0
            def running():
                nonlocal calls
                calls += 1
                if calls == 2:
                    (directory / "state.json").write_text("newer state")
                return False
            with self.assertRaises(RuntimeError):
                recovery.apply_repair(directory, running=running)
            self.assertEqual((directory / "state.json").read_text(), "newer state")

    def testLiveObservationKeepsCurrentHomesLayoutsAndVisibleCursor(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            original = state()
            (directory / "state.json").write_text(json.dumps(original))
            desktop = dict(displays=[dict(id="screen", monitor=1)], visible={"1": "first"}, windows=[], windowHomes=[dict(id=42)], backendSession="live")
            backup, _ = recovery.apply_repair(directory, running=lambda: False, observation=(desktop, {"first": "current-layout"}))
            fixed = json.loads((directory / "state.json").read_text())
            self.assertEqual(fixed["lastDesktop"], desktop)
            self.assertEqual(fixed["dynamicMap"]["layouts"]["first"], "current-layout")
            self.assertEqual(fixed["dynamicMap"]["cursors"]["screen"], "first")
            self.assertTrue(fixed["dynamicMap"]["families"][0]["manuallyEdited"])
            self.assertEqual(json.loads((backup / "state.json").read_text()), original)

    def testOnlyVerifiedFrontendProcessCanBeStopped(self):
        own = types.SimpleNamespace(returncode=0, stdout="123\n")
        details = types.SimpleNamespace(returncode=0, stdout=str(os.getuid()) + " /Applications/AeroGrid.app/Contents/MacOS/AeroGrid\n")
        with patch.object(recovery.subprocess, "run", side_effect=[own, details]), patch.object(recovery.os, "kill") as kill, patch.object(recovery, "controller_running", return_value=False):
            recovery.stop_controller()
            kill.assert_called_once_with(123, signal.SIGTERM)
        details.stdout = str(os.getuid()) + " /usr/bin/AeroGrid\n"
        with patch.object(recovery.subprocess, "run", side_effect=[own, details]), patch.object(recovery.os, "kill") as kill:
            with self.assertRaises(RuntimeError):
                recovery.stop_controller()
            kill.assert_not_called()

    def testBackendObservationUsesReadOnlyCommands(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            cli = directory / "matching-cli"
            cli.touch()
            (directory / "config.json").write_text(json.dumps(dict(backendPath=str(cli))))
            desktop = dict(displays=[], visible={"1": "first"}, windows=[])
            snapshot = dict(version=1, tree={})
            values = [types.SimpleNamespace(returncode=0, stdout=json.dumps(value).encode()) for value in [desktop, snapshot]]
            with patch.object(recovery.subprocess, "run", side_effect=values) as run:
                actual, layouts = recovery.observe_backend(directory)
                self.assertEqual(actual, desktop)
                self.assertEqual(json.loads(layouts["first"]), snapshot)
                self.assertEqual(run.call_args_list[0].args[0][1:], ["grid-layout", "status"])
                self.assertEqual(run.call_args_list[1].args[0][1:], ["grid-layout", "--workspace", "first", "snapshot"])

    def testObservedCompactLayoutAndFullscreenHomeAreProtected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            original = state()
            original["dynamicMap"]["fullscreens"] = [dict(homeID="first", spaceID="native")]
            (directory / "state.json").write_text(json.dumps(original))
            desktop = dict(displays=[dict(id="screen", monitor=1, builtin=True)], visible={"1":"fourth"}, windows=[dict(workspace="fourth")])
            recovery.apply_repair(directory, running=lambda:False, observation=(desktop, {}))
            fixed = json.loads((directory / "state.json").read_text())["dynamicMap"]
            self.assertTrue(fixed["spaces"][3]["joinedWhileFolded"])
            self.assertTrue(fixed["fullscreens"][0]["homeEdited"])

    def testDiagnosticCliDoesNotExposeSpaceNamesOrWriteState(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            original = state()
            original["dynamicMap"]["spaces"][0]["name"] = "LOCAL PRIVATE LABEL"
            payload = json.dumps(original).encode()
            (directory / "state.json").write_bytes(payload)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/recover-spatial-map.py"), "--directory", str(directory)], capture_output=True, text=True, check=True)
            self.assertNotIn("LOCAL PRIVATE LABEL", result.stdout)
            self.assertIn("Sólo diagnóstico", result.stdout)
            self.assertEqual((directory / "state.json").read_bytes(), payload)
            self.assertFalse((directory / "backups").exists())
