import importlib.util
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import textwrap
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
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tools = pathlib.Path(temporary.name)
        self.write_tool("security", 'print("")\n')
        environment = patch.dict(os.environ, {"PATH": str(self.tools) + os.pathsep + os.environ["PATH"]})
        environment.start()
        self.addCleanup(environment.stop)

    def write_tool(self, name, source):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source))
        path.chmod(0o700)

    def signing_fixture(self, home):
        source = home / "source"
        for name in [".build/release/AeroGrid", "vendor/AeroSpace/.build/release/AeroSpaceApp",
                     "vendor/AeroSpace/.build/release/aerospace", "vendor/AeroSpace/docs/config-examples/default-config.toml",
                     "scripts/update-worker.py"]:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("first binary\n")
        self.write_tool("security", '''
            import json, os, sys
            with open(os.environ["FAKE_SIGNING_LOG"], "a") as log:
                log.write(json.dumps(["security", *sys.argv[1:]]) + "\\n")
            print(os.environ["FAKE_IDENTITIES"])
        ''')
        self.write_tool("codesign", '''
            import hashlib, json, os, pathlib, plistlib, sys
            args = sys.argv[1:]
            with open(os.environ["FAKE_SIGNING_LOG"], "a") as log:
                log.write(json.dumps(["codesign", *args]) + "\\n")
            app = pathlib.Path(args[-1])
            requirement = app / "fake-requirement"
            if "--sign" in args:
                identity = args[args.index("--sign") + 1]
                if identity != "-" and os.environ.get("FAKE_SIGNING_FAILURE") == "1":
                    sys.exit("fake identity signing failed")
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                if identity == "-":
                    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
                    value = 'cdhash H"' + hashlib.sha256(binary.read_bytes()).hexdigest() + '"'
                else:
                    value = 'identifier "' + info["CFBundleIdentifier"] + '" and certificate leaf = H"' + identity + '"'
                requirement.write_text(value)
            elif "--display" in args:
                if not requirement.exists():
                    sys.exit(1)
                value = requirement.read_text()
                prefix = "# designated => " if value.startswith("cdhash ") else "designated => "
                print(prefix + value, file=sys.stderr)
        ''')
        self.write_tool("tccutil", '''
            import json, os, sys
            with open(os.environ["FAKE_SIGNING_LOG"], "a") as log:
                log.write(json.dumps(["tccutil", *sys.argv[1:]]) + "\\n")
        ''')
        return source

    def install_fixture(self, home, identities, fail_signing=False):
        log = home / "signing.jsonl"
        log.write_text("")
        environment = dict(os.environ, HOME=str(home), FAKE_IDENTITIES=identities,
                           FAKE_SIGNING_LOG=str(log), FAKE_SIGNING_FAILURE=str(int(fail_signing)))
        script = '''
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("install", sys.argv[1])
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
installer.ROOT = pathlib.Path(sys.argv[2])
installer.validate_configuration = lambda configuration: None
run = installer.run
def isolated_run(*args):
    if not args[0].endswith("lsregister"):
        run(*args)
installer.run = isolated_run
installer.main()
'''
        result = subprocess.run([sys.executable, "-c", script, str(ROOT / "scripts/install.py"), str(home / "source")],
                                env=environment, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    def testStableCertificateSignsChangedBinariesWithoutResettingPermissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            source = self.signing_fixture(home)
            identity = "A" * 40
            identities = (
                f'  1) {"B" * 40} "AeroGrid Local Code Signing Backup"\n'
                f'  2) {identity} "AeroGrid Local Code Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
                f'  3) {"C" * 40} "Other identity"\n'
                '     3 identities found'
            )
            first, _ = self.install_fixture(home, identities)
            self.assertEqual(first.returncode, 0, first.stderr)
            for name in [".build/release/AeroGrid", "vendor/AeroSpace/.build/release/AeroSpaceApp"]:
                (source / name).write_text("second binary\n")
            result, calls = self.install_fixture(home, identities)
            self.assertEqual(result.returncode, 0, result.stderr)
            signs = [call for call in calls if "--sign" in call]
            self.assertEqual(len(signs), 2)
            self.assertEqual([call[call.index("--sign") + 1] for call in signs], [identity, identity])
            self.assertEqual([call for call in calls if call[0] == "tccutil"], [])
            self.assertEqual([call for call in calls if call[0] == "security"],
                             [["security", "find-identity", "-p", "codesigning"]])
            self.assertIn("Signing: AeroGrid Local Code Signing", result.stdout)
            for name, binary in [("AeroGrid", "AeroGrid"), ("AeroGrid Backend", "AeroSpace")]:
                installed = home / f"Applications/{name}.app/Contents/MacOS/{binary}"
                self.assertEqual(installed.read_text(), "second binary\n")

    def testMigrationFromAdhocToCertificateResetsBothPermissionsOnce(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            self.signing_fixture(home)
            first, _ = self.install_fixture(home, "")
            self.assertEqual(first.returncode, 0, first.stderr)
            identity = "A" * 40
            result, calls = self.install_fixture(home, f'  1) {identity} "AeroGrid Local Code Signing"')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertCountEqual([call for call in calls if call[0] == "tccutil"], [
                ["tccutil", "reset", "Accessibility", "local.AeroGrid"],
                ["tccutil", "reset", "Accessibility", "local.AeroGrid.Backend"],
            ])

    def installed_snapshot(self, home):
        snapshot = {}
        for name in ["Applications", "Library", ".local", ".aerospace.toml"]:
            root = home / name
            for path in [root, *root.rglob("*")]:
                if path.is_symlink():
                    value = path.readlink()
                elif path.is_file():
                    value = path.read_bytes()
                else:
                    value = None
                snapshot[str(path.relative_to(home))] = value
        return snapshot

    def testNoIdentityKeepsAdhocSigningAndResetsOnlyChangedRequirements(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            source = self.signing_fixture(home)
            unrelated = f'  1) {"B" * 40} "AeroGrid Local Code Signing Backup"'
            for changed in [True, False, True]:
                if changed:
                    for name in [".build/release/AeroGrid", "vendor/AeroSpace/.build/release/AeroSpaceApp"]:
                        with (source / name).open("a") as binary:
                            binary.write("changed\n")
                result, calls = self.install_fixture(home, unrelated)
                self.assertEqual(result.returncode, 0, result.stderr)
                signs = [call for call in calls if "--sign" in call]
                self.assertEqual([call[call.index("--sign") + 1] for call in signs], ["-", "-"])
                resets = [call for call in calls if call[0] == "tccutil"]
                expected = [["tccutil", "reset", "Accessibility", identifier]
                            for identifier in ["local.AeroGrid", "local.AeroGrid.Backend"]] if changed else []
                self.assertCountEqual(resets, expected)
                self.assertIn("Signing: ad-hoc (run scripts/setup-signing.py for permissions that survive updates)", result.stdout)

    def testTrustedIdentityListedTwiceIsOneIdentity(self):
        installer = module("install")
        sha1 = "B" * 40
        listing = (f'Policy: Code Signing\n  Matching identities\n  1) {sha1} "AeroGrid Local Code Signing"\n     1 identities found\n\n'
                   f'  Valid identities only\n  1) {sha1} "AeroGrid Local Code Signing"\n     1 valid identities found\n')
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=listing, stderr="")):
            self.assertEqual(installer.signing_identity(), sha1)

    def testDuplicateSigningIdentitiesAbortBeforeChangingInstalledFiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            self.signing_fixture(home)
            first, _ = self.install_fixture(home, "")
            self.assertEqual(first.returncode, 0, first.stderr)
            before = self.installed_snapshot(home)
            identities = '\n'.join(f'  {index}) {letter * 40} "AeroGrid Local Code Signing"'
                                   for index, letter in [(1, "A"), (2, "B")])
            result, calls = self.install_fixture(home, identities)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("More than one AeroGrid signing identity; run scripts/setup-signing.py --remove and set it up again.", result.stderr)
            self.assertEqual(calls, [["security", "find-identity", "-p", "codesigning"]])
            self.assertEqual(self.installed_snapshot(home), before)

    def testCertificateSigningFailureAbortsWithoutAdhocFallbackOrInstalledChanges(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            self.signing_fixture(home)
            first, _ = self.install_fixture(home, "")
            self.assertEqual(first.returncode, 0, first.stderr)
            before = self.installed_snapshot(home)
            identity = "A" * 40
            result, calls = self.install_fixture(home, f'  1) {identity} "AeroGrid Local Code Signing"', fail_signing=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fake identity signing failed", result.stderr)
            signs = [call for call in calls if "--sign" in call]
            self.assertEqual([call[call.index("--sign") + 1] for call in signs], [identity])
            self.assertEqual([call for call in calls if call[0] == "tccutil"], [])
            self.assertEqual(self.installed_snapshot(home), before)

    def testPermissionResetHandlesCertificateRotationRemovalAndMissingRequirements(self):
        installer = module("install")
        certificate = 'identifier "local.AeroGrid" and certificate leaf = H"one"'
        replacement = 'identifier "local.AeroGrid" and certificate leaf = H"two"'
        for previous, current, reset in [
            (None, certificate, False),
            (certificate, certificate, False),
            (certificate, replacement, True),
            (certificate, 'cdhash H"new"', True),
            (certificate, None, False),
        ]:
            with self.subTest(previous=previous, current=current), patch.object(installer, "run") as run:
                installer.reset_changed_permissions({"AeroGrid.app": previous}, {"AeroGrid.app": current})
                if reset:
                    run.assert_called_once_with("tccutil", "reset", "Accessibility", "local.AeroGrid")
                else:
                    run.assert_not_called()

    def testDesignatedRequirementReadsAdhocAndCertificateOutput(self):
        installer = module("install")
        requirements = [('# designated => ', 'cdhash H"one"'),
                        ('designated => ', 'identifier "local.AeroGrid" and certificate leaf = H"two"')]
        with tempfile.TemporaryDirectory() as temporary:
            for prefix, requirement in requirements:
                for stream in ["stdout", "stderr"]:
                    with self.subTest(prefix=prefix, stream=stream):
                        output = dict(returncode=0, stdout="", stderr="")
                        output[stream] = "Executable=fixture\n" + prefix + requirement + "\n"
                        with patch.object(installer.subprocess, "run", return_value=types.SimpleNamespace(**output)):
                            self.assertEqual(installer.designated_requirement(pathlib.Path(temporary)), requirement)

    def testInstalledFrontendIncludesUpdaterAndExactBuildIdentity(self):
        installer = module("install")
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            installer.ROOT = root
            (root / ".build").mkdir()
            metadata = dict(revision="a" * 40, dirty=False, builtAt="2026-10-28T00:00:00+00:00", updateProtocol=1)
            (root / ".build/build-info.json").write_text(json.dumps(metadata))
            binary = root / "binary"; binary.write_bytes(b"fixture binary")
            worker = ROOT / "scripts/update-worker.py"
            with patch.object(installer, "run"):
                app = installer.bundle(root / "stage", "AeroGrid", "AeroGrid", "local.AeroGrid", binary, [worker])
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["AeroGridRevision"], metadata["revision"])
            self.assertEqual(info["AeroGridSourceDirty"], False)
            self.assertTrue(pathlib.Path(info["AeroGridPythonPath"]).is_absolute())
            self.assertEqual((app / "Contents/Resources/update-worker.py").read_bytes(), worker.read_bytes())

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

    def testInstallerIgnoresHelperArgumentsButRefusesRealInstalledProcesses(self):
        installer = module("install")
        with tempfile.TemporaryDirectory() as temporary:
            installer.APPS = pathlib.Path(temporary) / "Applications"
            for name, executable in [("AeroGrid", "AeroGrid"), ("AeroGrid Backend", "AeroSpace")]:
                path = installer.APPS / f"{name}.app/Contents/MacOS/{executable}"
                path.parent.mkdir(parents=True)
                helper = subprocess.Popen(["/usr/bin/python3", "-c", "import time; time.sleep(30)", str(path)])
                try:
                    installer.ensure_apps_stopped()
                finally:
                    helper.terminate(); helper.wait(timeout=5)
                path.symlink_to("/bin/sleep")
                app = subprocess.Popen([str(path), "30"])
                try:
                    with self.assertRaisesRegex(RuntimeError, f"Quit {name}"):
                        installer.ensure_apps_stopped()
                finally:
                    app.terminate(); app.wait(timeout=5)

    def testInstallerRefusesWhenProcessInspectionFails(self):
        installer = module("install")
        with patch.object(installer.subprocess, "run", return_value=types.SimpleNamespace(returncode=2)):
            with self.assertRaisesRegex(RuntimeError, "Cannot check"):
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
