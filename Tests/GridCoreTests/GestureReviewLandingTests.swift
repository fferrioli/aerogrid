import XCTest
@testable import GridCore

final class GestureReviewLandingTests: XCTestCase {
    private func c(_ id: Int, _ x: Double, _ p: TouchPhase = .moved) -> TouchContact {
        TouchContact(sample: TouchSample(id: "f\(id)", x: x + Double(id) * 0.1, y: 0.5), phase: p)
    }
    private func three(_ x: Double, _ p: TouchPhase = .moved) -> [TouchContact] { (0..<3).map { c($0, x, p) } }
    private func names(_ e: [ContactGestureEvent]) -> [String] {
        e.map { switch $0 { case .step(let s): return s.direction.rawValue; case .ended: return "ENDED"; case .cancelled: return "CANCELLED" } }
    }
    /// Landing burst of 5 off-cadence packets (3 ms) and a fast first step: upper median = 3 ms, gap = 18 ms.
    func testR2_8b_LandingBurstMakesOneLateCadenceFrameARearm() {
        var r = ContactFrameRecognizer(), e: [ContactGestureEvent] = []
        func f(_ cs: [TouchContact], _ t: Double) { e += r.feed(cs, modifiers: 0, displayID: "d", threshold: 0.0401, invert: true, timestamp: t) }
        f([c(0, 0.2, .began)], 0)
        f([c(0, 0.2), c(1, 0.2, .began)], 0.003)
        f([c(0, 0.2), c(1, 0.2), c(2, 0.2, .began)], 0.006)
        f(three(0.2, .stationary), 0.009)
        f(three(0.2, .stationary), 0.012)
        f(three(0.2, .stationary), 0.015)
        var t = 0.015, x = 0.2
        for d in [0.008, 0.008, 0.020, 0.008, 0.008, 0.008] { t += d; x += 0.025; f(three(x), t) }
        f(three(x, .ended), t + 0.008)
        XCTAssertEqual(names(e).filter { $0 == "left" }.count, 1)
    }
}
