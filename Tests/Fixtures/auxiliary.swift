import Cocoa

@main struct AuxiliaryFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 180, width: 480, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AeroGrid Auxiliary Verification"
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSTextField(labelWithString: "Temporary second application — floating-window verification")
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { app.run() }
    }
}
