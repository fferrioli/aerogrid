import Foundation

public struct TouchSample {
    public var id: String; public var x: Double; public var y: Double
    public init(id: String, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}
public struct RecognizedSwipe {
    public var direction: Direction; public var fingers: Int; public var modifiers: Int; public var displayID: String?
    public init(direction:Direction,fingers:Int,modifiers:Int,displayID:String?) {
        self.direction = direction; self.fingers = fingers; self.modifiers = modifiers; self.displayID = displayID
    }
}
public struct SwipeRecognizer {
    private var previous: [String: TouchSample] = [:]
    private var fingers = 0, modifiers = 0
    private var displayID: String?
    private var dx = 0.0, dy = 0.0
    private var fired = false, cancelled = false
    public init() {}
    public mutating func reset() { self = SwipeRecognizer() }
    public mutating func feed(_ touches: [TouchSample], modifiers: Int, displayID: String?, threshold: Double, invert: Bool) -> RecognizedSwipe? {
        if touches.isEmpty { reset(); return nil }
        if previous.isEmpty {
            fingers = touches.count; self.modifiers = modifiers; self.displayID = displayID
        }
        if touches.count != fingers {
            // Fingers land at slightly different times. Admit extra fingers before motion locks in.
            if !fired, touches.count > fingers, touches.count <= 4, max(abs(dx), abs(dy)) < threshold * 0.4 {
                fingers = touches.count; dx = 0; dy = 0
            } else { cancelled = true }
        }
        if touches.count > 4 { cancelled = true }
        defer { previous = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, $0) }) }
        guard !cancelled, !fired, [3,4].contains(fingers), touches.allSatisfy({ previous[$0.id] != nil }) else { return nil }
        dx += touches.reduce(0) { $0 + $1.x - previous[$1.id]!.x } / Double(fingers)
        dy += touches.reduce(0) { $0 + $1.y - previous[$1.id]!.y } / Double(fingers)
        let horizontal = abs(dx) > abs(dy) * 1.35
        let vertical = abs(dy) > abs(dx) * 1.35
        guard (horizontal && abs(dx) >= threshold) || (vertical && abs(dy) >= threshold) else { return nil }
        fired = true
        let sign = invert ? -1.0 : 1.0
        let direction: Direction = horizontal ? (dx * sign > 0 ? .right : .left) : (dy * sign > 0 ? .up : .down)
        return RecognizedSwipe(direction: direction, fingers: fingers, modifiers: self.modifiers, displayID: self.displayID)
    }
}
