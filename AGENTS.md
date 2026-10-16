# AeroGrid development guidance

Read README.md, CONTRIBUTING.md, docs/architecture.md, and UPSTREAM.md before changing the implementation. Preserve existing configuration, user rules, and installation backups. Use the matching bundled backend CLI.

Validate controller changes with `swift test`, backend changes with `(cd vendor/AeroSpace && swift test)`, and installer changes with `python3 -m unittest discover -s Tests/InstallerTests -v`. Keep the recorded backend patch aligned with the pinned upstream. Distinguish simulated tests from physical acceptance.

Do not replace running app binaries, silently change global macOS gestures, bypass Accessibility approval, or overwrite user arrangements. Keep optional private-API failures bounded and visible. Never commit runtime state, diagnostics, credentials, or local configuration.
