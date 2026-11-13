import contextlib
import datetime
import importlib.util
import io
import os
import pathlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/setup-signing.py"
IDENTITY_NAME = "AeroGrid Local Code Signing"
KNOWN_PASSWORD = "one-use-test-password-do-not-print"
SHA1 = "A" * 40


def module():
    spec = importlib.util.spec_from_file_location("setup_signing", SCRIPT)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS security and LibreSSL")
class SetupSigningKeychainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aerogrid-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.keychain = self.root / "signing.keychain-db"
        # Every real security invocation names this disposable keychain explicitly.
        subprocess.run([
            "/usr/bin/security", "create-keychain", "-p", secrets.token_urlsafe(32),
            str(self.keychain),
        ], check=True, capture_output=True, text=True)
        self.addCleanup(self.delete_keychain)

    def delete_keychain(self):
        subprocess.run([
            "/usr/bin/security", "delete-keychain", str(self.keychain),
        ], check=True, capture_output=True, text=True)

    def invoke(self, *arguments):
        return subprocess.run([
            sys.executable, str(SCRIPT), "--keychain", str(self.keychain), *arguments,
        ], env={**os.environ, "TMPDIR": str(self.root)}, capture_output=True, text=True)

    def identities(self):
        result = subprocess.run([
            "/usr/bin/security", "find-identity", "-p", "codesigning", str(self.keychain),
        ], check=True, capture_output=True, text=True)
        return set(re.findall(
            r'^\s*\d+\) ([0-9A-Fa-f]{40}) "AeroGrid Local Code Signing"',
            result.stdout, re.MULTILINE,
        ))

    def assert_no_signing_files(self):
        self.assertEqual(list(self.root.rglob("*.pem")), [])
        self.assertEqual(list(self.root.rglob("*.p12")), [])

    def test_create_is_idempotent_and_status_reports_sha1(self):
        created = self.invoke()
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        identities = self.identities()
        self.assertEqual(len(identities), 1)
        self.assert_no_signing_files()

        # Validate the actual certificate, not just the requested OpenSSL flags.
        certificate = subprocess.run([
            "/usr/bin/security", "find-certificate", "-c", IDENTITY_NAME,
            "-p", str(self.keychain),
        ], check=True, capture_output=True, text=True)
        details = subprocess.run([
            "/usr/bin/openssl", "x509", "-noout", "-text",
        ], input=certificate.stdout, check=True, capture_output=True, text=True).stdout
        self.assertIn("Public-Key: (2048 bit)", details)
        self.assertRegex(details, r"Subject:.*CN\s*=\s*AeroGrid Local Code Signing")
        validity = re.search(r"Not Before:\s*(.+)\n\s*Not After\s*:\s*(.+)", details)
        self.assertIsNotNone(validity)
        start, end = [datetime.datetime.strptime(value.strip(), "%b %d %H:%M:%S %Y %Z") for value in validity.groups()]
        self.assertEqual(end - start, datetime.timedelta(days=3650))
        self.assertRegex(details, r"X509v3 Basic Constraints: critical\s+CA:FALSE")
        self.assertRegex(details, r"X509v3 Key Usage: critical\s+Digital Signature")
        self.assertRegex(details, r"X509v3 Extended Key Usage: critical\s+Code Signing")

        before = self.keychain.read_bytes()
        repeated = self.invoke()
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertEqual(self.identities(), identities)
        self.assertEqual(self.keychain.read_bytes(), before)
        status = self.invoke("--status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        self.assertIn(next(iter(identities)), status.stdout)
        self.assert_no_signing_files()

    def test_status_absent_and_remove_are_idempotent(self):
        absent = self.invoke("--status")
        self.assertEqual(absent.returncode, 1, absent.stdout + absent.stderr)
        self.assertIn("not found", absent.stdout.lower())
        created = self.invoke()
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        removed = self.invoke("--remove")
        self.assertEqual(removed.returncode, 0, removed.stdout + removed.stderr)
        self.assertEqual(self.identities(), set())
        self.assertEqual(self.invoke("--status").returncode, 1)
        repeated = self.invoke("--remove")
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assert_no_signing_files()

    def test_creation_keeps_secrets_private_and_cleans_temporary_files(self):
        signing = module()
        stdout, stderr = io.StringIO(), io.StringIO()
        actual_run = subprocess.run
        private_directories = set()
        imported_passwords = []

        def observe(command, **kwargs):
            if command[:2] == ["/usr/bin/openssl", "req"]:
                key = pathlib.Path(command[command.index("-keyout") + 1])
                private_directories.add(key.parent)
                self.assertEqual(stat.S_IMODE(key.parent.stat().st_mode), 0o700)
            if command[:2] == ["/usr/bin/security", "import"]:
                imported_passwords.append(command[command.index("-P") + 1])
            return actual_run(command, **kwargs)

        with patch.object(signing.secrets, "token_urlsafe", return_value=KNOWN_PASSWORD), \
                patch.object(signing.subprocess, "run", side_effect=observe), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = signing.main(["--keychain", str(self.keychain)])
        self.assertEqual(result, 0, stdout.getvalue() + stderr.getvalue())
        self.assertEqual(imported_passwords, [KNOWN_PASSWORD])
        self.assertNotIn(KNOWN_PASSWORD, stdout.getvalue() + stderr.getvalue())
        self.assertTrue(private_directories)
        self.assertTrue(all(not directory.exists() for directory in private_directories))
        self.assert_no_signing_files()


class SetupSigningIsolatedTests(unittest.TestCase):
    def test_identity_lookup_matches_exact_untrusted_name_and_deduplicates_rows(self):
        signing = module()
        output = (
            f'  1) {SHA1} "{IDENTITY_NAME}" (CSSMERR_TP_NOT_TRUSTED)\n'
            f'  2) {"B" * 40} "{IDENTITY_NAME} Other"\n'
            f'  1) {SHA1} "{IDENTITY_NAME}"\n'
        )
        with patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")) as run:
            self.assertEqual(signing.find_identity("/temporary/test.keychain-db"), SHA1)
        self.assertEqual(run.call_args.args[0], [
            "/usr/bin/security", "find-identity", "-p", "codesigning", "/temporary/test.keychain-db",
        ])

    def test_default_keychain_creation_verifies_certificate_requirement(self):
        signing = module()
        # All subprocess calls are mocked: the user's keychains are never queried.
        commands = []
        lookups = iter(["", f'  1) {SHA1} "{IDENTITY_NAME}" (CSSMERR_TP_NOT_TRUSTED)\n'])

        def run(command, **kwargs):
            commands.append(command)
            output = ""
            if command[1] == "default-keychain":
                output = '    "/temporary/login.keychain-db"\n'
            elif command[1] == "find-identity":
                output = next(lookups)
            elif command[:2] == ["/usr/bin/codesign", "-d"]:
                return subprocess.CompletedProcess(command, 0, "", f'designated => certificate leaf = H"{SHA1}"')
            return subprocess.CompletedProcess(command, 0, output, "")

        with patch.object(signing.subprocess, "run", side_effect=run), \
                patch.object(signing.shutil, "copy2"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(signing.main([]), 0)
        self.assertIn(["/usr/bin/security", "default-keychain", "-d", "user"], commands)
        signatures = [command for command in commands if command[0] == "/usr/bin/codesign" and "--sign" in command]
        self.assertEqual(len(signatures), 1)
        self.assertEqual(signatures[0][signatures[0].index("--sign") + 1], SHA1)
        self.assertTrue(any(command[:3] == ["/usr/bin/codesign", "-d", "-r-"] for command in commands))

    def test_failed_import_hides_password_and_cleans_private_directory(self):
        signing = module()
        directories = []
        stdout, stderr = io.StringIO(), io.StringIO()

        def run(command, **kwargs):
            if command[:2] == ["/usr/bin/security", "import"]:
                directories.append(pathlib.Path(command[2]).parent)
                raise subprocess.CalledProcessError(1, command, output=KNOWN_PASSWORD, stderr=KNOWN_PASSWORD)
            return subprocess.CompletedProcess(command, 0, "", "")

        with patch.object(signing.secrets, "token_urlsafe", return_value=KNOWN_PASSWORD), \
                patch.object(signing.subprocess, "run", side_effect=run), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertNotEqual(signing.main(["--keychain", "/temporary/test.keychain-db"]), 0)
        self.assertNotIn(KNOWN_PASSWORD, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn("/private/", stderr.getvalue())
        self.assertTrue(directories)
        self.assertTrue(all(not directory.exists() for directory in directories))

    def test_verification_copies_system_executable_without_protected_flags(self):
        # /usr/bin/true carries SIP's restricted flag; copying file flags fails for a normal user.
        signing = module()
        def fake_run(*command, input=None):
            if command[1] == "-d":
                return subprocess.CompletedProcess(command, 0, stdout="", stderr='designated => identifier "true" and certificate leaf = H"aa"')
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
        with patch.object(signing, "run", side_effect=fake_run):
            signing.verify_identity(SHA1)

    def test_verification_failure_keeps_identity_and_reports_remove(self):
        signing = module()
        for failure in ("sign", "missing-certificate-leaf"):
            with self.subTest(failure=failure):
                commands = []
                lookups = iter(["", f'  1) {SHA1} "{IDENTITY_NAME}"\n'])
                stderr = io.StringIO()

                def run(command, **kwargs):
                    commands.append(command)
                    output = ""
                    if command[1] == "default-keychain":
                        output = '"/temporary/login.keychain-db"'
                    elif command[1] == "find-identity":
                        output = next(lookups)
                    elif command[0] == "/usr/bin/codesign" and "--sign" in command and failure == "sign":
                        raise subprocess.CalledProcessError(1, command, stderr="no identity found")
                    return subprocess.CompletedProcess(command, 0, output, "")

                with patch.object(signing.subprocess, "run", side_effect=run), \
                        patch.object(signing.shutil, "copy2"), contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(stderr):
                    self.assertNotEqual(signing.main([]), 0)
                self.assertIn("--remove", stderr.getvalue())
                self.assertFalse(any(command[1] == "delete-identity" for command in commands))


if __name__ == "__main__":
    unittest.main()
