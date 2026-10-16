import XCTest
@testable import GridCore

/// Round-2 review probes. Each test PRINTS the observed outcome; assertions encode the behaviour
/// the brief asks for, so a failing assertion = divergence (bug or policy needing acceptance).
final class GestureReviewRound2Tests: XCTestCase {
    let thr = 0.0401
    private func c(_ id: Int, _ x: Double, _ y: Double = 0.5, _ p: TouchPhase = .moved, resting: Bool = false) -> TouchContact {
        TouchContact(sample: TouchSample(id: "f\(id)", x: x + Double(id) * 0.1, y: y), phase: p, resting: resting)
    }
    private func three(_ x: Double, _ y: Double = 0.5, _ p: TouchPhase = .moved) -> [TouchContact] { (0..<3).map { c($0, x, y, p) } }
    private func feed(_ r: inout ContactFrameRecognizer, _ cs: [TouchContact], _ t: Double, invert: Bool = true) -> [ContactGestureEvent] {
        r.feed(cs, modifiers: 0, displayID: "d", threshold: thr, invert: invert, timestamp: t)
    }
    private func names(_ e: [ContactGestureEvent]) -> [String] {
        e.map { switch $0 { case .step(let s): return s.direction.rawValue; case .ended: return "ENDED"; case .cancelled: return "CANCELLED" } }
    }
    private func steps(_ e: [ContactGestureEvent]) -> [String] { names(e).filter { $0 != "ENDED" && $0 != "CANCELLED" } }

    /// R2-1: held exploration that turns a corner (right, then down) without a frame in which
    /// ALL three fingers report .stationary. Old 300 ms rule allowed the second step; now none.
    func testR2_1_LTurnWithoutFullStationaryFrameLosesSecondStep() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        var t = 0.0, x = 0.3, y = 0.6
        e += feed(&r, three(x, y, .began), t)
        for _ in 0..<8 { t += 0.016; x += 0.008; e += feed(&r, three(x, y), t) }   // ~0.064 right
        // curve: decelerate x, start y (one finger always reports .moved)
        for i in 0..<30 { t += 0.016; x += max(0, 0.004 - Double(i) * 0.0004); y -= min(0.004, Double(i) * 0.0004); e += feed(&r, three(x, y), t) }
        e += feed(&r, three(x, y, .ended), t + 0.02)
        XCTAssertEqual(steps(e).count, 2, "corner turn while holding should explore a second axis")
    }

    /// R2-2: slow continuous held drag (the way the old, buggy invert=true build behaved: one step
    /// every threshold of travel). New design: one step per held stroke without a stationary frame.
    func testR2_2_SlowContinuousHeldDragExploresAfterArming() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        var t = 0.0, x = 0.2
        e += feed(&r, three(x, 0.5, .began), t)
        for _ in 0..<90 { t += 0.016; x += 0.003; e += feed(&r, three(x), t) }        // 0.27 over 1.44 s
        e += feed(&r, three(x, 0.5, .ended), t + 0.02)
        XCTAssertGreaterThan(steps(e).count, 1) // User requested continuous held exploration.
    }

    /// R2-3: an off-cadence packet mid-stroke (e.g. a resting thumb landing) in which the three
    /// members legitimately report .stationary rearms a continuous fast flick -> two steps.
    func testR2_3_OffCadenceStationaryPacketMidStrokeRearms() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        var t = 0.0, x = 0.2
        e += feed(&r, three(x, 0.5, .began), t)
        for i in 0..<12 {
            t += 0.008; x += 0.012; e += feed(&r, three(x), t)
            if i == 5 { // same positions, 2 ms later, plus a resting thumb landing
                e += feed(&r, three(x, 0.5, .stationary) + [TouchContact(sample: TouchSample(id: "thumb", x: 0.5, y: 0.05), phase: .began, resting: true)], t + 0.002)
            }
        }
        e += feed(&r, three(x, 0.5, .ended), t + 0.01)
        XCTAssertEqual(steps(e).count, 1, "one continuous stroke must stay one step")
    }

    /// R2-4: resting thumb becomes non-resting while the three fingers are lifting.
    func testR2_4_RestingThumbFlipDuringReleaseCancelsSelection() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        let thumb = { (rest: Bool, p: TouchPhase) in TouchContact(sample: TouchSample(id: "thumb", x: 0.5, y: 0.05), phase: p, resting: rest) }
        e += feed(&r, three(0.3, 0.5, .began) + [thumb(true, .stationary)], 0)
        e += feed(&r, three(0.36) + [thumb(true, .stationary)], 0.03)
        e += feed(&r, [c(0, 0.36, 0.5, .ended), c(1, 0.36), c(2, 0.36), thumb(true, .stationary)], 0.06)
        e += feed(&r, [c(1, 0.36, 0.5, .ended), c(2, 0.36), thumb(false, .moved)], 0.07)  // thumb reclassified
        e += feed(&r, [c(2, 0.36, 0.5, .ended), thumb(false, .moved)], 0.08)
        XCTAssertTrue(names(e).contains("ENDED"), "selection should commit; thumb was present all along")
    }

    /// R2-6: one-finger contact whose .ended is lost poisons the next 3-finger gesture.
    func testR2_6_ZombieSingleContactSwallowsNextGesture() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        e += feed(&r, [TouchContact(sample: TouchSample(id: "z", x: 0.5, y: 0.5), phase: .began)], 0)
        e += feed(&r, [], 0.2)                     // its terminal packet never arrives
        var t = 1.0, x = 0.2
        e += feed(&r, three(x, 0.5, .began), t)
        for _ in 0..<8 { t += 0.016; x += 0.01; e += feed(&r, three(x), t) }
        e += feed(&r, three(x, 0.5, .ended), t + 0.02)
        XCTAssertEqual(steps(e).count, 1)
    }

    /// R2-7: quick consecutive flicks that overlap: next cohort lands while the last finger of the previous is still down.
    func testR2_7_OverlappingConsecutiveFlicksLoseBoth() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        e += feed(&r, three(0.3, 0.5, .began), 0)
        e += feed(&r, three(0.36), 0.03)
        e += feed(&r, [c(0, 0.36, 0.5, .ended), c(1, 0.36, 0.5, .ended), c(2, 0.36)], 0.06)
        let n = { (id: Int, x: Double, p: TouchPhase) in TouchContact(sample: TouchSample(id: "n\(id)", x: x + Double(id) * 0.1, y: 0.5), phase: p) }
        e += feed(&r, [c(2, 0.36), n(0, 0.3, .began), n(1, 0.3, .began), n(2, 0.3, .began)], 0.07)
        e += feed(&r, [c(2, 0.36, 0.5, .ended), n(0, 0.31, .moved), n(1, 0.31, .moved), n(2, 0.31, .moved)], 0.08)
        for i in 1...6 { e += feed(&r, (0..<3).map { n($0, 0.31 + Double(i) * 0.012, .moved) }, 0.08 + Double(i) * 0.016) }
        e += feed(&r, (0..<3).map { n($0, 0.4, .ended) }, 0.2)
        XCTAssertEqual(names(e), ["left", "ENDED", "left", "ENDED"])
    }

    /// R2-8: median of intervals is polluted by fast off-cadence landing packets (3-4 ms). A single
    /// 30 ms hiccup (< 2 cadence frames) in continuous motion right after the first step rearms.
    func testR2_8_GapMedianSkewedByLandingPackets() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        e += feed(&r, [c(0, 0.2, 0.5, .began)], 0)
        e += feed(&r, [c(0, 0.2), c(1, 0.2, 0.5, .began)], 0.003)
        e += feed(&r, [c(0, 0.2), c(1, 0.2), c(2, 0.2, 0.5, .began)], 0.006)
        e += feed(&r, three(0.2, 0.5, .stationary), 0.009)
        var t = 0.009, x = 0.2
        for _ in 0..<3 { t += 0.016; x += 0.015; e += feed(&r, three(x), t) }   // first step here
        t += 0.030; x += 0.020; e += feed(&r, three(x), t)                         // 30 ms hiccup, still moving
        for _ in 0..<4 { t += 0.016; x += 0.015; e += feed(&r, three(x), t) }
        e += feed(&r, three(x, 0.5, .ended), t + 0.01)
        XCTAssertEqual(steps(e).count, 1)
    }

    /// R2-10: a held cohort that macOS reclassifies as resting while still (as ContactFrameTests models).
    func testR2_10_HeldFingersBecomeRestingThenMoveAgain() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        e += feed(&r, three(0.2, 0.5, .began), 0)
        e += feed(&r, three(0.26), 0.03)
        for i in 0..<10 { e += feed(&r, three(0.26, 0.5, .stationary).map { TouchContact(sample: $0.sample, phase: .stationary, resting: true) }, 0.05 + Double(i) * 0.016) }
        var t = 0.21, x = 0.26
        for _ in 0..<5 { t += 0.016; x += 0.012; e += feed(&r, three(x), t) }
        XCTAssertEqual(steps(e).count, 2)
    }
}
