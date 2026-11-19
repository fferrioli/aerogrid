import Foundation
import GridCore

final class AeroSpaceBackend: Backend, WindowManagerControl {
    var path: String
    var diagnosticHistory: DiagnosticHistory?
    var diagnosticOperation: UUID?
    var filterDesktop: ((Desktop) throws -> Desktop)?
    init(path: String) { self.path = path }
    @discardableResult func run(_ arguments: [String]) throws -> String {
        let history = diagnosticHistory
        let command = history?.enabled == true ? BackendDiagnosticCommand(arguments) : nil
        let start = ProcessInfo.processInfo.systemUptime
        var outcome = "io"
        defer {
            if let history, let command {
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                if outcome != "ok" || command.mutates || elapsed >= 500 {
                    let repeated = diagnosticOperation == nil || (command.readOnly && outcome != "ok")
                    history.event("command", BackendDiagnosticResult(command: command.name, outcome: outcome, elapsedMs: elapsed),
                                  operation: diagnosticOperation, repeating: repeated ? "command:\(command.name):\(outcome)" : nil)
                }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aerogrid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("out"), errURL = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { outcome = "launch"; throw error }
        if finished.wait(timeout: .now() + 4) == .timedOut, process.isRunning {
            outcome = "timeout"
            process.terminate()
            if finished.wait(timeout: .now() + 0.05) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
            throw GridError.unavailable("AeroSpace command timed out: \(arguments.first ?? "")")
        }
        let text = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            outcome = "rejected"
            let error = String(decoding: try Data(contentsOf: errURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if error.contains("Can't connect to AeroSpace server") {
                outcome = "disconnected"
                throw GridError.unavailable("El servicio de AeroGrid no responde. Intentando reconectar; si continúa, usá Recuperar.")
            }
            outcome = BackendDiagnosticCommand.rejection(error)
            throw GridError.unavailable(error.isEmpty ? "AeroSpace command failed" : error)
        }
        outcome = "ok"
        return text
    }
    func desktop() throws -> Desktop {
        let history = diagnosticHistory
        let includePlacement = history?.enabled == true
        let decoder = JSONDecoder()
        do {
            let args = includePlacement ? ["grid-layout", "--data", "diagnostics", "status"] : ["grid-layout", "status"]
            let data = Data(try run(args).utf8)
            guard includePlacement, let history, history.enabled else {
                let desktop = try decoder.decode(Desktop.self, from: data)
                return try filterDesktop?(desktop) ?? desktop
            }
            let status = try decoder.decode(DiagnosticBackendStatus.self, from: data)
            let desktop = try filterDesktop?(status.desktop) ?? status.desktop
            let snapshot = DiagnosticSnapshot(desktop: desktop, placement: status.placement, aliases: history.aliases)
            history.observe(.backend, snapshot, operation: diagnosticOperation)
            return desktop
        } catch {
            if includePlacement, let history, history.enabled {
                history.observe(.backend, .unavailableBackend, operation: diagnosticOperation)
                if error is DecodingError {
                    history.event("status-decode", ["outcome": "invalid"], operation: diagnosticOperation, repeating: "status-decode")
                }
            }
            throw error
        }
    }
    func managementStatus() throws -> WindowManagerStatus {
        try JSONDecoder().decode(WindowManagerStatus.self,from:Data(run(["grid-layout","management-status"]).utf8))
    }
    func setManagementEnabled(_ enabled:Bool) throws { try run(["enable",enabled ? "on" : "off"]) }
    func validate(workspace: String, monitor: Int) throws { try run(["grid-layout", "--workspace", workspace, "--data", String(monitor), "check"]) }
    func place(workspace: String, monitor: Int) throws { try run(["move-workspace-to-monitor", "--workspace", workspace, String(monitor)]) }
    func activate(workspace: String) throws { try run(["grid-layout", "--workspace", workspace, "activate"]) }
    private func targetData(monitor: Int, window: UInt32?) throws -> String {
        var target: [String: Any] = ["monitor": monitor]
        if let window { target["window"] = window }
        return String(decoding: try JSONSerialization.data(withJSONObject: target), as: UTF8.self)
    }
    func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
        try run(["grid-layout", "--workspace", workspace, "--data", targetData(monitor: monitor, window: window), "check-target"])
    }
    func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
        try run(["grid-layout", "--workspace", workspace, "--data", targetData(monitor: monitor, window: window), "activate-target"])
    }
    func focus(monitor: Int, window: UInt32?) throws {
        if let window { try focus(window: window) } else { try run(["focus-monitor", String(monitor)]) }
    }
    func windows(workspace: String) throws -> [UInt32] {
        try run(["list-windows", "--workspace", workspace, "--format", "%{window-id}|%{app-bundle-id}"]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] != "local.AeroGrid" else { return nil }
            return UInt32(fields[0])
        }
    }
    func focus(window: UInt32) throws { try run(["focus", "--window-id", String(window)]) }
    func minimumWidths(workspace: String) throws -> [String: Double] {
        try JSONDecoder().decode([String: Double].self, from: Data(run(["grid-layout", "--workspace", workspace, "constraints"]).utf8))
    }
    func recoverWindowHomes(_ homes: [WindowHome]) throws {
        let data = try JSONEncoder().encode(homes)
        try run(["grid-layout", "--data", String(decoding: data, as: UTF8.self), "recover-homes"])
    }
    func move(window: UInt32, workspace: String) throws { try run(["move-node-to-workspace", "--window-id", String(window), workspace]) }
    func moveVerified(window: WindowIdentity, workspace: String) throws {
        let data = try JSONEncoder().encode(window)
        try run(["grid-layout", "--workspace", workspace, "--data", String(decoding: data, as: UTF8.self), "move-window"])
    }
    func moveFullscreen(window: WindowIdentity, workspace: String) throws {
        let data = try JSONEncoder().encode(window)
        try run(["grid-layout", "--workspace", workspace, "--data", String(decoding: data, as: UTF8.self), "move-fullscreen-window"])
    }
    func snapshot(workspace: String) throws -> String { try run(["grid-layout", "--workspace", workspace, "snapshot"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    func restore(workspace: String, snapshot: String) throws { try run(["grid-layout", "--workspace", workspace, "--data", snapshot, "restore"]) }
    func layout(workspace: String, profile: String) throws { try run(["grid-layout", "--workspace", workspace, profile]) }
}
