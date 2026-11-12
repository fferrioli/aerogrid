import XCTest
@testable import GridCore

final class FullscreenResilienceTests: XCTestCase {
    private func fixture(alive: @escaping (Int32) -> Bool = { _ in true }) throws -> (DynamicEngine, MapBackend) {
        let config = Configuration(backendPath: "/unused")
        let workspace = config.grids[0].cells[0].workspace
        let display = Display(id: "external", monitor: 1, name: "Display", builtin: false, width: 1920, height: 1080)
        var desktop = Desktop(displays: [display], visible: [1: workspace], focusedMonitor: 1, focusedWindow: 1)
        desktop.nativeVisible = [1: 1]
        let backend = MapBackend(desktop)
        backend.setWindows([
            WindowInfo(id: 1, workspace: workspace, nativeFullscreen: true, nativeMonitor: 1),
            WindowInfo(id: 2, workspace: workspace),
            WindowInfo(id: 3, workspace: config.grids[0].cells[1].workspace)
        ])
        let engine = try DynamicEngine(configuration: config, backend: backend, isProcessAlive: alive)
        try engine.refresh()
        return (engine, backend)
    }

    func testTransientAbsencePreservesLinkAndSpace() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == link.spaceID })
        let windows = backend.screen.windows!
        backend.setWindows([windows[2]])
        // The derived space ID is a hash of the identity, so a delete-and-recreate cycle can end
        // identical in this fixture: the card must also survive every sample of the absence.
        for sample in 1...2 {
            try engine.refresh()
            XCTAssertEqual(engine.map.fullscreens.first, link, "sample \(sample)")
            XCTAssertEqual(engine.map.spaces.first { $0.id == space.id }, space, "sample \(sample)")
        }
        backend.setWindows(windows)
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first, link)
        XCTAssertEqual(engine.map.spaces.first { $0.id == space.id }, space)
    }

    func testSingleWindowedSamplePreservesMap() throws {
        let (engine, backend) = try fixture()
        let before = engine.map
        let moves = backend.windowMoves
        backend.screen.windows?[0].nativeFullscreen = false
        try engine.refresh()
        XCTAssertEqual(backend.windowMoves, moves)
        XCTAssertEqual(engine.map.spaces, before.spaces)
        XCTAssertEqual(engine.map.fullscreens, before.fullscreens)
        backend.screen.windows?[0].nativeFullscreen = true
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens, before.fullscreens)
    }

    func testInventoryBlackoutPreservesMap() throws {
        let (engine, backend) = try fixture()
        let before = engine.map
        let windows = backend.screen.windows!
        backend.setWindows([])
        // As in the transient-absence test, the map must hold on every blackout sample, not only after recovery.
        for sample in 1...5 {
            try engine.refresh()
            XCTAssertEqual(engine.map.spaces, before.spaces, "sample \(sample)")
            XCTAssertEqual(engine.map.fullscreens, before.fullscreens, "sample \(sample)")
            XCTAssertEqual(engine.map.layouts, before.layouts, "sample \(sample)")
        }
        backend.setWindows(windows)
        try engine.refresh()
        XCTAssertEqual(engine.map.spaces, before.spaces)
        XCTAssertEqual(engine.map.fullscreens, before.fullscreens)
        XCTAssertEqual(engine.map.layouts, before.layouts)
    }
    func testConfirmedAbsenceRestoresPlaceInAnotherWorkspace() throws {
        let (initial, backend) = try fixture()
        var state = initial.state
        state.dynamicMap!.fullscreens[0].manuallyEdited = true
        let engine = try DynamicEngine(configuration: initial.configuration, state: state, backend: backend, isProcessAlive: { _ in true })
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == link.spaceID })
        var window = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![2]])
        for _ in 0..<3 { try engine.refresh() }
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertEqual(engine.map.fullscreenPlaces?.first?.space, space)
        window.workspace = backend.screen.windows![0].workspace
        backend.setWindows(backend.screen.windows! + [window])
        try engine.refresh()
        let restored = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow == window.identity })
        XCTAssertEqual(restored.id, space.id)
        XCTAssertEqual(restored.rect, space.rect)
        XCTAssertEqual(engine.map.fullscreens.first?.manuallyEdited, link.manuallyEdited)
        XCTAssertEqual(engine.map.fullscreenPlaces, [])
        let events = engine.consumeEvents()
        XCTAssertTrue(events.contains { $0.hasPrefix("fullscreen-removed reason=closed") })
        XCTAssertTrue(events.contains { $0.hasPrefix("fullscreen-restored") })
        XCTAssertTrue(engine.consumeEvents().isEmpty)
        XCTAssertFalse(events.contains { $0.contains(window.appName) || (!$0.isEmpty && !window.title.isEmpty && $0.contains(window.title)) })
    }
    func testDeadProcessRemovesImmediatelyWithoutMemory() throws {
        let (engine, backend) = try fixture(alive: { _ in false })
        backend.setWindows([backend.screen.windows![2]])
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertTrue((engine.map.fullscreenPlaces ?? []).isEmpty)
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-removed reason=process-exit") })
    }
    func testRealExitRequiresTwoSamples() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        backend.screen.windows?[0].nativeFullscreen = false
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first, link)
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == link.spaceID })
    }
    func testLegacyMapDecodingAndStableRoundTrip() throws {
        let (engine, _) = try fixture()
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(engine.map)) as? [String: Any])
        object.removeValue(forKey: "fullscreenPlaces")
        let decoded = try JSONDecoder().decode(SpaceMap.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.fullscreenPlaces)
        XCTAssertEqual(try JSONDecoder().decode(SpaceMap.self, from: encoder.encode(decoded)), decoded)
    }

    func testOccupiedRememberedPositionUsesNearestVacancy() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == link.spaceID })
        var window = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![2]])
        for _ in 0..<3 { try engine.refresh() }
        var state = engine.state
        var blocker = space
        blocker.id = "blocker"; blocker.nativeWindow = nil; blocker.sourceID = nil
        blocker.workspace = "occupied"; blocker.userCreated = true
        state.dynamicMap!.spaces.append(blocker)
        let expected = SpacePlacement.nearestVacancy(near: space.rect, occupied: state.dynamicMap!.spaces.filter { !$0.isDormant && $0.board == space.board }.map(\.rect), width: space.rect.width, height: space.rect.height)
        let restoredEngine = try DynamicEngine(configuration: engine.configuration, state: state, backend: backend, isProcessAlive: { _ in true })
        window.workspace = backend.screen.windows![0].workspace
        backend.setWindows(backend.screen.windows! + [window])
        try restoredEngine.refresh()
        XCTAssertEqual(restoredEngine.map.spaces.first { $0.id == space.id }?.rect, expected)
        try restoredEngine.map.validate()
    }
    func testReusedWindowNumberDoesNotRestoreAnotherPIDPlace() throws {
        let (engine, backend) = try fixture()
        let identity = backend.screen.windows![0].identity
        var window = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![2]])
        for _ in 0..<3 { try engine.refresh() }
        window.pid += 1
        window.workspace = backend.screen.windows![0].workspace
        backend.setWindows(backend.screen.windows! + [window])
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreenPlaces?.first?.space.nativeWindow, identity)
        XCTAssertFalse(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-restored") })
    }
    func testWindowedDoubtEventsArePrivateAndConsumed() throws {
        let (engine, backend) = try fixture()
        _ = engine.consumeEvents()
        backend.screen.windows?[0].appName = "PRIVATE_APP_SENTINEL"
        backend.screen.windows?[0].title = "PRIVATE_TITLE_SENTINEL"
        backend.screen.windows?[0].nativeFullscreen = false
        try engine.refresh()
        let events = engine.consumeEvents()
        XCTAssertTrue(events.contains { $0.hasPrefix("fullscreen-doubt kind=windowed count=1") })
        XCTAssertFalse(events.contains { $0.contains("PRIVATE_APP_SENTINEL") || $0.contains("PRIVATE_TITLE_SENTINEL") })
        XCTAssertTrue(engine.consumeEvents().isEmpty)
    }

    func testClosingTheLastWindowRemovesItsCardAsSoonAsTheBlackoutGuardEnds() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        backend.setWindows([])
        for _ in 0..<DynamicEngine.blackoutLimit { try engine.refresh() }
        XCTAssertEqual(engine.map.fullscreens, [link], "an empty inventory is not evidence while the guard holds")
        let held = engine.consumeEvents()
        XCTAssertEqual(held.filter { $0.hasPrefix("inventory-blackout") }.count, DynamicEngine.blackoutLimit)
        XCTAssertFalse(held.contains { $0.hasPrefix("fullscreen-removed") })
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty, "absence counted during the guard removes the card on the next sample")
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-removed reason=closed") })
        // 2 s poll: (blackoutLimit + 1) samples stay within the 15 s closing bound.
        XCTAssertLessThanOrEqual((DynamicEngine.blackoutLimit + 1) * 2, 15)
    }

    func testDeadProcessEndsTheBlackoutImmediately() throws {
        var alive = true
        let (engine, backend) = try fixture(alive: { _ in alive })
        backend.setWindows([])
        alive = false
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-removed reason=process-exit") })
    }
}
