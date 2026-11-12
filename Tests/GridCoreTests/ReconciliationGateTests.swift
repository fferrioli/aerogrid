import XCTest
@testable import GridCore

final class ReconciliationGateTests: XCTestCase {
    func testInitiallyOpen() {
        var gate = ReconciliationGate()
        XCTAssertEqual(gate.settle, 3)
        XCTAssertTrue(gate.isOpen(at: 0))
        XCTAssertNil(gate.reason)
        XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: 0))
    }

    func testLockedClosesGate() {
        var gate = ReconciliationGate()
        XCTAssertFalse(gate.update(locked: true, screensAsleep: false, at: 1))
        XCTAssertFalse(gate.isOpen(at: 100))
        XCTAssertEqual(gate.reason, "locked")
    }

    func testSleepingScreensCloseUnlockedGate() {
        var gate = ReconciliationGate()
        gate.update(locked: false, screensAsleep: true, at: 1)
        XCTAssertFalse(gate.isOpen(at: 100))
        XCTAssertEqual(gate.reason, "screens-asleep")
    }

    func testSettlementOpensAtExactBoundary() {
        var gate = ReconciliationGate(settle: 2)
        gate.update(locked: true, screensAsleep: true, at: 0)
        gate.update(locked: false, screensAsleep: true, at: 1)
        XCTAssertEqual(gate.reason, "screens-asleep")
        XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: 2))
        XCTAssertEqual(gate.reason, "settling")
        XCTAssertFalse(gate.isOpen(at: 3.999))
        XCTAssertTrue(gate.isOpen(at: 4))
        XCTAssertTrue(gate.update(locked: false, screensAsleep: false, at: 4))
        XCTAssertNil(gate.reason)
    }

    func testRelockingRestartsSettlement() {
        var gate = ReconciliationGate()
        gate.update(locked: true, screensAsleep: false, at: 0)
        gate.update(locked: false, screensAsleep: false, at: 1)
        gate.update(locked: true, screensAsleep: false, at: 2)
        XCTAssertEqual(gate.reason, "locked")
        gate.update(locked: false, screensAsleep: false, at: 3)
        XCTAssertFalse(gate.isOpen(at: 4))
        XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: 5.999))
        XCTAssertTrue(gate.update(locked: false, screensAsleep: false, at: 6))
    }

    func testUpdateReportsEachReopeningExactlyOnce() {
        var gate = ReconciliationGate()
        for start: Double in [0, 10] {
            XCTAssertFalse(gate.update(locked: false, screensAsleep: true, at: start))
            XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: start + 1))
            XCTAssertTrue(gate.isOpen(at: start + 4))
            XCTAssertTrue(gate.update(locked: false, screensAsleep: false, at: start + 5))
            XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: start + 5))
            XCTAssertFalse(gate.update(locked: false, screensAsleep: false, at: start + 6))
        }
    }
}
