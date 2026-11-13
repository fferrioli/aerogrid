import Foundation

public struct TemplateSlot: Codable, Hashable {
    public var bundleID: String
    public var ordinal: Int

    public init(bundleID: String, ordinal: Int) {
        self.bundleID = bundleID
        self.ordinal = ordinal
    }
}

public struct TemplateNode: Codable, Equatable {
    public var weight: Double
    public var orientation: String?
    public var layout: String?
    public var slot: TemplateSlot?
    public var children: [TemplateNode]?

    public init(weight: Double = 1, orientation: String? = nil, layout: String? = nil, slot: TemplateSlot? = nil, children: [TemplateNode]? = nil) {
        self.weight = weight
        self.orientation = orientation
        self.layout = layout
        self.slot = slot
        self.children = children
    }

    fileprivate var slots: [TemplateSlot] {
        slot.map { [$0] } ?? (children ?? []).flatMap(\.slots)
    }

    fileprivate func instantiate(_ assignment: [TemplateSlot: WindowIdentity]) -> LayoutNode? {
        if let slot {
            guard let window = assignment[slot] else { return nil }
            return LayoutNode(id: window.id, pid: window.pid, weight: weight, orientation: orientation, layout: layout)
        }
        let children = (children ?? []).compactMap { $0.instantiate(assignment) }
        guard !children.isEmpty else { return nil }
        return LayoutNode(weight: weight, orientation: orientation, layout: layout, children: children)
    }
}

public struct TemplateFloating: Codable, Equatable {
    public var slot: TemplateSlot
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(slot: TemplateSlot, x: Double, y: Double, width: Double, height: Double) {
        self.slot = slot
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PlaceTemplate: Codable, Equatable {
    public var version = 1
    public var tree: TemplateNode
    public var floating: [TemplateFloating]
    public var fullscreen: TemplateSlot?
    public var capturedAt: Date

    public init(version: Int = 1, tree: TemplateNode, floating: [TemplateFloating] = [], fullscreen: TemplateSlot? = nil, capturedAt: Date) {
        self.version = version
        self.tree = tree
        self.floating = floating
        self.fullscreen = fullscreen
        self.capturedAt = capturedAt
    }

    public static func capture(snapshot: LayoutSnapshot, windows: [WindowInfo], now: Date) -> PlaceTemplate? {
        let bundles = Dictionary(windows.map { (WindowKey(id: $0.id, pid: $0.pid), $0.bundleID) }, uniquingKeysWith: { first, _ in first })
        var ordinals: [String: Int] = [:]

        func captureSlot(id: UInt32, pid: Int32) -> TemplateSlot? {
            guard let bundleID = bundles[WindowKey(id: id, pid: pid)], !bundleID.isEmpty else { return nil }
            let ordinal = ordinals[bundleID, default: 0]
            ordinals[bundleID] = ordinal + 1
            return TemplateSlot(bundleID: bundleID, ordinal: ordinal)
        }

        func captureNode(_ node: LayoutNode) -> TemplateNode? {
            if let id = node.id {
                guard let pid = node.pid, let slot = captureSlot(id: id, pid: pid) else { return nil }
                return TemplateNode(weight: node.weight, orientation: node.orientation, layout: node.layout, slot: slot)
            }
            let children = (node.children ?? []).compactMap(captureNode)
            guard !children.isEmpty else { return nil }
            return TemplateNode(weight: node.weight, orientation: node.orientation, layout: node.layout, children: children)
        }

        let tree = captureNode(snapshot.tree)
        let floating = snapshot.floating.compactMap { window -> TemplateFloating? in
            guard let slot = captureSlot(id: window.id, pid: window.pid) else { return nil }
            return TemplateFloating(slot: slot, x: window.x, y: window.y, width: window.width, height: window.height)
        }
        guard tree != nil || !floating.isEmpty else { return nil }
        let emptyRoot = TemplateNode(weight: snapshot.tree.weight, orientation: snapshot.tree.orientation, layout: snapshot.tree.layout, children: [])
        return PlaceTemplate(tree: tree ?? emptyRoot, floating: floating, capturedAt: now)
    }

    public static func fullscreen(slot: TemplateSlot, capturedAt: Date) -> PlaceTemplate {
        PlaceTemplate(tree: TemplateNode(orientation: "h", layout: "tiles", children: []), fullscreen: slot, capturedAt: capturedAt)
    }

    public var slots: [TemplateSlot] {
        tree.slots + floating.map(\.slot) + (fullscreen.map { [$0] } ?? [])
    }

    public func instantiate(_ assignment: [TemplateSlot: WindowIdentity], boot: String) -> LayoutSnapshot? {
        var restoredTree = tree.instantiate(assignment)
        let floating = floating.compactMap { item -> FloatingLayout? in
            guard let window = assignment[item.slot] else { return nil }
            return FloatingLayout(id: window.id, pid: window.pid, x: item.x, y: item.y, width: item.width, height: item.height)
        }
        if let fullscreen, let window = assignment[fullscreen] {
            let leaf = LayoutNode(id: window.id, pid: window.pid, fullscreen: true)
            if var root = restoredTree {
                if root.id != nil {
                    root = .root([root, leaf])
                } else {
                    root.children = (root.children ?? []) + [leaf]
                }
                restoredTree = root
            } else {
                restoredTree = .root([leaf])
            }
        }
        guard restoredTree != nil || !floating.isEmpty else { return nil }
        let emptyRoot = LayoutNode(weight: tree.weight, orientation: tree.orientation, layout: tree.layout, children: [])
        return LayoutSnapshot(boot: boot, tree: restoredTree ?? emptyRoot, floating: floating)
    }
}

private struct WindowKey: Hashable {
    let id: UInt32
    let pid: Int32
}

public struct CandidateWindow: Equatable {
    public var identity: WindowIdentity
    public var bundleID: String
    public var workspace: String

    public init(identity: WindowIdentity, bundleID: String, workspace: String) {
        self.identity = identity
        self.bundleID = bundleID
        self.workspace = workspace
    }
}

public struct PlaceTarget: Equatable {
    public var spaceID: String
    public var workspace: String
    public var template: PlaceTemplate

    public init(spaceID: String, workspace: String, template: PlaceTemplate) {
        self.spaceID = spaceID
        self.workspace = workspace
        self.template = template
    }
}

public struct PlaceAssignment: Equatable {
    public var window: WindowIdentity
    public var spaceID: String
    public var slot: TemplateSlot
    public var fullscreen: Bool

    public init(window: WindowIdentity, spaceID: String, slot: TemplateSlot, fullscreen: Bool) {
        self.window = window
        self.spaceID = spaceID
        self.slot = slot
        self.fullscreen = fullscreen
    }
}

public enum PlaceMatcher {
    public static func assign(candidates: [CandidateWindow], targets: [PlaceTarget], present: [CandidateWindow]) -> [PlaceAssignment] {
        let candidates = candidates.sorted(by: windowOrder)
        let candidateIDs = Set(candidates.map(\.identity))
        let present = present.filter { !candidateIDs.contains($0.identity) }.sorted(by: windowOrder)
        let slots = targets.map { target in
            target.template.slots.enumerated().sorted {
                if $0.element.ordinal != $1.element.ordinal { return $0.element.ordinal < $1.element.ordinal }
                return $0.offset < $1.offset
            }.map(\.element)
        }
        var occupied = targets.map { _ in Set<TemplateSlot>() }
        var usedWindows = Set<WindowIdentity>()
        var assignments: [PlaceAssignment] = []

        // Existing, ineligible windows fulfill places before candidates claim any.
        for (index, target) in targets.enumerated() {
            for window in present where window.workspace == target.workspace && !usedWindows.contains(window.identity) {
                guard let slot = slots[index].first(where: { $0.bundleID == window.bundleID && !occupied[index].contains($0) }) else { continue }
                occupied[index].insert(slot)
                usedWindows.insert(window.identity)
            }
        }

        func assign(_ window: CandidateWindow, to slot: TemplateSlot, targetIndex: Int) {
            let target = targets[targetIndex]
            occupied[targetIndex].insert(slot)
            usedWindows.insert(window.identity)
            assignments.append(PlaceAssignment(window: window.identity, spaceID: target.spaceID, slot: slot, fullscreen: target.template.fullscreen == slot))
        }

        // Reserve every candidate already at home before assigning cross-workspace moves.
        for (index, target) in targets.enumerated() {
            for window in candidates where window.workspace == target.workspace && !usedWindows.contains(window.identity) {
                guard let slot = slots[index].first(where: { $0.bundleID == window.bundleID && !occupied[index].contains($0) }) else { continue }
                assign(window, to: slot, targetIndex: index)
            }
        }

        for index in targets.indices {
            for slot in slots[index] where !occupied[index].contains(slot) {
                guard let window = candidates.first(where: { $0.bundleID == slot.bundleID && !usedWindows.contains($0.identity) }) else { continue }
                assign(window, to: slot, targetIndex: index)
            }
        }
        return assignments
    }

    private static func windowOrder(_ lhs: CandidateWindow, _ rhs: CandidateWindow) -> Bool {
        if lhs.identity.id != rhs.identity.id { return lhs.identity.id < rhs.identity.id }
        if lhs.identity.pid != rhs.identity.pid { return lhs.identity.pid < rhs.identity.pid }
        if lhs.identity.boot != rhs.identity.boot { return lhs.identity.boot < rhs.identity.boot }
        if lhs.bundleID != rhs.bundleID { return lhs.bundleID < rhs.bundleID }
        return lhs.workspace < rhs.workspace
    }
}
