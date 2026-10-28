import XCTest
@testable import GridCore

extension DynamicEngineTests {
    func testDiscoveredWorkspaceUsesCurrentBoardSpaceNotDormantImportSlot() throws {
        let source = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        let oldSpaces = engine.map.spaces
        backend.setWindows(backend.screen.windows! + [WindowInfo(id: 40, workspace: "new-app")])
        try engine.refresh()
        let discovered = try XCTUnwrap(engine.map.spaces.first { $0.workspace == "new-app" })
        XCTAssertEqual(discovered.row, source.row)
        XCTAssertEqual(discovered.column, source.rect.right)
        for old in oldSpaces { XCTAssertEqual(engine.map.spaces.first { $0.id == old.id }?.rect, old.rect) }
        XCTAssertTrue(backend.activations.isEmpty)
    }

    func testGeneratedFullscreenStaysBesideHomeWithDistantUnrelatedSpace() throws {
        let other = try engine.createSpace(nearID: external.id, displayID: ultra.id, row: 4, column: 9)
        backend.screen.windows?[0].nativeFullscreen = true
        backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2: 1]
        try engine.refresh()
        let home = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        let generated = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        XCTAssertEqual(generated.row, home.row)
        XCTAssertEqual(generated.column, home.rect.right)
        XCTAssertEqual(engine.map.spaces.first { $0.id == other }?.rect, SpaceRect(row: 4, column: 9))
    }

    func testFoldedDiscoveriesStayNextToVisibleSpaceAndSurviveRestart() throws {
        try unplug()
        let projected = engine.map.projectedSpaces(combined: true)
        let current = try XCTUnwrap(engine.currentSpace(on: laptop))
        let origin = try XCTUnwrap(projected.first { $0.id == current.id })
        let before = engine.map.spaces
        backend.setWindows(backend.screen.windows! + [WindowInfo(id: 41, workspace: "reopened-app")])
        try engine.refresh()
        let generated = try XCTUnwrap(engine.map.spaces.first { $0.workspace == "reopened-app" })
        let actual = try XCTUnwrap(generated.foldedRect)
        let expected = SpacePlacement.nearestVacancy(near: origin.rect, occupied: projected.filter { !$0.isDormant }.map(\.rect))
        XCTAssertEqual(actual, expected)
        for old in before {
            XCTAssertEqual(engine.map.spaces.first { $0.id == old.id }?.rect, old.rect)
            XCTAssertEqual(engine.map.spaces.first { $0.id == old.id }?.foldedRect, old.foldedRect)
        }
        let restarted = try DynamicEngine(configuration: config, state: engine.state, backend: backend)
        try restarted.refresh()
        XCTAssertEqual(restarted.map.spaces.first { $0.id == generated.id }?.foldedRect, actual)
    }

    func testClosingAndReopeningLastWindowDoesNotActivateAnotherWorkspace() throws {
        backend.setWindows(backend.screen.windows!.filter { $0.id != 3 })
        try engine.refresh()
        XCTAssertEqual(backend.screen.visible[1], chat.workspace)
        XCTAssertFalse(try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id }).isDormant)
        backend.setWindows(backend.screen.windows! + [WindowInfo(id: 42, workspace: chat.workspace)])
        try engine.refresh()
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id })
        XCTAssertEqual(engine.contents(of: space).map(\.id), [42])
        XCTAssertTrue(backend.activations.isEmpty)
    }
}

extension SpatialTests {
    func testAutomaticPlacementAvoidsCornerOnlyConnectionAndFitsWholeFootprint() {
        let source = SpaceRect(row: 0, column: 0)
        let occupied = [source, SpaceRect(row: 0, column: 1), SpaceRect(row: 5, column: 9)]
        XCTAssertEqual(SpacePlacement.nearestVacancy(near: source, occupied: occupied), SpaceRect(row: 1, column: 0))
        let wide = SpacePlacement.nearestVacancy(near: source, occupied: occupied, width: 2, height: 2)
        XCTAssertEqual(wide, SpaceRect(row: 1, column: 0, width: 2, height: 2))
        XCTAssertFalse(occupied.contains { $0.overlaps(wide) })
    }
}
