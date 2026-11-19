import Foundation
import OSLog

struct DiagnosticsPreference {
    static let key = "diagnostics.localHistoryEnabled"
    let defaults: UserDefaults

    var enabled: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }
    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Self.key) }
}

/// Records share a session and sequence, while snapshot bases are independent per stream.
final class DiagnosticHistory {
    enum Stream: String { case backend, map }

    private struct Record<Payload: Encodable>: Encodable {
        let schema = 1
        let session: UUID
        let sequence: UInt64
        let at: String
        let kind: String
        let operation: UUID?
        let payload: Payload
    }
    private struct SnapshotRecord: Encodable {
        var mode: String
        var base: UInt64?
        var rows: [String: [String: DiagnosticRow]]
        var removed: [String: [String]]? = nil
    }
    private struct Baseline {
        var snapshot: DiagnosticSnapshot
        var sequence: UInt64
        var lastCheckpoint: TimeInterval
    }

    let aliases = DiagnosticAliases()
    private let queue = DispatchQueue(label: "AeroGrid.diagnostic-history", qos: .utility)
    private let recording: LockedFlag
    private let file: DiagnosticLogFile
    private let encoder = JSONEncoder()
    private let formatter = ISO8601DateFormatter()
    private let session = UUID()
    private let checkpointInterval: TimeInterval
    private var sequence: UInt64 = 0
    private var baselines: [Stream: Baseline] = [:]
    private var lastRepeated: [String: TimeInterval] = [:]
    private var failed = false

    init(directory: URL, enabled: Bool, limit: Int = 8 * 1024 * 1024, checkpointInterval: TimeInterval = 120) {
        recording = LockedFlag(enabled)
        file = DiagnosticLogFile(url: directory.appendingPathComponent("history.jsonl"), limit: limit)
        self.checkpointInterval = checkpointInterval
        encoder.outputFormatting = [.sortedKeys]
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var enabled: Bool { recording.value }

    func setEnabled(_ value: Bool) {
        if !value { recording.value = false }
        queue.sync {
            baselines.removeAll()
            lastRepeated.removeAll()
            if value { recording.value = true }
        }
    }

    func flush() { queue.sync {} }

    func event<Payload: Encodable>(_ kind: String, _ payload: Payload, operation: UUID? = nil, repeating key: String? = nil) {
        guard enabled else { return }
        let at = Date(), uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard self.enabled else { return }
            if let key, let last = self.lastRepeated[key], uptime - last < 30 { return }
            if self.write(kind, payload, operation: operation, at: at), let key {
                self.lastRepeated[key] = uptime
            }
        }
    }

    func observe(_ stream: Stream, _ snapshot: DiagnosticSnapshot, operation: UUID? = nil,
                 uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        let at = Date()
        queue.async {
            guard self.enabled else { return }
            self.observeOnQueue(stream, snapshot, operation: operation, at: at, uptime: uptime)
        }
    }

    private func observeOnQueue(_ stream: Stream, _ snapshot: DiagnosticSnapshot, operation: UUID?, at: Date, uptime: TimeInterval) {
        let baseline = baselines[stream]
        let payload: SnapshotRecord
        if let baseline, uptime - baseline.lastCheckpoint < checkpointInterval {
            guard snapshot != baseline.snapshot else { return }
            var rows: [String: [String: DiagnosticRow]] = [:], removed: [String: [String]] = [:]
            for (table, entries) in snapshot.tables {
                let changed = entries.filter { baseline.snapshot.tables[table]?[$0.key] != $0.value }
                if !changed.isEmpty { rows[table] = changed }
            }
            for (table, entries) in baseline.snapshot.tables {
                let deleted = entries.keys.filter { snapshot.tables[table]?[$0] == nil }.sorted()
                if !deleted.isEmpty { removed[table] = deleted }
            }
            payload = SnapshotRecord(mode: "delta", base: baseline.sequence, rows: rows, removed: removed.isEmpty ? nil : removed)
        } else {
            payload = SnapshotRecord(mode: "checkpoint", rows: snapshot.tables)
        }
        if write(stream.rawValue, payload, operation: operation, at: at),
           payload.base == nil || baselines[stream] != nil {
            let time = payload.base == nil ? uptime : (baseline?.lastCheckpoint ?? uptime)
            baselines[stream] = Baseline(snapshot: snapshot, sequence: sequence, lastCheckpoint: time)
        }
    }

    @discardableResult private func write<Payload: Encodable>(_ kind: String, _ payload: Payload, operation: UUID?, at: Date) -> Bool {
        do {
            let record = Record(session: session, sequence: sequence + 1, at: formatter.string(from: at), kind: kind, operation: operation, payload: payload)
            var data = try encoder.encode(record)
            data.append(10)
            if try file.append(data) { baselines.removeAll(keepingCapacity: true) }
            sequence += 1
            failed = false
            return true
        } catch {
            if !failed { Logger(subsystem: "local.AeroGrid", category: "diagnostics").error("Could not write local diagnostic history") }
            failed = true
            return false
        }
    }
}
