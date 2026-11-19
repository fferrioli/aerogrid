import Foundation

public struct EngineDiagnosticEvent {
    public enum Kind: String {
        case fullscreenDoubt = "fullscreen-doubt"
        case fullscreenReturn = "fullscreen-return"
        case fullscreenReturnFailed = "fullscreen-return-failed"
        case fullscreenExit = "fullscreen-exit"
        case fullscreenRemoved = "fullscreen-removed"
        case fullscreenUnplaced = "fullscreen-unplaced"
        case fullscreenCreated = "fullscreen-created"
        case fullscreenRestored = "fullscreen-restored"
        case inventoryBlackout = "inventory-blackout"
        case inventoryRecovered = "inventory-recovered"
        case spaceWoken = "space-woken"
        case spaceDormant = "space-dormant"
        case spaceAdopted = "space-adopted"
        case foldSkipped = "fold-skipped"
        case topologyChanged = "topology-changed"
        case backendRestarted = "backend-restarted"
        case adaptedGeometryRepaired = "adapted-geometry-repaired"
        case familyFolded = "family-folded"
        case familyReunited = "family-reunited"
        case organizationRecovery = "organization-recovery"
        case navigationMismatch = "navigation-mismatch"
        case navigationRollback = "navigation-rollback"
        case focusMismatch = "focus-mismatch"
    }

    public let kind: Kind
    public let reason: String?
    public let count: Int?
    public let window: WindowIdentity?
    public let space: String?
    public let display: String?

    // Retain the core's existing textual event projection for callers that consume it.
    var legacyDescription: String {
        var fields = [kind.rawValue]
        if let reason { fields.append("\(kind == .fullscreenDoubt ? "kind" : "reason")=\(reason)") }
        if let count, kind != .foldSkipped { fields.append("count=\(count)") }
        if let window { fields += ["window=\(window.id)", "pid=\(window.pid)"] }
        if let space { fields.append("space=\(space.prefix(8))") }
        if let count, kind == .foldSkipped { fields.append("block=\(count)") }
        return fields.joined(separator: " ")
    }
}
