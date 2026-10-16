import Foundation

/// Recover a vanished owned service without creating a rapid restart loop.
public struct BackendLaunchPolicy {
    private var attempts: [TimeInterval] = []
    public init() {}

    public mutating func request(at now: TimeInterval, running: Bool) -> Bool {
        attempts.removeAll { now - $0 >= 60 }
        guard !running, attempts.count < 3,
              attempts.last.map({ now - $0 >= 10 }) ?? true else { return false }
        attempts.append(now)
        return true
    }
}
