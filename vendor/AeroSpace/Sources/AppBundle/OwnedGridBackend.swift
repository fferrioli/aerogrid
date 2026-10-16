import AppKit
import Common

/// An owned service must outlive its UI. A hidden MenuBarExtra is not a
/// lifetime anchor: SwiftUI may terminate the app when the extra is removed.
@MainActor public func runOwnedGridBackend() {
    let application = NSApplication.shared
    let delegate = OwnedGridBackendDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    ProcessInfo.processInfo.disableAutomaticTermination("AeroGrid window service")
    withExtendedLifetime(delegate) { application.run() }
}

@MainActor final class OwnedGridBackendDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        initAppBundle()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?.beforeTermination()
    }
}
