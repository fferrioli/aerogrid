import Darwin
import Foundation

enum LoginSession {
    static func consoleLoginDate() -> Date? {
        let user = NSUserName()
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let pointer = getutxent() {
            var entry = pointer.pointee
            guard entry.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: &entry.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: &entry.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let date = Date(timeIntervalSince1970: Double(entry.ut_tv.tv_sec) + Double(entry.ut_tv.tv_usec) / 1_000_000)
            latest = max(latest ?? date, date)
        }
        return latest
    }
}
