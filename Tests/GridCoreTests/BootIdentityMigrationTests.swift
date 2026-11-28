import XCTest
@testable import GridCore

final class BootIdentityMigrationTests: XCTestCase {
    private let boot = "9E9CC1F9-2A56-4BC9-980A-AA4189BBA237"
    private let window = WindowInfo(id: 31, pid: 42, boot: "1800000000", workspace: "home", nativeFullscreen: true, nativeMonitor: 1)
    private let display = Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1280, height: 800)

    private func fixture() throws -> (Configuration, RuntimeState, MapBackend) {
        let config = Configuration(backendPath: "/unused")
        let home = Space(id: "home", name: "Home", row: 2, column: 1, workspace: "home", preferredRole: "external")
        var card = Space(id: "fullscreen", name: "App", row: 2, column: 7, workspace: "home", preferredRole: "external")
        card.nativeWindow = window.identity
        card.sourceID = home.id
        card.foldedRect = SpaceRect(row: 0, column: 7)
        let layout = LayoutSnapshot(boot: window.boot, tree: .root([]))
        let link = FullscreenLink(spaceID: card.id, homeID: home.id, identity: window.identity, original: layout)
        let before = MapCheckpoint(spaces: [home, card], families: [], fullscreens: [link], homes: [], layouts: [home.id: try layout.json()])
        var edit = before
        edit.spaces[1].foldedRect = SpaceRect(row: 0, column: 2)
        edit.fullscreens[0].manuallyEdited = true
        var map = SpaceMap(configuration: config)
        map.version = 3
        map.spaces = before.spaces
        map.fullscreens = [link]
        map.layouts = before.layouts
        map.folded = true
        var last = Desktop(displays: [display], visible: [1: "home"], focusedMonitor: 1)
        last.windows = [window]
        map.undo = [OrganizationUndo(label: "Move card", before: before, after: edit, topology: last.topology)]
        map.placeRestore = PlaceRestoreState(boot: window.boot, restored: [window.identity])
        var state = RuntimeState()
        state.dynamicMap = map
        state.lastDesktop = last
        var current = last
        current.bootSession = boot
        current.legacyBootTime = "1800000001"
        var newWindow = window
        newWindow.boot = boot
        let backend = MapBackend(current)
        backend.setWindows([newWindow])
        return (config, state, backend)
    }

    func testLegacyIdentifierAndEditedFullscreenPositionSurviveUpgrade() throws {
        let (config, saved, backend) = try fixture()
        let engine = try DynamicEngine(configuration: config, state: saved, backend: backend, isProcessAlive: { _ in true })
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first?.spaceID, "fullscreen")
        XCTAssertEqual(engine.map.fullscreens.first?.identity.boot, boot)
        XCTAssertEqual(engine.map.spaces.first { $0.id == "fullscreen" }?.foldedRect, SpaceRect(row: 0, column: 2))
        XCTAssertEqual(engine.map.fullscreens.first?.manuallyEdited, true)
        XCTAssertEqual(engine.map.undo.last?.after.fullscreens.first?.identity.boot, boot)
        XCTAssertEqual(engine.map.placeRestore?.restored.first?.boot, boot)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .bootIdentityMigrated })
        backend.screen.legacyBootTime = "1800000030"
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first?.spaceID, "fullscreen")
        XCTAssertFalse(engine.consumeDiagnosticEvents().contains { $0.kind == .fullscreenRemoved })
    }

    func testPositionRecoveryWaitsForDeferredFullscreenOwner() throws {
        let (config, saved, backend) = try fixture()
        var rebased = saved
        let native = try XCTUnwrap(backend.screen.windows?.first)
        XCTAssertTrue(rebased.migrateBootIdentity(using: backend.screen))
        backend.setWindows([WindowInfo(id: 40, pid: 50, boot: boot, workspace: "home")])
        let engine = try DynamicEngine(configuration: config, state: rebased, backend: backend, isProcessAlive: { _ in true })
        try engine.refresh()
        XCTAssertNil(engine.state.legacyFullscreenGeometryResolved)
        XCTAssertEqual(engine.map.spaces.first { $0.id == "fullscreen" }?.foldedRect?.column, 7)
        backend.setWindows([native])
        try engine.refresh()
        XCTAssertTrue(engine.state.legacyFullscreenGeometryResolved == true)
        XCTAssertEqual(engine.map.spaces.first { $0.id == "fullscreen" }?.foldedRect?.column, 2)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .fullscreenPositionsRecovered })
    }

    func testPreviousBootOrUncorroboratedOwnerIsNeverMigrated() throws {
        let (_, saved, backend) = try fixture()
        var stale = saved
        backend.screen.legacyBootTime = "1800000300"
        XCTAssertFalse(stale.migrateBootIdentity(using: backend.screen))
        XCTAssertEqual(stale, saved)
        backend.screen.legacyBootTime = "1800000001"
        var other = try XCTUnwrap(backend.screen.windows?.first)
        other.pid += 1
        backend.setWindows([other])
        XCTAssertFalse(stale.migrateBootIdentity(using: backend.screen))
        XCTAssertEqual(stale, saved)
    }
}
