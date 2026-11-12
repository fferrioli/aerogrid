@testable import AppBundle
import XCTest

final class GridNativeRecoveryTest: XCTestCase {
    func testRetentionDecision() {
        XCTAssertTrue(gridShouldRetainFullscreenHome(fullscreen: true, explicitClose: false, terminated: false, owned: true))
        XCTAssertFalse(gridShouldRetainFullscreenHome(fullscreen: false, explicitClose: false, terminated: false, owned: true))
        XCTAssertFalse(gridShouldRetainFullscreenHome(fullscreen: true, explicitClose: true, terminated: false, owned: true))
        XCTAssertFalse(gridShouldRetainFullscreenHome(fullscreen: true, explicitClose: false, terminated: true, owned: true))
        XCTAssertFalse(gridShouldRetainFullscreenHome(fullscreen: true, explicitClose: false, terminated: false, owned: false))
    }

    func testPendingHomePruning() {
        var policy = GridPendingHomePruning()
        func sample(_ now: Double, alive: Bool = true, boot: Bool = true, owner: Bool = false, locked: Bool = false) -> Bool {
            policy.shouldDiscard(processAlive: alive, sameBoot: boot, ownerMatches: owner, locked: locked, now: now)
        }
        XCTAssertTrue(sample(0, alive: false))
        XCTAssertTrue(sample(0, boot: false))
        XCTAssertFalse(sample(0))
        XCTAssertFalse(sample(9))
        XCTAssertTrue(sample(10))
        XCTAssertFalse(sample(11, locked: true))
        XCTAssertFalse(sample(100, locked: true))
        XCTAssertFalse(sample(101))
        XCTAssertFalse(sample(110))
        XCTAssertTrue(sample(111))
        XCTAssertFalse(sample(112, owner: true))
        XCTAssertFalse(sample(120))
    }

    func testDeferredWindowNeedsCurrentBootMatchingOwnerAndNativeDisplay() {
        let home = GridWindowHome(id: 99, pid: 4, boot: "current", workspace: "editor", floating: false)
        let valid = GridNativeRecoveryEvidence(boot: "current", owners: [99: 4], monitors: [99: 2])
        XCTAssertTrue(valid.validates(home))
        XCTAssertFalse(GridNativeRecoveryEvidence(boot: "other", owners: [99: 4], monitors: [99: 2]).validates(home))
        XCTAssertFalse(GridNativeRecoveryEvidence(boot: "current", owners: [99: 5], monitors: [99: 2]).validates(home))
        XCTAssertFalse(GridNativeRecoveryEvidence(boot: "current", owners: [:], monitors: [99: 2]).validates(home))
        XCTAssertFalse(GridNativeRecoveryEvidence(boot: "current", owners: [99: 4], monitors: [:]).validates(home))
    }
    func testDeferredFullscreenInventoryKeepsItsHomeAndExactDisplay() throws {
        let home = GridWindowHome(id: 99, pid: 4, boot: "current", workspace: "editor", floating: false)
        let pending = GridDeferredNativeWindow(home: home, monitor: 2, appName: "Browser", bundleID: "test.browser")
        // Exercise the wire payload used by the organizer before AX discovery.
        let data = try JSONSerialization.data(withJSONObject: pending.inventory)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["id"] as? Int, 99)
        XCTAssertEqual(value["pid"] as? Int, 4)
        XCTAssertEqual(value["workspace"] as? String, "editor")
        XCTAssertEqual(value["nativeFullscreen"] as? Bool, true)
        XCTAssertEqual(value["nativeMonitor"] as? Int, 2)
        XCTAssertEqual(value["appName"] as? String, "Browser")
        XCTAssertTrue(pending.matches(workspace: "editor", monitor: 2))
        XCTAssertFalse(pending.matches(workspace: "other", monitor: 2))
        XCTAssertFalse(pending.matches(workspace: "editor", monitor: 1))
    }
}
