import SwiftUI
import Combine
import GridCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var overview: NSWindow?
    private var overviewScreen: NSScreen?
    private var settings: NSWindow?
    private var status: NSStatusItem?
    private var accessTimer: Timer?
    private var hoverStarted: Date?
    private var hoverScreen: UInt32?
    private var lastOpened = Date.distantPast
    private var departedAt: Date?
    private var menuDepth = 0
    private var monitors: [Any] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var quitting = false
    private var statusObservation: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let model = try AppModel(); self.model = model
            model.showOverview = { [weak self] in self?.openOverview() }
            model.closeOverview = { [weak self] restore in self?.closeOverview(restoreFocus: restore) }
            model.resizeOverview = { [weak self] size in self?.resizeOverview(to:size) }
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status?.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "AeroGrid")
            status?.button?.imagePosition = .imageLeading
            statusObservation = model.$paused.sink { [weak self] paused in
                self?.status?.button?.title = ""
                self?.status?.button?.image = NSImage(systemSymbolName:paused ? "pause.circle" : "square.grid.3x3",accessibilityDescription:"AeroGrid")
                self?.status?.button?.toolTip = paused ? "AeroGrid · En pausa" : "AeroGrid · Tus espacios"
            }
            status?.button?.target = self
            status?.button?.action = #selector(statusClicked)
            status?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            accessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkTopAccess() }
            status?.menu = nil
            menuObservers.append(NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) { [weak self] _ in self?.menuDepth += 1; self?.model?.organizationMenuOpen = true })
            menuObservers.append(NotificationCenter.default.addObserver(forName:NSMenu.didEndTrackingNotification,object:nil,queue:.main) { [weak self] _ in self?.menuDepth = max(0,(self?.menuDepth ?? 1)-1); self?.model?.organizationMenuOpen = (self?.menuDepth ?? 0) > 0 })
            if let local = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown],handler: { [weak self] event in self?.checkOutsideClick(); return event }) { monitors.append(local) }
            if let global = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown],handler: { [weak self] _ in self?.checkOutsideClick() }) { monitors.append(global) }
            model.start()
            if !model.inputReady && !model.paused { openSettings() }
        } catch {
            let alert = NSAlert(); alert.messageText = "AeroGrid couldn't start"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || model?.paused == true {
            let menu = NSMenu(); menu.autoenablesItems = false
            for (title, selector) in [("Ajustes…", #selector(openSettings)), ("Recuperar", #selector(recover)), (model?.paused == true ? "Reanudar AeroGrid" : "Pausar AeroGrid", #selector(togglePause)), ("Salir de AeroGrid", #selector(quit))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
                if selector == #selector(togglePause) { item.isEnabled = model?.pauseChanging != true }
                menu.addItem(item)
            }
            if let button = status?.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
        } else if overview?.isVisible == true { closeOverview(restoreFocus: true) }
        else { openOverview() }
    }
    @objc func openOverview() {
        guard let model, !model.paused, !model.pauseChanging, overview?.isVisible != true else { return }
        lastOpened = Date()
        model.captureWindowForOverview { [weak self] in
            guard let self else { return }
            if self.overview == nil {
                let panel = OrganizerPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 490), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "AeroGrid · Tus espacios"; panel.level = .floating
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.onCancel = { [weak self] in self?.closeOverview(restoreFocus:true) }
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
                self.overview = panel
            }
            self.overview?.contentView = NSHostingView(rootView:OverviewView(model:model))
            model.editingOrganization = false
            self.overviewScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let displays = model.desktop?.displays ?? []
            let active = displays.first { $0.id == model.targetDisplay() } ?? displays.first
            self.resizeOverview(to:MapPresentation.panelSize(displays:active.map { [$0] } ?? [],model:model,editable:true))
            model.overviewVisible = true
            self.overview?.makeKeyAndOrderFront(nil)
        }
    }
    private func resizeOverview(to size:CGSize) {
        guard let overview, let screen = overviewScreen ?? NSScreen.main else { return }
        let width = min(max(300,size.width),screen.visibleFrame.width-32)
        let height = min(max(180,size.height),screen.visibleFrame.height-70)
        let frame = NSRect(x:screen.visibleFrame.midX-width/2,y:screen.visibleFrame.maxY-height-12,width:width,height:height)
        if overview.frame != frame { overview.setFrame(frame,display:true) }
    }
    func closeOverview(restoreFocus: Bool) {
        overview?.orderOut(nil); model?.overviewVisible = false; model?.endDrag(); model?.editingOrganization = false; departedAt = nil; lastOpened = Date()
        if restoreFocus { model?.restoreOverviewFocus() }
    }
    private func checkTopAccess() {
        if NSEvent.pressedMouseButtons == 0 && model?.organizingDrag == true { model?.endDrag() }
        if let overview, overview.isVisible {
            guard model?.organizingDrag != true, model?.editingOrganization != true, menuDepth == 0, NSEvent.pressedMouseButtons == 0 else { departedAt = nil; return }
            if overview.frame.insetBy(dx:-30,dy:-35).contains(NSEvent.mouseLocation) { departedAt = nil }
            else if let departedAt, Date().timeIntervalSince(departedAt) > 0.65 { closeOverview(restoreFocus:true) }
            else if departedAt == nil { departedAt = Date() }
            return
        }
        guard model?.paused != true, model?.pauseChanging != true, model?.gestureSelection == nil, overview?.isVisible != true, Date().timeIntervalSince(lastOpened) > 1.2,
              NSEvent.pressedMouseButtons == 0, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else {
            hoverStarted = nil; return
        }
        let point = NSEvent.mouseLocation
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let inZone = abs(point.x - screen.frame.midX) <= 80 && point.y >= screen.frame.maxY - max(5, screen.safeAreaInsets.top)
        guard inZone else { hoverStarted = nil; return }
        if hoverScreen != id { hoverStarted = nil; hoverScreen = id }
        if hoverStarted == nil { hoverStarted = Date() }
        if let start = hoverStarted, Date().timeIntervalSince(start) >= 0.55 { hoverStarted = nil; openOverview() }
    }
    private func checkOutsideClick() {
        guard let overview, overview.isVisible, model?.organizingDrag != true, model?.editingOrganization != true,
              menuDepth == 0, !overview.frame.contains(NSEvent.mouseLocation) else { return }
        // An outside click gives focus to the clicked app; don't override it.
        closeOverview(restoreFocus:false)
    }
    @objc func openSettings() {
        guard let model else { return }
        if settings == nil { settings = makeWindow(title: "AeroGrid Settings", view: SettingsView(model: model)) }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePause() { if let model { model.setPaused(!model.paused) } }
    @objc func recover() { model?.recover() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard let model else { return .terminateNow }
        quitting = true
        model.prepareToQuit { sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.center()
        return window
    }
    func applicationWillTerminate(_ notification: Notification) { accessTimer?.invalidate(); model?.stop() }
}

@main
struct AeroGridMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "local.AeroGrid").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if args.first == "--verify-dynamic-fixtures", args.count == 2 || (args.count == 3 && args[2] == "--normal-only") {
            do { try DynamicVerification.run(output: URL(fileURLWithPath: args[1]),nativeChecks:args.count == 2) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--replay-gestures", args.count == 3 {
            do { try GestureReplay.run(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2])) }
            catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            return
        }
        if args.first == "--verify-panel-lifecycle", args.count == 2 {
            do { try PanelVerification.run(output:URL(fileURLWithPath:args[1])) }
            catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            return
        }
        if args.first == "--preview-organizer" {
            do { try OrganizerSandbox.run() } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            return
        }
        if args.first == "--render-organizer" {
            guard args.count == 2 || (args.count == 3 && args[2] == "--merge") else { fputs("Usage: --render-organizer PATH [--merge]\n", stderr); exit(1) }
            do { try OrganizerPreview.render(to: URL(fileURLWithPath: args[1]), merge: args.count == 3) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--validate-spatial-state" {
            do {
                guard args.count == 2 else { throw GridError.invalid("Usage: --validate-spatial-state DIRECTORY") }
                let directory = URL(fileURLWithPath:args[1],isDirectory:true)
                let config = try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:directory.appendingPathComponent("config.json")))
                let saved = try JSONDecoder().decode(RuntimeState.self,from:Data(contentsOf:directory.appendingPathComponent("state.json")))
                let engine = try DynamicEngine(configuration:config,state:saved,backend:AeroSpaceBackend(path:config.backendPath))
                guard engine.map.version == 3 else { throw GridError.invalid("Recover the pending operation before validating migration") }
                let second = try DynamicEngine(configuration:config,state:engine.state,backend:AeroSpaceBackend(path:config.backendPath))
                guard engine.state == second.state else { throw GridError.invalid("Migration is not idempotent") }
                let report:[String:Any] = ["version":engine.map.version,"spaces":engine.map.spaces.count,
                    "idsPreserved":saved.dynamicMap?.spaces.map(\.id) == engine.map.spaces.map(\.id),
                    "workspacesPreserved":saved.dynamicMap?.spaces.map(\.workspace) == engine.map.spaces.map(\.workspace),
                    "idempotent":true,"writesUserState":false]
                print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            return
        }
        if args.first == "--validate-config" {
            do {
                guard args.count == 2 else { throw GridError.invalid("Usage: AeroGrid --validate-config FILE") }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                try JSONDecoder().decode(Configuration.self, from: data).validate()
                print("AeroGrid configuration is valid")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--action" {
            guard !otherInstances.isEmpty else { fputs("AeroGrid isn't running. Open ~/Applications/AeroGrid.app first.\n", stderr); exit(1) }
            DistributedNotificationCenter.default().postNotificationName(.init("local.AeroGrid.action"), object: nil, userInfo: ["arguments": Array(args.dropFirst())], deliverImmediately: true)
            return
        }
        if args.first == "--migrate-state" {
            do {
                guard otherInstances.isEmpty else { throw GridError.invalid("Quit AeroGrid before migrating its state") }
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AeroGrid")
                let store = try Store(directory: directory)
                guard let config = try store.load(Configuration.self, name: "config.json") else { throw GridError.invalid("Configuration not installed") }
                let saved = try store.load(RuntimeState.self, name: "state.json") ?? RuntimeState()
                let engine = try DynamicEngine(configuration: config, state: saved, backend: AeroSpaceBackend(path: config.backendPath), store: store)
                try engine.importVisibleLayouts()
                print("Dynamic map migrated; current visible layouts preserved")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--map" {
            do {
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AeroGrid")
                guard let state = try Store(directory: directory).load(RuntimeState.self, name: "state.json"), let map = state.dynamicMap else { throw GridError.unavailable("Dynamic map not yet migrated") }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(map), as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--status" {
            do {
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AeroGrid")
                guard let config = try Store(directory: dir).load(Configuration.self, name: "config.json") else { throw GridError.unavailable("Configuration not installed") }
                let backend = AeroSpaceBackend(path: config.backendPath)
                print(try backend.run(["grid-layout", "status"]))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.first == "--health" {
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AeroGrid/health.json")
            if let data = try? Data(contentsOf: path) { print(String(decoding: data, as: UTF8.self)) }
            else { fputs("AeroGrid hasn't published health yet.\n", stderr); exit(1) }
            return
        }
        if !otherInstances.isEmpty { return }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class OrganizerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
