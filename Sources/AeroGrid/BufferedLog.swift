import Foundation
import OSLog

/// Detailed gesture packets have their own buffer and retention budget.
final class BufferedLog {
    private let file: DiagnosticLogFile
    private let limit: Int
    private let queue = DispatchQueue(label: "AeroGrid.gesture-packets", qos: .utility)
    private var buffer = Data()
    private var scheduled = false
    private var enabled = true
    private var failed = false

    init(url: URL, limit: Int = 1_000_000) {
        self.limit = limit
        file = DiagnosticLogFile(url: url, limit: limit)
    }

    func json(_ packet: [String: Any]) {
        queue.async {
            guard self.enabled, var data = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]) else { return }
            data.append(10)
            self.append(data)
        }
    }

    func setEnabled(_ value: Bool, discardPending: Bool = false) {
        queue.sync {
            enabled = value
            if !value {
                if discardPending { buffer.removeAll(keepingCapacity: true) }
                else { flushBuffer() }
            }
        }
    }

    func flush() { queue.sync { flushBuffer() } }

    private func append(_ data: Data) {
        guard enabled, data.count <= limit else { return }
        if buffer.count + data.count > limit { flushBuffer() }
        buffer.append(data)
        if buffer.count >= 32_768 { flushBuffer() }
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) {
            self.scheduled = false
            self.flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        do {
            try file.append(buffer)
            failed = false
        } catch {
            if !failed { Logger(subsystem: "local.AeroGrid", category: "diagnostics").error("Could not write detailed gesture packets") }
            failed = true
        }
    }
}
