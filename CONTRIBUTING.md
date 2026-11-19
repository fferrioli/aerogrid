# Development

AeroGrid is experimental. For behavior changes, describe the user-visible problem, the intended result, and the validation performed. Keep changes to the bundled window engine narrow and retain upstream notices.

## Build and test

Use macOS with Swift 6.2+ and Python 3.9+:

```sh
zsh scripts/build.sh
swift test
(cd vendor/AeroSpace && swift test)
python3 -m unittest discover -s Tests/InstallerTests -v
python3 -m unittest discover -s Tests/RecoveryTests -v
python3 -m unittest discover -s Tests/UpdateTests -v
```

The backend source is vendored directly, including AeroGrid modifications. A normal clone needs no submodule initialization. `scripts/aerospace-grid.patch` records changes against the pinned AeroSpace revision in [UPSTREAM.md](UPSTREAM.md). After changing `vendor/AeroSpace/Sources`, regenerate it with `zsh scripts/regenerate-backend-patch.sh` (clones the pinned revision into a temporary directory; the output is byte-identical when nothing changed).

Root tests exercise the core model, layout/navigation behavior, organization transactions, lifecycle policy, and gesture packet recognition. Backend tests cover the window engine and its extensions. Installer tests run against temporary homes with external system calls mocked; they need the release products from the build step.

Recorded gesture fixtures use aliased contact identifiers and contain no window content. Replay is useful regression evidence; it does not prove physical gesture behavior.

## Run live fixtures

Use an installed controller and matching backend built from this checkout. Start AeroGrid, leave it active and unlocked on a normal macOS desktop, and finish any update first. Keep the desktop idle during the run. Use ordinary Accessibility approvals for the installed apps.

```sh
mkdir -p dist
swiftc -parse-as-library Tests/Fixtures/windows.swift -o dist/GridFixture
python3 scripts/live-diagnostics-smoke.py
python3 scripts/run-live-smoke.py
python3 scripts/run-live-smoke.py --dynamic
```

Run the checks one at a time. Diagnostics exercises the real controller's history and fullscreen navigation. The backend smoke checks live layout snapshots and native Spaces. `--dynamic` requires the built-in and external displays. It exercises the controller against the live backend and simulates display topology changes. `--normal-only` skips its native fullscreen checks. For physical disconnect, reconnect, and optional backend restart, run `python3 scripts/live-hardware.py [--restart-backend]` from a disposable macOS account with both displays attached and no managed windows.

The ordinary controller drains pending work and quits while the installed backend stays up. Each run gets fresh state, workspaces and diagnostics in a private directory under `~/Library/Caches/AeroGrid/LiveFixtures`. The startup interlock holds the ordinary controller out until fixture processes have stopped, their windows are gone, and the original visible workspaces, native Spaces and surviving focus are restored. Results are printed or saved under the private run directory. These runs collect temporary diagnostic history independently of the normal preference.

Ctrl-C and termination trigger the same cleanup. If a runner is force-killed, or native restoration fails, reconnect the original displays and run `python3 scripts/run-live-smoke.py --recover` before restarting AeroGrid. Keep the recorded native Spaces available for recovery. Raw reports stay local. Run directories can be removed after recovery completes.

To verify the installed diagnostics opt-out separately, disable **Record local window and Space diagnostics**, make an ordinary window change, and check that both history files remain byte-for-byte unchanged. Restart AeroGrid to confirm the toggle stays off. Turn it back on to check that the next observable state starts new checkpoints.

For frontend CPU changes, `AeroGrid --benchmark-idle REPORT.json` measures process CPU and model publications with visible settings, hidden settings, and no UI. It uses 12 fictional windows, a fake backend, and a deliberately frequent 0.5-second poll. Do not equate these short synthetic measurements with a long-running user's Activity Monitor reading. Unchanged polls must produce no UI publications; real focus/layout changes and corroborated release settlement must still propagate.

## Validate behavior on hardware

For gesture changes, check quick flicks, consecutive flicks, held exploration, reversals, two-finger scrolling, and release/momentum isolation. For layout changes, check moving an app to occupied/empty/new spaces, splitting, stacking, whole-space insertion, resizing, and Undo. For topology changes, check physical disconnect/reconnect and native fullscreen on each display.

Report simulated checks separately from real trackpad and display tests. Do not treat model tests or demo animations as physical acceptance.

For updater changes, cover API failures, archive traversal and symlinks, build failure/cancellation, shutdown handoff, dead-worker recovery, installed build metadata, and configuration preservation. Update tests sign real built products into a temporary home while suppressing LaunchServices registration and all TCC changes; they never replace the running installation. `AeroGrid --verify-status-menu REPORT.json` exercises a separate native status item and verifies all menu rows fit without hover. It starts no window-management service.

## Protect the live setup

- Do not overwrite running app bundles. Quit AeroGrid and its owned backend before installing.
- Back up configuration before changing it. Preserve existing app rules, user shortcuts, and the first installation backup.
- Do not change global macOS gestures automatically or bypass Accessibility approval.
- Signature-changing updates can require renewed Accessibility grants. Finish the build before asking someone to retest.
- Do not commit local configuration, saved state, diagnostics, signing identities, or build products. Review logs before sharing them.

## Package a build

```sh
python3 scripts/package.py
python3 scripts/package-source.py
```

The binary packager currently targets Apple Silicon and expects the release products to have been built. The source packager includes source, docs, dependency notices, and the demo, while excluding build caches and runtime data. Both write into ignored `dist/`.

For the project structure, see [architecture](docs/architecture.md). Third-party terms remain applicable; a project-wide license for original AeroGrid code has not yet been selected.
