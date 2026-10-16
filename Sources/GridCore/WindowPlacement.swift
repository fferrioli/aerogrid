import Foundation

public enum WindowPlacement: String, CaseIterable, Codable {
    case left, right, top, bottom, stack
    public var label: String {
        switch self {
        case .left: return "A la izquierda"
        case .right: return "A la derecha"
        case .top: return "Arriba"
        case .bottom: return "Abajo"
        case .stack: return "Apilar"
        }
    }
}

extension LayoutSnapshot {
    /// Both preview and commit use this operation, wrapping only the chosen subtree.
    public func placing(_ incoming: LayoutNode, beside targetIDs: Set<UInt32>, placement: WindowPlacement) throws -> LayoutSnapshot {
        guard let id = incoming.id, let pid = incoming.pid, !targetIDs.isEmpty, !targetIDs.contains(id) else { throw GridError.stale }
        var result = self
        func remove(_ node: LayoutNode) -> LayoutNode? {
            if node.id == id { return nil }
            guard node.id == nil else { return node }
            var copy = node
            copy.children = (node.children ?? []).compactMap(remove)
            return copy.children?.isEmpty == false ? copy : nil
        }
        var inserted = false
        func insert(_ node: LayoutNode) -> LayoutNode {
            if Set(node.ids) == targetIDs {
                inserted = true
                var existing = node, incoming = incoming
                existing.weight = 1; incoming.weight = 1
                let before = placement == .left || placement == .top
                var group = LayoutNode.root(before ? [incoming, existing] : [existing, incoming],
                    layout: placement == .stack ? "accordion" : "tiles",
                    orientation: placement == .top || placement == .bottom ? "v" : "h")
                group.weight = node.weight
                return group
            }
            var copy = node; copy.children = node.children?.map(insert); return copy
        }
        guard let remaining = remove(tree) else { throw GridError.stale }
        result.tree = insert(remaining)
        guard inserted else { throw GridError.invalid("El grupo cambió; elegí nuevamente el destino") }
        result.floating.removeAll { $0.id == id && $0.pid == pid }
        result.focus = id
        return result
    }
}
