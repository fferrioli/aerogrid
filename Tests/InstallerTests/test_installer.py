import importlib.util
import json
import pathlib
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class InstallerTests(unittest.TestCase):
    def testCleanMacNeedsNoExistingAeroSpaceAndKeepsSeedBackupAcrossUpdates(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/first"
            with patch.object(installer, "run"), patch.object(installer, "validate_configuration"):
                installer.main()
                config = home / ".aerospace.toml"
                manifest = json.loads((installer.SUPPORT / "installation.json").read_text())
                backup = pathlib.Path(manifest["backup"])
                seed = backup.read_text()
                self.assertEqual(installer.prepare_config.__globals__["parse"](seed)["persistent-workspaces"], [])
                settings = json.loads((installer.SUPPORT / "config.json").read_text())
                names = {cell["workspace"] for grid in settings["grids"] for cell in grid["cells"]}
                self.assertTrue(names)
                self.assertTrue(all(name.startswith("grid-") for name in names))
                self.assertEqual(set(installer.prepare_config.__globals__["parse"](config.read_text())["persistent-workspaces"]), names)
                self.assertEqual(settings["backendPath"], str(home / "Applications/AeroGrid Backend.app/Contents/Resources/aerospace"))
                installer.BACKUPS = installer.SUPPORT / "backups/second"
                installer.main()
            self.assertEqual(backup.read_text(), seed)
            self.assertEqual(json.loads((installer.SUPPORT / "installation.json").read_text())["backup"], str(backup))
            remover = module("uninstall")
            remover.HOME = home
            remover.SUPPORT = installer.SUPPORT
            with patch.object(remover.subprocess, "run", return_value=types.SimpleNamespace(returncode=1)):
                remover.main()
            self.assertEqual(installer.prepare_config.__globals__["parse"](config.read_text())["persistent-workspaces"], [])

    def testFailedCleanInstallDoesNotLeaveConfigOrInstalledBundles(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/failure"
            with patch.object(installer, "run"), patch.object(installer, "validate_configuration"), \
                    patch.object(installer, "write_json", side_effect=RuntimeError("disk failure")):
                with self.assertRaisesRegex(RuntimeError, "disk failure"):
                    installer.main()
            self.assertFalse((home / ".aerospace.toml").exists())
            self.assertFalse((installer.APPS / "AeroGrid.app").exists())
            self.assertFalse((installer.APPS / "AeroGrid Backend.app").exists())
            self.assertFalse((installer.SUPPORT / "installation.json").exists())

    def testPermissionResetIsLimitedToChangedOwnedAdhocSignatures(self):
        installer = module("install")
        previous = {"AeroGrid.app": 'cdhash H"one"', "AeroGrid Backend.app": 'cdhash H"same"'}
        current = {"AeroGrid.app": 'cdhash H"two"', "AeroGrid Backend.app": 'cdhash H"same"'}
        with patch.object(installer, "run") as run:
            installer.reset_changed_adhoc_permissions(previous, current)
            run.assert_called_once_with("tccutil", "reset", "Accessibility", "local.AeroGrid")
        with patch.object(installer, "run") as run:
            installer.reset_changed_adhoc_permissions({}, {"AeroGrid.app": 'identifier "local.AeroGrid" and anchor apple generic'})
            run.assert_not_called()

    def testRepeatedInstallPreservesOriginalBackupAndUninstallPreservesUserSettings(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/first"
            original = 'persistent-workspaces = ["legacy", "C"]\nstart-at-login = false\n[workspace-to-monitor-force-assignment]\nM = "secondary"\nOther = "main"\n[[on-window-detected]]\nif.app-name-regex-substring = "Cursor"\nrun = "move-node-to-workspace W"\n'
            config = home / ".aerospace.toml"
            config.write_text(original)
            with patch.object(installer, "run"), patch.object(installer, "validate_configuration"):
                installer.main()
                manifest = json.loads((installer.SUPPORT / "installation.json").read_text())
                first_backup = manifest["backup"]
                self.assertNotIn("legacy", manifest["managedWorkspaces"])
                self.assertNotIn("C", manifest["managedWorkspaces"])
                self.assertEqual(pathlib.Path(first_backup).read_text(), original)
                # A user's unrelated edit after install must survive both update and uninstall.
                config.write_text(config.read_text().replace("start-at-login = false", "start-at-login = true"))
                installer.BACKUPS = installer.SUPPORT / "backups/second"
                installer.main()
            updated_manifest = json.loads((installer.SUPPORT / "installation.json").read_text())
            self.assertEqual(updated_manifest["backup"], first_backup)
            remover = module("uninstall")
            remover.HOME = home
            remover.SUPPORT = installer.SUPPORT
            with patch.object(remover.subprocess, "run", return_value=types.SimpleNamespace(returncode=1)):
                remover.main()
            restored = config.read_text()
            self.assertEqual(installer.prepare_config.__globals__["parse"](restored)["persistent-workspaces"], ["legacy", "C"])
            self.assertIn('start-at-login = true', restored)
            self.assertIn('M = "secondary"', restored)
            self.assertIn('Other = "main"', restored)
            self.assertIn('run = "move-node-to-workspace W"', restored)
            self.assertTrue(pathlib.Path(first_backup).exists())
            self.assertFalse((home / "Applications/AeroGrid.app").exists())
            self.assertFalse((home / ".local/bin/aerogrid").exists())

    def testMalformedConfigAndSigningFailureDoNotReplaceInstalledFiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/attempt"
            app = installer.APPS / "AeroGrid.app"
            app.mkdir(parents=True)
            marker = app / "previous-build"
            marker.write_text("keep")
            config = home / ".aerospace.toml"
            config.write_text('persistent-workspaces = [invalid\n')
            with patch.object(installer, "validate_configuration"):
                with self.assertRaises(Exception):
                    installer.main()
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual(config.read_text(), 'persistent-workspaces = [invalid\n')
            config.write_text('start-at-login = false\n')
            with patch.object(installer, "validate_configuration"), patch.object(installer, "run", side_effect=RuntimeError("signing failed")):
                with self.assertRaisesRegex(RuntimeError, "signing failed"):
                    installer.main()
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual(config.read_text(), 'start-at-login = false\n')
            self.assertFalse((installer.SUPPORT / "installation.json").exists())

    def testInstallerRefusesRunningBundlesBeforeAnyMutation(self):
        installer = module("install")
        with patch.object(installer.subprocess, "run", return_value=types.SimpleNamespace(returncode=0)):
            with self.assertRaisesRegex(RuntimeError, "Quit AeroGrid"):
                installer.ensure_apps_stopped()

    def testTomlLiteralNamesCommentsAndMultilineCallbacksArePreserved(self):
        installer = module("install")
        original = '''# Keep this comment
"persistent-workspaces" = [
    'literal\\n[name]', # Keep literal backslash and brackets
    "C",
]
after-startup-command = ["""exec-and-forget echo hello
[this is text, not a table]
"""]
[workspace-to-monitor-force-assignment]
"M" = ["secondary", "main"]
Other = "main"
'''
        updated, ownership = installer.prepare_config(original, ["M", "C", "grid-new"], original, {})
        parsed = installer.prepare_config.__globals__["parse"](updated)
        self.assertEqual(parsed["persistent-workspaces"][0], 'literal\\n[name]')
        self.assertIn('# Keep literal backslash and brackets', updated)
        self.assertIn('[this is text, not a table]', updated)
        self.assertEqual(parsed["workspace-to-monitor-force-assignment"], {"Other": "main"})
        remover = module("uninstall")
        restored = remover.remove_owned_settings(updated, original, ownership)
        self.assertEqual(installer.prepare_config.__globals__["parse"](restored)["workspace-to-monitor-force-assignment"]["M"], ["secondary", "main"])

    def testFailedCommitRestoresBundlesConfigsAndExistingLaunchers(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/rollback"
            staging = home / "staging"
            staging.mkdir()
            old = installer.APPS / "AeroGrid.app"
            old.mkdir(parents=True)
            (old / "marker").write_text("old")
            new = staging / "AeroGrid.app"
            new.mkdir()
            (new / "marker").write_text("new")
            installer.SUPPORT.mkdir(parents=True)
            saved = installer.SUPPORT / "config.json"
            saved.write_text('{"old": true}')
            config = home / ".aerospace.toml"
            config.write_text("old-config")
            with patch.object(installer, "write_json", side_effect=RuntimeError("write failed")):
                with self.assertRaisesRegex(RuntimeError, "write failed"):
                    installer.commit_install([new], {}, config, "new-config", {})
            self.assertEqual((old / "marker").read_text(), "old")
            self.assertEqual(saved.read_text(), '{"old": true}')
            self.assertEqual(config.read_text(), "old-config")
            self.assertFalse((installer.SUPPORT / "installation.json").exists())

    def testLauncherFailureRollsBackAlreadyCommittedConfigAndBundles(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            installer = module("install")
            installer.HOME = home
            installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/rollback"
            staging = home / "staging"
            staging.mkdir()
            staged = []
            for name in ["AeroGrid", "AeroGrid Backend"]:
                installed = installer.APPS / f"{name}.app"
                installed.mkdir(parents=True)
                (installed / "marker").write_text("old")
                replacement = staging / installed.name
                replacement.mkdir()
                (replacement / "marker").write_text("new")
                staged.append(replacement)
            installer.SUPPORT.mkdir(parents=True)
            config = home / ".aerospace.toml"
            config.write_text("old-config")
            saved = installer.SUPPORT / "config.json"
            saved.write_text('{"old": true}')
            manifest = installer.SUPPORT / "installation.json"
            manifest.write_text('{"previous": true}')
            local_bin = home / ".local/bin"
            local_bin.mkdir(parents=True)
            controller_link = local_bin / "aerogrid"
            controller_link.symlink_to("old-controller")
            backend_launcher = local_bin / "aerogrid-aerospace"
            backend_launcher.write_text("old-backend-launcher")
            create_symlink = pathlib.Path.symlink_to

            def fail_backend_link(path, target, *args, **kwargs):
                if path == backend_launcher:
                    raise OSError("launcher creation failed")
                return create_symlink(path, target, *args, **kwargs)

            with patch.object(pathlib.Path, "symlink_to", fail_backend_link):
                with self.assertRaisesRegex(OSError, "launcher creation failed"):
                    installer.commit_install(staged, {"new": True}, config, "new-config", {"new": True})
            for name in ["AeroGrid", "AeroGrid Backend"]:
                self.assertEqual((installer.APPS / f"{name}.app/marker").read_text(), "old")
            self.assertEqual(config.read_text(), "old-config")
            self.assertEqual(saved.read_text(), '{"old": true}')
            self.assertEqual(manifest.read_text(), '{"previous": true}')
            self.assertEqual(controller_link.readlink(), pathlib.Path("old-controller"))
            self.assertEqual(backend_launcher.read_text(), "old-backend-launcher")


if __name__ == "__main__":
    unittest.main()
