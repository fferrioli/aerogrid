import XCTest
@testable import GridCore

/// Regressions from the independent review, including the observed interleaved-lift sequence.
final class GestureReviewRegressionTests: XCTestCase {
    private func c(_ id: Int, _ x: Double, _ p: TouchPhase = .moved) -> TouchContact {
        TouchContact(sample: TouchSample(id: "f\(id)", x: x + Double(id) * 0.1, y: 0.5), phase: p)
    }
    private func three(_ x: Double, _ p: TouchPhase = .moved) -> [TouchContact] { (0..<3).map { c($0, x, p) } }
    private func feed(_ r: inout ContactFrameRecognizer, _ cs: [TouchContact], _ t: Double, ended: Bool = false, invert: Bool) -> [ContactGestureEvent] {
        r.feed(cs, ended: ended, modifiers: 0, displayID: "d", threshold: 0.0401, invert: invert, timestamp: t)
    }
    private func steps(_ e: [ContactGestureEvent]) -> Int { e.filter { if case .step = $0 { return true }; return false }.count }
    private func cancelled(_ e: [ContactGestureEvent]) -> Bool { e.contains { if case .cancelled = $0 { return true }; return false } }
    private func ended(_ e: [ContactGestureEvent]) -> Bool { e.contains { if case .ended = $0 { return true }; return false } }

    /// P0-1: with the user's real config (invert=true) one 300 ms flick must still be one step.
    func testInvertedFlickIsOneStep() {
        for invert in [false, true] {
            var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
            e += feed(&r, three(0.1, .began), 0, invert: invert)
            for i in 1...18 { e += feed(&r, three(0.1 + Double(i) * 0.02), Double(i) * 0.016, invert: invert) }
            e += feed(&r, three(0.46, .ended), 0.3, invert: invert)
            XCTAssertEqual(steps(e), 1, "invert=\(invert)")
            XCTAssertTrue(ended(e), "invert=\(invert)")
        }
    }
    /// P0-1 (other half): immediate physical reversal must return to origin with invert=true too.
    func testInvertedImmediateReversal() {
        var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
        e += feed(&r, three(0.3, .began), 0, invert: true)
        var x = 0.3, t = 0.0
        for dx in [0.03, 0.03, -0.03, -0.03, -0.03] { x += dx; t += 0.03; e += feed(&r, three(x), t, invert: true) }
        XCTAssertEqual(steps(e), 2)
    }
    /// P0-2: exact packet shape observed at t=10347.377-.424 in diagnostics.log.
    func testStaleFullFrameAfterPartialLiftStillCommits() {
        var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
        let x = 0.36
        e += feed(&r, three(0.30, .began), 0.290, invert: false)
        e += feed(&r, three(0.35), 0.340, invert: false)
        e += feed(&r, three(x), 0.357, invert: false)
        e += feed(&r, [c(0, x, .ended), c(1, x), c(2, x)], 0.377, invert: false)
        e += feed(&r, [c(1, x), c(2, x)], 0.385, invert: false)
        e += feed(&r, three(x), 0.390, invert: false)                 // stale frame
        e += feed(&r, [c(1, x, .ended), c(2, x)], 0.393, invert: false)
        e += feed(&r, [c(2, x)], 0.401, invert: false)
        e += feed(&r, [c(2, x, .ended)], 0.416, invert: false)
        e += feed(&r, [], 0.424, ended: true, invert: false)
        XCTAssertFalse(cancelled(e)); XCTAssertTrue(ended(e)); XCTAssertEqual(steps(e), 1)
    }
    /// P1-3: one missing finger in a single packet (absence is not a lift) must not kill the gesture.
    func testSubsetPacketBeforeFirstStepIsNotRelease() {
        var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
        e += feed(&r, three(0.30, .began), 0, invert: false)
        e += feed(&r, three(0.31), 0.016, invert: false)
        e += feed(&r, [c(1, 0.312), c(2, 0.312)], 0.024, invert: false)
        e += feed(&r, three(0.33), 0.032, invert: false)
        e += feed(&r, three(0.38), 0.048, invert: false)
        e += feed(&r, three(0.38, .ended), 0.08, invert: false)
        XCTAssertEqual(steps(e), 1); XCTAssertTrue(ended(e))
    }
    /// P1-4: a foreign empty packet whose NSEvent phase is .ended must not commit while the cohort is down.
    func testForeignEmptyEndedPacketDoesNotEndCohort() {
        var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
        e += feed(&r, three(0.30, .began), 0, invert: false)
        e += feed(&r, three(0.35), 0.03, invert: false)
        let early = feed(&r, [], 0.05, ended: true, invert: false)
        XCTAssertFalse(ended(early), "lift inferred from an empty foreign packet")
        e += feed(&r, three(0.36), 0.40, invert: false)
        e += feed(&r, three(0.36, .ended), 0.45, invert: false)
        XCTAssertTrue(ended(e))
    }
    /// P1-5: two moving fingers + a stationary non-resting third contact must not select (no coherent 3-finger motion).
    func testTwoMovingFingersWithStationaryThirdContactDoesNotStep() {
        var r = ContactFrameRecognizer(); var e: [ContactGestureEvent] = []
        let thumb = { (p: TouchPhase) in TouchContact(sample: TouchSample(id: "thumb", x: 0.5, y: 0.05), phase: p) }
        e += feed(&r, [c(0, 0.3, .began), c(1, 0.3, .began)], 0, invert: false)
        e += feed(&r, [c(0, 0.3, .stationary), c(1, 0.3, .stationary), thumb(.began)], 0.05, invert: false)
        for i in 1...6 { e += feed(&r, [c(0, 0.3 + Double(i) * 0.03), c(1, 0.3 + Double(i) * 0.03), thumb(.stationary)], 0.05 + Double(i) * 0.016, invert: false) }
        XCTAssertEqual(steps(e), 0)
    }
}

extension GestureReviewRegressionTests {
    func testQuickStrokeNeverRepeatsBeforeHeldExploration() {
        for invert in [false,true] {
            var r = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
            events += feed(&r,three(0.1,.began),0,invert:invert)
            for index in 1...20 { events += feed(&r,three(0.1+Double(index)*0.015),Double(index)/60,invert:invert) }
            events += feed(&r,three(0.4,.ended),0.4,invert:invert)
            XCTAssertEqual(steps(events),1,"invert=\(invert)")
            XCTAssertTrue(ended(events))
        }
    }
    func testSeparateHeldStrokesWithNoPacketsWhilePaused() {
        for invert in [false,true] {
            var r = ContactFrameRecognizer()
            _ = feed(&r,three(0.1,.began),0,invert:invert)
            XCTAssertEqual(steps(feed(&r,three(0.16),0.02,invert:invert)),1)
            _ = feed(&r,three(0.2),0.04,invert:invert)
            // No contact packets are generated while the fingers remain still.
            XCTAssertEqual(steps(feed(&r,three(0.26),0.7,invert:invert)),1)
        }
    }
    func testSlowSparseContinuousStrokeDoesNotMistakeItsOwnCadenceForPause() {
        var r = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
        events += feed(&r,three(0.1,.began),0,invert:true)
        for index in 1...3 { events += feed(&r,three(0.1+Double(index)*0.06),Double(index)*0.2,invert:true) }
        XCTAssertEqual(steps(events),1)
    }
    func testFinalMotionSpreadAcrossSubsetLiftPacketsCanStillSelect() {
        for invert in [false,true] {
            var r = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
            events += feed(&r,three(0.1,.began),0,invert:invert)
            events += feed(&r,[c(0,0.18,.ended)],0.06,invert:invert)
            events += feed(&r,[c(1,0.18,.ended)],0.07,invert:invert)
            events += feed(&r,[c(2,0.18,.ended)],0.08,invert:invert)
            XCTAssertEqual(steps(events),1)
            XCTAssertTrue(ended(events)); XCTAssertFalse(cancelled(events))
        }
    }
    func testTrailingSnapshotAfterAllLiftsCannotStartGhostGesture() {
        var r = ContactFrameRecognizer()
        _ = feed(&r,three(0.1,.began),0,invert:true)
        _ = feed(&r,three(0.16),0.02,invert:true)
        XCTAssertTrue(ended(feed(&r,three(0.16,.ended),0.04,invert:true)))
        XCTAssertTrue(feed(&r,three(0.16),0.05,invert:true).isEmpty)
        XCTAssertTrue(feed(&r,three(0.3),0.07,invert:true).isEmpty)
        _ = feed(&r,three(0.1,.began),0.2,invert:true) // Explicit landing allows identity reuse.
        XCTAssertEqual(steps(feed(&r,three(0.16),0.22,invert:true)),1)
    }
    func testGlobalCancellationAndEmptyEndedPacketsCannotInterruptHold() {
        var r = ContactFrameRecognizer()
        _ = feed(&r,three(0.1,.began),0,invert:true)
        _ = feed(&r,three(0.16),0.02,invert:true)
        let foreign = r.feed([],cancelled:true,modifiers:0,displayID:"d",threshold:0.0401,invert:true,timestamp:0.03)
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertTrue(feed(&r,[],0.04,ended:true,invert:true).isEmpty)
        XCTAssertTrue(ended(feed(&r,three(0.16,.ended),0.1,invert:true)))
    }
    func testSubsetLandingOfFourthFingerDoesNotCancelOrChangeScope() {
        var r = ContactFrameRecognizer()
        _ = feed(&r,[c(0,0.1,.began),c(1,0.1,.began),c(2,0.1,.began)],0,invert:true)
        XCTAssertTrue(feed(&r,[c(3,0.1,.began)],0.01,invert:true).isEmpty)
        let result = feed(&r,(0..<4).map { c($0,0.18) },0.03,invert:true)
        guard case .step(let swipe)? = result.first else { return XCTFail("Missing four-finger step") }
        XCTAssertEqual(swipe.fingers,4); XCTAssertEqual(swipe.direction,.left)
    }
}

extension GestureReviewRegressionTests {
    func testAllAxesAndFingerScopesWithInversionAndInterleavedLift() {
        for fingers in [3,4] { for invert in [false,true] { for axis in [0,1] { for sign in [-1.0,1.0] {
            var r = ContactFrameRecognizer(), result:[ContactGestureEvent] = []
            func packet(_ distance:Double,_ phase:TouchPhase = .moved,_ endedID:Int? = nil) -> [TouchContact] {
                (0..<fingers).map { id in
                    let sample = TouchSample(id:String(id),x:0.4+(axis == 0 ? distance*sign : 0),y:0.4+(axis == 1 ? distance*sign : 0))
                    return TouchContact(sample:sample,phase:id == endedID ? .ended : phase)
                }
            }
            result += r.feed(packet(0,.began),modifiers:4,displayID:"original",threshold:0.05,invert:invert,timestamp:0)
            result += r.feed(packet(0.08),modifiers:0,displayID:"other",threshold:0.05,invert:!invert,timestamp:0.02)
            // Inversion is frozen when the contacts land, like scope and target.
            for id in 0..<fingers {
                result += r.feed(packet(0.08,.moved,id),modifiers:0,displayID:"other",threshold:0.05,invert:invert,timestamp:0.05+Double(id)*0.02)
                result += r.feed(packet(0.08),modifiers:0,displayID:"other",threshold:0.05,invert:invert,timestamp:0.06+Double(id)*0.02)
            }
            let direction:Direction = axis == 0 ? ((sign > 0) != invert ? .right : .left) : ((sign > 0) != invert ? .up : .down)
            let swipes = result.compactMap { if case .step(let swipe) = $0 { return swipe };return nil }
            XCTAssertEqual(swipes.count,1); XCTAssertEqual(swipes.first?.direction,direction)
            XCTAssertEqual(swipes.first?.fingers,fingers); XCTAssertEqual(swipes.first?.modifiers,4)
            XCTAssertEqual(swipes.first?.displayID,"original"); XCTAssertTrue(ended(result)); XCTAssertFalse(cancelled(result))
        } } } }
    }
}
