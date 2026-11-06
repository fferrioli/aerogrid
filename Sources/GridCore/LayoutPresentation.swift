import Foundation

extension LayoutSnapshot {
    /// Presentation only: keep every live window reachable while layout and inventory
    /// snapshots settle. This never writes inferred geometry back to the backend.
    public func presenting(windows: [WindowInfo]) -> LayoutSnapshot {
        let owners = Set(windows.map(\.identity))
        var result = self
        result.tree = tree.retaining(owners, boot: boot) ?? .root([])
        result.floating = floating.filter { owners.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: boot)) }
        let represented = Set(result.tree.ids + result.floating.map(\.id))
        let missing = windows.filter { !represented.contains($0.id) }
        let children = result.tree.children ?? []
        let weight = children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / Double(children.count)
        result.tree.children = children + missing.map { LayoutNode(id: $0.id, pid: $0.pid, weight: weight) }
        result.boot = windows.first?.boot ?? boot
        if let focus, !windows.contains(where: { $0.id == focus }) { result.focus = nil }
        return result
    }
}
