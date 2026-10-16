import Foundation

public enum ContactGestureEvent {
    case step(RecognizedSwipe)
    case ended
    case cancelled
}
public enum ContactPhase { case active, releasing, ended, cancelled }

/// Measures coherent strokes while touching; only explicit cohort lift commits the selection.
public struct ContactGestureRecognizer {
    private struct Motion { var x = 0.0, y = 0.0 }
    private var previous:[String:TouchSample] = [:]
    private var motion:[String:Motion] = [:]
    private var fingers = 0, modifiers = 0
    private var displayID:String?
    private var sign = 1.0
    private var locked = false, cancelled = false, releasing = false
    private var armed = true
    private var lastDirection:Direction?
    private var firstStepAt:TimeInterval?
    private var lastStepAt:TimeInterval?
    public init() {}
    var contactFingerCount: Int? { !cancelled && !previous.isEmpty ? fingers : nil }
    public mutating func reset() { self = Self() }
    mutating func rearmStroke() {
        guard locked, !releasing, !cancelled else { return }
        armed = true; motion.removeAll()
    }
    mutating func resumeContacts(_ touches:[TouchSample]) {
        guard !cancelled else { return }
        previous = Dictionary(uniqueKeysWithValues:touches.map { ($0.id,$0) })
        motion.removeAll(); releasing = false
    }
    public func canEnrollContacts(threshold:Double) -> Bool {
        let travelled = motion.values.map { max(abs($0.x),abs($0.y)) }.max() ?? 0
        return !locked && !cancelled && !releasing && travelled < threshold*0.4
    }
    public mutating func feedEvents(_ touches:[TouchSample],phase:ContactPhase = .active,
        modifiers:Int,displayID:String?,threshold:Double,invert:Bool,timestamp:TimeInterval = ProcessInfo.processInfo.systemUptime,
        stationary:Bool? = nil) -> [ContactGestureEvent] {
        var events:[ContactGestureEvent] = []
        // Final per-finger positions can arrive in separate packets. Before the first step, keep
        // measuring those positions throughout release; after it, lifting cannot add another step.
        if (phase == .ended || phase == .releasing), !locked, !cancelled {
            if let event = measure(touches,modifiers:modifiers,displayID:displayID,threshold:threshold,invert:invert,timestamp:timestamp,stationary:false) { events.append(event) }
        }
        if let event = feed(touches,phase:phase,modifiers:modifiers,displayID:displayID,threshold:threshold,invert:invert,timestamp:timestamp,stationary:stationary) { events.append(event) }
        return events
    }
    public mutating func feed(_ touches:[TouchSample],phase:ContactPhase = .active,modifiers:Int,
        displayID:String?,threshold:Double,invert:Bool,timestamp:TimeInterval = ProcessInfo.processInfo.systemUptime,
        stationary:Bool? = nil) -> ContactGestureEvent? {
        if phase == .cancelled || phase == .ended {
            let report = locked && !cancelled; reset()
            guard report else { return nil }
            return phase == .ended ? .ended : .cancelled
        }
        if phase == .releasing { releasing = true; return nil }
        guard !releasing else { return nil }
        return measure(touches,modifiers:modifiers,displayID:displayID,threshold:threshold,invert:invert,timestamp:timestamp,stationary:stationary)
    }
    private mutating func measure(_ touches:[TouchSample],modifiers:Int,displayID:String?,threshold:Double,invert:Bool,timestamp:TimeInterval,stationary:Bool?) -> ContactGestureEvent? {
        guard !touches.isEmpty, !cancelled else { return nil }
        if previous.isEmpty {
            fingers = touches.count; self.modifiers = modifiers; self.displayID = displayID
            sign = invert ? -1 : 1
        }
        defer { previous = Dictionary(uniqueKeysWithValues:touches.map { ($0.id,$0) }) }
        if touches.count != fingers {
            let travelled = motion.values.map { max(abs($0.x),abs($0.y)) }.max() ?? 0
            if !locked, touches.count > fingers, touches.count <= 4, travelled < threshold*0.4 {
                fingers = touches.count; motion.removeAll()
            } else { return cancelMotion() }
        }
        guard touches.allSatisfy({ previous[$0.id] != nil }) else {
            if locked { return cancelMotion() }
            return nil
        }
        var still = true
        for touch in touches {
            let dx = (touch.x-previous[touch.id]!.x)*sign
            let dy = (touch.y-previous[touch.id]!.y)*sign
            still = still && dx == 0 && dy == 0
            motion[touch.id,default:Motion()].x += dx
            motion[touch.id,default:Motion()].y += dy
        }
        guard [3,4].contains(fingers) else { return nil }
        if !armed && (stationary ?? still) {
            armed = true; motion.removeAll(); return nil
        }
        let dx = motion.values.reduce(0) { $0+$1.x }/Double(fingers)
        let dy = motion.values.reduce(0) { $0+$1.y }/Double(fingers)
        let horizontal = abs(dx) > abs(dy)*1.35
        let vertical = abs(dy) > abs(dx)*1.35
        let direction:Direction
        if horizontal { direction = dx > 0 ? .right : .left }
        else if vertical { direction = dy > 0 ? .up : .down }
        else { return nil }
        let reversing = lastDirection.map { Self.opposite($0) == direction } ?? false
        let turning = lastDirection.map { Self.horizontal($0) != horizontal } ?? false
        let exploring = firstStepAt.map { timestamp-$0 >= 0.5 } ?? false
        if !armed && !reversing && !turning && !exploring { motion.removeAll(); return nil }
        // A quick flick remains one step. Deliberate held exploration repeats only on
        // fresh coherent motion, at a pace that leaves each destination readable.
        if exploring && !armed && !reversing {
            if still { motion.removeAll(); return nil }
            if let lastStepAt, timestamp-lastStepAt < 0.16 { return nil }
        }
        guard (horizontal ? abs(dx) : abs(dy)) >= threshold else { return nil }
        let forward = (horizontal ? dx : dy) > 0 ? 1.0 : -1.0
        // Every enrolled finger must contribute in the selected direction. Averaging two moving
        // fingers with a stationary third must never become a three-finger swipe.
        guard touches.allSatisfy({ touch in
            guard let value = motion[touch.id] else { return false }
            return (horizontal ? value.x : value.y)*forward >= threshold*0.25
        }) else { return nil }
        locked = true; armed = false; lastDirection = direction; motion.removeAll()
        if firstStepAt == nil { firstStepAt = timestamp }
        lastStepAt = timestamp
        return .step(RecognizedSwipe(direction:direction,fingers:fingers,modifiers:self.modifiers,displayID:self.displayID))
    }
    private mutating func cancelMotion() -> ContactGestureEvent? {
        let report = locked && !cancelled; cancelled = true
        return report ? .cancelled : nil
    }
    private static func horizontal(_ direction:Direction) -> Bool { direction == .left || direction == .right }
    private static func opposite(_ direction:Direction) -> Direction {
        switch direction { case .left:return .right;case .right:return .left;case .up:return .down;case .down:return .up }
    }
}
