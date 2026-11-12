import Foundation

/// Suspends reconciliation until observed lock and sleep transitions have settled.
public struct ReconciliationGate {
    public var settle: TimeInterval
    private var locked = false
    private var screensAsleep = false
    private var releasedAt: TimeInterval?

    public init(settle: TimeInterval = 3) {
        self.settle = settle
    }

    /// Reports each settled reopening once, when observations are updated.
    @discardableResult
    public mutating func update(locked: Bool, screensAsleep: Bool, at now: TimeInterval) -> Bool {
        let wasBlocked = self.locked || self.screensAsleep
        self.locked = locked
        self.screensAsleep = screensAsleep
        if locked || screensAsleep {
            releasedAt = nil
            return false
        }
        if wasBlocked {
            releasedAt = now
        }
        if releasedAt != nil, isOpen(at: now) {
            releasedAt = nil
            return true
        }
        return false
    }

    public func isOpen(at now: TimeInterval) -> Bool {
        guard !locked, !screensAsleep else { return false }
        return releasedAt.map { now >= $0 + settle } ?? true
    }

    /// The last observed reason; call update to acknowledge elapsed settlement.
    public var reason: String? {
        if locked { return "locked" }
        if screensAsleep { return "screens-asleep" }
        if releasedAt != nil { return "settling" }
        return nil
    }
}
