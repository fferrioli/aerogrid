import Foundation
import GridCore

final class AeroSpaceBackend: Backend, WindowManagerControl {
    var path: String
    init(path: String) { self.path = path }
    @discardableResult func run(_ arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aerogrid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("out"), errURL = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw GridError.unavailable("AeroSpace command timed out: \(arguments.first ?? "")")
        }
        let text = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let error = String(decoding: try Data(contentsOf: errURL), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if error.contains("Can't connect to AeroSpace server") {
                throw GridError.unavailable("El servicio de AeroGrid no responde. Intentando reconectar; si continúa, usá Recuperar.")
            }
            throw GridError.unavailable(error.isEmpty ? "AeroSpace command failed" : error)
        }
        return text
    }
    func desktop() throws -> Desktop { try JSONDecoder().decode(Desktop.self, from: Data(run(["grid-layout", "status"]).utf8)) }
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
    func snapshot(workspace: String) throws -> String { try run(["grid-layout", "--workspace", workspace, "snapshot"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    func restore(workspace: String, snapshot: String) throws { try run(["grid-layout", "--workspace", workspace, "--data", snapshot, "restore"]) }
    func layout(workspace: String, profile: String) throws { try run(["grid-layout", "--workspace", workspace, profile]) }
}
