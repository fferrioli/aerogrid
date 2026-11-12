# Architecture

AeroGrid separates spatial organization from the window engine. The native menu app owns the map and gestures; its bundled AeroSpace fork applies window operations.

| Component | Responsibility |
|---|---|
| `Sources/AeroGrid` | AppKit/SwiftUI interface, multitouch input, floating organizer, backend supervision, action serialization |
| `Sources/GridCore` | Spatial model, rectangle navigation, layouts, topology adaptation, gesture recognition, persisted state |
| `vendor/AeroSpace` | Window discovery, tiling, native fullscreen integration, and versioned `grid-layout` commands |
| `scripts` | Per-user installation, configuration preservation, uninstall, packaging, and opt-in live smoke tools |
| `Tests` | Core regressions, aliased gesture fixtures, installer tests, and disposable live windows |
| `demo` | Standalone animated product demonstration; independent of the live window engine |

## Navigation and gestures

The input layer recognizes configured contact cohorts and freezes the display target at gesture start. A reported recontact remains provisional until a later contact frame confirms it alongside the fingers that stayed down. Repeated native landing snapshots cannot erase an earlier lift. A quick flick chooses one neighbor. Continued deliberate movement after the hold threshold explores additional candidates. Selection is previewed during contact; only the final target is committed at release.

Release-settlement checks run only while an explicitly lifted cohort needs corroboration; idle and held contacts have no repeating release timer. Full packet construction/logging is opt-in for troubleshooting. Recognition still receives all contact frames, and release timing/thresholds are unchanged.

For a stable desktop, committing a gesture captures only the departing and arriving layouts. A fresh window inventory validates membership and display ownership before switching; topology changes, backend restarts, fullscreen changes, and pending recovery use complete reconciliation. The coordinated-target preflight, post-switch visibility checks, and rollback remain active. Command completion uses process-exit notification rather than a polling sleep. Local navigation timings distinguish queue time from execution time.

Navigation uses space rectangles and remembered entry positions. It skips geometric holes, retains deliberately created empty destinations, and excludes a destination already visible on another display. Each display keeps an independent cursor. Coordinated moves stop at blocked edges rather than wrapping.

## Organization and recovery

Stable space identifiers are independent of display labels and backend workspace names. The map stores board-local geometry, footprints, display ownership, layouts, normal/fullscreen targets, adaptation families, and bounded Undo history. Titles are derived from current apps.

Native fullscreen remembers the original layout without freezing its membership: snapshots reconcile closed/moved windows and newly opened groups against the live backend tree. Fullscreen exit preserves new nested groups as well as the original slots. The organizer also checks layout coverage against the live inventory, exposing any missing windows while snapshots settle; this display fallback never writes inferred geometry back to the backend.

Fullscreen app cards can move to empty destinations or creation slots on the same physical display. These moves exchange the fullscreen destination's map rectangle with an empty rectangle, preserving the native Space and all other app positions. Occupied destinations, split/stack drops, and moves to another physical display are rejected. One organization Undo restores the map; fullscreen exit retains the chosen position through the existing edited-fullscreen reconciliation.

Some apps omit background fullscreen windows from Accessibility after a backend restart. A pending window home remains discoverable when WindowServer confirms its owner and the native Spaces API confirms its physical display. The backend validates boot/PID/workspace/display before opening that exact native Space, then requests AX discovery. It neither activates background apps during inventory polling nor invents destinations from an unverified saved ID.

Not observing a fullscreen window is not taken as its closure. Three independent defenses cover a locked or dark session:

- **Reconciliation gate.** While the session is locked or the displays sleep, the frontend keeps the backend and input alive but neither reconciles nor persists the map; any gesture, drag, or organizer is cancelled. Lock state comes from the session dictionary on each tick, with lock, screen-sleep and session notifications triggering an early tick. After release the gate waits 3 s, then runs one recovery.
- **Backend retention.** When Accessibility stops exposing a live fullscreen window without an explicit close, the owned backend keeps its home pending, so `status` still reports it and rediscovery rebinds it to its original workspace. A pending home is pruned when its process exits, the boot changes, or WindowServer stops listing the window for that PID for 10 s of unlocked time. While the session is locked, AX liveness is not used to collect windows, and a "not fullscreen" AX reading does not exit a window that WindowServer still places on a fullscreen Space.
- **Confirmation and place memory.** The engine treats each poll as one sample. Removing a fullscreen card for absence needs 3 consecutive samples with the process alive; a fullscreen exit needs 2 windowed samples; a dead process or a new boot still removes immediately. An empty inventory right after a populated one is a blackout: for up to 5 samples nothing is removed, though absence keeps counting so cards of windows that really closed go right after; a dead owner process ends the blackout at once. If a confirmed removal discards an exclusive destination, its place is remembered (outside Undo) and restored when the same window identity returns, at the nearest vacancy if it was taken.

Automatic map changes and gate transitions are written to `diagnostics.log` as `map:` and `gate:` lines with numeric IDs, identifier prefixes and reasons only.

Automatic discoveries and generated fullscreen/split destinations use a nearby free edge of their source. Distant columns and dormant import slots do not push additions to the far side of the board. Combining boards preserves explicit adapted positions and places generated children relative to their adapted source. Existing coordinates and deliberate gaps are not globally compacted.

Organization changes are serialized and validate window ownership using process and boot identity. A pending transaction records rollback state so interrupted changes can recover before accepting new work. Undo checks for later incompatible edits and does not recreate closed windows.

Background refresh publishes desktop, map, hints and readiness only when their values change. Semantically identical layout snapshots keep their existing bytes, avoiding invalidations caused solely by JSON key order. Closed settings/organizer windows release their hosting views; settings construct only the active section rather than retaining all tabs in a native toolbar-backed TabView.

On disconnect, parallel layout groups become neighboring destinations; stacked subtrees remain intact. Family records preserve the original nested arrangement and proportions. Reconnection can recompose unchanged families without overwriting arrangements the user edited.

## Bundled engine

The backend has a distinct app identity (`local.AeroGrid.Backend`) and socket namespace. AeroGrid uses its matching CLI, starts only that owned backend, and supervises it with bounded retries. The service runs independently of SwiftUI window lifetime and has no separate menu bar item or login registration.

Pause/resume acknowledges the engine’s actual management state. Quit stops the owned service. An independently installed AeroSpace remains available but should not manage windows at the same time.

The fork adds versioned inventory, layout snapshot/restore, exact fullscreen targeting, and validated movement. Original AeroSpace entry points retain their upstream behavior. Pins and extension details are in [UPSTREAM.md](../UPSTREAM.md).

For the owned AeroGrid service, closing a focused normal window preserves its workspace through macOS's automatic fallback activation. A proposed cross-space focus change checks the original window's AX liveness; normal same-space polling adds no query. A subsequent input event, explicit workspace selection, or a returning window releases the hold. Event counters contain no keyboard contents. A delayed background-window closure cannot undo a recent deliberate navigation. Native fullscreen exits and independently running AeroSpace retain their normal behavior.

## Local storage

Installed app bundles live in `~/Applications`. User configuration, map state, backups, and diagnostics live in `~/Library/Application Support/AeroGrid`. Optional CLI links live in `~/.local/bin`.

The installer preserves existing AeroSpace configuration and rules; a clean installation gets a minimal configuration. Uninstall removes owned additions while retaining backups and user state. Raw state and diagnostics can identify local windows or apps and should be reviewed before sharing.

## Updates

The installed frontend carries a source revision, build metadata, Python interpreter path, and an update worker. Automatic checks use GitHub's public [commit and comparison API](https://docs.github.com/en/rest/commits/commits) for `fferrioli/aerogrid/main`; only an ahead revision is offered. No local configuration, window inventory, or logs are sent. Checks may be disabled independently of manual installation.

An explicit update action starts the worker in a private support subdirectory. It downloads the selected full commit archive over HTTPS, validates paths, bounds expansion, and checks all resolved symlinks remain in the source tree. Compilation uses that isolated source and the local toolchain, preserving existing checkouts. The worker validates the new build against current configuration before requesting shutdown. The frontend writes a handoff marker and follows normal serialized shutdown; both installed components must exit before the existing transactional installer can replace them. The installer revalidates current configuration, backs up bundles/configuration, and rolls back failed commits. The worker also preserves exact state/control/configuration bytes before installation.

The updater schedules quit on the AppKit run loop after its MainActor polling callback returns. Calling quit directly inside that callback deadlocks AppKit's deferred-termination loop against the main-queue shutdown reply. A native subprocess regression exercises this real termination path with a sandbox model, without starting the live backend. The worker and installer match executable paths at the start of the process command, so helper arguments cannot falsely block an update. Process-inspection failures prevent replacement.

Cancellation terminates only the worker's own build process group. Failed preparation keeps the current app running; a failed installation reopens the preserved app. Persistent status exposes errors/retry after relaunch, and a dead worker cannot leave the menu permanently busy. Local logs/backups remain private. Update preparation never changes macOS security policy; locally rebuilt ad-hoc signatures may require renewed Accessibility grants.

## Platform boundaries

Accessibility approval is required for both apps. Optional private macOS APIs are used for touch/native Space integration and can change between OS versions. Missing capabilities return bounded errors rather than silently disabling system protections. AeroGrid does not install a scripting addition or require changing SIP.
