import AppKit
import Combine
import GridCore
import SwiftUI

/// Real UI and polling against a fake desktop. Never starts input or the backend.
enum IdlePerformanceVerification {
    static func run(output: URL) throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let config = Configuration(backendPath: "/usr/bin/false")
        let display = Display(id: "idle-fixture", monitor: 1, name: "Fixture display", builtin: false, width: 3440, height: 1440)
        var desktop = Desktop(displays: [display], visible: [1:config.grids[1].cells[4].workspace], focusedMonitor: 1)
        desktop.nativeVisible = [:]
        desktop.windows = (0..<12).map { WindowInfo(id: UInt32($0 + 1), workspace: config.grids[1].cells[$0 % 9].workspace, appName: "Fixture app \($0)") }
        let model = try AppModel(preview: desktop, previewConfiguration: config)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AeroGrid · Idle verification"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center()
        defer { window.contentView = nil; window.close() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in model.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func cpuSeconds() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var reports: [[String: Any]] = []
        func measure(_ name: String, seconds: Double) {
            var publications = 0
            let observation = model.objectWillChange.sink { publications += 1 }
            let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
            spin(seconds)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            reports.append(["phase": name, "wallSeconds": elapsed, "cpuPercentOfOneCore": (cpuSeconds() - cpu) / elapsed * 100, "modelPublications": publications])
            observation.cancel()
        }
        window.orderFrontRegardless(); spin(1)
        measure("settings-visible", seconds: 5)
        window.orderOut(nil); spin(0.5)
        measure("settings-hidden", seconds: 5)
        window.contentView = nil; window.close(); spin(0.5)
        measure("no-ui", seconds: 5)
        let report: [String: Any] = ["phases": reports, "fakeBackend": true, "usesPhysicalGestures": false, "writesUserState": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
