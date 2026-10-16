import Foundation

/// Bounded local diagnostics: batch disk writes off the UI/event-tap run loop.
final class BufferedLog {
    private let url:URL
    private let limit:Int
    private let queue = DispatchQueue(label:"AeroGrid.diagnostics",qos:.utility)
    private let formatter = ISO8601DateFormatter()
    private var buffer = Data()
    private var scheduled = false
    init(url:URL,limit:Int = 1_000_000) { self.url = url; self.limit = limit }
    func text(_ message:String) {
        let date = Date()
        queue.async { self.append(Data("\(self.formatter.string(from:date)) \(message)\n".utf8)) }
    }
    func json(_ packet:[String:Any]) {
        queue.async {
            guard var data = try? JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys]) else { return }
            data.append(10); self.append(data)
        }
    }
    func flush() { queue.sync { flushBuffer() } }
    private func append(_ data:Data) {
        buffer.append(data)
        if buffer.count >= 32_768 { flushBuffer() }
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline:.now()+0.2) { self.scheduled = false; self.flushBuffer() }
    }
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let manager = FileManager.default
        // URL resource values can retain the pre-rotation size after the file is replaced.
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + buffer.count > limit {
            let previous = url.appendingPathExtension("previous")
            try? manager.removeItem(at:previous); try? manager.moveItem(at:url,to:previous)
        }
        if !manager.fileExists(atPath:url.path) { manager.createFile(atPath:url.path,contents:nil) }
        if let file = try? FileHandle(forWritingTo:url) {
            file.seekToEndOfFile(); file.write(buffer); try? file.close()
        }
        buffer.removeAll(keepingCapacity:true)
    }
}
