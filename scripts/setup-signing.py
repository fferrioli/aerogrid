#!/usr/bin/env python3
"""Explicitly manage AeroGrid's optional, stable local signing identity."""

import argparse
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile


IDENTITY_NAME = "AeroGrid Local Code Signing"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"


def run(*command, input=None):
    try:
        return subprocess.run(
            list(command), input=input, check=True, capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        # Never expose subprocess diagnostics or argv: import includes a password.
        raise RuntimeError(f"{Path(command[0]).name} {command[1]} failed.") from None


def find_identity(keychain):
    output = run(SECURITY, "find-identity", "-p", "codesigning", keychain).stdout
    rows = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', output, re.MULTILINE)
    # Trusted identities can appear again under "Valid identities only".
    identities = {sha1.upper() for sha1, name in rows if name == IDENTITY_NAME}
    if len(identities) > 1:
        raise RuntimeError(f"Multiple {IDENTITY_NAME} identities found; resolve duplicates first.")
    return next(iter(identities), None)


def create_identity(keychain):
    with tempfile.TemporaryDirectory(prefix="aerogrid-signing-") as temporary:
        os.chmod(temporary, 0o700)
        directory = Path(temporary)
        key = str(directory / "key.pem")
        certificate = str(directory / "certificate.pem")
        archive = str(directory / "identity.p12")
        run(
            OPENSSL, "req", "-batch", "-newkey", "rsa:2048", "-nodes", "-x509", "-sha256",
            "-days", "3650", "-subj", f"/CN={IDENTITY_NAME}", "-keyout", key, "-out", certificate,
            "-addext", "basicConstraints=critical,CA:false",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
        )
        password = secrets.token_urlsafe(32)
        run(
            OPENSSL, "pkcs12", "-export", "-inkey", key, "-in", certificate,
            "-name", IDENTITY_NAME, "-out", archive, "-passout", "stdin", input=password + "\n",
        )
        run(SECURITY, "import", archive, "-k", keychain, "-P", password, "-T", CODESIGN)
    identity = find_identity(keychain)
    if identity is None:
        raise RuntimeError("Imported signing identity not found.")
    return identity


def verify_identity(identity):
    try:
        with tempfile.TemporaryDirectory(prefix="aerogrid-signing-check-") as temporary:
            executable = str(Path(temporary) / "true")
            shutil.copy2("/usr/bin/true", executable)
            run(CODESIGN, "--force", "--sign", identity, executable)
            result = run(CODESIGN, "-d", "-r-", executable)
            if "certificate leaf" not in result.stdout + result.stderr:
                raise RuntimeError("Certificate requirement missing.")
    except (OSError, RuntimeError):
        raise RuntimeError("Signing verification failed; identity retained. Use --remove to delete it.") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keychain", metavar="PATH", help="Use this keychain instead of the user default.")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--status", action="store_true", help="Report the identity and its SHA-1.")
    action.add_argument("--remove", action="store_true", help="Delete the local signing identity.")
    arguments = parser.parse_args(argv)
    try:
        keychain = arguments.keychain
        if keychain is None:
            keychain = run(SECURITY, "default-keychain", "-d", "user").stdout.strip().strip('"')
            if not keychain:
                raise RuntimeError("User default keychain not found.")
        identity = find_identity(keychain)
        if arguments.remove:
            if identity:
                run(SECURITY, "delete-identity", "-Z", identity, keychain)
                print(f"Removed {IDENTITY_NAME}.")
            else:
                print(f"{IDENTITY_NAME} not found.")
            return 0
        if identity:
            print(f"{IDENTITY_NAME} exists: {identity}")
            return 0
        if arguments.status:
            print(f"{IDENTITY_NAME} not found.")
            return 1
        identity = create_identity(keychain)
        if arguments.keychain is None:
            verify_identity(identity)
        print(f"Created {IDENTITY_NAME}: {identity}")
        return 0
    except RuntimeError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except OSError:
        print("Error: Signing setup could not access temporary files.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
