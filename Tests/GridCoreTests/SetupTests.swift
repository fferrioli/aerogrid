import XCTest
@testable import GridCore

final class SetupTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var configuration: Configuration!
    private var backend: MapBackend!
    private var engine: DynamicEngine!
    private var editor: Space!
    private var chat: Space!

    override func setUpWithError() throws {
        configuration = Configuration(backendPath: "/unused")
        editor = Space(id: "editor-space", name: "Trabajo", row: 0, column: 0,
                       workspace: "editor", preferredRole: "builtin")
        chat = Space(id: "chat-space", name: "Chat", row: 0, column: 0,
                     workspace: "chat", preferredRole: "external")
        let desktop = Desktop(displays: [
            Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1710, height: 1073),
            Display(id: "external", monitor: 2, name: "External", builtin: false, width: 2560, height: 1440)
        ], visible: [1: editor.workspace, 2: chat.workspace], focusedMonitor: 1)
        backend = MapBackend(desktop)
        backend.setWindows([
            WindowInfo(id: 1, pid: 21, boot: "old", workspace: editor.workspace, bundleID: "app.editor"),
            WindowInfo(id: 2, pid: 22, boot: "old", workspace: editor.workspace, bundleID: "app.browser"),
            WindowInfo(id: 3, pid: 23, boot: "old", workspace: chat.workspace, bundleID: "app.chat")
        ])
        backend.trees[editor.workspace] = LayoutSnapshot(boot: "old", tree: .root([
            LayoutNode(id: 1, pid: 21, weight: 2),
            LayoutNode(id: 2, pid: 22, weight: 3)
        ], orientation: "v"))
        backend.trees[chat.workspace] = LayoutSnapshot(boot: "old", tree: .root([LayoutNode(id: 3, pid: 23)]))
        var map = SpaceMap(configuration: configuration)
        map.version = 3
        map.initialized = true
        map.spaces = [editor, chat]
        var state = RuntimeState()
        state.dynamicMap = map
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })
    }

    private func restartAwayFromSavedPlaces() throws {
        var map = engine.map
        map.spaces.removeAll { $0.id == chat.id }
        map.spaces[0].rect = SpaceRect(row: 20, column: 20)
        map.spaces.append(Space(id: "launch-space", name: "Inicio", row: 10, column: 10,
                                workspace: "launch", preferredRole: "builtin"))
        map.layouts = [:]
        map.undo = []
        backend.screen.visible = [1: "launch", 2: editor.workspace]
        backend.setWindows([
            WindowInfo(id: 101, pid: 31, boot: "new", workspace: "launch", bundleID: "app.editor"),
            WindowInfo(id: 102, pid: 32, boot: "new", workspace: "launch", bundleID: "app.browser"),
            WindowInfo(id: 103, pid: 33, boot: "new", workspace: "launch", bundleID: "app.chat")
        ])
        backend.trees = ["launch": LayoutSnapshot(boot: "new", tree: .root([
            LayoutNode(id: 101, pid: 31), LayoutNode(id: 102, pid: 32), LayoutNode(id: 103, pid: 33)
        ]))]
        var state = RuntimeState()
        state.dynamicMap = map
        state.lastDesktop = backend.screen
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })
        try engine.refresh()
    }

    func testSavedSetupAppliesAfterNewBootWithNewWindowIdentities() throws {
        let setup = try engine.makeSetup(name: "Trabajo")
        XCTAssertEqual(setup.spaces.map(\.spaceID), [editor.id, chat.id])
        try restartAwayFromSavedPlaces()

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result.moved, 3)
        XCTAssertEqual(result.missingBundleIDs, [])
        XCTAssertEqual(engine.map.spaces.first { $0.id == editor.id }?.rect, editor.rect)
        let recreated = try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id })
        XCTAssertEqual(recreated.rect, chat.rect)
        XCTAssertTrue(recreated.userCreated)
        XCTAssertEqual(try backend.windows(workspace: editor.workspace), [101, 102])
        XCTAssertEqual(try backend.windows(workspace: chat.workspace), [103])
        let layout = try XCTUnwrap(backend.trees[editor.workspace])
        XCTAssertEqual(layout.boot, "new")
        XCTAssertEqual(layout.tree.orientation, "v")
        XCTAssertEqual(layout.tree.children?.map(\.id), [101, 102])
        XCTAssertEqual(layout.tree.children?.map(\.weight), [2, 3])
        XCTAssertEqual(engine.map.undo.map(\.label), ["Aplicar setup"])
    }

    func testUndoRestoresPreviousSpacesTemplatesAndWindowHomes() throws {
        let setup = try engine.makeSetup(name: "Trabajo")
        try restartAwayFromSavedPlaces()
        // An absent app's remembered slot cannot be reconstructed from live windows on Undo.
        var previousState = engine.state
        previousState.dynamicMap?.placeTemplates = [editor.id: PlaceTemplate(tree: TemplateNode(
            orientation: "h", layout: "tiles", children: [
                TemplateNode(slot: TemplateSlot(bundleID: "app.absent", ordinal: 0))
            ]), capturedAt: clock.addingTimeInterval(-3600))]
        engine = try DynamicEngine(configuration: configuration, state: previousState, backend: backend, now: { self.clock })
        try engine.refresh()
        let previousSpaces = engine.map.spaces
        let previousTemplates = engine.map.placeTemplates
        let previousHomes = backend.screen.windowHomes
        let previousLayout = try LayoutSnapshot(json: backend.snapshot(workspace: "launch"))

        _ = try engine.applySetup(setup)
        try engine.undo()

        XCTAssertEqual(engine.map.spaces, previousSpaces)
        XCTAssertEqual(engine.map.placeTemplates, previousTemplates)
        XCTAssertEqual(backend.screen.windowHomes, previousHomes)
        XCTAssertEqual(try LayoutSnapshot(json: backend.snapshot(workspace: "launch")), previousLayout)
        XCTAssertTrue(engine.map.undo.isEmpty)
    }

    func testMissingAppsAreUniqueInFirstSlotOrder() throws {
        var setup = try engine.makeSetup(name: "Ausentes")
        let absent = TemplateSlot(bundleID: "app.absent", ordinal: 0)
        let second = TemplateSlot(bundleID: "app.second", ordinal: 0)
        setup.spaces[0].template = PlaceTemplate(tree: TemplateNode(children: [
            TemplateNode(slot: absent), TemplateNode(slot: second),
            TemplateNode(slot: TemplateSlot(bundleID: absent.bundleID, ordinal: 1))
        ]), capturedAt: clock)
        setup.spaces[1].template = PlaceTemplate(tree: TemplateNode(slot: absent), capturedAt: clock)

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result.missingBundleIDs, [absent.bundleID, second.bundleID])
        XCTAssertEqual(result.moved, 0)
        let events = engine.consumeEvents().filter { $0.hasPrefix("setup-applied ") }
        XCTAssertEqual(events, ["setup-applied space=editor-s moved=0 missing=3",
                                "setup-applied space=chat-spa moved=0 missing=1"])
        XCTAssertFalse(events.joined().contains("app."))
        XCTAssertFalse(events.joined().contains(setup.name))
    }

    func testApplyIgnoresFullscreenSlotsAndCanUndo() throws {
        var setup = try engine.makeSetup(name: "Fullscreen")
        setup.spaces = [setup.spaces[0]]
        setup.spaces[0].template = .fullscreen(slot: TemplateSlot(bundleID: "app.editor", ordinal: 0), capturedAt: clock)
        try restartAwayFromSavedPlaces()
        let previousSpaces = engine.map.spaces
        let previousTemplates = engine.map.placeTemplates
        let previousWindows = backend.screen.windows
        backend.windowMoves = []

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result, SetupApplyResult(moved: 0, missingBundleIDs: []))
        XCTAssertTrue(backend.windowMoves.isEmpty)
        XCTAssertEqual(backend.screen.windows, previousWindows)
        XCTAssertEqual(engine.map.placeTemplates?[editor.id], setup.spaces[0].template)
        XCTAssertEqual(engine.map.undo.map(\.label), ["Aplicar setup"])
        try engine.undo()
        XCTAssertEqual(engine.map.spaces, previousSpaces)
        XCTAssertEqual(engine.map.placeTemplates, previousTemplates)
        XCTAssertEqual(backend.screen.windows, previousWindows)
    }

    func testFullscreenSlotDoesNotConsumeCandidateForNormalSlot() throws {
        var setup = try engine.makeSetup(name: "Mixto")
        let slot = TemplateSlot(bundleID: "app.editor", ordinal: 0)
        setup.spaces[0].template = .fullscreen(slot: slot, capturedAt: clock)
        setup.spaces[1].template = PlaceTemplate(tree: TemplateNode(slot: slot), capturedAt: clock)
        try restartAwayFromSavedPlaces()

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result, SetupApplyResult(moved: 1, missingBundleIDs: []))
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 101 }?.workspace, chat.workspace)
        XCTAssertFalse(backend.screen.windows?.contains { $0.nativeFullscreen } == true)
        try engine.undo()
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 101 }?.workspace, "launch")
    }

    func testOutsideSpaceWindowAndTemplateRemainUnchanged() throws {
        var setup = try engine.makeSetup(name: "Solo editor")
        setup.spaces.removeAll { $0.spaceID == chat.id }
        try restartAwayFromSavedPlaces()
        let outsider = Space(id: "outside", name: "Otro", row: 4, column: 5,
                             workspace: "outside", preferredRole: "builtin")
        let template = PlaceTemplate.fullscreen(slot: TemplateSlot(bundleID: "app.unopened", ordinal: 0), capturedAt: clock)
        var state = engine.state
        state.dynamicMap?.spaces.append(outsider)
        state.dynamicMap?.placeTemplates?[outsider.id] = template
        backend.setWindows(try XCTUnwrap(backend.screen.windows) + [
            WindowInfo(id: 104, pid: 34, boot: "new", workspace: outsider.workspace, bundleID: "app.other")
        ])
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })
        try engine.refresh()
        let previousSpace = engine.map.spaces.first { $0.id == outsider.id }
        let previousTemplate = engine.map.placeTemplates?[outsider.id]
        let previousWindow = backend.screen.windows?.first { $0.id == 104 }
        backend.windowMoves = []

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(engine.map.spaces.first { $0.id == outsider.id }, previousSpace)
        XCTAssertEqual(engine.map.placeTemplates?[outsider.id], previousTemplate)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 104 }, previousWindow)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 103 }?.workspace, "launch")
        XCTAssertFalse(backend.windowMoves.contains(103))
        XCTAssertFalse(backend.windowMoves.contains(104))
    }

    func testRuledWindowStaysAndItsUnfilledSlotIsReported() throws {
        let setup = try engine.makeSetup(name: "Reglas")
        try restartAwayFromSavedPlaces()
        backend.screen.windows?[0].ruled = true
        backend.windowMoves = []

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.missingBundleIDs, ["app.editor"])
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 101 }?.workspace, "launch")
        XCTAssertFalse(backend.windowMoves.contains(101))
    }

    func testExplicitApplyIgnoresSessionRestoredAndUserPlacedRestrictions() throws {
        let setup = try engine.makeSetup(name: "Explícito")
        try restartAwayFromSavedPlaces()
        let identities = try XCTUnwrap(backend.screen.windows).map(\.identity)
        var state = engine.state
        state.dynamicMap?.placeRestore = PlaceRestoreState(boot: "new", restored: identities, userPlaced: identities)
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })
        engine.placeRestoreDeadline = clock.addingTimeInterval(300)

        XCTAssertEqual(try engine.applySetup(setup).moved, 3)
        XCTAssertEqual(try backend.windows(workspace: editor.workspace), [101, 102])
        XCTAssertEqual(try backend.windows(workspace: chat.workspace), [103])
    }

    func testStoreRoundTripMissingFileRenameAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        XCTAssertEqual(try store.loadSetups(), [])
        var setup = try engine.makeSetup(name: "Duplicado")
        setup.spaces[0].foldedRect = SpaceRect(row: 5, column: 6, width: 2, height: 3)
        setup.spaces[0].boardID = "board-id"
        let duplicate = Setup(name: setup.name, createdAt: clock.addingTimeInterval(10), spaces: [])
        try store.saveSetups([setup, duplicate])

        XCTAssertEqual(try store.loadSetups(), [setup, duplicate])
        let data = try Data(contentsOf: directory.appendingPathComponent("setups.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let spaces = try XCTUnwrap(json.first?["spaces"] as? [[String: Any]])
        XCTAssertNil(spaces.first?["nativeWindow"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("pid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
        try store.renameSetup(id: setup.id, name: "Nuevo")
        setup.name = "Nuevo"
        XCTAssertEqual(try store.loadSetups(), [setup, duplicate])
        try store.deleteSetup(id: setup.id)
        XCTAssertEqual(try store.loadSetups(), [duplicate])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("setups.json.backup").path))
    }

    func testMoveFailureRollsBackSpacesTemplatesAndHomes() throws {
        let setup = try engine.makeSetup(name: "Falla")
        try restartAwayFromSavedPlaces()
        let before = engine.map
        let homes = backend.screen.windowHomes
        backend.failWindow = 102

        XCTAssertThrowsError(try engine.applySetup(setup))

        XCTAssertEqual(engine.map.spaces, before.spaces)
        XCTAssertEqual(engine.map.placeTemplates, before.placeTemplates)
        XCTAssertEqual(backend.screen.windowHomes, homes)
        XCTAssertEqual(engine.map.undo, before.undo)
        XCTAssertNil(engine.map.pending)
        XCTAssertFalse(engine.consumeEvents().contains { $0.hasPrefix("setup-applied ") })
    }

    func testPendingRecoveryRestoresCheckpointTemplates() throws {
        _ = try engine.makeSetup(name: "Recuperar")
        let before = engine.map
        let checkpoint = MapCheckpoint(spaces: before.spaces, families: before.families, fullscreens: before.fullscreens,
                                       homes: try XCTUnwrap(backend.screen.windowHomes), layouts: before.layouts,
                                       placeTemplates: before.placeTemplates)
        var state = engine.state
        state.dynamicMap?.placeTemplates = [:]
        state.dynamicMap?.spaces[0].rect = SpaceRect(row: 9, column: 9)
        state.dynamicMap?.pending = PendingOrganization(before: checkpoint, desiredHomes: [])
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })

        try engine.refresh()

        XCTAssertEqual(engine.map.spaces, before.spaces)
        XCTAssertEqual(engine.map.placeTemplates, before.placeTemplates)
        XCTAssertNil(engine.map.pending)
    }

    func testCheckpointWithoutTemplatesStillDecodes() throws {
        let checkpoint = MapCheckpoint(spaces: [editor, chat], families: [], fullscreens: [], homes: [], layouts: [:])
        let data = try JSONEncoder().encode(checkpoint)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["placeTemplates"])
        XCTAssertEqual(try JSONDecoder().decode(MapCheckpoint.self, from: data), checkpoint)
    }

    func testCollisionsUseVacanciesWithoutDisplacingOutsideSpace() throws {
        var setup = try engine.makeSetup(name: "Colisión")
        setup.spaces.removeAll { $0.spaceID == chat.id }
        setup.spaces[0].rect = SpaceRect(row: 10, column: 10, width: 2, height: 2)
        setup.spaces[0].foldedRect = SpaceRect(row: 10, column: 10)
        try restartAwayFromSavedPlaces()
        let outside = try XCTUnwrap(engine.map.spaces.first { $0.workspace == "launch" })
        var state = engine.state
        let index = try XCTUnwrap(state.dynamicMap?.spaces.firstIndex { $0.id == outside.id })
        state.dynamicMap?.spaces[index].foldedRect = setup.spaces[0].foldedRect
        engine = try DynamicEngine(configuration: configuration, state: state, backend: backend, now: { self.clock })

        _ = try engine.applySetup(setup)

        let applied = try XCTUnwrap(engine.map.spaces.first { $0.id == editor.id })
        XCTAssertFalse(applied.rect.overlaps(outside.rect))
        XCTAssertFalse(try XCTUnwrap(applied.foldedRect).overlaps(try XCTUnwrap(setup.spaces[0].foldedRect)))
        XCTAssertEqual(engine.map.spaces.first { $0.id == outside.id }?.rect, outside.rect)
        try engine.map.validate()
    }

    func testAbsentDisplayKeepsBoardAndUsesFoldedGeometry() throws {
        let setup = try engine.makeSetup(name: "Pantalla ausente")
        try restartAwayFromSavedPlaces()
        backend.screen.displays.removeAll { !$0.builtin }
        backend.screen.visible = [1: "launch"]

        let result = try engine.applySetup(setup)

        XCTAssertEqual(result.moved, 3)
        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id })
        XCTAssertEqual(restored.board, "external")
        XCTAssertEqual(restored.rect, chat.rect)
        XCTAssertNotNil(restored.foldedRect)
        try engine.map.validate()
    }
}
