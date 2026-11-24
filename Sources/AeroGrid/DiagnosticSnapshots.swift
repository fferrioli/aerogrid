import CryptoKit
import Foundation
import GridCore

/// The optional part of the v3 status response. Decode separately from Desktop: telemetry
/// can fail or be unavailable without affecting window management or the persisted model.
struct BackendPlacementDiagnostics: Decodable {
    struct Window: Decodable {
        var source: String
        var ownerEvidence: String?
        var frame: DiagnosticFrame?
        var onScreen: Bool?
        var nativeSpaceIDs: [UInt64]?
    }
    struct Workspace: Decodable {
        var name: String
        var monitor: Int
    }
    struct NativeDisplay: Decodable {
        struct Space: Decodable { var id: UInt64; var type: Int }
        var monitor: Int?
        var current: UInt64
        var spaces: [Space]
    }
    var windows: [String: Window]
    var workspaces: [Workspace]
    var displayFrames: [Int: DiagnosticFrame]
    var nativeDisplays: [NativeDisplay]?
    var locked: Bool
    var pendingWindowIDs: [UInt32]
    var focusHoldWorkspace: String?
    var frontmostMatchesFocusedWindowOwner: Bool?
}

struct DiagnosticFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct DiagnosticAliases {
    private let key = SymmetricKey(size: .bits256)

    func id(_ domain: String, _ value: String) -> String {
        let hash = HMAC<SHA256>.authenticationCode(for: Data("\(domain)\u{0}\(value)".utf8), using: key)
        return Data(hash.prefix(12)).base64EncodedString()
    }

    func window(_ identity: WindowIdentity) -> String {
        id("window", "\(identity.id):\(identity.pid):\(identity.boot)")
    }
}

struct DiagnosticSnapshot: Equatable {
    var tables: [String: [String: DiagnosticRow]] = [:]

    mutating func add(_ table: String, _ key: String, _ row: DiagnosticRow) {
        tables[table, default: [:]][key] = row
    }
}

enum DiagnosticRow: Encodable, Equatable {
    case backend(Backend), display(Display), window(Window), workspace(Workspace), nativeSpace(NativeSpace)
    case map(Map), cell(Cell), cursor(Cursor)

    struct Backend: Encodable, Equatable {
        var inventory: String
        var placement: String
        var nativeCatalog: String
        var session: String?
        var focusedMonitor: Int?
        var focusedWindow: String?
        var focusWindowResolved: Bool?
        var focusHoldWorkspace: String?
        var frontmostMatchesFocusedWindowOwner: Bool?
    }
    struct Display: Encodable, Equatable {
        var id: String
        var monitor: Int
        var builtin: Bool
        var usableWidth: Double
        var usableHeight: Double
        var frame: DiagnosticFrame?
        var visibleWorkspace: String?
        var nativeVisibleWindow: String?
        var nativeVisibleWindowResolved: Bool?
    }
    struct Window: Encodable, Equatable {
        var app: String?
        var workspace: String
        var workspaceMonitor: Int?
        var nativeMonitor: Int?
        var floating: Bool
        var backendFullscreen: Bool
        var nativeSpaceKind: String?
        var nativeSpaces: [String]?
        var source: String?
        var ownerEvidence: String?
        var frame: DiagnosticFrame?
        var onScreen: Bool?
    }
    struct Workspace: Encodable, Equatable {
        var monitor: Int?
        var nativeHomeMonitor: Int?
        var occupancy: String
        var normalOccupancy: String
        var windows: [String]
        var pendingHomes: [String]
    }
    struct NativeSpace: Encodable, Equatable {
        var id: String
        var displayOrdinal: Int
        var monitor: Int?
        var order: Int
        var type: Int
        var current: Bool
        var occupancy: String
        var trackedWindows: [String]
    }
    struct Map: Encodable, Equatable {
        var initialized: Bool
        var folded: Bool
        var pendingOrganization: Bool
        var combinedProjection: Bool?
    }
    struct Cell: Encodable, Equatable {
        var workspace: String
        var board: String
        var grid: String?
        var preferredDisplay: String?
        var displayRole: String
        var rect: SpaceRect
        var projectedRect: SpaceRect?
        var kind: String
        var source: String?
        var fullscreenWindow: String?
        var fullscreenHome: String?
    }
    struct Cursor: Encodable, Equatable {
        var boardRole: String?
        var space: String?
        var connectedSpace: String?
        var activeGrid: String?
        var anchorSpace: String?
        var x: Double?
        var y: Double?
        var anchorRect: SpaceRect?
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .backend(let value): try value.encode(to: encoder)
        case .display(let value): try value.encode(to: encoder)
        case .window(let value): try value.encode(to: encoder)
        case .workspace(let value): try value.encode(to: encoder)
        case .nativeSpace(let value): try value.encode(to: encoder)
        case .map(let value): try value.encode(to: encoder)
        case .cell(let value): try value.encode(to: encoder)
        case .cursor(let value): try value.encode(to: encoder)
        }
    }
}

extension DiagnosticSnapshot {
    init(desktop: Desktop, placement: BackendPlacementDiagnostics?, aliases: DiagnosticAliases) {
        let windows = desktop.windows ?? []
        let windowAliases = Dictionary(windows.map { ($0.id, aliases.window($0.identity)) }, uniquingKeysWith: { _, last in last })
        let locked = placement?.locked == true
        let nativeDisplays = placement?.nativeDisplays ?? []
        add("summary", "backend", .backend(.init(
            inventory: locked ? "locked" : desktop.windows == nil ? "unavailable" : "reported",
            placement: placement == nil ? "unavailable" : "reported",
            nativeCatalog: nativeDisplays.isEmpty ? "unavailable" : "reported",
            session: desktop.backendSession.map { aliases.id("backend", $0) },
            focusedMonitor: positive(desktop.focusedMonitor), focusedWindow: desktop.focusedWindow.flatMap { windowAliases[$0] },
            focusWindowResolved: desktop.focusedWindow.map { windowAliases[$0] != nil },
            focusHoldWorkspace: placement?.focusHoldWorkspace.map { aliases.id("workspace", $0) },
            frontmostMatchesFocusedWindowOwner: placement?.frontmostMatchesFocusedWindowOwner)))
        for display in desktop.displays {
            let nativeWindow = desktop.nativeVisible?[display.monitor]
            let key = aliases.id("display", display.id)
            add("displays", key, .display(.init(id: key,
                monitor: display.monitor, builtin: display.builtin, usableWidth: display.width, usableHeight: display.height,
                frame: placement?.displayFrames[display.monitor],
                visibleWorkspace: desktop.visible[display.monitor].map { aliases.id("workspace", $0) },
                nativeVisibleWindow: nativeWindow.flatMap { windowAliases[$0] }, nativeVisibleWindowResolved: nativeWindow.map { windowAliases[$0] != nil })))
        }

        var byWorkspace: [String: [String]] = [:]
        var normalWorkspaces = Set<String>()
        var byNativeSpace: [UInt64: [String]] = [:]
        for window in windows {
            let key = aliases.window(window.identity)
            let evidence = placement?.windows[String(window.id)]
            byWorkspace[window.workspace, default: []].append(key)
            if !window.nativeFullscreen { normalWorkspaces.insert(window.workspace) }
            for space in evidence?.nativeSpaceIDs ?? [] { byNativeSpace[space, default: []].append(key) }
            let appID = window.bundleID.isEmpty
                ? aliases.id("appProcess", "\(window.pid):\(window.boot)")
                : aliases.id("app", window.bundleID)
            let nativeKind = window.nativeSpace.flatMap { ["fullscreen", "normal", "unknown"].contains($0) ? $0 : nil }
            let source = evidence.map(\.source).flatMap { ["windowTree", "retainedHome"].contains($0) ? $0 : nil }
            let ownerEvidence = evidence?.ownerEvidence.flatMap { ["matched", "mismatched", "unavailable"].contains($0) ? $0 : nil }
            add("windows", key, .window(.init(app: appID, workspace: aliases.id("workspace", window.workspace),
                workspaceMonitor: positive(window.monitor), nativeMonitor: positive(window.nativeMonitor), floating: window.floating,
                backendFullscreen: window.nativeFullscreen, nativeSpaceKind: nativeKind,
                nativeSpaces: evidence?.nativeSpaceIDs?.map { aliases.id("nativeSpace", String($0)) },
                source: source, ownerEvidence: ownerEvidence, frame: evidence?.frame, onScreen: evidence?.onScreen)))
        }

        let monitors = Dictionary((placement?.workspaces ?? []).map { ($0.name, $0.monitor) }, uniquingKeysWith: { _, last in last })
        let pendingIDs = Set(placement?.pendingWindowIDs ?? [])
        let pending = (desktop.windowHomes ?? []).filter { pendingIDs.contains($0.id) }
        let pendingByWorkspace = Dictionary(grouping: pending, by: \.workspace)
        let canReportEmpty = desktop.windows != nil && placement != nil && !locked
        let knownWorkspaces = Set(monitors.keys).union(desktop.visible.values).union(byWorkspace.keys).union(pendingByWorkspace.keys)
        for workspace in knownWorkspaces {
            let members = byWorkspace[workspace, default: []].sorted()
            let homes = pendingByWorkspace[workspace, default: []].map { aliases.window(.init(id: $0.id, pid: $0.pid, boot: $0.boot)) }.sorted()
            add("workspaces", aliases.id("workspace", workspace), .workspace(.init(monitor: positive(monitors[workspace]),
                nativeHomeMonitor: positive(desktop.nativeHomes?[workspace]),
                occupancy: workspaceOccupancy(tracked: !members.isEmpty, pending: !homes.isEmpty, canReportEmpty: canReportEmpty),
                normalOccupancy: workspaceOccupancy(tracked: normalWorkspaces.contains(workspace), pending: !homes.isEmpty, canReportEmpty: canReportEmpty),
                windows: members, pendingHomes: homes)))
        }
        for (displayIndex, display) in nativeDisplays.enumerated() {
            for (spaceIndex, space) in display.spaces.enumerated() {
                let members = byNativeSpace[space.id, default: []].sorted()
                let id = aliases.id("nativeSpace", String(space.id))
                add("nativeSpaces", "\(displayIndex):\(id)", .nativeSpace(.init(id: id, displayOrdinal: displayIndex,
                    monitor: positive(display.monitor), order: spaceIndex, type: space.type, current: display.current == space.id,
                    occupancy: members.isEmpty ? "unattributed" : "trackedWindows", trackedWindows: members)))
            }
        }
    }

    init(map: SpaceMap, configuration: Configuration, desktop: Desktop?, activeGrids: [String: String], aliases: DiagnosticAliases) {
        let combined = desktop.map { $0.displays.count == 1 }
        add("summary", "map", .map(.init(initialized: map.initialized == true, folded: map.folded,
            pendingOrganization: map.pending != nil, combinedProjection: combined)))
        let gridByCell = Dictionary(configuration.grids.flatMap { grid in grid.cells.map { ($0.id, grid.id) } }, uniquingKeysWith: { _, last in last })
        let projected = combined == true ? Dictionary(map.projectedSpaces(combined: true).map { ($0.id, $0.rect) }, uniquingKeysWith: { _, last in last }) : [:]
        let fullscreenHomes = Dictionary(map.fullscreens.map { ($0.spaceID, $0.homeID) }, uniquingKeysWith: { _, last in last })
        for space in map.spaces {
            let kind: String
            if space.nativeWindow != nil { kind = "fullscreen" }
            else if space.hiddenFullscreenHome == true { kind = "hiddenFullscreenHome" }
            else if space.isDormant { kind = "reserved" }
            else if space.userCreated { kind = "userCreated" }
            else { kind = "normal" }
            add("cells", aliases.id("cell", space.id), .cell(.init(workspace: aliases.id("workspace", space.workspace),
                board: aliases.id("board", space.board), grid: gridByCell[space.id].map { aliases.id("grid", $0) },
                preferredDisplay: space.preferredDisplay.map { aliases.id("display", $0) },
                displayRole: role(space.preferredRole, aliases: aliases), rect: space.rect, projectedRect: projected[space.id], kind: kind,
                source: space.sourceID.map { aliases.id("cell", $0) }, fullscreenWindow: space.nativeWindow.map(aliases.window),
                fullscreenHome: fullscreenHomes[space.id].map { aliases.id("cell", $0) })))
        }
        let connected = desktop?.displays ?? []
        let configuredRoles = Dictionary(configuration.displayAssignments.map { ($0.value, $0.key) }, uniquingKeysWith: { _, last in last })
        let displayRoles = Dictionary(connected.map { ($0.id, configuredRoles[$0.id] ?? ($0.builtin ? "builtin" : "external")) },
                                      uniquingKeysWith: { _, last in last })
        let displayIDs = Set(map.cursors.keys).union(map.connectedCursors.keys)
            .union(map.anchors?.keys.map { $0 } ?? []).union(activeGrids.keys).union(displayRoles.keys)
        for display in displayIDs {
            let anchor = map.anchors?[display]
            add("cursors", aliases.id("display", display), .cursor(.init(boardRole: displayRoles[display].map { role($0, aliases: aliases) },
                space: map.cursors[display].map { aliases.id("cell", $0) },
                connectedSpace: map.connectedCursors[display].map { aliases.id("cell", $0) }, activeGrid: activeGrids[display].map { aliases.id("grid", $0) },
                anchorSpace: anchor.map { aliases.id("cell", $0.spaceID) }, x: anchor?.x, y: anchor?.y, anchorRect: anchor?.frame)))
        }
    }
}

private func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }

private func workspaceOccupancy(tracked: Bool, pending: Bool, canReportEmpty: Bool) -> String {
    if tracked { return "trackedWindows" }
    if pending { return "pendingHomes" }
    return canReportEmpty ? "reportedEmpty" : "unavailable"
}

private func role(_ value: String, aliases: DiagnosticAliases) -> String {
    ["builtin", "external"].contains(value) ? value : aliases.id("role", value)
}
