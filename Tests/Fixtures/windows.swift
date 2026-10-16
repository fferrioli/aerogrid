import Cocoa

@main struct GridFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var windows: [NSWindow] = []
        for title in ["AeroGrid Verification A", "AeroGrid Verification B", "AeroGrid Verification C"] {
            let window = NSWindow(contentRect: NSRect(x: 150, y: 200, width: 600, height: 400), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = title
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentView = NSTextField(labelWithString: title + " — temporary verification window")
            window.makeKeyAndOrderFront(nil); windows.append(window)
        }
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(windows) { app.run() }
    }
}
