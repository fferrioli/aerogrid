import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import types
import unittest
import zipfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHA = "a" * 40


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class UpdateTests(unittest.TestCase):
    def archive(self, folder, extra=None):
        path = folder / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name in ["Package.swift", "scripts/build.sh", "scripts/install.py", "scripts/update-worker.py"]:
                archive.writestr(f"aerogrid-{SHA}/{name}", "fixture")
            if extra:
                extra(archive)
        return path

    def testExtractionRejectsTraversalWrongRevisionAndExternalLinks(self):
        worker = module("update-worker")
        for bad in ["../outside", f"aerogrid-{SHA}/../../outside", "/outside", "another-revision/Package.swift"]:
            with self.subTest(path=bad), tempfile.TemporaryDirectory() as temporary:
                folder = pathlib.Path(temporary)
                archive = self.archive(folder, lambda z: z.writestr(bad, "bad"))
                with self.assertRaises(ValueError):
                    worker.extract_archive(archive, folder / "code", SHA)
                self.assertFalse((folder / "outside").exists())
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            def link(z):
                entry = zipfile.ZipInfo(f"aerogrid-{SHA}/escape")
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(entry, "../../outside")
            archive = self.archive(folder, link)
            with self.assertRaisesRegex(ValueError, "Enlace fuera"):
                worker.extract_archive(archive, folder / "code", SHA)
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            outside = folder / "outside"; outside.mkdir()
            def nested_links(z):
                for name, target in [("escape", "../../outside"), ("escape/rogue", "..")] :
                    entry = zipfile.ZipInfo(f"aerogrid-{SHA}/{name}")
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    z.writestr(entry, target)
            with self.assertRaisesRegex(ValueError, "Enlace fuera"):
                worker.extract_archive(self.archive(folder, nested_links), folder / "code", SHA)
            self.assertEqual(list(outside.iterdir()), [])

    def testSafeUpstreamSymlinksAndExecutableScriptsArePreserved(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            def link(z):
                entry = zipfile.ZipInfo(f"aerogrid-{SHA}/xcode/package")
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(entry, "..")
            root = worker.extract_archive(self.archive(folder, link), folder / "code", SHA)
            self.assertEqual((root / "xcode/package").resolve(), root.resolve())
            self.assertTrue((root / "scripts/install.py").is_file())

    def testBadRevisionAndWrongControllerRefuseBeforeDownloadOrChanges(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            (folder / "request.json").write_text(json.dumps(dict(revision="main;bad", controllerPID=100)))
            with patch.object(worker, "download_archive") as download:
                with self.assertRaisesRegex(ValueError, "Revisión"):
                    worker.update(folder, folder)
                download.assert_not_called()
            with patch.object(worker.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout="501 /different/app")):
                with self.assertRaisesRegex(ValueError, "iniciada por AeroGrid"):
                    worker.verify_controller(100, folder)

    def testCancelledBuildStopsOnlyItsOwnProcessGroupAndLeavesAppState(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            job = pathlib.Path(temporary)
            (job / "cancel").touch()
            process = types.SimpleNamespace(pid=12345, poll=lambda: None, wait=lambda timeout=None: 0)
            with patch.object(worker.subprocess, "Popen", return_value=process), patch.object(worker.os, "killpg") as kill:
                with self.assertRaises(worker.Cancelled):
                    worker.run_command(["fake-build"], job)
                kill.assert_called_once_with(12345, worker.signal.SIGTERM)

    def testHandoffRefusesStillRunningComponentsWithoutKillingThem(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            job = pathlib.Path(temporary)
            (job / "install").touch()
            with patch.object(worker, "running_bundles", return_value=True), patch.object(worker.time, "monotonic", side_effect=[0, 0, 61]), patch.object(worker.os, "killpg") as kill:
                with self.assertRaisesRegex(RuntimeError, "siguen abiertos"):
                    worker.await_handoff(job, job)
                kill.assert_not_called()

    def testInstallationCannotBeInterruptedByCancellationOrBuildTimeout(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            job = pathlib.Path(temporary)
            (job / "cancel").touch()
            process = unittest.mock.Mock(pid=12345, returncode=0)
            process.poll.side_effect = [None, 0]
            with patch.object(worker.subprocess, "Popen", return_value=process), patch.object(worker.time, "monotonic", side_effect=[0, 99999]), patch.object(worker.time, "sleep"), patch.object(worker.os, "killpg") as kill:
                worker.run_command(["installer"], job, timeout=1, cancellable=False)
                kill.assert_not_called()

    def testBackupRetainsExactStateAndConfigurationBytes(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            support = home / "Library/Application Support/AeroGrid"
            support.mkdir(parents=True)
            job = home / "job"; job.mkdir()
            original = b'{ "private_fixture": "preserve exact bytes" }\n'
            for name in ["state.json", "config.json", "control.json", "installation.json"]:
                (support / name).write_bytes(original)
            worker.backup_state(home, job)
            for name in ["state.json", "config.json", "control.json", "installation.json"]:
                self.assertEqual((job / "backup" / name).read_bytes(), original)
                self.assertEqual((support / name).read_bytes(), original)
            self.assertEqual(stat.S_IMODE((job / "backup").stat().st_mode), 0o700)

    def testFullWorkflowKeepsAppRunningThroughBuildAndWaitsForHandoff(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            job = home / "job"; job.mkdir()
            (job / "request.json").write_text(json.dumps(dict(revision=SHA, controllerPID=100)))
            events = []
            old = home / "Applications/AeroGrid.app/marker"
            old.parent.mkdir(parents=True); old.write_text("old")
            def download(revision, archive, current_job):
                archive.write_bytes(self.archive(home).read_bytes())
            def command(args, current_job, cwd=None, **kwargs):
                if args[0] == "/bin/zsh":
                    self.assertEqual(old.read_text(), "old")
                    self.assertFalse((job / "install").exists())
                    self.assertEqual(kwargs["env"]["AEROGRID_BUILD_REVISION"], SHA)
                    (cwd / ".build").mkdir()
                    (cwd / ".build/build-info.json").write_text(json.dumps(dict(revision=SHA, dirty=False)))
                    events.append("build")
                elif args[-1] == "scripts/install.py":
                    self.assertEqual(events, ["build", "validated", "handoff"])
                    self.assertFalse(kwargs["cancellable"])
                    old.write_text("new")
                    events.append("install")
                else:
                    self.assertIn("--validate-config", args)
                    events.append("validated")
            def handoff(*args):
                self.assertEqual(old.read_text(), "old")
                self.assertEqual(json.loads((job / "status.json").read_text())["phase"], "ready")
                events.append("handoff")
            tool = types.SimpleNamespace(returncode=0, stdout="Apple Swift version 6.2.3")
            with patch.object(worker, "verify_controller"), patch.object(worker, "download_archive", side_effect=download), patch.object(worker, "run_command", side_effect=command), patch.object(worker, "await_handoff", side_effect=handoff), patch.object(worker.subprocess, "run", return_value=tool) as external:
                worker.update(job, home)
                self.assertEqual(external.call_args.args[0], ["/usr/bin/open", str(home / "Applications/AeroGrid.app")])
            self.assertEqual(old.read_text(), "new")
            self.assertEqual(json.loads((job / "status.json").read_text())["phase"], "complete")
            self.assertFalse((job / "source").exists())
            self.assertFalse((job / "source.zip").exists())

    def testBuildFailureDoesNotRequestHandoffOrInstall(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            job = home / "job"; job.mkdir()
            (job / "request.json").write_text(json.dumps(dict(revision=SHA, controllerPID=100)))
            def download(revision, archive, current_job):
                archive.write_bytes(self.archive(home).read_bytes())
            with patch.object(worker, "verify_controller"), patch.object(worker, "download_archive", side_effect=download), patch.object(worker, "run_command", side_effect=RuntimeError("build failed")), patch.object(worker, "await_handoff") as handoff, patch.object(worker.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout="Swift version 6.2")):
                with self.assertRaisesRegex(RuntimeError, "build failed"):
                    worker.update(job, home)
                handoff.assert_not_called()
                self.assertFalse((job / "backup").exists())

    def testFailedHandoffReopensControllerWhenBackendRemainsRunning(self):
        worker = module("update-worker")
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            job = home / "job"; job.mkdir()
            source = home / "code"; (source / ".build").mkdir(parents=True)
            (source / ".build/build-info.json").write_text(json.dumps(dict(revision=SHA, dirty=False)))
            (job / "request.json").write_text(json.dumps(dict(revision=SHA, controllerPID=100)))
            tool = types.SimpleNamespace(returncode=0, stdout="Swift version 6.2")
            with patch.object(worker, "verify_controller"), patch.object(worker, "download_archive"), patch.object(worker, "extract_archive", return_value=source), patch.object(worker, "run_command") as command, patch.object(worker, "await_handoff", side_effect=RuntimeError("backend still running")), patch.object(worker, "running_bundles", return_value=True), patch.object(worker.subprocess, "run", return_value=tool) as external:
                with self.assertRaisesRegex(RuntimeError, "backend still running"):
                    worker.update(job, home)
                self.assertEqual(external.call_args.args[0], ["/usr/bin/open", str(home / "Applications/AeroGrid.app")])
                self.assertEqual(command.call_count, 2) # Build and validation only; no installation.

    def testNetworkRedirectsMustRemainOnGitHubOverHTTPS(self):
        worker = module("update-worker")
        redirect = worker.GitHubRedirects()
        for url in ["http://codeload.github.com/archive", "https://example.com/archive"]:
            with self.assertRaisesRegex(RuntimeError, "inesperada"):
                redirect.redirect_request(None, None, 302, "", {}, url)

    def testWorkflowInstallsBothRealBuiltBundlesInTemporaryHomeAndKeepsState(self):
        worker = module("update-worker")
        installer = module("install")
        real_run = subprocess.run
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            job = home / "job"; job.mkdir()
            source = home / "prepared-source"; source.mkdir()
            files = [".build/release/AeroGrid", "vendor/AeroSpace/.build/release/AeroSpaceApp", "vendor/AeroSpace/.build/release/aerospace", "vendor/AeroSpace/docs/config-examples/default-config.toml", "scripts/update-worker.py"]
            for name in files:
                target = source / name; target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(ROOT / name)
            (source / ".build/build-info.json").write_text(json.dumps(dict(revision=SHA, dirty=False, builtAt="2026-10-28T00:00:00+00:00")))
            installer.ROOT = source; installer.HOME = home; installer.APPS = home / "Applications"
            installer.SUPPORT = home / "Library/Application Support/AeroGrid"
            installer.BACKUPS = installer.SUPPORT / "backups/update-test"
            installer.SUPPORT.mkdir(parents=True)
            for name in ["AeroGrid", "AeroGrid Backend"]:
                old = home / f"Applications/{name}.app"
                old.mkdir(parents=True)
                (old / "old-build-marker").write_text("previous build")
            state = b'{"test_fixture": "exact bytes preserved"}\n'
            (installer.SUPPORT / "state.json").write_bytes(state)
            (installer.SUPPORT / "control.json").write_text('{"paused": true}\n')
            config = installer.default_config(home / "Applications/AeroGrid Backend.app/Contents/Resources/aerospace")
            (installer.SUPPORT / "config.json").write_text(json.dumps(config))
            (job / "request.json").write_text(json.dumps(dict(revision=SHA, controllerPID=100)))
            calls = []
            def external(args, **kwargs):
                if args[0] == "/usr/bin/open":
                    calls.append("reopen")
                    return types.SimpleNamespace(returncode=0)
                return real_run(args, **kwargs)
            def installer_run(*args):
                # Only signing is real. Never register test bundles or touch TCC.
                if args[0] == "codesign":
                    real_run(args, check=True, capture_output=True)
                else:
                    self.assertTrue(args[0] == "tccutil" or args[0].endswith("lsregister"))
            def command(args, current_job, cwd=None, **kwargs):
                if args[0] == "/bin/zsh":
                    calls.append("built-products")
                elif args[-1] == "scripts/install.py":
                    self.assertEqual(calls, ["built-products", "validated", "handoff"])
                    installer.main()
                else:
                    real_run(args, check=True, capture_output=True)
                    calls.append("validated")
            with patch.object(worker, "verify_controller"), patch.object(worker, "download_archive", side_effect=lambda revision, archive, current_job: archive.touch()), patch.object(worker, "extract_archive", return_value=source), patch.object(worker, "run_command", side_effect=command), patch.object(worker, "await_handoff", side_effect=lambda *args: calls.append("handoff")), patch.object(worker.subprocess, "run", side_effect=external), patch.object(installer, "run", side_effect=installer_run):
                worker.update(job, home)
            self.assertEqual((installer.SUPPORT / "state.json").read_bytes(), state)
            self.assertEqual((job / "backup/state.json").read_bytes(), state)
            self.assertEqual((installer.SUPPORT / "control.json").read_text(), '{"paused": true}\n')
            for name in ["AeroGrid", "AeroGrid Backend"]:
                app = home / f"Applications/{name}.app"
                real_run(["codesign", "--verify", "--deep", str(app)], check=True, capture_output=True)
                self.assertEqual((installer.BACKUPS / f"{name}.app/old-build-marker").read_text(), "previous build")
                self.assertFalse((app / "old-build-marker").exists())
            self.assertEqual(json.loads((job / "status.json").read_text())["phase"], "complete")
            self.assertEqual(calls[-1], "reopen")

    def testBuildIdentityDoesNotUseAncestorRepositoryAndValidatesOverride(self):
        info = module("build-info")
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            with patch.dict(os.environ, {"AEROGRID_BUILD_REVISION": SHA}):
                self.assertEqual(info.build_info(folder)["revision"], SHA)
            with patch.dict(os.environ, {"AEROGRID_BUILD_REVISION": "main"}):
                with self.assertRaises(ValueError):
                    info.build_info(folder)
            with patch.dict(os.environ, {}, clear=True), patch.object(info.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=str(folder.parent))):
                self.assertIsNone(info.build_info(folder)["revision"])
                (folder / "source-version.json").write_text(json.dumps(dict(revision=SHA, dirty=False)))
                self.assertEqual(info.build_info(folder)["revision"], SHA)


if __name__ == "__main__":
    unittest.main()
