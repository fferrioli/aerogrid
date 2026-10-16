import Foundation
import CryptoKit

public struct WindowIdentity: Codable, Equatable, Hashable {
    public var id: UInt32
    public var pid: Int32
    public var boot: String
    public init(id: UInt32, pid: Int32, boot: String) { self.id = id; self.pid = pid; self.boot = boot }
}
public struct WindowInfo: Codable, Equatable, Identifiable {
    public var id: UInt32
    public var pid: Int32
    public var boot: String
    public var workspace: String
    public var floating: Bool
    public var title: String
    public var appName: String
    public var bundleID: String
    public var nativeFullscreen: Bool
    public var nativeMonitor: Int?
    public var monitor: Int?
    public var identity: WindowIdentity { WindowIdentity(id: id, pid: pid, boot: boot) }
    public init(id: UInt32, pid: Int32 = 1, boot: String = "test", workspace: String, floating: Bool = false, title: String = "Window", appName: String = "App", bundleID: String = "test", nativeFullscreen: Bool = false, nativeMonitor: Int? = nil) {
        self.id = id; self.pid = pid; self.boot = boot; self.workspace = workspace; self.floating = floating
        self.title = title; self.appName = appName; self.bundleID = bundleID
        self.nativeFullscreen = nativeFullscreen; self.nativeMonitor = nativeMonitor
    }
}
public struct LayoutNode: Codable, Equatable {
    public var id: UInt32?
    public var pid: Int32?
    public var weight: Double
    public var orientation: String?
    public var layout: String?
    public var fullscreen: Bool?
    public var children: [LayoutNode]?
    public init(id: UInt32? = nil, pid: Int32? = nil, weight: Double = 1, orientation: String? = nil, layout: String? = nil, fullscreen: Bool? = nil, children: [LayoutNode]? = nil) {
        self.id = id; self.pid = pid; self.weight = weight; self.orientation = orientation
        self.layout = layout; self.fullscreen = fullscreen; self.children = children
    }
    public var ids: [UInt32] { id.map { [$0] } ?? (children ?? []).flatMap(\.ids) }
    public var blocks: [LayoutNode] {
        if id != nil || layout == "accordion" { return ids.isEmpty ? [] : [self] }
        return (children ?? []).flatMap(\.blocks)
    }
    public func retaining(_ identities: Set<WindowIdentity>, boot: String) -> LayoutNode? {
        if let id, let pid { return identities.contains(WindowIdentity(id: id, pid: pid, boot: boot)) ? self : nil }
        var copy = self
        copy.children = (children ?? []).compactMap { $0.retaining(identities, boot: boot) }
        return copy.children?.isEmpty == false ? copy : nil
    }
    public static func root(_ children: [LayoutNode], layout: String = "tiles", orientation: String = "h") -> LayoutNode {
        LayoutNode(orientation: orientation, layout: layout, children: children)
    }
}
public struct FloatingLayout: Codable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}
public struct LayoutSnapshot: Codable, Equatable {
    public var version: Int = 1
    public var boot: String
    public var tree: LayoutNode
    public var floating: [FloatingLayout]
    public var focus: UInt32?
    public init(boot: String, tree: LayoutNode, floating: [FloatingLayout] = [], focus: UInt32? = nil) {
        self.boot = boot; self.tree = tree; self.floating = floating; self.focus = focus
    }
    public init(json: String) throws { self = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
    public func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public func merging(_ source: LayoutSnapshot, sourceOwners: Set<WindowIdentity>, targetOwners: Set<WindowIdentity>, focus: UInt32?) throws -> LayoutSnapshot {
        guard boot == source.boot else { throw GridError.stale }
        var groups: [LayoutNode] = []
        for tree in [tree.retaining(targetOwners, boot: boot), source.tree.retaining(sourceOwners, boot: boot)].compactMap({ $0 }) {
            var group = tree; group.weight = 1; groups.append(group)
        }
        let sourceFloats = source.floating.filter { sourceOwners.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: boot)) }
        let targetFloats = floating.filter { targetOwners.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: boot)) }
        let mergedTree = groups.count == 1 ? groups[0] : LayoutNode.root(groups)
        return LayoutSnapshot(boot: boot, tree: mergedTree, floating: targetFloats + sourceFloats, focus: focus)
    }
    public func block(_ node: LayoutNode, includeFloating: Bool) -> LayoutSnapshot {
        let root = node.id != nil ? LayoutNode.root([node]) : node
        return LayoutSnapshot(boot: boot, tree: root, floating: includeFloating ? floating : [], focus: node.ids.contains(focus ?? 0) ? focus : node.ids.first)
    }
}
public struct Space: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var row: Int
    public var column: Int
    public var workspace: String
    public var preferredRole: String
    public var preferredDisplay: String?
    public var sourceID: String?
    public var nativeWindow: WindowIdentity?
    public var userCreated: Bool = false
    public var joinedWhileFolded: Bool? = nil
    public var spanColumns: Int? = nil
    public var spanRows: Int? = nil
    public var boardID: String? = nil
    public var dormant: Bool? = nil
    public var automaticName: Bool? = nil
    public var foldedRect: SpaceRect? = nil
    public init(id: String = UUID().uuidString, name: String, row: Int, column: Int, workspace: String, preferredRole: String) {
        self.id = id; self.name = name; self.row = row; self.column = column
        self.workspace = workspace; self.preferredRole = preferredRole
    }
}
public struct SplitFamily: Codable, Equatable {
    public var sourceID: String
    public var original: LayoutSnapshot
    public var childIDs: [String]
    public var manuallyEdited: Bool = false
}
public struct FullscreenLink: Codable, Equatable {
    public var spaceID: String
    public var homeID: String
    public var identity: WindowIdentity
    public var original: LayoutSnapshot?
    public var manuallyEdited: Bool = false
    public var homeEdited: Bool? = nil
}
public struct MapCheckpoint: Codable, Equatable {
    public var spaces: [Space]
    public var families: [SplitFamily]
    public var fullscreens: [FullscreenLink]
    public var homes: [WindowHome]
    public var layouts: [String: String]
}
public struct OrganizationUndo: Codable, Equatable {
    public var label: String
    public var before: MapCheckpoint
    public var after: MapCheckpoint
    public var topology: String
}
public struct PendingOrganization: Codable, Equatable {
    public var before: MapCheckpoint
    public var desiredHomes: [WindowHome]
}
public struct SpaceMap: Codable, Equatable {
    public var version = 2
    public var spaces: [Space]
    public var cursors: [String: String] = [:]
    public var connectedCursors: [String: String] = [:]
    public var anchors: [String: NavigationAnchor]? = nil
    public var families: [SplitFamily] = []
    public var fullscreens: [FullscreenLink] = []
    public var layouts: [String: String] = [:]
    public var undo: [OrganizationUndo] = []
    public var pending: PendingOrganization?
    public var folded = false
    public var initialized: Bool? = nil
    public init(configuration: Configuration) {
        spaces = []
        var offset = 0
        for grid in configuration.grids {
            spaces += grid.cells.map { cell in
                Space(id: cell.id, name: cell.name, row: cell.row, column: cell.column + offset, workspace: cell.workspace, preferredRole: grid.displayRole)
            }
            offset += grid.columns + 1
        }
    }
    public static func derivedIdentity(sourceID: String, component: String) -> (id: String, workspace: String) {
        let hash = SHA256.hash(data: Data("\(sourceID)\u{0}\(component)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return ("derived-\(hash)", "grid-derived-\(hash)")
    }
    public func neighbor(from origin: Space, direction: Direction, eligible: Set<String>) -> Space? {
        candidates(from: origin, direction: direction, eligible: eligible).first
    }
    public func candidates(from origin: Space, direction: Direction, eligible: Set<String>) -> [Space] {
        let candidates = spaces.filter { $0.id != origin.id && eligible.contains($0.id) }
        switch direction {
        case .left, .right:
            return candidates.filter { $0.row == origin.row && (direction == .left ? $0.column < origin.column : $0.column > origin.column) }
                .sorted { abs($0.column - origin.column) < abs($1.column - origin.column) }
        case .up, .down:
            return candidates.filter { direction == .up ? $0.row < origin.row : $0.row > origin.row }.sorted {
                let rowA = abs($0.row - origin.row), rowB = abs($1.row - origin.row)
                if rowA != rowB { return rowA < rowB }
                let colA = abs($0.column - origin.column), colB = abs($1.column - origin.column)
                if colA != colB { return colA < colB }
                if $0.column != $1.column { return $0.column < $1.column }
                return $0.id < $1.id
            }
        }
    }
    public func vacant(near space: Space) -> (row: Int, column: Int) {
        if version >= 3 { let rect = frontier(near: space); return (rect.row, rect.column) }
        let occupied = Set(spaces.map { "\($0.row):\($0.column)" })
        for distance in 1...10000 {
            let candidates = [(space.row, space.column + distance), (space.row + distance, space.column)]
            for (row, column) in candidates where !occupied.contains("\(row):\(column)") { return (row, column) }
        }
        return (space.row + 10001, space.column)
    }
    public func validate() throws {
        guard [2,3].contains(version), !spaces.isEmpty, spaces.count <= 4096, Set(spaces.map(\.id)).count == spaces.count,
              Set(spaces.filter { !$0.isDormant }.map { version == 2 ? "\($0.row):\($0.column)" : "\($0.board):\($0.row):\($0.column)" }).count == spaces.filter({ !$0.isDormant }).count else { throw GridError.invalid("Invalid dynamic map") }
        guard spaces.allSatisfy({ $0.rect.isValid && ($0.foldedRect?.isValid ?? true) }) else { throw GridError.invalid("Invalid space bounds") }
        let adapted = spaces.filter { !$0.isDormant && $0.foldedRect != nil }
        for (index,space) in adapted.enumerated() {
            guard !adapted.dropFirst(index+1).contains(where: { space.foldedRect!.overlaps($0.foldedRect!) }) else { throw GridError.invalid("Los espacios adaptados se superponen") }
        }
        if version >= 3 {
            for space in spaces where !space.isDormant {
                guard fits(space.rect, board: space.board, excluding: [space.id]) else { throw GridError.invalid("Los casilleros se superponen o su tamaño no es válido") }
            }
        }
        guard (anchors ?? [:]).values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && ($0.frame?.isValid ?? true) }) else { throw GridError.invalid("Invalid navigation anchor") }
        let ids = Set(spaces.map(\.id))
        guard Set(fullscreens.map(\.identity)).count == fullscreens.count,
              spaces.filter({ $0.nativeWindow != nil }).allSatisfy({ space in fullscreens.contains { $0.spaceID == space.id && $0.identity == space.nativeWindow } }) else { throw GridError.invalid("Broken fullscreen identity") }
        let normalWorkspaces = spaces.filter { $0.nativeWindow == nil }.map(\.workspace)
        guard Set(normalWorkspaces).count == normalWorkspaces.count else { throw GridError.invalid("Two normal spaces share a workspace") }
        guard families.allSatisfy({ ids.contains($0.sourceID) && $0.childIDs.allSatisfy(ids.contains) }),
              fullscreens.allSatisfy({ ids.contains($0.homeID) && ids.contains($0.spaceID) }) else { throw GridError.invalid("Broken space relationships") }
        for space in spaces {
            guard (1...64).contains(space.rect.width), (1...64).contains(space.rect.height),
                  (-100000...100000).contains(space.row), (-100000...100000).contains(space.column),
                  space.workspace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw GridError.invalid("Invalid space position or workspace") }
        }
    }
}

public struct NavigationHint {
    public var name: String
    public var row: Int
    public var column: Int
    public var neighbors: [String: String]
}

public struct MergePreview: Identifiable {
    public var id = UUID().uuidString
    public var sourceID: String
    public var targetID: String
    public var sourceName: String
    public var targetName: String
    public var sourceWindows: [WindowInfo]
    public var targetWindows: [WindowInfo]
    public var sourceLayout: LayoutSnapshot
    public var targetLayout: LayoutSnapshot
    public var result: LayoutSnapshot
    public init(sourceID: String, targetID: String, sourceName: String, targetName: String, sourceWindows: [WindowInfo], targetWindows: [WindowInfo], sourceLayout: LayoutSnapshot, targetLayout: LayoutSnapshot, result: LayoutSnapshot) {
        self.sourceID = sourceID; self.targetID = targetID; self.sourceName = sourceName; self.targetName = targetName
        self.sourceWindows = sourceWindows; self.targetWindows = targetWindows
        self.sourceLayout = sourceLayout; self.targetLayout = targetLayout; self.result = result
    }
}

public struct ReunitePreview: Identifiable {
    public var id: String { sourceID }
    public var sourceID: String
    public var name: String
    public var windows: [WindowInfo]
    public var result: LayoutSnapshot
    public init(sourceID: String, name: String, windows: [WindowInfo], result: LayoutSnapshot) {
        self.sourceID = sourceID; self.name = name; self.windows = windows; self.result = result
    }
}
