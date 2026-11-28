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


final class DormantSpacePlacementTests: XCTestCase {
    private let active = Space(id: "editor", name: "Editor", row: 0, column: 3, workspace: "editor", preferredRole: "builtin")
    private let remembered = SpaceRect(row: 1, column: 1)
    private let display = Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1600, height: 900)

    private func fixture(position: SpaceRect, explicit: Bool = false) throws -> (DynamicEngine, MapBackend) {
        let config = Configuration(backendPath: "/unused")
        var map = SpaceMap(configuration: config)
        map.version = 3
        map.folded = true
        map.initialized = true
        var editor = active
        editor.foldedRect = active.rect
        var panel = Space(id: "panel", name: "Panel", row: remembered.row, column: remembered.column,
                          workspace: "panel", preferredRole: "builtin")
        panel.foldedRect = position
        panel.dormant = !explicit
        panel.userCreated = explicit
        map.spaces = [editor, panel]
        var desktop = Desktop(displays: [display], visible: [1: editor.workspace], focusedMonitor: 1, focusedWindow: 10)
        desktop.backendSession = "before"
        desktop.windows = [WindowInfo(id: 10, workspace: editor.workspace, bundleID: "test.editor")]
        var state = RuntimeState()
        state.dynamicMap = map
        state.lastDesktop = desktop
        let backend = MapBackend(desktop)
        backend.setWindows(desktop.windows! + [WindowInfo(id: 11, pid: 51, workspace: panel.workspace, floating: true,
                                                          bundleID: "test.panel", nativeSpace: "normal", ruled: true)])
        backend.screen.visible[1] = panel.workspace
        backend.screen.focusedWindow = 11
        let engine = try DynamicEngine(configuration: config, state: state, backend: backend)
        return (engine, backend)
    }

    func testFloatingWindowRoutedToDormantSlotWakesItNextToPriorVisibleCard() throws {
        let (engine, backend) = try fixture(position: remembered)
        let prior = engine.map.spaces.first
        try engine.refresh()

        let card = try XCTUnwrap(engine.map.spaces.first { $0.id == "panel" })
        let projected = try XCTUnwrap(card.foldedRect)
        XCTAssertTrue(projected.sharesEdge(with: active.rect))
        XCTAssertEqual(card.rect, remembered)
        XCTAssertEqual(engine.map.spaces.first, prior)
        XCTAssertEqual(engine.contents(of: card).map(\.id), [11])
        XCTAssertEqual(backend.screen.visible[1], card.workspace)
        XCTAssertTrue(backend.windowMoves.isEmpty)
        XCTAssertTrue(backend.activations.isEmpty)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains {
            $0.kind == .spaceWoken && $0.space == card.id && $0.reason == "floating-window"
        })

        backend.setWindows(backend.screen.windows!.filter { $0.id != 11 })
        backend.screen.visible[1] = active.workspace
        try engine.refresh()
        XCTAssertTrue(engine.map.spaces.first { $0.id == card.id }?.isDormant == true)
        XCTAssertEqual(engine.map.spaces.first, prior)
    }

    func testEmptyStartupWorkspaceDoesNotAcquireAnAdaptedSlot() throws {
        let (engine, backend) = try fixture(position: remembered)
        backend.setWindows(backend.screen.windows!.filter { $0.id != 11 })
        backend.screen.backendSession = "after"
        try engine.refresh()

        let card = try XCTUnwrap(engine.map.spaces.first { $0.id == "panel" })
        XCTAssertTrue(card.isDormant)
        XCTAssertNil(card.foldedRect)
        XCTAssertEqual(backend.screen.visible[1], active.workspace)
    }

    func testDormantSlotKeepsAdjacentPositionAndExplicitGapStaysIntact() throws {
        let nextToEditor = SpaceRect(row: 0, column: 2)
        for (position, explicit) in [(nextToEditor, false), (remembered, true)] {
            let (engine, _) = try fixture(position: position, explicit: explicit)
            try engine.refresh()
            XCTAssertEqual(engine.map.spaces.first { $0.id == "panel" }?.foldedRect, position)
        }
    }
}
