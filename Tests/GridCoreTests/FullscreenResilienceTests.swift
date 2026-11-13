import XCTest
@testable import GridCore

final class FullscreenResilienceTests: XCTestCase {
    /// Records restores while preserving the shared MapBackend's inventory and movement behavior.
    private final class RestoreTrackingBackend: Backend {
        let base: MapBackend
        var restores = 0
        var fullscreenMoves: [WindowHome] = []
        init(_ base: MapBackend) { self.base = base }
        func desktop() throws -> Desktop { try base.desktop() }
        func validate(workspace: String, monitor: Int) throws { try base.validate(workspace: workspace, monitor: monitor) }
        func place(workspace: String, monitor: Int) throws { try base.place(workspace: workspace, monitor: monitor) }
        func activate(workspace: String) throws { try base.activate(workspace: workspace) }
        func focus(monitor: Int, window: UInt32?) throws { try base.focus(monitor: monitor, window: window) }
        func focus(window: UInt32) throws { try base.focus(window: window) }
        func windows(workspace: String) throws -> [UInt32] { try base.windows(workspace: workspace) }
        func recoverWindowHomes(_ homes: [WindowHome]) throws { try base.recoverWindowHomes(homes) }
        func move(window: UInt32, workspace: String) throws { try base.move(window: window, workspace: workspace) }
        func moveFullscreen(window: WindowIdentity, workspace: String) throws {
            fullscreenMoves.append(WindowHome(id: window.id, pid: window.pid, boot: window.boot, workspace: workspace, floating: false))
            try base.move(window: window.id, workspace: workspace)
        }
        func snapshot(workspace: String) throws -> String { try base.snapshot(workspace: workspace) }
        func restore(workspace: String, snapshot: String) throws {
            restores += 1
            try base.restore(workspace: workspace, snapshot: snapshot)
        }
        func layout(workspace: String, profile: String) throws { try base.layout(workspace: workspace, profile: profile) }
        func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
            try base.validateTarget(workspace: workspace, monitor: monitor, window: window)
        }
        func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
            try base.activateTarget(workspace: workspace, monitor: monitor, window: window)
        }
    }

    private func ownHomeFixture() throws -> (DynamicEngine, MapBackend, RestoreTrackingBackend) {
        let config = Configuration(backendPath: "/unused")
        let display = Display(id: "external", monitor: 1, name: "Display", builtin: false, width: 1920, height: 1080)
        var desktop = Desktop(displays: [display], visible: [1: "wb"], focusedMonitor: 1, focusedWindow: 2)
        desktop.nativeVisible = [1: 2]
        let backend = MapBackend(desktop)
        backend.setWindows([
            WindowInfo(id: 1, workspace: "wa", nativeFullscreen: true, nativeMonitor: 1),
            WindowInfo(id: 2, workspace: "wb", nativeFullscreen: true, nativeMonitor: 1)
        ])
        var state = RuntimeState()
        var map = SpaceMap(configuration: config)
        map.version = 3
        map.spaces = [
            Space(id: "card-a", name: "A", row: 0, column: 0, workspace: "wa", preferredRole: "external"),
            Space(id: "card-b", name: "B", row: 0, column: 1, workspace: "wb", preferredRole: "external")
        ]
        state.dynamicMap = map
        let tracking = RestoreTrackingBackend(backend)
        let engine = try DynamicEngine(configuration: config, state: state, backend: tracking, isProcessAlive: { _ in true })
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.count, 2)
        XCTAssertTrue(engine.map.fullscreens.allSatisfy { $0.spaceID == $0.homeID })
        _ = engine.consumeEvents()
        return (engine, backend, tracking)
    }

    func testReturningOwnHomeFullscreenRecoversCardBeforeReconcilingOtherLinks() throws {
        let (engine, backend, tracking) = try ownHomeFixture()
        let before = engine.map
        let cardA = try XCTUnwrap(before.spaces.first { $0.id == "card-a" })
        let cardB = try XCTUnwrap(before.spaces.first { $0.id == "card-b" })
        var returning = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![1]])
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        XCTAssertNil(engine.map.spaces.first { $0.id == cardA.id }?.nativeWindow)
        XCTAssertTrue(engine.map.spaces.first { $0.id == cardA.id }?.isDormant == true)
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-removed reason=closed ") })

        returning.workspace = cardB.workspace
        backend.setWindows(backend.screen.windows! + [returning])
        try engine.refresh()

        XCTAssertEqual(tracking.fullscreenMoves, [WindowHome(id: returning.id, pid: returning.pid, boot: returning.boot, workspace: cardA.workspace, floating: false)])
        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == cardA.id })
        XCTAssertEqual(restored.id, cardA.id)
        XCTAssertEqual(restored.rect, cardA.rect)
        XCTAssertEqual(restored.workspace, cardA.workspace)
        XCTAssertEqual(restored.nativeWindow, returning.identity)
        XCTAssertFalse(restored.isDormant)
        XCTAssertTrue(engine.map.spaces.first { $0.id == cardB.id } == cardB, "B must remain identical")
        XCTAssertEqual(engine.map.spaces.map(\.id), before.spaces.map(\.id))
        XCTAssertEqual(engine.map.fullscreens.sorted { $0.spaceID < $1.spaceID }, before.fullscreens.sorted { $0.spaceID < $1.spaceID })
        let events = engine.consumeEvents()
        XCTAssertTrue(events.contains("fullscreen-return window=1 pid=1 space=card-a"))
        XCTAssertTrue(events.contains("fullscreen-restored window=1 pid=1 space=card-a"))
    }

    func testUnrememberedFullscreenDoesNotSplitAnotherFullscreenCard() throws {
        let (engine, backend, tracking) = try ownHomeFixture()
        let before = engine.map
        backend.setWindows(backend.screen.windows! + [WindowInfo(id: 3, workspace: "wb", nativeFullscreen: true, nativeMonitor: 1)])

        for sample in 1...3 {
            try engine.refresh()
            assertMapPreserved(engine, before, sample: sample)
        }

        XCTAssertTrue(tracking.fullscreenMoves.isEmpty)
        XCTAssertEqual(engine.consumeEvents().filter { $0 == "fullscreen-unplaced window=3 pid=1 space=card-b" }.count, 1)
    }

    func testReturningExclusiveFullscreenMovesToOriginalHomeWorkspace() throws {
        let (initial, backend) = try fixture()
        let tracking = RestoreTrackingBackend(backend)
        let engine = try DynamicEngine(configuration: initial.configuration, state: initial.state, backend: tracking, isProcessAlive: { _ in true })
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        let exclusive = try XCTUnwrap(engine.map.spaces.first { $0.id == link.spaceID })
        let home = try XCTUnwrap(engine.map.spaces.first { $0.id == link.homeID })
        var returning = backend.screen.windows![0]
        let remaining = Array(backend.screen.windows!.dropFirst())
        backend.setWindows(remaining)
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        XCTAssertFalse(engine.map.spaces.contains { $0.id == exclusive.id })
        returning.workspace = remaining[1].workspace
        backend.setWindows(remaining + [returning])

        try engine.refresh()

        XCTAssertEqual(tracking.fullscreenMoves, [WindowHome(id: returning.id, pid: returning.pid, boot: returning.boot, workspace: home.workspace, floating: false)])
        let restored = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow == returning.identity })
        XCTAssertEqual(restored.id, exclusive.id)
        XCTAssertEqual(restored.rect, exclusive.rect)
        XCTAssertEqual(restored.workspace, home.workspace)
        XCTAssertEqual(engine.map.fullscreens.first?.homeID, home.id)
        XCTAssertEqual(engine.map.fullscreenPlaces, [])
    }

    func testFailedFullscreenReturnPreservesPlaceAndRetriesWithoutDuplicateEvents() throws {
        let (engine, backend, tracking) = try ownHomeFixture()
        let before = engine.map
        var returning = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![1]])
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        let absent = engine.map
        let place = try XCTUnwrap(absent.fullscreenPlaces?.first)
        XCTAssertEqual(place.space.nativeWindow, returning.identity)
        _ = engine.consumeEvents()
        returning.workspace = "wb"
        returning.appName = "PRIVATE_APP_SENTINEL"
        returning.title = "PRIVATE_TITLE_SENTINEL"
        backend.setWindows(backend.screen.windows! + [returning])
        backend.failWindow = returning.id

        for _ in 0..<2 {
            try engine.refresh()
            XCTAssertEqual(engine.map, absent)
            XCTAssertEqual(engine.map.fullscreenPlaces, [place])
        }
        let failed = engine.consumeEvents()
        XCTAssertEqual(tracking.fullscreenMoves.count, 2)
        XCTAssertEqual(failed.filter { $0 == "fullscreen-return-failed window=1 pid=1 space=card-a" }.count, 1)
        XCTAssertFalse(failed.contains { $0.hasPrefix("fullscreen-restored ") || $0.hasPrefix("fullscreen-created ") || $0.hasPrefix("fullscreen-unplaced ") })
        XCTAssertFalse(failed.contains { $0.contains("PRIVATE_APP_SENTINEL") || $0.contains("PRIVATE_TITLE_SENTINEL") })

        backend.failWindow = nil
        try engine.refresh()

        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == "card-a" })
        XCTAssertEqual(restored.rect, before.spaces.first { $0.id == "card-a" }?.rect)
        XCTAssertEqual(restored.workspace, "wa")
        XCTAssertEqual(restored.nativeWindow, returning.identity)
        XCTAssertFalse(restored.isDormant)
        XCTAssertEqual(engine.map.spaces.first { $0.id == "card-b" }, before.spaces.first { $0.id == "card-b" })
        XCTAssertEqual(engine.map.spaces.count, before.spaces.count)
        XCTAssertEqual(engine.map.fullscreenPlaces, [])
        let events = engine.consumeEvents()
        XCTAssertTrue(events.contains("fullscreen-return window=1 pid=1 space=card-a"))
        XCTAssertTrue(events.contains("fullscreen-restored window=1 pid=1 space=card-a"))
    }

    func testReturningFullscreenAlreadyAtOwnHomeRestoresCurrentCardWithoutMove() throws {
        let (initial, backend, tracking) = try ownHomeFixture()
        var state = initial.state
        let index = try XCTUnwrap(state.dynamicMap?.fullscreens.firstIndex { $0.identity.id == 1 })
        state.dynamicMap!.fullscreens[index].manuallyEdited = true
        let engine = try DynamicEngine(configuration: initial.configuration, state: state, backend: tracking, isProcessAlive: { _ in true })
        let returning = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![1]])
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        // The current card, including edits made while absent, is authoritative.
        var absent = engine.state
        let card = try XCTUnwrap(absent.dynamicMap?.spaces.firstIndex { $0.id == "card-a" })
        absent.dynamicMap!.spaces[card].column = 4
        absent.dynamicMap!.spaces[card].sourceID = "card-b"
        let edited = absent.dynamicMap!.spaces[card]
        let restoredEngine = try DynamicEngine(configuration: engine.configuration, state: absent, backend: tracking, isProcessAlive: { _ in true })
        backend.setWindows(backend.screen.windows! + [returning])

        try restoredEngine.refresh()

        let restored = try XCTUnwrap(restoredEngine.map.spaces.first { $0.id == edited.id })
        XCTAssertTrue(tracking.fullscreenMoves.isEmpty)
        XCTAssertEqual(restored.rect, edited.rect)
        XCTAssertEqual(restored.workspace, edited.workspace)
        XCTAssertEqual(restored.sourceID, edited.sourceID)
        XCTAssertEqual(restored.nativeWindow, returning.identity)
        XCTAssertFalse(restored.isDormant)
        let link = try XCTUnwrap(restoredEngine.map.fullscreens.first { $0.identity == returning.identity })
        XCTAssertEqual(link.spaceID, edited.id)
        XCTAssertEqual(link.homeID, edited.id)
        XCTAssertTrue(link.manuallyEdited)
        XCTAssertEqual(restoredEngine.map.fullscreenPlaces, [])
        XCTAssertTrue(restoredEngine.consumeEvents().contains("fullscreen-restored window=1 pid=1 space=card-a"))
    }

    func testReturningFullscreenWithDeletedOwnCardUsesNewWindowBehavior() throws {
        let (engine, backend, tracking) = try ownHomeFixture()
        var returning = backend.screen.windows![0]
        backend.setWindows([backend.screen.windows![1]])
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        XCTAssertNotNil(engine.map.fullscreenPlaces?.first)
        try engine.removeEmptySpace("card-a")
        let before = engine.map
        _ = engine.consumeEvents()
        returning.workspace = "wb"
        backend.setWindows(backend.screen.windows! + [returning])

        try engine.refresh()

        XCTAssertTrue(tracking.fullscreenMoves.isEmpty)
        XCTAssertEqual(engine.map, before)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == "card-a" })
        let events = engine.consumeEvents()
        XCTAssertEqual(events.filter { $0 == "fullscreen-unplaced window=1 pid=1 space=card-b" }.count, 1)
        XCTAssertFalse(events.contains { $0.hasPrefix("fullscreen-restored ") || $0.hasPrefix("fullscreen-return ") })
    }

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

    private func disagreementFixture() throws -> (DynamicEngine, MapBackend, RestoreTrackingBackend) {
        let (initial, backend) = try fixture()
        backend.screen.windows?[1].nativeFullscreen = true
        backend.screen.windows?[1].nativeMonitor = 1
        try initial.refresh()
        let full = try XCTUnwrap(initial.map.spaces.first { $0.nativeWindow?.id == 1 })
        let emptyID = try initial.createSpace(nearID: full.id, displayID: "external")
        try initial.moveWindow(XCTUnwrap(full.nativeWindow), to: emptyID)
        try initial.refresh()
        let moved = try XCTUnwrap(initial.map.fullscreens.first { $0.identity.id == 1 })
        XCTAssertTrue(moved.manuallyEdited)
        XCTAssertNotEqual(moved.spaceID, moved.homeID)
        XCTAssertEqual(initial.map.fullscreens.count, 2)
        let tracking = RestoreTrackingBackend(backend)
        let engine = try DynamicEngine(configuration: initial.configuration, state: initial.state, backend: tracking, isProcessAlive: { _ in true })
        backend.windowMoves.removeAll()
        for index in 0..<2 {
            backend.screen.windows?[index].nativeFullscreen = false
            backend.screen.windows?[index].nativeSpace = "fullscreen"
            backend.screen.windows?[index].appName = "PRIVATE_APP_SENTINEL"
            backend.screen.windows?[index].title = "PRIVATE_TITLE_SENTINEL"
        }
        return (engine, backend, tracking)
    }

    private func assertMapPreserved(_ engine: DynamicEngine, _ before: SpaceMap, sample: Int, file: StaticString = #filePath, line: UInt = #line) {
        // Keep red reproduction output concise while checking complete collections, including dormant flags.
        XCTAssertTrue(engine.map.spaces == before.spaces, "spaces changed at sample \(sample)", file: file, line: line)
        XCTAssertTrue(engine.map.fullscreens == before.fullscreens, "fullscreens changed at sample \(sample)", file: file, line: line)
        XCTAssertTrue(engine.map.layouts == before.layouts, "layouts changed at sample \(sample)", file: file, line: line)
    }

    func testDisagreementInventoryPreservesExclusiveContentsAndNavigation() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        let exclusive = try XCTUnwrap(engine.map.spaces.first { $0.id == link.spaceID })
        let home = try XCTUnwrap(engine.map.spaces.first { $0.id == link.homeID })
        XCTAssertNotEqual(exclusive.id, home.id)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "fullscreen"
        backend.screen.windows?[0].nativeMonitor = nil
        backend.screen.windows?[0].monitor = 1

        try engine.refresh()

        XCTAssertEqual(engine.contents(of: exclusive).map(\.identity), [link.identity])
        XCTAssertFalse(engine.contents(of: home).contains { $0.identity == link.identity })
        let observed = try XCTUnwrap(engine.observed)
        let selection = try NavigationSelection(map: engine.map, configuration: engine.configuration,
                                                desktop: observed, scope: .active, displayID: "external")
        XCTAssertTrue(selection.eligible["external"]?.contains(exclusive.id) == true)
        XCTAssertEqual(selection.owners[exclusive.id], [link.identity])
        XCTAssertEqual(observed.windows?.first { $0.identity == link.identity }?.nativeMonitor, 1)
        XCTAssertEqual(engine.state.lastDesktop, observed)
        XCTAssertEqual(backend.screen.windows?[0].nativeFullscreen, false, "inventory adjustment must only change the copy")
    }

    func testDisagreementInventoryDoesNotCaptureLayoutsOrAdoptWorkspace() throws {
        for unknownWorkspace in [false, true] {
            let config = Configuration(backendPath: "/unused")
            let workspace = config.grids[0].cells[0].workspace
            let display = Display(id: "external", monitor: 1, name: "Display", builtin: false, width: 1920, height: 1080)
            var desktop = Desktop(displays: [display], visible: [1: workspace], focusedMonitor: 1, focusedWindow: 1)
            desktop.nativeVisible = [1: 1]
            let backend = MapBackend(desktop)
            backend.setWindows([
                WindowInfo(id: 1, workspace: workspace, nativeFullscreen: true, nativeMonitor: 1),
                WindowInfo(id: 2, workspace: workspace, nativeFullscreen: true, nativeMonitor: 1)
            ])
            let engine = try DynamicEngine(configuration: config, backend: backend, isProcessAlive: { _ in true })
            try engine.refresh()
            XCTAssertEqual(engine.map.fullscreens.count, 2)
            let before = engine.map
            for index in 0..<2 {
                backend.screen.windows?[index].nativeFullscreen = false
                backend.screen.windows?[index].nativeSpace = "fullscreen"
            }
            if unknownWorkspace { backend.screen.windows?[0].workspace = "unmapped-fullscreen" }
            backend.calls.removeAll()

            for sample in 1...5 {
                try engine.refresh()
                assertMapPreserved(engine, before, sample: sample)
                XCTAssertTrue(engine.map == before, "map changed at sample \(sample), unknown workspace: \(unknownWorkspace)")
                XCTAssertFalse(backend.calls.contains { $0.hasPrefix("snapshot:") }, "fullscreen disagreement must not capture a normal layout")
                XCTAssertFalse(engine.map.spaces.contains { $0.workspace == "unmapped-fullscreen" })
            }
        }
    }

    func testUnlinkedNativeSpaceEvidenceKeepsWindowNormal() throws {
        let (engine, backend) = try fixture()
        let before = engine.map
        let window = try XCTUnwrap(backend.screen.windows?.first { $0.id == 2 })
        let home = try XCTUnwrap(engine.map.spaces.first { $0.workspace == window.workspace && $0.nativeWindow == nil })
        backend.screen.windows?[1].nativeSpace = "fullscreen"
        _ = engine.consumeEvents()

        for _ in 0..<5 {
            try engine.refresh()
            XCTAssertEqual(engine.map.fullscreens, before.fullscreens)
            XCTAssertEqual(engine.map.spaces, before.spaces)
            XCTAssertFalse(engine.map.spaces.contains { $0.nativeWindow == window.identity })
            XCTAssertTrue(engine.contents(of: home).contains { $0.identity == window.identity })
            XCTAssertEqual(engine.observed?.windows?.first { $0.identity == window.identity }?.nativeFullscreen, false)
        }
        XCTAssertFalse(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-doubt kind=disagree ") || $0.hasPrefix("fullscreen-created ") })
    }

    func testNativeSpaceDisagreementPreservesBothFullscreenCards() throws {
        let (engine, backend, tracking) = try disagreementFixture()
        let before = engine.map
        for sample in 1...5 {
            try engine.refresh()
            assertMapPreserved(engine, before, sample: sample)
            XCTAssertTrue(backend.windowMoves.isEmpty)
            XCTAssertEqual(tracking.restores, 0)
        }
        let events = engine.consumeEvents()
        for link in before.fullscreens {
            let expected = "fullscreen-doubt kind=disagree window=\(link.identity.id) pid=\(link.identity.pid) space=\(link.spaceID.prefix(8))"
            XCTAssertEqual(events.filter { $0 == expected }.count, 1)
        }
        XCTAssertFalse(events.contains { $0.hasPrefix("fullscreen-exit") })
        XCTAssertFalse(events.contains { $0.contains("PRIVATE_APP_SENTINEL") || $0.contains("PRIVATE_TITLE_SENTINEL") })
    }

    func testFullscreenReturnsAfterNativeSpaceDisagreementWithoutExit() throws {
        let (engine, backend, tracking) = try disagreementFixture()
        let before = engine.map
        for _ in 0..<5 { try engine.refresh() }
        for index in 0..<2 { backend.screen.windows?[index].nativeFullscreen = true }
        try engine.refresh()
        assertMapPreserved(engine, before, sample: 6)
        XCTAssertTrue(backend.windowMoves.isEmpty)
        XCTAssertEqual(tracking.restores, 0)
        XCTAssertFalse(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-exit") })
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

    func testNativeNormalExitRequiresTwoSamples() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "normal"
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first, link)
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == link.spaceID })
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-exit") })
    }

    func testUnknownNativeSpaceExitRequiresFiveSamples() throws {
        let (initial, backend) = try fixture()
        let tracking = RestoreTrackingBackend(backend)
        let engine = try DynamicEngine(configuration: initial.configuration, state: initial.state, backend: tracking, isProcessAlive: { _ in true })
        let before = engine.map
        let link = try XCTUnwrap(before.fullscreens.first)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "unknown"
        for sample in 1...4 {
            try engine.refresh()
            assertMapPreserved(engine, before, sample: sample)
            XCTAssertEqual(tracking.restores, 0)
            XCTAssertTrue(engine.consumeEvents().contains {
                $0.hasPrefix("fullscreen-doubt kind=windowed-unknown count=\(sample) ")
            })
        }
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == link.spaceID })
        XCTAssertEqual(tracking.restores, 1, "confirmed exit uses the existing restoration path")
        XCTAssertTrue(engine.consumeEvents().contains { $0.hasPrefix("fullscreen-exit") })
    }

    func testCurrentNativeSpaceSampleDecidesExitThreshold() throws {
        for evidence in [["unknown", "normal"], ["normal", "unknown", "normal"],
                         ["normal", "unknown", "unknown", "unknown", "unknown"]] {
            let (engine, backend) = try fixture()
            let link = try XCTUnwrap(engine.map.fullscreens.first)
            backend.screen.windows?[0].nativeFullscreen = false
            for (index, nativeSpace) in evidence.enumerated() {
                backend.screen.windows?[0].nativeSpace = nativeSpace
                try engine.refresh()
                if index < evidence.count - 1 { XCTAssertEqual(engine.map.fullscreens, [link]) }
                else { XCTAssertTrue(engine.map.fullscreens.isEmpty) }
            }
        }
    }

    func testUnrecognizedNativeSpaceUsesUnknownThreshold() throws {
        let (engine, backend) = try fixture()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "future-value"
        for _ in 0..<4 { try engine.refresh(); XCTAssertEqual(engine.map.fullscreens, [link]) }
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }

    func testDisagreementResetsSamplesAndLogsAgainAfterFullscreenReturns() throws {
        let (engine, backend) = try fixture()
        let before = engine.map
        _ = engine.consumeEvents()
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "unknown"
        for _ in 0..<4 { try engine.refresh() }
        backend.screen.windows?[0].nativeSpace = "fullscreen"
        for _ in 0..<5 { try engine.refresh() }
        XCTAssertEqual(engine.consumeEvents().filter { $0.hasPrefix("fullscreen-doubt kind=disagree ") }.count, 1)
        backend.screen.windows?[0].nativeSpace = "normal"
        try engine.refresh()
        assertMapPreserved(engine, before, sample: 10)
        backend.screen.windows?[0].nativeFullscreen = true
        try engine.refresh()
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "fullscreen"
        try engine.refresh()
        assertMapPreserved(engine, before, sample: 12)
        XCTAssertEqual(engine.consumeEvents().filter { $0.hasPrefix("fullscreen-doubt kind=disagree ") }.count, 1)
    }

    func testLegacyWindowInfoDecodesWithoutNativeSpace() throws {
        let json = #"{"id":1,"pid":2,"boot":"test","workspace":"legacy","floating":false,"title":"","appName":"","bundleID":"test","nativeFullscreen":true,"nativeMonitor":1}"#
        let decoded = try JSONDecoder().decode(WindowInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.nativeSpace)
        XCTAssertEqual(decoded, WindowInfo(id: 1, pid: 2, workspace: "legacy", title: "", appName: "", nativeFullscreen: true, nativeMonitor: 1))
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
