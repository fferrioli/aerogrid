#!/usr/bin/env python3
"""Run disposable-window checks while the ordinary controller is shut down."""
import argparse
import subprocess

from live_fixture_session import fixture_session, native_by_monitor, normal, recover
from live_smoke import verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dynamic", action="store_true", help="Exercise controller organization using the live backend")
    mode.add_argument("--recover", action="store_true", help="Restore the desktop and clear an interrupted fixture session")
    parser.add_argument("--normal-only", action="store_true", help="Skip the dynamic smoke's native fullscreen assertions")
    args = parser.parse_args()
    if args.normal_only and not args.dynamic:
        parser.error("--normal-only requires --dynamic")
    if args.recover:
        recover()
        return

    def choose_display(desktop):
        native = native_by_monitor(desktop)
        displays = desktop["displays"]
        if args.dynamic and (len(displays) != 2 or not any(d["builtin"] for d in displays)):
            raise RuntimeError("Connect the built-in and external displays for the dynamic smoke")
        candidates = [d for d in displays if normal(native[str(d["monitor"])])]
        if args.dynamic:
            candidates = [d for d in candidates if not d["builtin"]]
        if not candidates:
            raise RuntimeError("Visit a normal desktop on the fixture display first")
        return min(candidates, key=lambda d: d["builtin"])

    with fixture_session(choose_display) as session:
        if args.dynamic:
            options = ["--normal-only"] if args.normal_only else []
            verifier = session.start_verifier("--verify-dynamic-fixtures", *options)
            try:
                if verifier.wait(timeout=90):
                    raise RuntimeError("Dynamic verification failed. See live-dynamic.txt and verifier.log in the private run directory")
            except subprocess.TimeoutExpired as error:
                raise RuntimeError("Dynamic verification timed out") from error
            print("PASS: dynamic verification finished. See live-dynamic.txt in the private run directory")
        else:
            verify(session)


if __name__ == "__main__":
    main()
