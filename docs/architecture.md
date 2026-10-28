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

For a stable desktop, committing a gesture captures only the departing and arriving layouts. A fresh window inventory validates membership and display ownership before switching; topology changes, backend restarts, fullscreen changes, and pending recovery use complete reconciliation. The coordinated-target preflight, post-switch visibility checks, and rollback remain active. Command completion uses process-exit notification rather than a polling sleep. Local navigation timings distinguish queue time from execution time.

Navigation uses space rectangles and remembered entry positions. It skips geometric holes, retains deliberately created empty destinations, and excludes a destination already visible on another display. Each display keeps an independent cursor. Coordinated moves stop at blocked edges rather than wrapping.

## Organization and recovery

Stable space identifiers are independent of display labels and backend workspace names. The map stores board-local geometry, footprints, display ownership, layouts, normal/fullscreen targets, adaptation families, and bounded Undo history. Titles are derived from current apps.

Automatic discoveries and generated fullscreen/split destinations use a nearby free edge of their source. Distant columns and dormant import slots do not push additions to the far side of the board. Combining boards preserves explicit adapted positions and places generated children relative to their adapted source. Existing coordinates and deliberate gaps are not globally compacted.

Organization changes are serialized and validate window ownership using process and boot identity. A pending transaction records rollback state so interrupted changes can recover before accepting new work. Undo checks for later incompatible edits and does not recreate closed windows.

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

Cancellation terminates only the worker's own build process group. Failed preparation keeps the current app running; a failed installation reopens the preserved app. Persistent status exposes errors/retry after relaunch, and a dead worker cannot leave the menu permanently busy. Local logs/backups remain private. Update preparation never changes macOS security policy; locally rebuilt ad-hoc signatures may require renewed Accessibility grants.

## Platform boundaries

Accessibility approval is required for both apps. Optional private macOS APIs are used for touch/native Space integration and can change between OS versions. Missing capabilities return bounded errors rather than silently disabling system protections. AeroGrid does not install a scripting addition or require changing SIP.
