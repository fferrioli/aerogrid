import XCTest
@testable import GridCore

extension DynamicEngineTests {
    private func navigationSelection(scope: Scope = .active) throws -> NavigationSelection {
        let upper = config.grids[1].cells[0]
        if !backend.screen.windows!.contains(where: { $0.workspace == upper.workspace }) {
            backend.setWindows(backend.screen.windows! + [WindowInfo(id: 9, workspace: upper.workspace)])
        }
        if scope == .all {
            let other = config.grids[0].cells[0]
            backend.setWindows(backend.screen.windows! + [WindowInfo(id: 10, workspace: other.workspace)])
        }
        try engine.refresh()
        var selection = try NavigationSelection(map: engine.map, configuration: config, desktop: backend.screen, scope: scope, displayID: ultra.id)
        XCTAssertTrue(selection.step(.up))
        backend.calls = []; backend.activations = []
        return selection
    }
    func testNavigationPreparationDoesNotGrowWithUnrelatedSpaces() throws {
        for count in [0, 30] {
            let unrelated = (0..<count).map { index in
                var window = WindowInfo(id: UInt32(100 + index), workspace: "unrelated-\(index)")
                window.monitor = laptop.monitor // Keep the measured gesture's source/destination on the other board.
                return window
            }
            backend.setWindows(backend.screen.windows! + unrelated)
            let selection = try navigationSelection()
            let targetID = try XCTUnwrap(selection.selected[ultra.id]?.spaceID)
            let target = try XCTUnwrap(engine.map.spaces.first { $0.id == targetID })
            try engine.commitNavigation(selection)
            let activation = try XCTUnwrap(backend.calls.firstIndex(of: "activate:\(target.workspace)"))
            let preparation = backend.calls.prefix(upTo: activation)
            XCTAssertLessThanOrEqual(preparation.filter { $0 == "desktop" }.count, 3)
            XCTAssertLessThanOrEqual(preparation.filter { $0.hasPrefix("snapshot:") }.count, 2)
            XCTAssertFalse(preparation.contains { $0.hasPrefix("snapshot:unrelated-") })
            XCTAssertEqual(backend.screen.visible[2], target.workspace)
            // Return to the origin so the next sample exercises the same gesture.
            try backend.activateTarget(workspace: external.workspace, monitor: 2, window: nil)
        }
    }
    func testNavigationCapturesRecentSourceAndDestinationLayoutEdits() throws {
        let selection = try navigationSelection()
        let targetID = try XCTUnwrap(selection.selected[ultra.id]?.spaceID)
        let target = try XCTUnwrap(engine.map.spaces.first { $0.id == targetID })
        backend.trees[external.workspace]?.tree.orientation = "v"
        backend.trees[target.workspace] = LayoutSnapshot(boot: "test", tree: .root([LayoutNode(id: 9, pid: 1)], layout: "accordion"))
        try engine.commitNavigation(selection)
        let source = try LayoutSnapshot(json: XCTUnwrap(engine.map.layouts[external.id]))
        let destination = try LayoutSnapshot(json: XCTUnwrap(engine.map.layouts[targetID]))
        XCTAssertEqual(source.tree.orientation, "v")
        XCTAssertEqual(destination.tree.layout, "accordion")
        XCTAssertEqual(backend.trees[target.workspace]?.tree.layout, "accordion")
    }
    func testNavigationUsesLatestTitlesWithoutFallingBackToFullMapCapture() throws {
        let selection = try navigationSelection()
        backend.screen.windows?[0].title = "New document title"
        backend.screen.windows?.reverse()
        try engine.commitNavigation(selection)
        XCTAssertEqual(engine.observed?.windows?.first { $0.id == 1 }?.title, "New document title")
        XCTAssertFalse(backend.calls.contains("snapshot:\(chat.workspace)"))
    }
    func testNavigationFallsBackOnBackendRestart() throws {
        let selection = try navigationSelection()
        backend.screen.backendSession = "new-session"
        try engine.commitNavigation(selection)
        XCTAssertTrue(backend.calls.contains("snapshot:\(chat.workspace)"))
        XCTAssertEqual(engine.observed?.backendSession, "new-session")
    }
    func testNavigationFallsBackOnChangedMembershipAndRejectsChangedTarget() throws {
        let selection = try navigationSelection()
        backend.screen.windows?.removeAll { $0.id == 9 }
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertTrue(backend.calls.contains("snapshot:\(chat.workspace)"))
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testNavigationRejectsOwnershipChangeDuringPreparation() throws {
        let selection = try navigationSelection()
        backend.onSnapshot = { [backend] _ in
            if let index = backend?.screen.windows?.firstIndex(where: { $0.id == 9 }) {
                backend?.screen.windows?[index].pid = 99
            }
        }
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testNavigationRejectsTopologyChangeWithoutActivatingOldTarget() throws {
        let selection = try navigationSelection()
        backend.screen.displays = [laptop]
        backend.screen.visible.removeValue(forKey: 2)
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertTrue(engine.map.folded)
        XCTAssertFalse(backend.activations.contains { $0.0 == config.grids[1].cells[0].workspace })
    }
    func testCoordinatedNavigationPreflightsAllTargetsBeforeAnyActivation() throws {
        let selection = try navigationSelection(scope: .all)
        let destinationID = try XCTUnwrap(selection.selected[ultra.id]?.spaceID)
        backend.failValidation = try XCTUnwrap(engine.map.spaces.first { $0.id == destinationID }?.workspace)
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testCoordinatedNavigationRollsBackAfterSecondActivationFails() throws {
        let selection = try navigationSelection(scope: .all)
        let before = backend.screen.visible, anchors = engine.map.anchors
        let destinationID = try XCTUnwrap(selection.selected[ultra.id]?.spaceID)
        backend.failActivation = try XCTUnwrap(engine.map.spaces.first { $0.id == destinationID }?.workspace)
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertFalse(backend.activations.isEmpty)
        XCTAssertEqual(backend.screen.visible, before)
        XCTAssertEqual(engine.map.anchors, anchors)
    }
    func testNavigationSnapshotFailureDoesNotActivateDestination() throws {
        let selection = try navigationSelection()
        backend.failSnapshot = external.workspace
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testConsecutiveNavigationUsesCommittedOrigin() throws {
        let forward = try navigationSelection()
        try engine.commitNavigation(forward)
        var back = try NavigationSelection(map: engine.map, configuration: config, desktop: XCTUnwrap(engine.observed), scope: .active, displayID: ultra.id)
        XCTAssertTrue(back.step(.down))
        try engine.commitNavigation(back)
        XCTAssertEqual(backend.screen.visible[2], external.workspace)
        XCTAssertEqual(backend.activations.count, 2)
    }
}
