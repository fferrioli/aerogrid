import AppKit
import SwiftUI
import ServiceManagement
import GridCore

final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var desktop: Desktop?
    @Published var state = RuntimeState()
    @Published var message = "Iniciando AeroGrid…"
    @Published var organizationError: String?
    @Published var gestureMessage = "Swipe to inspect recognition"
    @Published private(set) var paused = false { didSet { if paused { input.reset() } } }
    @Published private(set) var pauseChanging = false
    private var managementNeedsSync = true
    private var backendLaunchPolicy = BackendLaunchPolicy()
    private var shuttingDown = false
    @Published var testingGestures = false { didSet { if testingGestures { input.reset() } } }
    @Published var inputReady = false
    @Published var backendReady = false
    @Published var moveMode = false
    @Published var overviewVisible = false
    let directory: URL
    private let store: Store
    private var engine: DynamicEngine
    private let backend: AeroSpaceBackend
    private let management: WindowManagerControl
    private var isPreview = false
    private let input: GestureInput
    private let queue = DispatchQueue(label: "AeroGrid.engine", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var pendingOperations: [(feedback: Bool, control: Bool, completion: ((Error?) -> Void)?, work: (DynamicEngine) throws -> Void)] = []
    private var notifications: [NSObjectProtocol] = []
    private var hud: NSPanel?
    private var navigationPanels: [NSPanel] = []
    private var hudGeneration = 0
    private var hudScheduled = false
    var resizeOverview: ((CGSize) -> Void)?
    @Published var navigationHints: [String: NavigationHint] = [:]
    private var overviewWindowID: UInt32?
    private var topologySettlesAt = Date.distantPast
    var showOverview: (() -> Void)?
    var closeOverview: ((Bool) -> Void)?
    @Published var organizingDrag = false
    @Published var editingOrganization = false
    var organizationMenuOpen = false
    @Published var gestureSelection: NavigationSelection?
    private var gestureScope: Scope?
    private lazy var diagnostics = BufferedLog(url:directory.appendingPathComponent("diagnostics.log"))
    private lazy var gesturePackets = BufferedLog(url:directory.appendingPathComponent("gesture-packets.jsonl"),limit:16_000_000)
    private var committingGesture = false
    private var deferredContacts: [ContactGestureEvent] = []
    @Published var organizationWindowToMove: WindowIdentity?
    @Published var draggedWindow: WindowIdentity?
    @Published var draggedSpace: String?
    @Published var mergePreview: MergePreview?
    @Published var reunitePreview: ReunitePreview?
    init() throws {
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AeroGrid")
        store = try Store(directory: directory)
        let defaultBackend = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AeroGrid Backend.app/Contents/Resources/aerospace").path
        let config = try store.load(Configuration.self, name: "config.json") ?? Configuration(backendPath: defaultBackend)
        try config.validate()
        let saved = try store.load(RuntimeState.self, name: "state.json") ?? RuntimeState()
        configuration = config
        backend = AeroSpaceBackend(path: config.backendPath); management = backend
        paused = try store.load(WindowManagerPreferences.self,name:"control.json")?.paused ?? false
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend, store: store)
        input = GestureInput(configuration: config)
        try store.save(config, name: "config.json")
        input.target = { [weak self] in self?.targetDisplay() }
        input.shouldSuppressScroll = { [weak self] in
            guard let self else { return false }
            return !self.paused && !self.pauseChanging && !self.testingGestures && self.backendReady && !self.organizingDrag && !self.editingOrganization && !self.organizationMenuOpen
        }
        input.onDiagnostic = { [weak self] in self?.gestureMessage = $0 }
        input.onTrace = { [weak self] in self?.log($0) }
        input.onPacket = { [weak self] in self?.gesturePackets.json($0) }
        input.onSwipe = { [weak self] swipe in self?.handle(swipe) }
        input.onContact = { [weak self] event in self?.handleContact(event) }
    }
    init(preview: Desktop, previewConfiguration: Configuration? = nil, previewMap: SpaceMap? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aerogrid-preview-\(UUID().uuidString)")
        store = try Store(directory:directory)
        let config = previewConfiguration ?? Configuration(backendPath:"/usr/bin/false")
        configuration = config; backend = AeroSpaceBackend(path:config.backendPath)
        management = OrganizerSandboxManagement(); isPreview = true
        var map = previewMap ?? SpaceMap(configuration:config)
        try map.migrateSpatial(configuration:config,desktop:preview)
        var layouts:[String:LayoutSnapshot] = [:]
        for space in map.spaces {
            let members = (preview.windows ?? []).filter { $0.workspace == space.workspace && !$0.nativeFullscreen }
            if let first = members.first {
                let snapshot = LayoutSnapshot(boot:first.boot,tree:.root(members.map { LayoutNode(id:$0.id,pid:$0.pid) }))
                layouts[space.workspace] = snapshot; map.layouts[space.id] = try snapshot.json()
            }
        }
        var initial = RuntimeState(); initial.dynamicMap = map; initial.lastDesktop = preview
        engine = try DynamicEngine(configuration:config,state:initial,backend:OrganizerSandboxBackend(preview,layouts:layouts))
        input = GestureInput(configuration:config)
        state = engine.state; desktop = preview; backendReady = true; message = "Sandbox · no modifica el escritorio"
    }
    func start() {
        launchBackend()
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        inputReady = !paused && input.start()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume(); self.timer = timer
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.input.reset()
            self?.endDrag()
            self?.closeOverview?(true)
            self?.topologySettlesAt = Date().addingTimeInterval(0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
        })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.recover() })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.input.reset() })
        notifications.append(DistributedNotificationCenter.default().addObserver(forName: .init("local.AeroGrid.action"), object: nil, queue: .main) { [weak self] notification in
            guard let args = notification.userInfo?["arguments"] as? [String] else { return }
            self?.externalAction(args)
        })
    }
    func stop() { timer?.cancel(); input.stop(); deferredContacts.removeAll(); pendingOperations.removeAll(); diagnostics.flush(); gesturePackets.flush() }
    func targetDisplay() -> String? {
        if configuration.targeting == .focused { return desktop?.displays.first { $0.monitor == desktop?.focusedMonitor }?.id }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    func grid(for display: Display) -> GridCore.Grid? {
        guard let desktop else { return nil }
        if let g = configuration.grids.first(where: { $0.cells.contains { $0.workspace == desktop.visible[display.monitor] } }) { return g }
        return configuration.grids.first { $0.id == state.activeGrids[display.id] } ?? configuration.grids.first { $0.displayRole == (display.builtin ? "builtin" : "external") }
    }
    private func perform(feedback: Bool = true, coalesce: Bool = false, control: Bool = false, completion: ((Error?) -> Void)? = nil, _ work: @escaping (DynamicEngine) throws -> Void) {
        guard control || (!paused && !pauseChanging) else {
            completion?(GridError.unavailable("AeroGrid está en pausa")); return
        }
        if busy {
            // Polling can be skipped; user actions must survive a refresh already in progress.
            guard !coalesce else { return }
            guard control || pendingOperations.count < 8 else {
                message = "Too many queued actions; wait for switching to finish"
                log(message); writeHealth(); completion?(GridError.unavailable(message))
                return
            }
            pendingOperations.append((feedback, control, completion, work))
            return
        }
        busy = true
        queue.async {
            var error: Error?
            do { try work(self.engine) } catch let failure { error = failure }
            let observed = self.engine.observed, state = self.engine.state
            let hints = self.engine.navigationHints()
            DispatchQueue.main.async {
                self.busy = false; self.state = state; self.desktop = observed; self.navigationHints = hints
                if let selection = self.gestureSelection, let map = state.dynamicMap, let observed,
                   (try? selection.validate(map:map,configuration:self.configuration,desktop:observed)) == nil { self.handleContact(.cancelled) }
                if let error {
                    self.message = error.localizedDescription; self.organizationError = self.message
                    if feedback && !self.overviewVisible { self.showHUD(self.message) }
                    self.log(self.message)
                } else {
                    self.backendReady = true; if feedback { self.organizationError = nil }
                    self.message = self.paused ? "AeroGrid en pausa" : "Activo · \(observed?.displays.count ?? 0) pantalla(s)"
                }
                self.writeHealth()
                completion?(error)
                while !self.pendingOperations.isEmpty {
                    let next = self.pendingOperations.removeFirst()
                    if (self.paused || self.pauseChanging) && !next.control {
                        next.completion?(GridError.unavailable("AeroGrid está en pausa")); continue
                    }
                    self.perform(feedback:next.feedback,control:next.control,completion:next.completion,next.work)
                    break
                }
            }
        }
    }
    func refresh() {
        guard !shuttingDown, !pauseChanging, Date() >= topologySettlesAt else { return }
        launchBackend()
        if paused {
            if input.running { input.stop() }
            inputReady = false
        } else if !AXIsProcessTrusted() {
            input.stop()
            inputReady = false
        } else if !input.running {
            inputReady = input.start()
        } else {
            inputReady = true
        }
        guard gestureSelection == nil, !organizingDrag, !editingOrganization, !organizationMenuOpen else { return }
        let desiredPause = paused, syncManagement = managementNeedsSync || paused
        perform(feedback:false,coalesce:true,control:true) { engine in
            do {
                if syncManagement { try WindowManagerSession.setPaused(desiredPause,backend:self.management) }
                if !desiredPause { try engine.refresh() }
                DispatchQueue.main.async { self.managementNeedsSync = false }
            } catch {
                DispatchQueue.main.async { self.backendReady = false; self.managementNeedsSync = true }
                throw error
            }
        }
    }
    func navigate(_ direction: Direction, scope: Scope, displayID: String? = nil) {
        let id = displayID ?? targetDisplay()
        perform { try $0.navigate(direction, scope: scope, displayID: id) }
    }
    func jump(gridID: String, cellID: String, displayID: String?) {
        let move = moveMode
        let window = overviewWindowID
        perform { engine in
            if move {
                guard let window else { throw GridError.unavailable("Focus an application window, then open the grid overview") }
                try engine.moveFocusedWindow(gridID: gridID, cellID: cellID, windowOverride: window)
                try engine.refresh()
            }
            else { try engine.jump(gridID: gridID, cellID: cellID, displayID: displayID) }
        }
    }
    func captureWindowForOverview(_ completion: @escaping () -> Void) {
        queue.async {
            let desktop = try? self.backend.desktop()
            let app = try? self.backend.run(["list-windows", "--focused", "--format", "%{app-bundle-id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if app != "local.AeroGrid" { self.overviewWindowID = desktop?.focusedWindow }
                completion()
            }
        }
    }
    func selectGrid(offset: Int, displayID: String? = nil) { let id = displayID ?? targetDisplay(); perform { try $0.selectGrid(offset: offset, displayID: id) } }
    func cycleWindow(offset: Int, displayID: String? = nil) { let id = displayID ?? targetDisplay(); perform { try $0.cycleWindow(offset: offset, displayID: id); try $0.refresh() } }
    func saveProfile() { let id = targetDisplay(); perform { try $0.saveProfile(displayID: id) } }
    func apply(_ config: Configuration) {
        guard !pauseChanging else { return }
        let shouldRefresh = !paused
        perform(feedback:false,control:true) { engine in
            try engine.updateConfiguration(config)
            self.backend.path = config.backendPath
            DispatchQueue.main.async { self.configuration = config; self.input.configuration = config }
            if shouldRefresh { try engine.refresh() }
        }
    }
    func recover() { managementNeedsSync = true; launchBackend(); inputReady = !paused && input.start(); refresh() }
    func setPaused(_ value:Bool) {
        guard value != paused, !pauseChanging else { return }
        pauseChanging = true; input.stop(); inputReady = false; deferredContacts.removeAll(); closeOverview?(false); endDrag()
        perform(control:true,completion:{ [weak self] error in
            guard let self else { return }
            self.pauseChanging = false
            if error == nil {
                self.paused = value; self.managementNeedsSync = false
                self.message = value ? "AeroGrid en pausa" : "AeroGrid activo"
            } else { self.backendReady = false; self.managementNeedsSync = true }
            if !self.paused && !self.isPreview { self.inputReady = self.input.start() }
            self.writeHealth()
        }) { engine in
            try WindowManagerSession.setPaused(value,backend:self.management) {
                if !value { try engine.refresh() }
                try self.store.save(WindowManagerPreferences(paused:value),name:"control.json")
            }
        }
    }
    func prepareToQuit(_ completion:@escaping () -> Void) {
        shuttingDown = true
        pauseChanging = true; input.stop(); deferredContacts.removeAll(); pendingOperations.removeAll(); closeOverview?(false)
        queue.async {
            if !self.isPreview && self.ownsBackend { try? self.backend.setManagementEnabled(false) }
            DispatchQueue.main.async {
                if !self.isPreview && self.ownsBackend {
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier:"local.AeroGrid.Backend") { app.terminate() }
                }
                completion()
            }
        }
    }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openTrackpadSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!) }
    private var ownsBackend: Bool {
        backend.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AeroGrid Backend.app/Contents/Resources/aerospace").path
    }
    func launchBackend() {
        guard !isPreview, !shuttingDown, ownsBackend else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier:"local.AeroGrid.Backend").isEmpty
        guard backendLaunchPolicy.request(at:ProcessInfo.processInfo.systemUptime,running:running) else { return }
        managementNeedsSync = true; backendReady = false
        message = "Iniciando el servicio de AeroGrid…"
        let options = NSWorkspace.OpenConfiguration(); options.activates = false
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AeroGrid Backend.app")
        NSWorkspace.shared.openApplication(at:url,configuration:options) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.shuttingDown { application?.terminate(); return }
                guard let error else { return }
                self.message = "No se pudo iniciar el servicio de AeroGrid. Usá Recuperar."
                self.log("Backend launch failed: \(error.localizedDescription)")
                self.writeHealth()
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { message = error.localizedDescription }
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func exportConfig() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AeroGrid-config.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(configuration).write(to: url, options: .atomic) }
            catch { message = error.localizedDescription }
        }
    }
    func importConfig() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)); try config.validate(); apply(config) }
            catch { message = error.localizedDescription }
        }
    }
    private func handle(_ swipe: RecognizedSwipe) {
        let binding = configuration.bindings.first {
            $0.fingers == swipe.fingers && $0.modifiers == swipe.modifiers && $0.direction == swipe.direction
        }
        let displayName = desktop?.displays.first { $0.id == swipe.displayID }?.name
            ?? swipe.displayID ?? "Focused display"
        let action = binding.map { "\($0.action) · \($0.scope == .all ? "All displays" : "This display")" }
            ?? "No binding"
        gestureMessage = "\(swipe.fingers) fingers · \(swipe.direction.rawValue) · modifiers \(swipe.modifiers) · \(displayName) · \(action)"
        guard !paused, !pauseChanging, !testingGestures, backendReady, let binding else { return }
        switch binding.action {
        case "navigate": break // Contact sessions preview now and commit on explicit lift.
        case "next-grid": selectGrid(offset: 1, displayID: swipe.displayID)
        case "previous-grid": selectGrid(offset: -1, displayID: swipe.displayID)
        case "next-window": cycleWindow(offset: 1, displayID: swipe.displayID)
        case "previous-window": cycleWindow(offset: -1, displayID: swipe.displayID)
        case "overview": showOverview?()
        default: break
        }
    }
    func handleContact(_ event: ContactGestureEvent) {
        if committingGesture {
            if case .cancelled = event {
                // Discard only the interrupted contact; completed gestures already queued survive.
                if let end = deferredContacts.lastIndex(where: { if case .ended = $0 { return true }; return false }) {
                    deferredContacts = Array(deferredContacts.prefix(through:end))
                } else { deferredContacts.removeAll() }
                log("Contact cancelled during commit; preserved complete queued gestures")
            }
            else if deferredContacts.count < 64 { deferredContacts.append(event) }
            else { deferredContacts.removeAll(); message = "Esperá a que termine el cambio antes de continuar" }
            return
        }
        switch event {
        case .cancelled:
            log("Contact cancelled: pending=\(gestureSelection != nil)")
            gestureSelection = nil; gestureScope = nil; closeNavigationHUD()
        case .ended:
            log("Contact ended: pending=\(gestureSelection != nil)")
            guard let selection = gestureSelection else { return }
            gestureSelection = nil; gestureScope = nil; closeNavigationHUD()
            guard !paused, !pauseChanging, !testingGestures, !selection.isAtOrigin, pendingOperations.count < 8 else { return }
            committingGesture = true
            log("Navigation commit: \(selection.selected.mapValues(\.spaceID))")
            closeOverview?(false)
            perform(feedback:true,completion: { [weak self] error in
                guard let self else { return }
                self.committingGesture = false
                self.log(error.map { "Navigation failed: \($0.localizedDescription)" } ?? "Navigation committed")
                let waiting = self.deferredContacts; self.deferredContacts.removeAll()
                // Resolve each following gesture against the desktop that actually committed.
                if error == nil { for event in waiting { self.handleContact(event) } }
            }) { engine in try engine.commitNavigation(selection) }
        case .step(let swipe):
            log("Contact step: \(swipe.fingers) \(swipe.direction.rawValue)")
            guard !paused, !pauseChanging, !testingGestures, backendReady, !committingGesture, !organizingDrag, !editingOrganization, !organizationMenuOpen,
                  let binding = configuration.bindings.first(where: { $0.fingers == swipe.fingers && $0.modifiers == swipe.modifiers && $0.direction == swipe.direction }),
                  binding.action == "navigate", let desktop, let map = state.dynamicMap else { return }
            do {
                var selection = try gestureSelection ?? NavigationSelection(map:map,configuration:configuration,desktop:desktop,scope:binding.scope,displayID:swipe.displayID)
                guard gestureScope == nil || gestureScope == binding.scope else { handleContact(.cancelled); return }
                try selection.validate(map:map,configuration:configuration,desktop:desktop)
                gestureScope = binding.scope
                let moved = selection.step(swipe.direction)
                gestureSelection = selection
                gestureMessage = moved ? "Selección pendiente · soltá para abrir" : "Borde del mapa · soltá o volvé al origen"
                scheduleNavigationHUD()
            } catch { handleContact(.cancelled); message = error.localizedDescription }
        }
    }
    private func externalAction(_ args: [String]) {
        guard !args.isEmpty else { return }
        switch args[0] {
        case "navigate" where args.count >= 3:
            if let d = Direction(rawValue: args[1]), let s = Scope(rawValue: args[2]) { navigate(d, scope: s) }
        case "next-grid": selectGrid(offset: 1)
        case "previous-grid": selectGrid(offset: -1)
        case "next-window": cycleWindow(offset: 1)
        case "previous-window": cycleWindow(offset: -1)
        case "overview": showOverview?()
        case "jump" where args.count >= 2: openSpace(args[1], displayID: args.count > 2 ? args[2] : targetDisplay())
        case "move-space" where args.count == 3: moveSpace(args[1], to: args[2])
        case "move-window" where args.count == 3:
            if let id = UInt32(args[1]), let window = desktop?.windows?.first(where: { $0.id == id }) { moveWindow(window.identity, to: args[2]) }
        case "arrange" where args.count == 4: arrange(args[1], layout: args[2], orientation: args[3])
        case "reunite" where args.count == 2: reunite(args[1])
        case "undo": undoOrganization()
        case "recover": recover()
        case "permissions": requestPermission()
        case "pause": setPaused(true)
        case "resume": setPaused(false)
        default: message = "Unknown external action"
        }
    }
    var spaces: [Space] { state.dynamicMap?.spaces ?? [] }
    func recordOrganizationDrag(_ message: String) { log("Organizer: \(message)") }
    func currentSpace(on display: Display) -> Space? {
        if let native = desktop?.nativeVisible?[display.monitor] { return spaces.first { $0.nativeWindow?.id == native } }
        return spaces.first { $0.workspace == desktop?.visible[display.monitor] && $0.nativeWindow == nil }
    }
    func windows(in space: Space) -> [WindowInfo] {
        if let identity = space.nativeWindow { return (desktop?.windows ?? []).filter { $0.identity == identity } }
        return (desktop?.windows ?? []).filter { $0.workspace == space.workspace && !$0.nativeFullscreen }
    }
    func openSpace(_ id: String, displayID: String?) {
        perform { engine in
            try engine.jump(cellID: id, displayID: displayID)
            DispatchQueue.main.async { self.closeOverview?(false) }
        }
    }
    func removeEmptySpace(_ id: String) { perform { try $0.removeEmptySpace(id) } }
    func renameSpace(_ id: String, name: String) { perform { try $0.renameSpace(id, name: name) } }
    func prepareMerge(_ id: String, into target: String) {
        perform(feedback: false) { engine in
            let preview = try engine.makeMergePreview(id, into: target)
            DispatchQueue.main.async {
                var named = preview
                if let source = self.spaces.first(where: { $0.id == id }) { named.sourceName = self.displayName(source) }
                if let destination = self.spaces.first(where: { $0.id == target }) { named.targetName = self.displayName(destination) }
                self.mergePreview = named
            }
        }
    }
    func mergeSpaces(_ preview: MergePreview) {
        perform { try $0.mergeSpaces(preview.sourceID, into: preview.targetID,
                                    expectedSource: Set(preview.sourceWindows.map(\.identity)), expectedTarget: Set(preview.targetWindows.map(\.identity))) }
        mergePreview = nil
    }
    func moveSpace(_ id: String, to target: String) { perform { try $0.moveSpace(id, to: target) } }
    func insertSpace(_ id: String, beside target: String, edge: Direction) { perform { try $0.insertSpace(id,beside:target,edge:edge) } }
    func moveWindow(_ window: WindowIdentity, to target: String) { perform { try $0.moveWindow(window, to: target) } }
    func dropWindow(_ window: WindowIdentity, to target: String, layout: String, orientation: String) {
        perform { try $0.moveWindow(window, to: target, layout: layout, orientation: orientation) }
    }
    func reorderWindow(_ window: WindowIdentity, before target: WindowIdentity) {
        recordOrganizationDrag("reorder \(window.id) before \(target.id)")
        perform { try $0.reorderWindow(window, before: target) }
    }
    func arrange(_ id: String, layout: String, orientation: String) { perform { try $0.arrange(id, layout: layout, orientation: orientation) } }
    func assignSpace(_ id: String, displayID: String) { perform { try $0.assignSpace(id, displayID: displayID) } }
    func reunite(_ source: String) { perform { try $0.reunite(sourceID: source) } }
    func prepareReunite(_ source: String) {
        perform(feedback: false) { engine in
            let preview = try engine.makeReunitePreview(sourceID: source)
            DispatchQueue.main.async { self.reunitePreview = preview }
        }
    }
    func reunite(_ preview: ReunitePreview) {
        perform { try $0.reunite(sourceID: preview.sourceID, expectedOwners: Set(preview.windows.map(\.identity))) }
        reunitePreview = nil
    }
    func undoOrganization() { perform { try $0.undo() } }
    func createSpace(near: String? = nil, moving: WindowIdentity? = nil, displayID: String? = nil) {
        let display = displayID ?? targetDisplay()
        perform { engine in
            _ = try engine.createSpace(nearID: near, displayID: display, moving: moving)
        }
    }
    func createSpaceAt(row: Int, column: Int, moving: WindowIdentity? = nil, displayID: String?) {
        perform { _ = try $0.createSpace(nearID:nil,displayID:displayID,row:row,column:column,moving:moving) }
    }
    var projectedSpaces: [Space] { state.dynamicMap?.projectedSpaces(combined:desktop?.displays.count == 1) ?? [] }
    func boardSpaces(_ display: Display) -> [Space] {
        guard let desktop else { return [] }
        let role = configuration.displayAssignments.first { $0.value == display.id }?.key ?? (display.builtin ? "builtin" : "external")
        let geometry = gestureSelection?.spaces ?? projectedSpaces
        return geometry.filter { !$0.isDormant && (desktop.displays.count == 1 || ($0.preferredDisplay.map { $0 == display.id } ?? ($0.preferredRole == role))) }
    }
    func displayName(_ space: Space) -> String {
        SpaceLabels.title(windows:windows(in:space))
    }
    func layout(_ space: Space) -> LayoutSnapshot {
        if let identity = space.nativeWindow { return LayoutSnapshot(boot:identity.boot,tree:.root([LayoutNode(id:identity.id,pid:identity.pid)])) }
        if let json = state.dynamicMap?.layouts[space.id], let saved = try? LayoutSnapshot(json:json) { return saved }
        let windows = windows(in:space)
        return LayoutSnapshot(boot:windows.first?.boot ?? "",tree:.root(windows.filter { !$0.floating }.map { LayoutNode(id:$0.id,pid:$0.pid) }))
    }
    func setSpaceRect(_ id: String, _ rect: SpaceRect, displayID:String? = nil) { perform { try $0.setSpaceRect(id,rect:rect,displayID:displayID) } }
    func beginDrag(window: WindowIdentity? = nil, space: String? = nil) {
        log("Organization drag: window=\(window?.id ?? 0) space=\(space ?? "")")
        organizingDrag = true; draggedWindow = window; draggedSpace = space
    }
    func endDrag() { organizingDrag = false; draggedWindow = nil; draggedSpace = nil }
    func placeWindow(_ identity: WindowIdentity,in space: String,group: Set<UInt32>,placement: GridCore.WindowPlacement) {
        guard let target = spaces.first(where: { $0.id == space }), let source = desktop?.windows?.first(where: { $0.identity == identity }) else { return }
        let expected = layout(target).tree
        perform { try $0.placeWindow(identity,in:space,group:group,placement:placement,expectedTarget:expected,expectedSourceWorkspace:source.workspace) }
    }
    func placementPreview(_ identity: WindowIdentity,in space: String,group: Set<UInt32>,placement: GridCore.WindowPlacement) -> LayoutSnapshot? {
        guard let source = spaces.first(where: { windows(in:$0).contains(where: { $0.identity == identity }) }), let target = spaces.first(where: { $0.id == space }) else { return nil }
        func find(_ node: LayoutNode) -> LayoutNode? {
            if node.id == identity.id && node.pid == identity.pid { return node }
            return (node.children ?? []).compactMap(find).first
        }
        guard let incoming = find(layout(source).tree) else { return nil }
        return try? layout(target).placing(incoming,beside:group,placement:placement)
    }
    func moveSpaceToVacancy(_ id: String) {
        perform { engine in
            guard let anchor = engine.map.spaces.first(where: { $0.id == id }) else { throw GridError.stale }
            let position = engine.map.vacant(near: anchor)
            try engine.moveSpace(id, row: position.row, column: position.column)
        }
    }
    func moveSpaceAt(_ id: String, row: Int, column: Int) { perform { try $0.moveSpace(id, row: row, column: column) } }
    func focusWindow(_ identity: WindowIdentity) { perform { try $0.focusWindow(identity) } }
    func restoreOverviewFocus() {
        guard let id = overviewWindowID, let window = desktop?.windows?.first(where: { $0.id == id }) else { return }
        focusWindow(window.identity)
    }
    private func scheduleNavigationHUD() {
        guard navigationPanels.isEmpty, !hudScheduled else { return }
        hudScheduled = true
        let generation = hudGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hudGeneration == generation else { return }
            self.hudScheduled = false
            guard self.gestureSelection != nil else { return }
            self.showNavigationHUD()
        }
    }
    private func showNavigationHUD() {
        guard navigationPanels.isEmpty else { return }
        hud?.close()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
            let id = CFUUIDCreateString(nil,uuid) as String
            guard let display = desktop?.displays.first(where: { $0.id == id }),
                  gestureSelection?.selected[id] != nil else { continue }
            let contentSize = MapPresentation.panelSize(displays:[display],model:self,editable:false)
            let width = min(contentSize.width,screen.visibleFrame.width-48)
            let height = min(contentSize.height,screen.visibleFrame.height-80)
            let panel = NSPanel(contentRect:NSRect(x:screen.visibleFrame.midX-width/2,y:screen.visibleFrame.maxY-height-12,width:width,height:height),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
            panel.title = "AeroGrid · Navegación"
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView:SpatialHUDView(model:self,display:display))
            panel.orderFrontRegardless(); navigationPanels.append(panel)

        }
    }
    private func closeNavigationHUD() {
        hudGeneration += 1; hudScheduled = false
        navigationPanels.forEach { $0.close() }; navigationPanels.removeAll()
    }
    private func showHUD(_ text: String) {
        hud?.close(); closeNavigationHUD()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - 280, y: screen.visibleFrame.maxY - 135, width: 560, height: 108), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Text(text).font(.headline).lineLimit(4).padding(12).frame(maxWidth: .infinity).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        panel.orderFrontRegardless(); hud = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak panel] in panel?.close() }
    }
    private func log(_ text: String) { diagnostics.text(text) }
    private func writeHealth() {
        let health: [String: Any] = ["backendReady": backendReady, "gestureInputReady": inputReady,
                                   "accessibilityGranted": AXIsProcessTrusted(), "paused": paused, "pauseChanging": pauseChanging,
                                   "managementEnabled": backendReady && !pauseChanging ? !paused as Any : NSNull(),
                                   "message": message, "gesture": gestureMessage,
                                   "updatedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: health, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("health.json"), options: .atomic)
        }
    }
}
