import XCTest
@testable import GridCore

final class FakeBackend: Backend {
    var screen: Desktop
    var members: [String: [UInt32]] = [:]
    var constraints: [String: [String: Double]] = [:]
    var calls: [String] = []
    var snapshots: [String: String] = [:]
    var failWorkspace: String?
    var invalidWorkspace: String?
    var failMoveWindow: UInt32?
    var changeTopologyOnActivation = false
    init(_ desktop: Desktop) { screen = desktop }
    func desktop() throws -> Desktop { screen }
    func validate(workspace: String, monitor: Int) throws { if workspace == invalidWorkspace { throw GridError.invalid("Assignment blocked") } }
    func place(workspace: String, monitor: Int) throws {
        calls.append("place:\(workspace):\(monitor)")
        if workspace == failWorkspace { throw GridError.unavailable("Injected placement failure") }
        screen.visible[monitor] = workspace
    }
    func activate(workspace: String) throws {
        calls.append("activate:\(workspace)")
        screen.focusedMonitor = screen.visible.first { $0.value == workspace }?.key ?? 1
        if changeTopologyOnActivation { screen.displays.removeLast(); changeTopologyOnActivation = false }
    }
    func focus(monitor: Int, window: UInt32?) throws { screen.focusedMonitor = monitor; screen.focusedWindow = window; calls.append("focus:\(monitor)") }
    func windows(workspace: String) throws -> [UInt32] { members[workspace] ?? [] }
    func minimumWidths(workspace: String) throws -> [String: Double] { constraints[workspace] ?? [:] }
    func recoverWindowHomes(_ homes: [WindowHome]) throws {
        calls.append("recover-homes")
        for home in homes { try move(window: home.id, workspace: home.workspace) }
        screen.windowHomes = homes
    }
    func focus(window: UInt32) throws { screen.focusedWindow = window }
    func move(window: UInt32, workspace: String) throws {
        if window == failMoveWindow { throw GridError.unavailable("Injected migration failure") }
        for key in members.keys { members[key]?.removeAll { $0 == window } }
        members[workspace, default: []].append(window)
    }
    func snapshot(workspace: String) throws -> String { snapshots[workspace] ?? "tree:\(workspace)" }
    func restore(workspace: String, snapshot: String) throws { calls.append("restore:\(workspace):\(snapshot)"); snapshots[workspace] = snapshot }
    func layout(workspace: String, profile: String) throws { calls.append("layout:\(workspace):\(profile)"); snapshots[workspace] = profile }
}

final class EngineTests: XCTestCase {
    var config: Configuration!
    var backend: FakeBackend!
    var engine: Engine!
    var laptop: Display { Display(id: "laptop-screen", monitor: 1, name: "MacBook", builtin: true, width: 1470, height: 920) }
    var ultra: Display { Display(id: "ultra-screen", monitor: 2, name: "Ultrawide", builtin: false, width: 3440, height: 1440) }
    override func setUpWithError() throws {
        config = Configuration(backendPath: "/unused")
        backend = FakeBackend(Desktop(displays: [laptop, ultra], visible: [1: config.grids[0].cells[4].workspace, 2: config.grids[1].cells[4].workspace], focusedMonitor: 1, focusedWindow: 42))
        engine = try Engine(configuration: config, backend: backend)
        try engine.refresh(); backend.calls = []
    }
    func testActiveScopeLeavesOtherMonitorUntouched() throws {
        let original = backend.screen.visible[1]
        try engine.navigate(.right, scope: .active, displayID: ultra.id)
        XCTAssertEqual(backend.screen.visible[1], original)
        XCTAssertEqual(backend.screen.visible[2], config.grids[1].cells[5].workspace)
        XCTAssertEqual(backend.screen.focusedMonitor, 2)
    }
    func testAllScopePreservesIndependentCoordinatesAndOriginFocus() throws {
        try engine.navigate(.left, scope: .active, displayID: ultra.id)
        try engine.navigate(.up, scope: .all, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], config.grids[0].cells[1].workspace)
        XCTAssertEqual(backend.screen.visible[2], config.grids[1].cells[0].workspace)
        XCTAssertEqual(backend.screen.focusedMonitor, 1)
    }
    func testBoundaryPreflightMovesNone() throws {
        try engine.navigate(.left, scope: .active, displayID: ultra.id)
        backend.calls = []; let before = backend.screen
        XCTAssertThrowsError(try engine.navigate(.left, scope: .all, displayID: laptop.id))
        XCTAssertEqual(backend.screen, before)
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("place:") })
    }
    func testPartialFailureRollsBackBothDisplays() throws {
        let before = backend.screen
        backend.failWorkspace = config.grids[1].cells[5].workspace
        XCTAssertThrowsError(try engine.navigate(.right, scope: .all, displayID: laptop.id))
        XCTAssertEqual(backend.screen.visible, before.visible)
        XCTAssertEqual(backend.screen.focusedMonitor, before.focusedMonitor)
        XCTAssertEqual(engine.observed?.visible, before.visible)
    }
    func testAssignmentPreflightDoesNotSwitchAnyDisplay() throws {
        backend.invalidWorkspace = config.grids[1].cells[5].workspace
        let before = backend.screen
        XCTAssertThrowsError(try engine.navigate(.right, scope: .all, displayID: laptop.id))
        XCTAssertEqual(backend.screen, before)
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testTopologyChangeCancelsRemainingMoves() throws {
        backend.changeTopologyOnActivation = true
        XCTAssertThrowsError(try engine.navigate(.right, scope: .all, displayID: laptop.id))
        XCTAssertEqual(backend.screen.visible[1], config.grids[0].cells[4].workspace)
    }
    func testExternalNavigationSynchronizesCursor() throws {
        backend.screen.visible[2] = config.grids[1].cells[0].workspace
        try engine.refresh()
        try engine.navigate(.down, scope: .active, displayID: ultra.id)
        XCTAssertEqual(backend.screen.visible[2], config.grids[1].cells[3].workspace)
    }
    func testFoldedGridSelectionAndClamshellScope() throws {
        backend.screen.displays = [laptop]; backend.screen.visible.removeValue(forKey: 2)
        try engine.refresh()
        try engine.selectGrid(offset: 1, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], config.grids[1].cells[4].workspace)
        try engine.navigate(.up, scope: .all, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], config.grids[1].cells[1].workspace)
        XCTAssertEqual(engine.state.cursors[config.grids[0].id], config.grids[0].cells[4].id)
    }
    func testCannotStealVisibleGridFromAnotherDisplay() throws {
        XCTAssertThrowsError(try engine.jump(gridID: config.grids[1].id, cellID: config.grids[1].cells[4].id, displayID: laptop.id))
    }
    func testWideSnapshotSurvivesLaptopEditsAndReconnect() throws {
        let cell = config.grids[1].cells[4]
        backend.members[cell.workspace] = [10,11,12]
        backend.snapshots[cell.workspace] = "nested-wide-2:1"
        try engine.refresh()
        backend.screen.displays = [laptop]; backend.screen.visible.removeValue(forKey: 2)
        try engine.refresh(); try engine.selectGrid(offset: 1, displayID: laptop.id)
        XCTAssertTrue(backend.calls.contains("layout:\(cell.workspace):compact"))
        backend.snapshots[cell.workspace] = "laptop-edited"
        backend.members[cell.workspace] = [10,12,13]
        try engine.refresh()
        backend.screen.displays = [laptop, ultra]
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("restore:\(cell.workspace):nested-wide-2:1"))
        XCTAssertEqual(engine.state.snapshots["\(cell.id):compact"], "laptop-edited")
        XCTAssertEqual(backend.screen.visible[2], cell.workspace)
    }
    func testOccupiedCellRemovalRequiresDestinationBeforeAnyMutation() throws {
        let old = config.grids[0].cells[0]
        backend.members[old.workspace] = [10,11]
        config.grids[0].cells.removeFirst()
        XCTAssertThrowsError(try engine.updateConfiguration(config))
        XCTAssertEqual(backend.members[old.workspace], [10,11])
        try engine.updateConfiguration(config, removedCellDestinations: [old.id: config.grids[0].cells[0].id])
        XCTAssertEqual(backend.members[config.grids[0].cells[0].workspace], [10,11])
    }
    func testWindowCyclingSameAppIDsAndMoving() throws {
        let ws = config.grids[0].cells[4].workspace
        backend.members[ws] = [42,43,44]
        try engine.cycleWindow(offset: 1, displayID: laptop.id)
        XCTAssertEqual(backend.screen.focusedWindow, 43)
        try engine.moveFocusedWindow(gridID: config.grids[0].id, cellID: config.grids[0].cells[5].id)
        XCTAssertEqual(backend.members[ws], [42,44])
        XCTAssertEqual(backend.members[config.grids[0].cells[5].workspace], [43])
    }
    func testDockedNativeFullscreenKeepsItsGridOnActualPhysicalDisplay() throws {
        let cell = config.grids[0].cells[4]
        backend.screen.nativeHomes = [cell.workspace: 2]
        try engine.refresh()
        XCTAssertEqual(backend.screen.visible[2], cell.workspace)
        XCTAssertEqual(backend.screen.visible[1], config.grids[1].cells[4].workspace)
        backend.screen.nativeHomes = [:]
        try engine.refresh()
        XCTAssertEqual(backend.screen.visible[1], cell.workspace)
        XCTAssertEqual(backend.screen.visible[2], config.grids[1].cells[4].workspace)
    }
    func testRestartWhileUndockedReconcilesSavedTopology() throws {
        let saved = engine.state
        backend.screen.displays = [laptop]; backend.screen.visible.removeValue(forKey: 2)
        let restarted = try Engine(configuration: config, state: saved, backend: backend)
        try restarted.refresh()
        XCTAssertEqual(restarted.observed?.displays.count, 1)
        try restarted.selectGrid(offset: 1, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], config.grids[1].cells[4].workspace)
    }
    func testCapturedDisplayDisappearingDoesNotNavigateAnotherDisplay() throws {
        backend.screen.displays = [laptop]
        backend.calls = []
        XCTAssertThrowsError(try engine.navigate(.right, scope: .active, displayID: ultra.id))
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testFailedCellMigrationRollsBackWindowsAndKeepsConfiguration() throws {
        let cell = config.grids[0].cells[0]
        backend.members[cell.workspace] = [10,11]
        backend.failMoveWindow = 11
        let original = config!
        config.grids[0].cells.removeFirst()
        XCTAssertThrowsError(try engine.updateConfiguration(config, removedCellDestinations: [cell.id: config.grids[0].cells[0].id]))
        XCTAssertEqual(Set(backend.members[cell.workspace] ?? []), Set([10,11]))
        XCTAssertEqual(engine.configuration, original)
    }
    func testOverviewMovesCapturedAppWindowInsteadOfOverviewWindow() throws {
        backend.members[config.grids[0].cells[4].workspace] = [42,999]
        backend.screen.focusedWindow = 999
        try engine.moveFocusedWindow(gridID: config.grids[0].id, cellID: config.grids[0].cells[5].id, windowOverride: 42)
        XCTAssertEqual(backend.members[config.grids[0].cells[4].workspace], [999])
        XCTAssertEqual(backend.members[config.grids[0].cells[5].workspace], [42])
    }
    func testVisibleCellAdaptsWhenWindowCountChangesWithoutNavigation() throws {
        let cell = config.grids[0].cells[4]
        backend.snapshots[cell.workspace] = "wide-before-adaptation"
        backend.members[cell.workspace] = [42,43,44]
        let before = backend.screen
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("layout:\(cell.workspace):compact"))
        XCTAssertEqual(engine.state.snapshots["\(cell.id):wide"], "wide-before-adaptation")
        XCTAssertEqual(backend.screen, before)
        backend.snapshots[cell.workspace] = "compact-edited"
        backend.members[cell.workspace] = [42,44]
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("restore:\(cell.workspace):wide-before-adaptation"))
        XCTAssertEqual(engine.state.snapshots["\(cell.id):compact"], "compact-edited")
    }
    func testVisibleProfileSettingAppliesOnRefresh() throws {
        let cell = config.grids[0].cells[4]
        config.grids[0].cells[4].profile = .vertical
        try engine.updateConfiguration(config)
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("layout:\(cell.workspace):vertical"))
    }
    func testPausedLayoutAdaptationLeavesUserLayoutUntouched() throws {
        config.automaticLayouts = false
        config.grids[0].cells[4].profile = .compact
        try engine.updateConfiguration(config)
        backend.members[config.grids[0].cells[4].workspace] = [42,43,44]
        try engine.refresh()
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("layout:") || $0.hasPrefix("restore:") })
    }
    func testDisplaySpecificLayoutEditsDoNotOverwriteLaptopProfile() throws {
        let cell = config.grids[1].cells[4]
        backend.members[cell.workspace] = [10,11,12]
        config.grids[1].cells[4].displayProfiles = [ultra.id: .compact]
        try engine.updateConfiguration(config)
        try engine.refresh()
        backend.snapshots[cell.workspace] = "ultra-custom-compact"
        try engine.refresh()
        backend.screen.displays = [laptop]
        backend.screen.visible.removeValue(forKey: 2)
        try engine.refresh()
        try engine.selectGrid(offset: 1, displayID: laptop.id)
        backend.snapshots[cell.workspace] = "laptop-custom-compact"
        try engine.refresh()
        backend.screen.displays = [laptop, ultra]
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("restore:\(cell.workspace):ultra-custom-compact"))
        XCTAssertEqual(engine.state.snapshots["\(cell.id):compact"], "laptop-custom-compact")
        XCTAssertEqual(engine.state.snapshots["\(cell.id):display-\(ultra.id):compact"], "ultra-custom-compact")
    }
    func testBackendRestartRestoresSavedTreeBeforeCapturingResetLayout() throws {
        let cell = config.grids[0].cells[4]
        backend.screen.backendSession = "session-one"
        backend.snapshots[cell.workspace] = "saved-nested-tree"
        engine = try Engine(configuration: config, backend: backend)
        try engine.refresh()
        backend.screen.backendSession = "session-two"
        backend.snapshots[cell.workspace] = "backend-reset-tree"
        try engine.refresh()
        XCTAssertTrue(backend.calls.contains("restore:\(cell.workspace):saved-nested-tree"))
        XCTAssertEqual(engine.state.snapshots["\(cell.id):wide"], "saved-nested-tree")
    }
    func testBackendRestartRecoversMembershipBeforeRestoringProfiles() throws {
        let cell = config.grids[0].cells[4]
        backend.screen.backendSession = "session-one"
        backend.screen.windowHomes = [WindowHome(id: 42, pid: 100, boot: "boot-one", workspace: cell.workspace)]
        backend.members[cell.workspace] = [42]
        engine = try Engine(configuration: config, backend: backend)
        try engine.refresh()
        backend.screen.backendSession = "session-two"
        backend.members[cell.workspace] = []
        backend.members["backend-default"] = [42]
        backend.screen.visible = [1: "backend-default", 2: "backend-other"]
        backend.screen.windowHomes = [WindowHome(id: 42, pid: 100, boot: "boot-one", workspace: "backend-default")]
        backend.calls = []
        try engine.refresh()
        XCTAssertEqual(backend.members[cell.workspace], [42])
        XCTAssertEqual(backend.members["backend-default"], [])
        let recover = try XCTUnwrap(backend.calls.firstIndex(of: "recover-homes"))
        let restore = try XCTUnwrap(backend.calls.firstIndex(where: { $0.hasPrefix("restore:") }))
        XCTAssertLessThan(recover, restore)
        XCTAssertEqual(engine.observed?.windowHomes?.first?.workspace, cell.workspace)
        XCTAssertEqual(engine.observed?.visible[1], cell.workspace)
        XCTAssertEqual(engine.observed?.visible[2], config.grids[1].cells[4].workspace)
    }
    func testWindowMinimumWidthPreventsCrampedTilesAndDoesNotOscillate() throws {
        let cell = config.grids[0].cells[4]
        backend.members[cell.workspace] = [42,43]
        backend.constraints[cell.workspace] = ["boot:pid:42": 900, "boot:pid:43": 0]
        try engine.refresh()
        XCTAssertEqual(engine.state.appliedProfiles[cell.id], "compact")
        backend.calls = []
        // The accordion is wide enough, so the app no longer needs to clamp it.
        backend.constraints[cell.workspace] = ["boot:pid:42": 0, "boot:pid:43": 0]
        try engine.refresh()
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("layout:") || $0.hasPrefix("restore:") })
        // A closed/replaced window doesn't impose its stale inferred minimum.
        backend.constraints[cell.workspace] = ["boot:other-pid:44": 0, "boot:pid:43": 0]
        try engine.refresh()
        XCTAssertEqual(engine.state.appliedProfiles[cell.id], "wide")
    }
    func testLegacyTransientMinimumWidthsAreDiscardedOnce() throws {
        var saved = RuntimeState()
        saved.windowMinimumWidths = ["boot:pid:42": 2560]
        let migrated = try Engine(configuration: config, state: saved, backend: backend)
        XCTAssertNil(migrated.state.windowMinimumWidths)
        XCTAssertEqual(migrated.state.minimumWidthDetectionVersion, 2)
        saved.minimumWidthDetectionVersion = 2
        let current = try Engine(configuration: config, state: saved, backend: backend)
        XCTAssertEqual(current.state.windowMinimumWidths, saved.windowMinimumWidths)
    }
}
