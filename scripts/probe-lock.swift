// Passive lock/fullscreen inventory. Run: swift scripts/probe-lock.swift output/lock.jsonl [interval seconds]
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    fputs("usage: swift scripts/probe-lock.swift output/lock.jsonl [seconds]\n", stderr); exit(1)
}
let interval = arguments.count == 3 ? Double(arguments[2]) ?? 0 : 10
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output", isDirectory: true).standardizedFileURL
let destination = URL(fileURLWithPath: arguments[1]).standardizedFileURL
guard interval.isFinite, interval > 0, destination.path.hasPrefix(root.path + "/") else {
    fputs("Expected an output/ destination and a positive finite interval\n", stderr); exit(1)
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
let file = try FileHandle(forWritingTo: destination)
try file.seekToEnd()

// Project only explicitly allowed fields; never persist raw CLI output or errors,
// which may contain application names, window titles, or local paths.
func command(_ operation: String) -> [String: Any] {
    let process = Process()
    process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/aerogrid-aerospace")
    process.arguments = ["grid-layout", operation]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["error": "launch failed"] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return ["error": "command failed", "exitCode": process.terminationStatus] }
    guard let decoded = try? JSONSerialization.jsonObject(with: data) else { return ["error": "invalid JSON"] }
    if operation == "native-status" { return ["displays": decoded] }
    guard let value = decoded as? [String: Any] else { return ["error": "invalid status JSON"] }
    if operation == "status" {
        let windows = (value["windows"] as? [[String: Any]] ?? []).map { row in
            row.filter { ["id", "pid", "workspace", "nativeFullscreen"].contains($0.key) }
        }.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        return ["windows": windows, "windowHomes": (value["windowHomes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }.sorted(), "nativeVisible": value["nativeVisible"] ?? [:]]
    }
    return value
}
let formatter = ISO8601DateFormatter()
var previous: Data?
var lastWrite = ProcessInfo.processInfo.systemUptime
while true {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.map { row -> [String: Any] in
        ["id": row[kCGWindowNumber as String] ?? NSNull(), "pid": row[kCGWindowOwnerPID as String] ?? NSNull(), "onscreen": row[kCGWindowIsOnscreen as String] ?? NSNull()]
    }.sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
    var record: [String: Any] = ["CGSSessionScreenIsLocked": session["CGSSessionScreenIsLocked"] ?? NSNull(), "kCGSSessionOnConsoleKey": session["kCGSSessionOnConsoleKey"] ?? NSNull(), "frontBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "cgWindows": windows, "status": command("status"), "nativeStatus": command("native-status")]
    let comparable = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    let now = ProcessInfo.processInfo.systemUptime
    if comparable != previous || now - lastWrite >= 300 {
        record["time"] = formatter.string(from: Date())
        record["heartbeat"] = comparable == previous
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(10)
        try file.write(contentsOf: line)
        previous = comparable
        lastWrite = now
    }
    // Run the main loop instead of sleeping so NSWorkspace keeps frontmostApplication current.
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
}
