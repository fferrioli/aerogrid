AeroGrid — personal test build, Apple Silicon / macOS 14+

1. Transfer this entire ZIP to the other Mac and extract it.
2. Quit AeroSpace and other window managers before starting AeroGrid.
3. Double-click Install AeroGrid.command. Python 3.9+ is required for the
   installer; compiling, Xcode and a separate AeroSpace installation are not.
4. Enable BOTH AeroGrid and AeroGrid Backend in System Settings > Privacy &
   Security > Accessibility. If absent, use + to add the apps from your user's
   Applications folder. Authorize with Touch ID/password, then click Recover.
5. In Trackpad > More Gestures, disable/remap conflicting native three/four
   finger gestures (fullscreen swipes, Mission Control, App Expose). If enabled,
   also disable three-finger dragging in Accessibility > Pointer Control.
   AeroGrid does not change these system settings automatically.

The installer includes the AeroSpace backend and matching command-line client.
It installs both apps in ~/Applications and creates settings for the current
user. It backs up an existing AeroSpace config; a clean Mac gets a minimal one
with no personal app rules or keyboard bindings. Existing AeroGrid settings on
the target Mac are retained. This archive contains NO window state, diagnostics,
display identities or personal configuration from the development Mac.

This is an ad-hoc signed, unnotarized test build. If macOS blocks a component,
attempt to open it, then review its entry under Privacy & Security > Open Anyway.
Do this separately for AeroGrid and AeroGrid Backend if necessary. Apple guide:
https://support.apple.com/en-us/102445

Using it:
- Click the AeroGrid menu-bar icon to organize your spaces.
- Drag an app tile to another tile, an empty space, or a +.
- Three fingers: navigate on the display under the pointer.
- Four fingers: navigate both displays.
- Hold contact to explore several spaces; lift to switch.
- Right-click the AeroGrid icon for settings, pause/resume, Recover, or Quit.
- For multiple monitors/native fullscreen, enable Desktop & Dock > Mission
  Control > Displays have separate Spaces (macOS may require logging out).

To check readiness in Terminal:
  ~/.local/bin/aerogrid --health
accessibilityGranted, backendReady and gestureInputReady should all be true.

To remove it: choose Salir de AeroGrid, then run Uninstall AeroGrid.command.
Your layouts, settings and backups are retained in:
  ~/Library/Application Support/AeroGrid
The original AeroSpace app is not replaced. A minimal config created on a clean
Mac is retained after uninstall; previously existing configs have only AeroGrid's
owned additions removed.

This test build includes the latest backend lifetime correction. Post-permission
stability and real gestures still require testing; a second physical Mac has not
been tested by the agent. Intel Macs require a separate build.
