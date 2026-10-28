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

The backend source is vendored directly, including AeroGrid modifications. A normal clone needs no submodule initialization. `scripts/aerospace-grid.patch` records changes against the pinned AeroSpace revision in [UPSTREAM.md](UPSTREAM.md).

Root tests exercise the core model, layout/navigation behavior, organization transactions, lifecycle policy, and gesture packet recognition. Backend tests cover the window engine and its extensions. Installer tests run against temporary homes with external system calls mocked; they need the release products from the build step.

Recorded gesture fixtures use aliased contact identifiers and contain no window content. Replay is useful regression evidence; it does not prove physical gesture behavior.

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
