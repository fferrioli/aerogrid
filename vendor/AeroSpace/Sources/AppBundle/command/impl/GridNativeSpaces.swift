import AppKit
import Common
import PrivateApi

@MainActor private var gridDesktopSpaces: [String: UInt64] = [:]

@MainActor func gridActivationWindow(_ workspace: Workspace) -> Window? {
    // Normal windows can become most recent while switching away from native fullscreen.
    // Keep that fullscreen target reachable when returning to its cell.
    workspace.macOsNativeFullscreenWindowsContainer.mostRecentWindowRecursive
        ?? workspace.mostRecentWindowRecursive ?? workspace.anyLeafWindowRecursive
}

struct GridNativeDisplay {
    var id: String
    var current: UInt64
    var spaces: [(id: UInt64, type: Int)]
}

@MainActor private func nativeDisplays() -> [GridNativeDisplay]? {
    guard let array = AeroGridCopyDisplaySpaces() as? [[String: Any]] else { return nil }
    return array.compactMap { value in
        guard let id = value["Display Identifier"] as? String,
              let current = value["Current Space"] as? [String: Any], let currentID = current["ManagedSpaceID"] as? UInt64,
              let spaces = value["Spaces"] as? [[String: Any]] else { return nil }
        return GridNativeDisplay(id: id, current: currentID, spaces: spaces.compactMap {
            guard let id = $0["ManagedSpaceID"] as? UInt64, let type = $0["type"] as? Int else { return nil }
            return (id, type)
        })
    }
}
@MainActor func gridNativeStatus() throws -> String {
    guard let displays = nativeDisplays() else { throw NSError(domain: "Native Spaces API unavailable", code: 1) }
    let values = displays.map { d -> [String: Any] in
        ["id": d.id, "current": d.current, "spaces": d.spaces.map { ["id": $0.id, "type": UInt64($0.type)] }]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
}
@MainActor func gridNativeMonitor(_ window: Window) -> MonitorInfo? {
    guard window.parent is MacosFullscreenWindowsContainer, let displays = nativeDisplays() else { return nil }
    let spaces = AeroGridCopyWindowSpaces(window.windowId) as? [NSNumber] ?? []
    guard let display = displays.first(where: { d in spaces.contains { value in d.spaces.contains { $0.id == value.uint64Value && $0.type == 4 } } }) else { return nil }
    return sortedMonitorInfos.first { monitor in
        let screen = NSScreen.screens[monitor.monitorAppKitNsScreenScreensId - 1]
        let cg = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue() else { return false }
        return CFUUIDCreateString(nil, uuid) as String == display.id
    }
}
@MainActor func gridNativeWorkspaceMonitors() -> [String: Int] {
    var result: [String: Int] = [:]
    for ws in Workspace.all {
        for window in ws.macOsNativeFullscreenWindowsContainer.allLeafWindowsRecursive {
            if let id = gridNativeMonitor(window)?.monitorId_oneBased { result[ws.name] = id }
        }
    }
    return result
}

@MainActor func gridNativeCheck(_ workspace: Workspace, monitor: MonitorInfo) throws {
    if isUnitTest { return }
    let full = workspace.macOsNativeFullscreenWindowsContainer.allLeafWindowsRecursive
    guard !full.isEmpty else { return }
    guard let displays = nativeDisplays() else { throw NSError(domain: "Native Spaces API unavailable", code: 1) }
    let screen = NSScreen.screens[monitor.monitorAppKitNsScreenScreensId - 1]
    let cg = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let uuid = CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue()
    let id = uuid.map { CFUUIDCreateString(nil, $0) as String }
    guard let display = displays.first(where: { $0.id == id }) ?? (displays.count == 1 ? displays.first : nil) else { throw NSError(domain: "Cannot match native display", code: 1) }
    for window in full {
        let spaces = AeroGridCopyWindowSpaces(window.windowId) as? [NSNumber] ?? []
        guard spaces.contains(where: { value in display.spaces.contains { $0.id == value.uint64Value } }) else { throw NSError(domain: "Native fullscreen window is on another physical display", code: 1) }
    }
}

@MainActor func gridNativeActivate(_ workspace: Workspace, selected: Window? = nil, normal: Bool = false, targetMonitor: MonitorInfo? = nil) async throws {
    if isUnitTest { return }
    guard let displays = nativeDisplays(), !displays.isEmpty else { throw NSError(domain: "Native Spaces API unavailable", code: 1) }
    let monitor = targetMonitor ?? workspace.workspaceMonitor
    let screen = NSScreen.screens[monitor.monitorAppKitNsScreenScreensId - 1]
    let cg = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let uuid = CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue()
    let displayID = uuid.map { CFUUIDCreateString(nil, $0) as String }
    // macOS uses "Main" when Spaces are shared across displays.
    guard let display = displays.first(where: { $0.id == displayID }) ?? (displays.count == 1 ? displays.first : nil) else { throw NSError(domain: "Cannot match native display", code: 1) }
    if display.spaces.first(where: { $0.id == display.current })?.type == 0 { gridDesktopSpaces[display.id] = display.current }
    let candidate = normal ? nil : (selected ?? gridActivationWindow(workspace))
    let fullscreen = candidate.flatMap { w in workspace.macOsNativeFullscreenWindowsContainer.children.contains(w) ? w : nil }
    var destination: UInt64?
    if let fullscreen {
        let spaces = AeroGridCopyWindowSpaces(fullscreen.windowId) as? [NSNumber] ?? []
        destination = spaces.map(\.uint64Value).first { id in display.spaces.contains { $0.id == id && $0.type == 4 } }
    } else {
        // An explicit normal target may live on a different desktop from the last cached one.
        let spaces = selected.map { AeroGridCopyWindowSpaces($0.windowId) as? [NSNumber] ?? [] } ?? []
        destination = spaces.map(\.uint64Value).first { id in display.spaces.contains { $0.id == id && $0.type == 0 } }
            ?? gridDesktopSpaces[display.id].flatMap { id in display.spaces.contains { $0.id == id && $0.type == 0 } ? id : nil }
            ?? display.spaces.first(where: { $0.type == 0 })?.id
    }
    guard let destination else { throw NSError(domain: "Native fullscreen target isn't available on this display", code: 1) }
    try await gridNativeSwitch(display: display, destination: destination, monitor: monitor)
}

@MainActor func gridNativeFocusSpace(_ space: UInt64) async throws {
    guard let display = nativeDisplays()?.first(where: { $0.spaces.contains { $0.id == space } }), let monitor = sortedMonitorInfos.first(where: { m in
        let screen = NSScreen.screens[m.monitorAppKitNsScreenScreensId - 1]
        let cg = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(cg)?.takeRetainedValue() else { return false }
        return CFUUIDCreateString(nil, uuid) as String == display.id
    }) else { throw NSError(domain: "Native Space unavailable", code: 1) }
    try await gridNativeSwitch(display: display, destination: space, monitor: monitor)
}

@MainActor private func gridNativeSwitch(display: GridNativeDisplay, destination: UInt64, monitor: MonitorInfo) async throws {
    guard display.spaces.contains(where: { $0.id == destination }) else { throw NSError(domain: "Native Space unavailable", code: 1) }
    guard destination != display.current else { return }
    if nativeDisplays()?.count == 1 && monitorInfos.count > 1 {
        throw NSError(domain: "Enable Displays have separate Spaces for independent native fullscreen navigation", code: 1)
    }
    // Target the display temporarily; restore the pointer after verified native navigation.
    let oldPoint = CGEvent(source: nil)?.location
    defer { if let oldPoint { CGWarpMouseCursorPosition(oldPoint) } }
    for _ in 0..<display.spaces.count {
        guard let current = nativeDisplays()?.first(where: { $0.id == display.id }),
              let currentIndex = current.spaces.firstIndex(where: { $0.id == current.current }),
              let destinationIndex = current.spaces.firstIndex(where: { $0.id == destination }) else { throw NSError(domain: "Display or Space disappeared during native navigation", code: 1) }
        if current.current == destination { return }
        guard AeroGridPostSpaceSwipe(monitor.rect.center, destinationIndex > currentIndex ? 1 : -1) else { throw NSError(domain: "Cannot post native space switch", code: 1) }
        var changed = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(30))
            if let now = nativeDisplays()?.first(where: { $0.id == display.id }), now.current != current.current { changed = true; break }
        }
        guard changed else { throw NSError(domain: "macOS did not accept the native Space switch", code: 1) }
        // The current Space changes before Dock finishes its transition. Posting another
        // swipe or raising a window immediately can interrupt that transition.
        try await Task.sleep(for: .milliseconds(300))
    }
    if nativeDisplays()?.first(where: { $0.id == display.id })?.current == destination { return }
    throw NSError(domain: "Native Space navigation did not reach its target", code: 1)
}

@MainActor func gridNativeVisibleWindows() -> [String: UInt32] {
    guard let displays = nativeDisplays() else { return [:] }
    var result: [String: UInt32] = [:]
    for ws in Workspace.all {
        for window in ws.macOsNativeFullscreenWindowsContainer.allLeafWindowsRecursive {
            let spaces = AeroGridCopyWindowSpaces(window.windowId) as? [NSNumber] ?? []
            for display in displays where spaces.contains(where: { $0.uint64Value == display.current }) {
                if let monitor = gridNativeMonitor(window)?.monitorId_oneBased { result[String(monitor)] = window.windowId }
            }
        }
    }
    return result
}

@MainActor func gridNormalWindow(_ workspace: Workspace) -> Window? {
    workspace.rootTilingContainer.mostRecentWindowRecursive ?? workspace.floatingWindows.first
}
