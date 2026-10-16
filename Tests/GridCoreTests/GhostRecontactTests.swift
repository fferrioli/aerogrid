import XCTest
@testable import GridCore

final class GhostRecontactTests: XCTestCase {
    private func c(_ id: Int, _ x: Double, _ phase: TouchPhase = .moved) -> TouchContact {
        TouchContact(sample: TouchSample(id: String(id), x: x, y: 0.5), phase: phase)
    }
    private func feed(_ input: inout ContactFrameRecognizer, _ contacts: [TouchContact], _ time: Double, end: Bool = false) -> [ContactGestureEvent] {
        input.feed(contacts, ended: end, modifiers: 0, displayID: "display", threshold: 0.05, invert: false, timestamp: time)
    }
    private func start(_ input: inout ContactFrameRecognizer) {
        _ = feed(&input, [c(0, 0.2, .began), c(1, 0.3, .began), c(2, 0.4, .began)], 0)
        _ = feed(&input, [c(0, 0.3), c(1, 0.4), c(2, 0.5)], 0.03)
    }
    private func ends(_ events: [ContactGestureEvent]) -> Int {
        events.filter { if case .ended = $0 { return true }; return false }.count
    }
    func testUnconfirmedRecontactCannotEraseLiftEvidence() {
        var input = ContactFrameRecognizer(); start(&input)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.07)
        _ = feed(&input, [c(0, 0.41), c(1, 0.51)], 0.078)
        // A late native snapshot reports the lifted finger as a new landing once.
        _ = feed(&input, [c(0, 0.394), c(1, 0.494), c(2, 0.59, .began)], 0.083)
        _ = feed(&input, [], 0.083, end: false)
        _ = feed(&input, [c(1, 0.52, .ended)], 0.095)
        _ = feed(&input, [], 0.101, end: true)
        XCTAssertTrue(input.needsSettlement)
        XCTAssertEqual(ends(input.advance(timestamp: 0.3)), 1)
        XCTAssertTrue(input.advance(timestamp: 1).isEmpty)
    }
    func testUnconfirmedNewIdentityDoesNotCancelHeldSelection() {
        var input = ContactFrameRecognizer(); start(&input)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.07)
        let candidate = feed(&input, [c(0, 0.4), c(1, 0.5), c(3, 0.2, .began)], 0.09)
        XCTAssertTrue(candidate.isEmpty)
        XCTAssertEqual(ends(feed(&input, [c(0, 0.41, .ended), c(1, 0.51, .ended)], 0.11)), 1)
        XCTAssertEqual(ends(input.advance(timestamp: 0.4)), 0)
        // Explicit lifts close this original cohort even though the candidate vanished.
        XCTAssertFalse(input.needsSettlement)
    }
    func testRepeatedBeganSnapshotsDoNotConfirmAReplacement() {
        var input = ContactFrameRecognizer(); start(&input)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.07)
        let late = [c(0, 0.4), c(1, 0.5), c(2, 0.59, .began)]
        _ = feed(&input, late, 0.08)
        _ = feed(&input, late, 0.09)
        _ = feed(&input, [c(1, 0.51, .ended)], 0.1)
        _ = feed(&input, [], 0.11, end: true)
        XCTAssertEqual(ends(input.advance(timestamp: 0.4)), 1)
    }
    func testConfirmedReplacementPreservesMotionSinceLanding() {
        for id in [2, 3] {
            var input = ContactFrameRecognizer(); start(&input)
            _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.7)
            XCTAssertTrue(feed(&input, [c(0, 0.2), c(1, 0.3), c(id, 0.4, .began)], 0.72).isEmpty)
            let moved = feed(&input, [c(0, 0.27), c(1, 0.37), c(id, 0.47)], 0.9)
            XCTAssertEqual(moved.filter { if case .step = $0 { return true }; return false }.count, 1)
            XCTAssertEqual(ends(feed(&input, [c(0, 0.27, .ended), c(1, 0.37, .ended), c(id, 0.47, .ended)], 1)), 1)
        }
    }
    func testCandidateAndForeignEndDoNotCommitWhileTwoFingersRemainDown() {
        var input = ContactFrameRecognizer(); start(&input)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.7)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.59, .began)], 0.71)
        _ = feed(&input, [], 0.72, end: true)
        XCTAssertFalse(input.needsSettlement)
        XCTAssertTrue(input.advance(timestamp: 20).isEmpty)
    }
    func testFourFingerGhostRecontactStillCompletesOnMajorityLiftAndNativeEnd() {
        var input = ContactFrameRecognizer()
        _ = feed(&input, (0..<4).map { c($0, 0.1 * Double($0), .began) }, 0)
        _ = feed(&input, (0..<4).map { c($0, 0.1 * Double($0) + 0.1) }, 0.03)
        _ = feed(&input, [c(0, 0.2), c(1, 0.3), c(2, 0.4), c(3, 0.5, .ended)], 0.7)
        _ = feed(&input, [c(0, 0.2), c(1, 0.3), c(2, 0.4), c(3, 0.49, .began)], 0.71)
        _ = feed(&input, [c(1, 0.3, .ended), c(2, 0.4, .ended)], 0.73)
        _ = feed(&input, [], 0.74, end: true)
        XCTAssertEqual(ends(input.advance(timestamp: 1)), 1)
    }
    func testNextGestureStartsNormallyAfterGhostRecontactSettles() {
        var input = ContactFrameRecognizer(); start(&input)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.6, .ended)], 0.07)
        _ = feed(&input, [c(0, 0.4), c(1, 0.5), c(2, 0.59, .began)], 0.08)
        _ = feed(&input, [c(1, 0.51, .ended)], 0.1)
        _ = feed(&input, [], 0.11, end: true)
        XCTAssertEqual(ends(input.advance(timestamp: 0.4)), 1)
        _ = feed(&input, [c(0, 0.2, .began), c(1, 0.3, .began), c(2, 0.4, .began)], 0.5)
        let step = feed(&input, [c(0, 0.3), c(1, 0.4), c(2, 0.5)], 0.53)
        XCTAssertEqual(step.filter { if case .step = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(ends(feed(&input, [c(0, 0.3, .ended), c(1, 0.4, .ended), c(2, 0.5, .ended)], 0.55)), 1)
    }

}
