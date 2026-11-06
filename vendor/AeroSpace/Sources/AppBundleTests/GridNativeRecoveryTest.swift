@testable import AppBundle
import XCTest

final class GridNativeRecoveryTest: XCTestCase {
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
