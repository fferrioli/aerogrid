import GridCore
import XCTest
@testable import AeroGrid

final class ReconciliationDecisionTests: XCTestCase {
    func testClosedTicksNeverRefreshAndReopeningRecoversOnce() {
        var gate = ReconciliationGate(settle: 3)
        var refreshes = 0
        var recoveries = 0
        for tick in 0..<20 {
            let reopened = gate.update(locked: tick < 10, screensAsleep: false, at: Double(tick))
            switch reconciliationDecision(open: gate.isOpen(at: Double(tick)), reopened: reopened) {
            case .wait: break
            case .refresh: refreshes += 1
            case .recover: recoveries += 1
            }
            if tick < 13 { XCTAssertEqual(refreshes, 0); XCTAssertEqual(recoveries, 0) }
        }
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(refreshes, 6)
    }
}
