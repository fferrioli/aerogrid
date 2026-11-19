import Foundation
import GridCore

struct DiagnosticBackendStatus: Decodable {
    private enum CodingKeys: String, CodingKey { case placementDiagnostics }
    let desktop: Desktop
    let placement: BackendPlacementDiagnostics?

    init(from decoder: Decoder) throws {
        desktop = try Desktop(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        placement = try? fields.decodeIfPresent(BackendPlacementDiagnostics.self, forKey: .placementDiagnostics)
    }
}

struct BackendDiagnosticResult: Encodable {
    var command: String
    var outcome: String
    var elapsedMs: Int
}

struct BackendDiagnosticCommand {
    let name: String
    let readOnly: Bool
    var mutates: Bool { !readOnly }

    init(_ arguments: [String]) {
        switch arguments.first ?? "" {
        case "grid-layout":
            // Arguments include workspace names, window identities and layout JSON.
            // Use only an allowlisted operation name, never the arguments themselves.
            let operation = arguments.last ?? ""
            switch operation {
            case "status", "management-status", "snapshot", "constraints", "check", "check-target", "native-status":
                name = operation; readOnly = true
            case "activate", "activate-target", "move-window", "move-fullscreen-window", "recover-homes", "restore", "wide", "compact", "vertical", "native-focus":
                name = operation; readOnly = false
            default: name = "other"; readOnly = true
            }
        case "list-windows": name = "list-windows"; readOnly = true
        case let operation where ["focus", "focus-monitor", "move-workspace-to-monitor", "move-node-to-workspace", "enable", "macos-native-fullscreen"].contains(operation):
            name = operation; readOnly = false
        default: name = "other"; readOnly = true
        }
    }

    static func rejection(_ stderr: String) -> String {
        let message = stderr.lowercased()
        if message.contains("not ready") || message.contains("still starting") { return "notReady" }
        if message.contains("server is disabled") { return "disabled" }
        if message.contains("accessibility") { return "accessibility" }
        if message.contains("did not accept") || message.contains("cannot post native space switch") { return "nativeSwitch" }
        if message.contains("native spaces api unavailable") || message.contains("cannot match native display") { return "nativeUnavailable" }
        if message.contains("identity") || message.contains("window not found") || message.contains("space disappeared") { return "staleTarget" }
        return "rejected"
    }
}

struct DiagnosticAction: Encodable {
    struct Destination: Encodable {
        let cell: String
        let x: Double
        let y: Double
        let rect: SpaceRect?
    }
    var name: String
    var outcome: String
    var elapsedMs: Int?
    var queueMs: Int?
    var cells: [String]?
    var display: String?
    var window: String?
    var direction: String?
    var scope: String?
    var destinations: [String: Destination]?

    static func outcome(_ error: Error?) -> String {
        guard let error else { return "ok" }
        switch error {
        case GridError.invalid: return "invalid"
        case GridError.boundary: return "boundary"
        case GridError.unavailable: return "unavailable"
        case GridError.stale: return "stale"
        case is DecodingError: return "decode"
        default: return "failed"
        }
    }
}

struct DiagnosticReconciliation: Encodable {
    let event: String
    let reason: String?
    let count: Int?
    let window: String?
    let cell: String?
    let display: String?

    init(_ source: EngineDiagnosticEvent, aliases: DiagnosticAliases) {
        event = source.kind.rawValue
        reason = source.reason
        count = source.count
        window = source.window.map(aliases.window)
        cell = source.space.map { aliases.id("cell", $0) }
        display = source.display.map { aliases.id("display", $0) }
    }
}

extension DiagnosticSnapshot {
    static var unavailableBackend: Self {
        var snapshot = Self()
        snapshot.add("summary", "backend", .backend(.init(inventory: "unavailable", placement: "unavailable", nativeCatalog: "unavailable")))
        return snapshot
    }
}
