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

## Adapted spaces overlap / «Los espacios adaptados se superponen»

See the [Spanish recovery guide](recovery.es.md). A standalone Python tool can back up and repair the adapted map on an older installation, keep the window service running, and refresh saved observations from the live backend without rebuilding or changing permissions. The corrected app repairs conflicting adapted positions on load and refresh, and releases stale adapted positions when dormant spaces reappear.

## Automatic spaces leave large gaps

Update both AeroGrid and its bundled backend. New discoveries and generated fullscreen/split destinations now use a nearby free edge rather than the board's farthest column or an unused legacy slot. Existing arrangements stay in place: drag a space by its header to close an older gap or insert it beside another space. Navigation skips unassigned holes.

## Closing a window changes the workspace where an app reopens

The updated owned backend keeps the active workspace through automatic macOS focus fallback after closing a normal window. It can remain empty while the app restarts. A deliberate click, key press, or AeroGrid navigation releases that protection; a window reopening before you navigate uses the current workspace. This does not impose a permanent app-to-workspace rule, and native fullscreen exits still follow macOS's Space transition. Report an unexpected switch with the steps and whether you interacted between closure and relaunch; no work-window titles are needed.

## Update

Use **Actualizar AeroGrid…** from the menu bar icon's right-click menu. An **↑** indicates an update. You can check manually with **Buscar actualizaciones…** and view preparation progress or cancel from that same menu. See the [Spanish updater guide](updates.es.md) for failures and permissions.

For an older installation that does not yet have this menu, quit AeroGrid from its menu, update this checkout, rebuild, and install once:

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
