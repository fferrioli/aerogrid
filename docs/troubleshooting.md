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

## High CPU while idle

Update AeroGrid from its menu. The frontend avoids redundant UI publications, releases closed settings/organizer views, and runs gesture-release checks only while needed. Detailed packet logging is off by default and has its own files. Enable **Record detailed gesture packets** under **Settings → Import & diagnostics** while reproducing a gesture issue. It turns off on restart.

If CPU remains high after updating, distinguish **AeroGrid** from **AeroGrid Backend** in Activity Monitor, note whether the organizer/settings are visible, and capture a short **Sample Process** report. Samples can contain local paths; review them before sharing. An isolated UI benchmark is available as `AeroGrid --benchmark-idle REPORT.json`; it uses fake windows/backend and does not measure your physical desktop or start gesture input.

## Fullscreen windows or external displays behave unexpectedly

Enable **Displays have separate Spaces** for independent native fullscreen navigation. A native fullscreen Space that has never been visited may need one visit before macOS exposes its window.

On disconnect, normal gestures reach the adapted spaces without a modifier. Reconnection automatically reunites unchanged groups. If you reorganized a group while disconnected, that choice is preserved; **Reunir grupo** explicitly restores its grouping.

### Fullscreen apps after locking or sleeping the display

While the Mac is locked or the display is off, the map deliberately stays still: the status reads «En reposo · pantalla bloqueada» or «En reposo · pantalla apagada», and `--health` reports `reconciliationGate` as `locked`, `screens-asleep` or `settling` instead of `open`. A few seconds after unlocking, AeroGrid recovers once and resumes.

A fullscreen card that briefly cannot be observed stays in place. AeroGrid requires several consecutive observations before removing it, and a returning window can reclaim its previous position. In the local history, look for `gate` records and `reconciliation` events such as `fullscreen-doubt` with reason `disagree`, `fullscreen-removed` with reason `closed`, and `fullscreen-restored`.

To check the protection without locking the Mac, the owned backend can hide one window from its Accessibility discovery for a bounded time. Take a fullscreen window `id` from `"$HOME/.local/bin/aerogrid-aerospace" grid-layout status`, then:

```sh
"$HOME/.local/bin/aerogrid-aerospace" grid-layout --data '{"windowID":ID,"seconds":30,"forget":false}' debug-blind
```

The card should not move, and no other fullscreen card should change. With `"forget":true` the backend also drops its own retained record, reproducing the original failure: the log shows `fullscreen-doubt`, then `fullscreen-removed reason=closed`, and `fullscreen-restored` at the same place once the window is observable again: at expiry if its Space is the current one, otherwise when its Space is visited (Accessibility does not list a fullscreen window on another Space). If the backend registers the returning window in another workspace, `fullscreen-return` precedes the restore; no other card should change. Blindness lives only in memory, lasts 1–600 seconds, and `"seconds":0` cancels it. Unlike a real blackout, an expired blindness rediscovers the window by itself; a real background fullscreen window is rediscovered when its Space is visited.

If every action fails with «La identidad de un bloque está ocupada por otro espacio» (versions before this fix), close the window that was just opened in the affected app. Current versions record `fold-skipped` with reason `identity-taken` and leave that card unfolded.

If a card that was in fullscreen turned into an ordinary space while its window stayed in fullscreen (a version before this protection could do that), exit and re-enter fullscreen in that window once, then place its card again.

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

## Local window and Space history

AeroGrid records recent local history by default. In **Settings → Import & diagnostics**, turn off **Record local window and Space diagnostics** to stop history and detailed packet recording immediately. The setting persists across app restarts. Existing files stay on disk and can be deleted after quitting AeroGrid. Turning history back on starts new checkpoints as observations become available. If needed, **Open local files** opens the support folder. The separate `--health` command still reports the last readiness state, pause and reconciliation gate, and the time that status changed.

The history lives in `~/Library/Application Support/AeroGrid/diagnostics/history.jsonl` and `history.jsonl.previous`, with up to 8 MiB per file and owner-only access. The optional `gesture-packets.jsonl` and its `.previous` have a separate 16 MiB per-file budget. Older `diagnostics.log` and packet files in the parent directory may remain from earlier builds. AeroGrid sends no diagnostic data anywhere.

- `map` records the controller's desired cells, board and display assignments, grid-unit rectangles, fullscreen targets, cursors, and anchors. A reserved cell can exist without a corresponding observed workspace. A gesture action records the intended destination anchors separately from backend observations.
- `backend` records the backend's workspace membership, visible workspace, logical focus, WindowServer frames and reported native Space memberships. Join cell `workspace` and `fullscreenWindow` aliases to workspace and window rows. A workspace's `reportedEmpty` status means the backend reported no tracked windows or pending homes in that scope at that sample. `normalOccupancy` considers the backend's normal windows. A native Space with `unattributed` occupancy appeared in the macOS catalog without a matching tracked window. Its owner and physical occupancy are unknown, including on a fullscreen Space. Older or temporarily unavailable observations can omit frames, Space membership, or monitor attribution.
- `action`, `command`, `reconciliation`, `gate`, and `health` describe the operation, controlled outcome, and observed transitions. Match operation IDs to see intermediate backend observations, including an unavailable sample or a visibility mismatch before rollback. An inventory blackout event can explain why the map keeps a card after a transient empty backend report.

Each JSON line has a schema version, UTC timestamp, session ID, and sequence. For a `map` or `backend` stream, begin with a checkpoint, then apply deltas using `base` to match the previous sequence of that stream. A delta replaces the listed rows and deletes keys in `removed`. Unchanged polls produce no delta. The next observation after rotation or two minutes starts a new checkpoint.

Window and display geometry is desktop metadata. Frames use Quartz's global display coordinates in points, with the main display's top-left as origin and positive y going down. Off-screen or parked frames can have negative or unexpected positions. Frame position alone does not establish native Space membership. Apps, windows, workspaces, displays, cells, and native Space IDs use aliases consistent within one frontend run, including across a backend restart. AeroGrid refreshes the aliases when the frontend restarts. Window titles, app names, contents, raw command arguments, and raw identifiers are excluded from this history.

## Share a useful report

Include the macOS version, CPU architecture, display setup, exact steps, and whether the issue affects quick or held gestures. Review the relevant history excerpt before sharing it. Saved arrangements and older logs can contain app and window information. Attach only the files or lines relevant to the issue.
