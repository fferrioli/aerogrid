import Foundation

public struct GestureScrollContext {
    public var fingers: Int
    public var modifiers: Int
    public init(fingers:Int,modifiers:Int) { self.fingers = fingers; self.modifiers = modifiers }
}

/// Claims trackpad scrolling from an assigned contact cohort, including its release tail.
/// Ordinary two-finger contacts, mouse wheels and a fresh scroll sequence remain independent.
public struct GestureScrollGuard {
    private var claimed = false
    private var releaseAt: TimeInterval?
    private var momentumAt: TimeInterval?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func observe(_ context:GestureScrollContext?,events:[ContactGestureEvent],bindings:[GestureBinding],enabled:Bool,timestamp:TimeInterval) {
        guard enabled else { reset(); return }
        if let context, context.fingers < 3 { reset(); return }
        let matching = bindings.filter { $0.fingers == context?.fingers && $0.modifiers == context?.modifiers }
        if context != nil && matching.isEmpty { reset(); return }
        let allDirections = Set(matching.map(\.direction)) == Set(Direction.allCases)
        let recognized = events.contains { event in
            guard case .step(let swipe) = event else { return false }
            return bindings.contains { $0.fingers == swipe.fingers && $0.modifiers == swipe.modifiers && $0.direction == swipe.direction }
        }
        if context != nil && (allDirections || recognized) {
            claimed = true; releaseAt = nil; momentumAt = nil
        } else if claimed && context == nil {
            claimed = false; releaseAt = timestamp
        }
        // A single-direction binding stays claimed after its first matching step,
        // while that same cohort remains alive; subset/release packets do not release it.
        if recognized && context == nil { releaseAt = timestamp }
    }
    public mutating func suppress(precise:Bool,began:Bool,momentum:Bool,momentumEnded:Bool,timestamp:TimeInterval) -> Bool {
        guard precise else { return false }
        if claimed { return true }
        guard let releaseAt else { return false }
        if began && !momentum { reset(); return false }
        let last = momentumAt ?? releaseAt
        guard timestamp-last <= 0.25, timestamp-releaseAt <= 3 else { reset(); return false }
        if momentum { momentumAt = timestamp }
        if momentumEnded { reset() }
        return true
    }
}
