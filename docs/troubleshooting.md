# Troubleshooting

## Check readiness

Open AeroGrid, then run:

```sh
"$HOME/.local/bin/aerogrid" --health
```

With management enabled, `accessibilityGranted`, `backendReady`, and `gestureInputReady` should be `true`. While paused, management and input intentionally stop. Right-click the menu bar icon to resume or use **Recover / Recuperar**.

## Accessibility remains denied

Enable both **AeroGrid** and **AeroGrid Backend** in System Settings → Privacy & Security → Accessibility. If missing, add the apps from `~/Applications` with **+**. Complete any macOS authentication request, then choose Recover.

A rebuilt app’s ad-hoc signature can differ from the previously approved build. After updating, macOS may require toggling the affected entry off and on. If System Settings shows stale state, quit and reopen it before retrying. Do not edit the permission database or disable system protections.

## Cannot connect to the window service

Choose Recover. AeroGrid starts its bundled backend automatically with bounded retries. Confirm both installed app bundles exist, both permissions are enabled, and the app is not paused. Do not start a separate AeroSpace instance alongside AeroGrid.

The bundled CLI matches the engine. Use `~/.local/bin/aerogrid-aerospace` for extension diagnostics rather than a separately installed `aerospace` client.

## Mission Control opens, or gestures conflict

Remap conflicting native gestures under System Settings → Trackpad → More Gestures. Check App Exposé and Accessibility’s three-finger dragging too. AeroGrid leaves these preferences under your control.

A quick gesture selects one neighbor. To explore farther, keep contact briefly after the first step and continue moving; resting still does not repeat. If using a modifier binding, hold the modifier before touching the trackpad and keep it held until lift.

Avoid enabling another gesture provider for the same bindings at the same time. A new two-finger scroll should remain usable; report accidental source scrolling separately from navigation failures.

## Fullscreen windows or external displays behave unexpectedly

Enable **Displays have separate Spaces** for independent native fullscreen navigation. A native fullscreen Space that has never been visited may need one visit before macOS exposes its window.

On disconnect, normal gestures reach the adapted spaces without a modifier. Reconnection automatically reunites unchanged groups. If you reorganized a group while disconnected, that choice is preserved; **Reunir grupo** explicitly restores its grouping.

## Update

Quit AeroGrid from its menu, update this checkout, rebuild, and install:

```sh
git pull --ff-only
zsh scripts/build.sh
python3 scripts/install.py
open "$HOME/Applications/AeroGrid.app"
```

Installer backups are retained across updates. Renew Accessibility for any rebuilt component if macOS requests it.

## Uninstall

Quit AeroGrid, then run from the source checkout:

```sh
python3 scripts/uninstall.py
```

The uninstaller removes owned apps and links, merges out owned configuration additions, and keeps state and backups. You can then reopen the original AeroSpace app if you used it previously.

## Share a useful report

Include the macOS version, CPU architecture, display setup, exact steps, and whether the issue affects quick or held gestures. Review diagnostics before attaching them: local state and logs can contain app/window information. Never upload your entire Application Support folder.
