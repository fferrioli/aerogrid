// AeroGrid's versioned, narrowly scoped layout snapshot extension.
import AppKit
import Common

struct GridLayoutNode: Codable {
    var id: UInt32?
    var pid: Int32?
    var weight: Double
    var orientation: String?
    var layout: String?
    var fullscreen: Bool?
    var children: [GridLayoutNode]?
}
struct GridFloat: Codable {
    var id: UInt32
    var pid: Int32
    var x: Double; var y: Double; var width: Double; var height: Double
}
struct GridLayoutSnapshot: Codable {
    var version = 1
    var boot: String
    var tree: GridLayoutNode
    var floating: [GridFloat]
    var focus: UInt32?
}
struct GridWindowHome: Codable {
    var id: UInt32
    var pid: Int32
    var boot: String
    var workspace: String
    var floating: Bool
}
@MainActor private var gridPendingWindowHomes: [UInt32: GridWindowHome] = [:]

struct GridMinimumWidthTracker {
    private struct Candidate {
        var frame: [CGFloat]
        var width: CGFloat
        var since: TimeInterval
    }
    private var candidates: [String: Candidate] = [:]

    mutating func observe(identity: String, requested: Rect?, actual: Rect?, display: Rect, now: TimeInterval) -> Double {
        guard let requested, let actual, actual.width > requested.width + 1 else {
            candidates.removeValue(forKey: identity)
            return 0
        }
        let frame = [requested.minX, requested.minY, requested.width, requested.height,
                     display.minX, display.minY, display.width, display.height]
        if let previous = candidates[identity], previous.frame == frame,
           abs(previous.width - actual.width) <= 1 {
            return now - previous.since >= 1 ? Double(actual.width) : 0
        }
        if candidates.count >= 4096 { candidates.removeAll() }
        candidates[identity] = Candidate(frame: frame, width: actual.width, since: now)
        return 0
    }

    mutating func forget(windowID: UInt32) {
        candidates = candidates.filter { !$0.key.hasSuffix(":\(windowID)") }
    }
}
@MainActor private var gridMinimumWidthTracker = GridMinimumWidthTracker()

@MainActor func gridForgetRecoveredWindowHome(_ id: UInt32) {
    gridPendingWindowHomes.removeValue(forKey: id)
    gridMinimumWidthTracker.forget(windowID: id)
}

@MainActor func gridApplyRecoveredWindowHome(_ window: Window) {
    guard let home = gridPendingWindowHomes[window.windowId] else { return }
    guard home.boot == gridBootIdentity(), window.app.pid == home.pid else {
        gridForgetRecoveredWindowHome(window.windowId)
        return
    }
    let workspace = Workspace.get(byName: home.workspace)
    if window.parent is MacosFullscreenWindowsContainer {
        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window.layoutReason = .macos(prevParentKind: home.floating ? .floatingWindowsContainer : .tilingContainer)
    } else if window.parent is MacosHiddenAppsWindowsContainer {
        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window.layoutReason = .macos(prevParentKind: home.floating ? .floatingWindowsContainer : .tilingContainer)
    } else if window.layoutReason != .standard {
        return
    } else if home.floating {
        window.bindAsFloatingWindow(to: workspace)
    } else {
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    gridForgetRecoveredWindowHome(window.windowId)
}
@MainActor private var gridNativeLayoutSnapshots: [String: GridLayoutSnapshot] = [:]
@MainActor private let gridBackendSession = UUID().uuidString

@MainActor func gridRememberNativeLayout(_ workspace: Workspace) async {
    if !workspace.macOsNativeFullscreenWindowsContainer.children.isEmpty,
       gridNativeLayoutSnapshots[workspace.name] != nil { return }
    // Closing a native window may skip the normal fullscreen-exit callback.
    gridNativeLayoutSnapshots.removeValue(forKey: workspace.name)
    let command = GridLayoutCommand(args: GridLayoutCmdArgs(rawArgs: []))
    if let json = try? await command.snapshot(workspace), let saved = try? JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(json.utf8)) {
        gridNativeLayoutSnapshots[workspace.name] = saved
    }
}
@MainActor func gridRestoreAfterNativeExit(_ workspace: Workspace) {
    guard workspace.macOsNativeFullscreenWindowsContainer.children.isEmpty,
          let saved = gridNativeLayoutSnapshots.removeValue(forKey: workspace.name) else { return }
    GridLayoutCommand(args: GridLayoutCmdArgs(rawArgs: [])).restore(saved, workspace)
}
private func gridBootIdentity() -> String {
    // WindowServer IDs are only meaningful during this login/boot; also check owner PID.
    var boot = timeval(); var size = MemoryLayout<timeval>.size
    _ = unsafe sysctlbyname("kern.boottime", &boot, &size, nil, 0)
    return String(boot.tv_sec)
}
struct GridLayoutCommand: Command {
    let args: GridLayoutCmdArgs
    var shouldResetClosedWindowsCache: Bool { !["status", "snapshot"].contains(args.operation.val) }
    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do {
            if args.operation.val == "management-status" { return .succ(io.out(try gridManagementStatus())) }
            if args.operation.val == "status" {
                guard isUnitTest || AXIsProcessTrusted() else { return .fail(io.err("AeroGrid Backend needs Accessibility permission")) }
                guard isUnitTest || gridBackendReady else { return .fail(io.err("AeroGrid Backend is still starting")) }
                return .succ(io.out(try await status()))
            }
            if args.operation.val == "native-status" { return .succ(io.out(try gridNativeStatus())) }
            if args.operation.val == "native-focus" {
                guard let id = args.data.flatMap(UInt64.init) else { return .fail(io.err("Expected native Space ID")) }
                try await gridNativeFocusSpace(id)
                return .succ
            }
            if args.operation.val == "recover-homes" {
                guard let data = args.data else { return .fail(io.err("Expected window homes JSON")) }
                let homes = try JSONDecoder().decode([GridWindowHome].self, from: Data(data.utf8))
                guard homes.count <= 4096, Set(homes.map(\.id)).count == homes.count,
                      homes.allSatisfy({ !$0.workspace.isEmpty && $0.workspace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else {
                    return .fail(io.err("Invalid window homes"))
                }
                let boot = gridBootIdentity()
                for home in homes where home.boot == boot {
                    gridPendingWindowHomes[home.id] = home
                    if let window = Window.get(byId: home.id) { gridApplyRecoveredWindowHome(window) }
                }
                return .succ
            }
            guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
            let ws = target.workspace
            switch args.operation.val {
            case "move-window":
                guard let data = args.data?.data(using: .utf8) else { return .fail(io.err("Expected window identity")) }
                let identity = try JSONDecoder().decode(GridMoveIdentity.self, from: data)
                guard identity.boot == gridBootIdentity(), let window = Window.get(byId: identity.id), window.app.pid == identity.pid else { return .fail(io.err("Window identity changed")) }
                guard !(window.parent is MacosFullscreenWindowsContainer) else { return .fail(io.err("Exit fullscreen before moving this window into a different group")) }
                return moveWindowToWorkspace(window, ws, io, focusFollowsWindow: false, failIfNoop: false)
            case "constraints":
                var widths: [String: Double] = [:]
                let boot = gridBootIdentity()
                for window in ws.rootTilingContainer.allLeafWindowsRecursive where !window.isFullscreen && window.app.rawAppBundleId != "local.AeroGrid" {
                    let identity = "\(boot):\(window.app.pid):\(window.windowId)"
                    widths[identity] = 0
                    // Hidden/native-transition frames aren't evidence of an app's minimum size.
                    // Confirm a stable rejection over separate observations after AX has settled.
                    let eligible = ws.isVisible && ws.macOsNativeFullscreenWindowsContainer.children.isEmpty && window.layoutReason == .standard
                    let actual = eligible ? (try? await window.getAxRect(.nonCancellable)) : nil
                    widths[identity] = gridMinimumWidthTracker.observe(identity: identity,
                        requested: eligible ? window.lastAppliedLayoutPhysicalRect : nil,
                        actual: actual, display: ws.workspaceMonitor.visibleRect, now: ProcessInfo.processInfo.systemUptime)
                }
                return .succ(io.out(String(decoding: try JSONEncoder().encode(widths), as: UTF8.self)))
            case "check-target", "activate-target":
                guard let data = args.data?.data(using: .utf8) else { return .fail(io.err("Expected target JSON")) }
                let request = try JSONDecoder().decode(GridActivationTarget.self, from: data)
                guard let monitor = sortedMonitorInfos.first(where: { $0.monitorId_oneBased == request.monitor }) else { return .fail(io.err("Target display unavailable")) }
                if let forced = ws.forceAssignedMonitor, forced.monitorId_oneBased != request.monitor { return .fail(io.err("Workspace is force-assigned to another display")) }
                let window: Window?
                if let id = request.window {
                    guard let selected = ws.macOsNativeFullscreenWindowsContainer.allLeafWindowsRecursive.first(where: { $0.windowId == id }) else { return .fail(io.err("Fullscreen window no longer exists in this space")) }
                    if !isUnitTest, gridNativeMonitor(selected)?.monitorId_oneBased != request.monitor { return .fail(io.err("Fullscreen belongs to another physical display")) }
                    window = selected
                } else {
                    window = gridNormalWindow(ws)
                }
                if args.operation.val == "activate-target" {
                    gridPendingWorkspaces.insert(ws.name)
                    defer { gridPendingWorkspaces.remove(ws.name) }
                    if request.window == nil {
                        guard placeWorkspaceOnMonitor(ws, targetMonitor: monitor) else { return .fail(io.err("Workspace assignment conflict")) }
                    }
                    try await gridNativeActivate(ws, selected: window, normal: request.window == nil, targetMonitor: monitor)
                    if let window {
                        guard window.focusWindow() else { return .fail(io.err("Window could not be focused")) }
                        window.nativeFocus()
                    } else {
                        guard ws.focusWorkspace() else { return .fail(io.err("Workspace could not be focused")) }
                    }
                }
            case "check":
                guard let id = args.data.flatMap(Int.init), let monitor = sortedMonitorInfos.first(where: { $0.monitorId_oneBased == id }) else { return .fail(io.err("Target display unavailable")) }
                if let forced = ws.forceAssignedMonitor, forced.monitorId_oneBased != id { return .fail(io.err("Workspace '\(ws.name)' is force-assigned to another display")) }
                try gridNativeCheck(ws, monitor: monitor)
            case "snapshot":
                return .succ(io.out(try await snapshot(ws)))
            case "restore":
                guard let data = args.data?.data(using: .utf8) else { return .fail(io.err("Missing --data JSON")) }
                let saved = try JSONDecoder().decode(GridLayoutSnapshot.self, from: data)
                var ids = Set<UInt32>()
                try validate(saved.tree, depth: 0, ids: &ids)
                guard saved.version == 1 else { return .fail(io.err("Unsupported layout snapshot version")) }
                guard saved.boot == gridBootIdentity() else { return .fail(io.err("Layout IDs expired after reboot; apply a fresh profile")) }
                if !ws.macOsNativeFullscreenWindowsContainer.children.isEmpty { gridNativeLayoutSnapshots[ws.name] = saved }
                restore(saved, ws)
            case "compact", "wide", "vertical":
                let root = ws.rootTilingContainer
                if args.operation.val == "compact" {
                    // Flatten only the compact profile; the wide tree is serialized independently.
                    let windows = root.allLeafWindowsRecursive
                    for w in windows { w.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
                    for child in root.children where child is TilingContainer { child.unbindFromParent() }
                    root.layout = .accordion; root.changeOrientation(.h)
                    if var saved = gridNativeLayoutSnapshots[ws.name] {
                        func leaves(_ n: GridLayoutNode) -> [GridLayoutNode] { n.id != nil ? [n] : (n.children ?? []).flatMap(leaves) }
                        saved.tree = GridLayoutNode(weight: 1, orientation: "h", layout: "accordion", children: leaves(saved.tree))
                        gridNativeLayoutSnapshots[ws.name] = saved
                    }
                } else {
                    root.layout = .tiles; root.changeOrientation(args.operation.val == "vertical" ? .v : .h)
                }
                clampFloating(ws)
            case "activate":
                gridPendingWorkspaces.insert(ws.name)
                defer { gridPendingWorkspaces.remove(ws.name) }
                let window = gridActivationWindow(ws)
                try await gridNativeActivate(ws)
                let focused = window?.visualWorkspace === ws ? window?.focusWindow() ?? false : ws.focusWorkspace()
                guard focused else { return .fail(io.err("Workspace assignment conflict")) }
                // Explicit native focus also raises native fullscreen without toggling it off.
                if window?.visualWorkspace === ws { window?.nativeFocus() }
            default: return .fail(io.err("Unknown grid-layout operation"))
            }
            return .succ
        } catch { return .fail(io.err("grid-layout: \(error.localizedDescription)")) }
    }

    @MainActor private func status() async throws -> String {
        let displays: [[String: Any]] = sortedMonitorInfos.map { m in
            let index = m.monitorAppKitNsScreenScreensId - 1
            let screen = NSScreen.screens[index]
            let cg = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "unknown-\(cg)"
            return ["id": id, "monitor": m.monitorId_oneBased ?? 0, "name": m.name,
                    "builtin": CGDisplayIsBuiltin(cg) != 0, "width": m.visibleRect.width, "height": m.visibleRect.height]
        }
        let visible = Dictionary(uniqueKeysWithValues: sortedMonitorInfos.map { (String($0.monitorId_oneBased ?? 0), $0.activeWorkspace.name) })
        let nativeHomes = gridNativeWorkspaceMonitors()
        let focusedMonitor = focus.windowOrNil.flatMap { gridNativeMonitor($0)?.monitorId_oneBased }
            ?? focus.workspace.workspaceMonitor.monitorId_oneBased ?? 1
        let boot = gridBootIdentity()
        let actualHomes: [GridWindowHome] = Workspace.all.flatMap { workspace in
            workspace.allLeafWindowsRecursive.map { window in
                var floating = window.isFloating
                if case .macos(let previous) = window.layoutReason { floating = previous == .floatingWindowsContainer }
                return GridWindowHome(id: window.windowId, pid: window.app.pid, boot: boot, workspace: workspace.name, floating: floating)
            }
        }
        var homeByID = Dictionary(uniqueKeysWithValues: actualHomes.map { ($0.id, $0) })
        for home in gridPendingWindowHomes.values where home.boot == boot {
            guard isUnitTest || NSRunningApplication(processIdentifier: home.pid) != nil else {
                gridForgetRecoveredWindowHome(home.id)
                continue
            }
            homeByID[home.id] = home
        }
        let homes = try JSONSerialization.jsonObject(with: JSONEncoder().encode(homeByID.keys.sorted().compactMap { homeByID[$0] }))
        var inventory: [[String: Any]] = []
        for ws in Workspace.all {
            for window in ws.allLeafWindowsRecursive where window.app.rawAppBundleId != "local.AeroGrid" {
                let native = window.parent is MacosFullscreenWindowsContainer
                var value: [String: Any] = ["id": window.windowId, "pid": window.app.pid, "boot": boot,
                    "workspace": ws.name, "floating": window.isFloating, "monitor": ws.workspaceMonitor.monitorId_oneBased ?? 0,
                    "title": (try? await window.getTitle(.nonCancellable)) ?? "",
                    "appName": window.app.name ?? "Application", "bundleID": window.app.rawAppBundleId ?? "",
                    "nativeFullscreen": native]
                if let monitor = gridNativeMonitor(window)?.monitorId_oneBased { value["nativeMonitor"] = monitor }
                inventory.append(value)
            }
        }
        let value: [String: Any] = ["windows": inventory, "nativeVisible": gridNativeVisibleWindows(), "displays": displays, "visible": visible, "nativeHomes": nativeHomes, "backendSession": gridBackendSession, "windowHomes": homes,
                                  "focusedMonitor": focusedMonitor,
                                  "focusedWindow": focus.windowOrNil.map { NSNumber(value: $0.windowId) } ?? NSNull(), "extensionVersion": 2]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    @MainActor private func captureNode(_ node: TreeNode) -> GridLayoutNode {
        let weight = (node.parent as? TilingContainer).map { Double(node.getWeight($0.orientation)) } ?? 1
        if let w = node as? Window { return GridLayoutNode(id: w.windowId, pid: w.app.pid, weight: weight, fullscreen: w.isFullscreen) }
        let c = node as! TilingContainer
        return GridLayoutNode(weight: weight, orientation: c.orientation == .h ? "h" : "v", layout: c.layout.rawValue, children: c.children.map(captureNode))
    }
    @MainActor fileprivate func snapshot(_ ws: Workspace) async throws -> String {
        let rect = ws.workspaceMonitor.visibleRect
        var floats: [GridFloat] = []
        for w in ws.floatingWindows {
            if let r = try await w.getGridSnapshotRect(.nonCancellable) {
                floats.append(GridFloat(id: w.windowId, pid: w.app.pid, x: (r.minX - rect.minX) / max(rect.width, 1), y: (r.minY - rect.minY) / max(rect.height, 1), width: r.width / max(rect.width, 1), height: r.height / max(rect.height, 1)))
            }
        }
        if ws.macOsNativeFullscreenWindowsContainer.children.isEmpty {
            gridNativeLayoutSnapshots.removeValue(forKey: ws.name)
        }
        let tree = gridNativeLayoutSnapshots[ws.name]?.tree ?? captureNode(ws.rootTilingContainer)
        let saved = GridLayoutSnapshot(boot: gridBootIdentity(), tree: tree, floating: floats, focus: ws.mostRecentWindowRecursive?.windowId)
        return String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    }
    private func validate(_ node: GridLayoutNode, depth: Int, ids: inout Set<UInt32>) throws {
        guard depth <= 32, node.weight.isFinite, node.weight > 0 else { throw NSError(domain: "Invalid layout weight/depth", code: 1) }
        if let id = node.id {
            guard ids.insert(id).inserted, node.pid != nil, node.children == nil else { throw NSError(domain: "Duplicate/invalid layout leaf", code: 1) }
        } else {
            guard ["h", "v"].contains(node.orientation), ["tiles", "accordion"].contains(node.layout), let children = node.children, children.count <= 512 else { throw NSError(domain: "Invalid layout container", code: 1) }
            for child in children { try validate(child, depth: depth + 1, ids: &ids) }
        }
    }
    @MainActor fileprivate func restore(_ saved: GridLayoutSnapshot, _ ws: Workspace) {
        if !ws.macOsNativeFullscreenWindowsContainer.children.isEmpty {
            gridNativeLayoutSnapshots[ws.name] = saved
        } else {
            gridNativeLayoutSnapshots.removeValue(forKey: ws.name)
        }
        let normal = ws.rootTilingContainer.allLeafWindowsRecursive + ws.floatingWindows
        let allowed = Dictionary(uniqueKeysWithValues: normal.map { ($0.windowId, $0) })
        let old = ws.rootTilingContainer
        // Keep windows bound until replacement exists, then remove the old tree.
        old.unbindFromParent()
        let root = TilingContainer(parent: ws, adaptiveWeight: 1, saved.tree.orientation == "v" ? .v : .h, Layout(rawValue: saved.tree.layout ?? "tiles") ?? .tiles, index: INDEX_BIND_LAST)
        root.gridPreservesStructure = true
        var used = Set<UInt32>()
        func build(_ n: GridLayoutNode, parent: TilingContainer) {
            if let id = n.id {
                guard let w = allowed[id], w.app.pid == n.pid else { return }
                w.bind(to: parent, adaptiveWeight: n.weight, index: INDEX_BIND_LAST)
                w.isFullscreen = n.fullscreen ?? false; used.insert(id)
            } else {
                let c = TilingContainer(parent: parent, adaptiveWeight: n.weight, n.orientation == "v" ? .v : .h, Layout(rawValue: n.layout ?? "tiles") ?? .tiles, index: INDEX_BIND_LAST)
                for child in n.children ?? [] { build(child, parent: c) }
                if c.children.isEmpty { c.unbindFromParent() }
            }
        }
        for n in saved.tree.children ?? [] { build(n, parent: root) }
        let r = ws.workspaceMonitor.visibleRect
        for f in saved.floating {
            guard let w = allowed[f.id], w.app.pid == f.pid, !used.contains(f.id) else { continue }
            w.bindAsFloatingWindow(to: ws); used.insert(f.id)
            let width = max(100, min(r.width, f.width * r.width)), height = max(100, min(r.height, f.height * r.height))
            w.setAxFrame(CGPoint(x: r.minX + max(0, min(r.width - width, f.x * r.width)), y: r.minY + max(0, min(r.height - height, f.y * r.height))), CGSize(width: width, height: height))
        }
        // New windows retain floating/tiling membership; missing windows simply vanish.
        for w in normal where !used.contains(w.windowId) {
            if !w.isFloating { w.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
        }
        if let id = saved.focus, let w = allowed[id] { w.markAsMostRecentChild() }
    }
    @MainActor private func clampFloating(_ ws: Workspace) {
        let rect = ws.workspaceMonitor.visibleRect
        for w in ws.floatingWindows {
            let old = w.lastAppliedLayoutPhysicalRect
            let size = CGSize(width: min(rect.width, old?.width ?? 800), height: min(rect.height, old?.height ?? 600))
            w.setAxFrame(CGPoint(x: rect.minX + max(0, (rect.width - size.width) / 2), y: rect.minY + max(0, (rect.height - size.height) / 2)), size)
        }
    }
}

@MainActor func gridManagementStatus() throws -> String {
    let status = ["enabled":TrayMenuModel.shared.isEnabled,"ready":isUnitTest || (gridBackendReady && AXIsProcessTrusted())]
    return String(decoding:try JSONSerialization.data(withJSONObject:status,options:[.sortedKeys]),as:UTF8.self)
}

struct GridActivationTarget: Codable {
    var monitor: Int
    var window: UInt32?
}
struct GridMoveIdentity: Codable {
    var id: UInt32
    var pid: Int32
    var boot: String
}
