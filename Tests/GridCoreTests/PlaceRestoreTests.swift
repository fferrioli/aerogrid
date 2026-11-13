import XCTest
@testable import GridCore

final class PlaceRestoreTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var config: Configuration!
    private var backend: PlaceRestoreBackend!
    private var engine: DynamicEngine!
    private var home: Cell { config.grids[1].cells[4] }
    private var other: Cell { config.grids[0].cells[4] }

    override func setUpWithError() throws {
        config = Configuration(backendPath: "/unused")
        let displays = [
            Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1710, height: 1073),
            Display(id: "external", monitor: 2, name: "External", builtin: false, width: 5120, height: 1410)
        ]
        var desktop = Desktop(displays: displays, visible: [1: other.workspace, 2: home.workspace], focusedMonitor: 1)
        desktop.nativeVisible = [:]
        backend = PlaceRestoreBackend(desktop)
        backend.model.setWindows([
            WindowInfo(id: 101, pid: 21, boot: "new", workspace: other.workspace, bundleID: "app.editor"),
            WindowInfo(id: 102, pid: 22, boot: "new", workspace: other.workspace, bundleID: "app.browser")
        ])
        var map = SpaceMap(configuration: config)
        map.placeTemplates = [home.id: PlaceTemplate(tree: TemplateNode(orientation: "v", layout: "tiles", children: [
            TemplateNode(weight: 2, slot: TemplateSlot(bundleID: "app.editor", ordinal: 0)),
            TemplateNode(weight: 3, slot: TemplateSlot(bundleID: "app.browser", ordinal: 0))
        ]), capturedAt: clock)]
        var state = RuntimeState()
        state.dynamicMap = map
        engine = try DynamicEngine(configuration: config, state: state, backend: backend, now: { self.clock })
    }

    func testNewBootRestoresTemplatesWithCurrentIdentities() throws {
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [101, 102])
        let restored = try XCTUnwrap(backend.restores.last { $0.0 == home.workspace }?.1)
        XCTAssertEqual(restored.boot, "new")
        XCTAssertEqual(restored.tree.orientation, "v")
        XCTAssertEqual(restored.tree.children?.map(\.id), [101, 102])
        XCTAssertEqual(restored.tree.children?.map(\.weight), [2, 3])
        let events = engine.consumeEvents().filter { $0.hasPrefix("place-restored ") }
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains("place-restored window=101 pid=21 space=\(home.id.prefix(8)) ordinal=0"))
        XCTAssertFalse(events.joined().contains("app.editor"))
    }

    func testExpiredDeadlineAllowsManualRestoreAndSingleUndo() throws {
        engine.placeRestoreDeadline = clock
        try engine.refresh()
        XCTAssertTrue(backend.model.windowMoves.isEmpty)
        XCTAssertEqual(try engine.restorePlaces(), 2)
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [101, 102])
        XCTAssertEqual(engine.map.undo.map(\.label), ["Restaurar lugares"])
        try engine.undo()
        XCTAssertEqual(try backend.windows(workspace: other.workspace), [101, 102])
        XCTAssertTrue(engine.map.undo.isEmpty)
    }

    func testUserMoveAfterRestorationIsRespectedAutomaticallyAndManually() throws {
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        let identity = try XCTUnwrap(backend.model.screen.windows?.first?.identity)
        try backend.model.move(window: identity.id, workspace: other.workspace)
        backend.model.windowMoves.removeAll()
        try engine.refresh()
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(identity) == true)
        XCTAssertTrue(backend.model.windowMoves.isEmpty)
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
    }

    func testRuledWindowIsExcludedFromAutomaticAndManualRestore() throws {
        backend.model.screen.windows?[0].ruled = true
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertEqual(backend.model.windowMoves, [102])
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertFalse(engine.map.placeRestore?.restored.contains(try XCTUnwrap(backend.model.screen.windows?.first?.identity)) == true)
    }

    func testFailedMoveIsRecordedAndNotRetriedAutomatically() throws {
        backend.model.failWindow = 101
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertTrue(engine.consumeEvents().contains("place-restore-failed window=101 pid=21 space=\(home.id.prefix(8)) ordinal=0"))
        let identity = try XCTUnwrap(backend.model.screen.windows?.first?.identity)
        XCTAssertTrue(engine.map.placeRestore?.restored.contains(identity) == true)
        backend.model.failWindow = nil
        try engine.refresh()
        XCTAssertEqual(backend.model.windowMoves.filter { $0 == 101 }.count, 1)
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertFalse(engine.consumeEvents().contains { $0.hasPrefix("place-restore-failed ") })
    }

    func testFullscreenSlotEntersFullscreenOnlyOnce() throws {
        var map = engine.map
        map.placeTemplates = [home.id: .fullscreen(slot: TemplateSlot(bundleID: "app.editor", ordinal: 0), capturedAt: clock)]
        var state = RuntimeState()
        state.dynamicMap = map
        engine = try DynamicEngine(configuration: config, state: state, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        let identity = try XCTUnwrap(backend.model.screen.windows?.first?.identity)
        XCTAssertEqual(backend.fullscreenEntries, [identity])
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, home.workspace)
        try engine.refresh()
        try engine.refresh()
        XCTAssertEqual(backend.fullscreenEntries, [identity])
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertEqual(backend.fullscreenEntries, [identity])
    }

    func testLegacyStateAndWindowDecodeWithoutOptionalFields() throws {
        var encodedWindow = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(backend.model.screen.windows?.first))) as? [String: Any])
        encodedWindow.removeValue(forKey: "ruled")
        let decodedWindow = try JSONDecoder().decode(WindowInfo.self, from: JSONSerialization.data(withJSONObject: encodedWindow))
        XCTAssertNil(decodedWindow.ruled)
        encodedWindow["ruled"] = true
        XCTAssertEqual(try JSONDecoder().decode(WindowInfo.self, from: JSONSerialization.data(withJSONObject: encodedWindow)).ruled, true)
        var encodedMap = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.map)) as? [String: Any])
        encodedMap.removeValue(forKey: "placeRestore")
        let decodedMap = try JSONDecoder().decode(SpaceMap.self, from: JSONSerialization.data(withJSONObject: encodedMap))
        XCTAssertNil(decodedMap.placeRestore)
        XCTAssertEqual(decodedMap.placeTemplates, engine.map.placeTemplates)
    }

    func testRestorationStatePersistsAndResetsOnNewBoot() throws {
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        backend.model.failWindow = 101
        try engine.refresh()
        let saved = try JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(engine.state))
        XCTAssertEqual(saved.dynamicMap?.placeRestore?.boot, "new")
        backend.model.failWindow = nil
        backend.model.windowMoves.removeAll()
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertTrue(backend.model.windowMoves.isEmpty)
        backend.model.setWindows([WindowInfo(id: 101, pid: 21, boot: "next", workspace: other.workspace, bundleID: "app.editor")])
        try engine.refresh()
        XCTAssertEqual(engine.map.placeRestore?.boot, "next")
        XCTAssertEqual(engine.map.placeRestore?.restored, [WindowIdentity(id: 101, pid: 21, boot: "next")])
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [101])
    }

    func testOrganizationMoveMarksWindowAsUserPlaced() throws {
        try engine.refresh()
        let identity = try XCTUnwrap(backend.model.screen.windows?.first?.identity)
        try engine.moveWindow(identity, to: home.id)
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(identity) == true)
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertFalse(engine.map.placeRestore?.restored.contains(identity) == true)
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(identity) == true)
    }

    func testSameWorkspaceOrganizationMarksWindowAsUserPlaced() throws {
        try engine.refresh()
        let windows = try XCTUnwrap(backend.model.screen.windows)
        try engine.reorderWindow(windows[1].identity, before: windows[0].identity)
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(windows[1].identity) == true)
        XCTAssertEqual(backend.model.screen.windows?.map(\.workspace), [other.workspace, other.workspace])
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertFalse(engine.map.placeRestore?.restored.contains(windows[1].identity) == true)
        XCTAssertEqual(try engine.restorePlaces(), 0)
    }

    func testDormantTargetAndLaterWindowRestoreInSeparateRefreshes() throws {
        var state = engine.state
        let homeIndex = try XCTUnwrap(state.dynamicMap?.spaces.firstIndex { $0.id == home.id })
        state.dynamicMap?.spaces[homeIndex].dormant = true
        backend.model.setWindows([try XCTUnwrap(backend.model.screen.windows?.first)])
        engine = try DynamicEngine(configuration: config, state: state, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [101])
        XCTAssertEqual(engine.map.placeTemplates?[home.id]?.slots.count, 2)
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows) + [WindowInfo(id: 103, pid: 22, boot: "new", workspace: other.workspace, bundleID: "app.browser")])
        try engine.refresh()
        let restored = try XCTUnwrap(backend.restores.last?.1)
        XCTAssertEqual(restored.tree.children?.map(\.id), [101, 103])
        XCTAssertEqual(restored.tree.children?.map(\.weight), [2, 3])
        XCTAssertEqual(backend.model.windowMoves.filter { $0 == 101 }.count, 1)
    }

    func testLayoutRestoreFailureDoesNotRetryMoves() throws {
        backend.failRestoreWorkspace = home.workspace
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [101, 102])
        XCTAssertTrue(engine.consumeEvents().contains("place-layout-failed space=\(home.id.prefix(8))"))
        let moves = backend.model.windowMoves
        backend.failRestoreWorkspace = nil
        try engine.refresh()
        XCTAssertEqual(backend.model.windowMoves, moves)
    }
}

private final class PlaceRestoreBackend: Backend {
    let model: MapBackend
    var restores: [(String, LayoutSnapshot)] = []
    var fullscreenEntries: [WindowIdentity] = []
    var failRestoreWorkspace: String?
    init(_ desktop: Desktop) { model = MapBackend(desktop) }
    func desktop() throws -> Desktop { try model.desktop() }
    func validate(workspace: String, monitor: Int) throws {}
    func place(workspace: String, monitor: Int) throws { try model.place(workspace: workspace, monitor: monitor) }
    func activate(workspace: String) throws {}
    func focus(monitor: Int, window: UInt32?) throws { try model.focus(monitor: monitor, window: window) }
    func focus(window: UInt32) throws { try model.focus(window: window) }
    func windows(workspace: String) throws -> [UInt32] { try model.windows(workspace: workspace) }
    func move(window: UInt32, workspace: String) throws { try model.move(window: window, workspace: workspace) }
    func moveVerified(window: WindowIdentity, workspace: String) throws {
        guard model.screen.windows?.contains(where: { $0.identity == window }) == true else { throw GridError.stale }
        try model.move(window: window.id, workspace: workspace)
    }
    func recoverWindowHomes(_ homes: [WindowHome]) throws { try model.recoverWindowHomes(homes) }
    func snapshot(workspace: String) throws -> String {
        let boot = model.screen.windows?.first?.boot ?? "new"
        if model.trees[workspace]?.boot != boot { model.trees[workspace] = LayoutSnapshot(boot: boot, tree: .root([])) }
        return try model.snapshot(workspace: workspace)
    }
    func restore(workspace: String, snapshot: String) throws {
        if failRestoreWorkspace == workspace { throw GridError.unavailable("Injected layout restore failure") }
        restores.append((workspace, try LayoutSnapshot(json: snapshot)))
        try model.restore(workspace: workspace, snapshot: snapshot)
    }
    func enterFullscreen(window: WindowIdentity) throws {
        fullscreenEntries.append(window)
        let index = try XCTUnwrap(model.screen.windows?.firstIndex { $0.identity == window })
        model.screen.windows?[index].nativeFullscreen = true
        model.screen.windows?[index].nativeMonitor = 2
    }
    func layout(workspace: String, profile: String) throws {}
}


// Regressions from the independent F1-1 review.
extension PlaceRestoreTests {
    func testExternalMoveOfLastWindowClearsSourceTemplate() throws {
        var editor = try XCTUnwrap(backend.model.screen.windows?.first)
        editor.workspace = home.workspace
        backend.model.setWindows([editor])
        try engine.refresh()

        try backend.model.move(window: editor.id, workspace: other.workspace)
        try engine.refresh()

        XCTAssertNil(engine.map.placeTemplates?[home.id])
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertEqual(try backend.windows(workspace: other.workspace), [editor.id])
    }

    func testBlackoutRecoveryResetsUserPlacementBaseline() throws {
        try engine.refresh()
        let original = try XCTUnwrap(backend.model.screen.windows)
        let editor = original[0]
        backend.model.setWindows([])
        try engine.refresh()
        backend.model.setWindows(original.map { window in
            var window = window
            if window.id == editor.id { window.workspace = home.workspace }
            return window
        })

        try engine.refresh()
        XCTAssertFalse(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)
        try engine.refresh()
        XCTAssertFalse(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)

        try backend.model.move(window: editor.id, workspace: other.workspace)
        try engine.refresh()
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)
    }

    func testFoldMovementIsNotInferredAsUserPlacementOnNextRefresh() throws {
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows).map { window in
            var window = window
            window.workspace = home.workspace
            return window
        })
        try engine.refresh()
        let identities = try XCTUnwrap(backend.model.screen.windows).map(\.identity)
        backend.model.screen.displays.removeAll { !$0.builtin }
        backend.model.screen.visible = [1: home.workspace]
        try engine.refresh()
        XCTAssertFalse(engine.map.families.isEmpty)

        try engine.refresh()

        for identity in identities {
            XCTAssertFalse(engine.map.placeRestore?.userPlaced.contains(identity) == true)
        }
    }

    func testReviewExternalMoveRemovesSourceSlot() throws {
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows).map { window in
            var window = window; window.workspace = home.workspace; return window
        })
        try engine.refresh()
        let editor = try XCTUnwrap(backend.model.screen.windows?.first)
        try backend.model.move(window: editor.id, workspace: other.workspace)
        try engine.refresh()
        XCTAssertTrue(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)
        XCTAssertEqual(engine.map.placeTemplates?[home.id]?.slots.map(\.bundleID), ["app.browser"])
    }

    func testReviewBackendRecoveryIsNotUserPlacement() throws {
        backend.model.screen.backendSession = "before"
        try engine.refresh()
        backend.model.screen.backendSession = "after"
        let editor = try XCTUnwrap(backend.model.screen.windows?.first)
        try backend.model.move(window: editor.id, workspace: home.workspace)
        try engine.refresh()
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertFalse(engine.map.placeRestore?.userPlaced.contains(editor.identity) == true)
        XCTAssertEqual(try engine.restorePlaces(), 2)
    }

    func testManualRestoreIgnoresFullscreenSlots() throws {
        var state = engine.state
        state.dynamicMap?.placeTemplates = [home.id: .fullscreen(slot: TemplateSlot(bundleID: "app.editor", ordinal: 0), capturedAt: clock)]
        engine = try DynamicEngine(configuration: config, state: state, backend: backend, now: { self.clock })
        XCTAssertEqual(try engine.restorePlaces(), 0)
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertFalse(backend.model.screen.windows?.first?.nativeFullscreen == true)
        XCTAssertTrue(backend.fullscreenEntries.isEmpty)
        try engine.undo()
        XCTAssertEqual(backend.model.screen.windows?.first?.workspace, other.workspace)
        XCTAssertFalse(backend.model.screen.windows?.first?.nativeFullscreen == true)
    }

    func testReviewFoldedPlacesSurviveNewBoot() throws {
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows).map { window in
            var window = window; window.workspace = home.workspace; return window
        })
        try engine.refresh()
        backend.model.screen.displays.removeAll { !$0.builtin }
        backend.model.screen.visible = [1: home.workspace]
        try engine.refresh()
        let family = try XCTUnwrap(engine.map.families.first { $0.sourceID == home.id })
        let childID = try XCTUnwrap(family.childIDs.first { $0 != home.id })
        let child = try XCTUnwrap(engine.map.spaces.first { $0.id == childID })
        XCTAssertEqual(try backend.windows(workspace: child.workspace), [102])
        let saved = engine.state
        backend.model.setWindows([
            WindowInfo(id: 201, pid: 31, boot: "next", workspace: other.workspace, bundleID: "app.editor"),
            WindowInfo(id: 202, pid: 32, boot: "next", workspace: other.workspace, bundleID: "app.browser")
        ])
        backend.model.trees.removeAll()
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: child.workspace), [202])
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [201])
    }
}


extension PlaceRestoreTests {
    func testReviewShutdownThenReverseLaunchPreservesPlaces() throws {
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows).map { window in
            var window = window; window.workspace = home.workspace; return window
        })
        backend.model.trees[home.workspace] = LayoutSnapshot(boot: "new", tree: .root([
            LayoutNode(id: 101, pid: 21, weight: 2), LayoutNode(id: 102, pid: 22, weight: 3)
        ], orientation: "v"))
        try engine.refresh()
        let original = try XCTUnwrap(engine.map.placeTemplates?[home.id])
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows).filter { $0.id == 101 })
        try engine.refresh()
        backend.model.setWindows([])
        for _ in 0...DynamicEngine.blackoutLimit { try engine.refresh() }
        XCTAssertEqual(engine.map.placeTemplates?[home.id], original)
        let saved = engine.state
        backend.model.setWindows([WindowInfo(id: 201, pid: 31, boot: "next", workspace: other.workspace, bundleID: "app.browser")])
        backend.model.trees.removeAll()
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)
        try engine.refresh()
        XCTAssertEqual(engine.map.placeTemplates?[home.id], original)
        backend.model.setWindows(try XCTUnwrap(backend.model.screen.windows) + [WindowInfo(id: 202, pid: 32, boot: "next", workspace: other.workspace, bundleID: "app.editor")])
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: home.workspace), [201, 202])
        let restored = try XCTUnwrap(backend.restores.last?.1)
        XCTAssertEqual(restored.tree.children?.map(\.id), [202, 201])
        XCTAssertEqual(restored.tree.children?.map(\.weight), [2, 3])
        XCTAssertEqual(backend.model.windowMoves.filter { $0 == 201 }.count, 1)
        XCTAssertEqual(backend.model.windowMoves.filter { $0 == 202 }.count, 1)
    }
}
