import XCTest
@testable import GridCore

final class BackendLaunchPolicyTests: XCTestCase {
    func testServiceDisappearanceRecoversWithoutDuplicateOrRapidLaunches() {
        var policy = BackendLaunchPolicy()
        XCTAssertTrue(policy.request(at:0,running:false))
        XCTAssertFalse(policy.request(at:2,running:false))
        XCTAssertFalse(policy.request(at:10,running:true))
        XCTAssertTrue(policy.request(at:12,running:false))
        XCTAssertTrue(policy.request(at:22,running:false))
        XCTAssertFalse(policy.request(at:32,running:false))
        XCTAssertTrue(policy.request(at:60,running:false))
        XCTAssertFalse(policy.request(at:62,running:false))
    }
}
