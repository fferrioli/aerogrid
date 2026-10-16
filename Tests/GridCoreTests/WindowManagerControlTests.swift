import XCTest
@testable import GridCore

final class WindowManagerControlTests: XCTestCase {
    final class Control: WindowManagerControl {
        var enabled = true, ready = true, ignoreChanges = false, failAfterChange = false
        var changes: [Bool] = []
        func managementStatus() throws -> WindowManagerStatus { .init(enabled:enabled,ready:ready) }
        func setManagementEnabled(_ value:Bool) throws {
            changes.append(value)
            if !ignoreChanges { enabled = value }
            if failAfterChange && changes.count == 1 { throw GridError.unavailable("Lost acknowledgement") }
        }
    }
    func testPauseAndResumeControlTheActualEngineAndVerifyBeforePublishing() throws {
        let backend = Control()
        var acknowledged: [Bool] = []
        try WindowManagerSession.setPaused(true,backend:backend) { acknowledged.append(backend.enabled) }
        XCTAssertFalse(backend.enabled)
        try WindowManagerSession.setPaused(false,backend:backend) { acknowledged.append(backend.enabled) }
        XCTAssertTrue(backend.enabled)
        XCTAssertEqual(acknowledged,[false,true]); XCTAssertEqual(backend.changes,[false,true])
    }
    func testUnacknowledgedTransitionRestoresPreviousEngineState() {
        let backend = Control(); backend.failAfterChange = true
        var persisted = false
        XCTAssertThrowsError(try WindowManagerSession.setPaused(true,backend:backend) { persisted = true })
        XCTAssertTrue(backend.enabled); XCTAssertFalse(persisted)
        XCTAssertEqual(backend.changes,[false,true])
    }
    func testResumeRefreshFailureRestoresThePausedEngine() {
        let backend = Control(); backend.enabled = false
        XCTAssertThrowsError(try WindowManagerSession.setPaused(false,backend:backend) { throw GridError.stale })
        XCTAssertFalse(backend.enabled); XCTAssertEqual(backend.changes,[true,false])
    }
    func testRejectedChangeNeverRunsPersistenceAndNotReadyDoesNotMutate() {
        let backend = Control(); backend.ignoreChanges = true
        var persisted = false
        XCTAssertThrowsError(try WindowManagerSession.setPaused(true,backend:backend) { persisted = true })
        XCTAssertFalse(persisted); XCTAssertTrue(backend.enabled)
        backend.ready = false; backend.changes.removeAll()
        XCTAssertThrowsError(try WindowManagerSession.setPaused(true,backend:backend))
        XCTAssertTrue(backend.changes.isEmpty)
    }
    func testAlreadyPausedReconciliationDoesNotToggleTheEngine() throws {
        let backend = Control(); backend.enabled = false
        try WindowManagerSession.setPaused(true,backend:backend)
        XCTAssertTrue(backend.changes.isEmpty)
        let restored = try JSONDecoder().decode(WindowManagerPreferences.self,from:JSONEncoder().encode(WindowManagerPreferences(paused:true)))
        XCTAssertTrue(restored.paused)
    }
}
