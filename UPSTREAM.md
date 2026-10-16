# Pinned upstreams

- AeroSpace: `74a1bf17e82d70e0a21945ba04bb4f590bf19f83`, https://github.com/nikitabobko/AeroSpace. Its original license and third-party notices remain under `vendor/AeroSpace/legal`.
- SwipeAeroSpace: `5d7099af89691deb61bdccd8e9607235aaa0b274`, https://github.com/MediosZ/SwipeAeroSpace. MIT, Copyright (c) 2025 Tricster. Event-tap/NSTouch input adapted in `GestureInput.swift`; full notice in `vendor/SwipeAeroSpace/LICENSE`.

- TOMLKit 0.13.3: `8c963db32784623f8fc076ad4ef9b6b01ab0d542`, https://github.com/python-poetry/tomlkit. Pure Python source is vendored under `vendor/python/tomlkit` for preserving config formatting during install/uninstall; MIT notice in `vendor/python/LICENSE-tomlkit`.

The layout fork adds one versioned `grid-layout` command and preserves normal layouts through native fullscreen. A Swift 6.2 compatibility adjustment moves an upstream asynchronous defer into the explicit post-callback path. The release build runs on the locally installed Swift 6.2.3 toolchain.

Native Space discovery uses optional SkyLight read APIs (also documented in Hammerspoon's `hs.spaces` implementation). Native switches post Dock swipe events using the event-field technique documented by InstantSpaceSwitcher and yabai. Missing symbols and unaccepted switches return errors; no scripting addition or SIP change is required.

The helper's existing socket/UI dependencies were not copied into the controller. AeroGrid uses a dependency-free Swift package for its own menu app, core model, and tests; the AeroSpace fork retains its pinned package dependencies.

The fork uses the distinct `local.AeroGrid.Backend` bundle identity and socket namespace. It requests normal macOS Accessibility approval at startup and does not reset TCC permission entries.

Additional fork fixes preserve unrelated monitors when placing an invisible workspace, retain a native fullscreen activation target through Dock transitions, and expose PID/boot-validated window-home recovery for backend restarts. Window homes awaiting AX discovery are retained until their windows become visible; readiness is withheld until initial backend discovery finishes.

The dynamic-map upgrade extends `grid-layout` to version 2: window inventory with native visibility, `check-target`/`activate-target` selecting normal content or an exact fullscreen window, and `move-window` validating PID/boot before mutation. The backend ignores the `local.AeroGrid` auxiliary control app. Legacy operations remain available for existing diagnostics and snapshot regression tests.

Explicitly restored roots preserve container structure/orientations and scale child weights proportionally. This prevents upstream normalization from rotating/flattening merged groups or changing internal ratios when their allocated size changes. Empty containers are still removed. Roots that have not been restored retain upstream normalization/resizing behavior.

For the owned AeroGrid backend bundle only, the menu-bar extra and independent login registration are suppressed. A read-only `grid-layout management-status` reports readiness/enablement without a layout session, including when disabled. AeroGrid delegates actual pause/resume to the existing enable command. Standalone AeroSpace bundle presentation is preserved.

The owned backend entry point uses an AppKit service run loop, independent of SwiftUI scene lifetime. Removing its menu-bar extra allowed the previous owned app to terminate normally after launch. Original AeroSpace identities continue through the upstream SwiftUI entry point. The owned delegate retains termination cleanup and does not terminate when the last window closes.
