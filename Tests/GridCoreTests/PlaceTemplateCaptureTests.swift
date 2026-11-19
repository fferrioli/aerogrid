import XCTest
@testable import GridCore

final class PlaceTemplateCaptureTests: XCTestCase {
    private var config: Configuration!
    private var backend: MapBackend!
    private var engine: DynamicEngine!
    private var home: Cell { config.grids[1].cells[4] }

    override func setUpWithError() throws {
        config = Configuration(backendPath: "/unused")
        let laptop = Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1710, height: 1073)
        let external = Display(id: "external", monitor: 2, name: "External", builtin: false, width: 5120, height: 1410)
        var desktop = Desktop(displays: [laptop, external], visible: [1: config.grids[0].cells[4].workspace, 2: home.workspace], focusedMonitor: 2, focusedWindow: 1)
        desktop.nativeVisible = [:]
        desktop.backendSession = "session"
        backend = MapBackend(desktop)
        backend.setWindows([
            WindowInfo(id: 1, workspace: home.workspace, bundleID: "app.editor"),
            WindowInfo(id: 2, workspace: home.workspace, bundleID: "app.editor"),
            WindowInfo(id: 3, workspace: home.workspace, bundleID: "app.browser")
        ])
        backend.trees[home.workspace] = LayoutSnapshot(boot: "test", tree: .root([
            LayoutNode(id: 2, pid: 1, weight: 2),
            LayoutNode(id: 1, pid: 1, weight: 3),
            LayoutNode(id: 3, pid: 1)
        ]))
        engine = try DynamicEngine(configuration: config, backend: backend)
    }

    // Inspect the serialized map too: templates must survive state.json round trips.
    private func templates(_ engine: DynamicEngine) throws -> [String: PlaceTemplate] {
        let data = try JSONEncoder().encode(engine.map)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard let value = object["placeTemplates"] else { return [:] }
        return try JSONDecoder().decode([String: PlaceTemplate].self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testCapturePersistsSlotsAcrossBoots() throws {
        try engine.refresh()
        let captured = try XCTUnwrap(templates(engine)[home.id])
        XCTAssertEqual(captured.slots, [
            TemplateSlot(bundleID: "app.editor", ordinal: 0),
            TemplateSlot(bundleID: "app.editor", ordinal: 1),
            TemplateSlot(bundleID: "app.browser", ordinal: 0)
        ])
        XCTAssertEqual(captured.tree.children?.map(\.weight), [2, 3, 1])
        let saved = try JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(engine.state))
        backend.setWindows([])
        backend.screen.backendSession = "new-boot-session"
        let restarted = try DynamicEngine(configuration: config, state: saved, backend: backend)
        try restarted.refresh()
        XCTAssertEqual(try templates(restarted)[home.id], captured)
        backend.setWindows([WindowInfo(id: 10, boot: "new-boot", workspace: home.workspace, bundleID: "app.editor")])
        backend.trees[home.workspace] = LayoutSnapshot(boot: "new-boot", tree: .root([LayoutNode(id: 10, pid: 1)]))
        try restarted.refresh()
        XCTAssertEqual(try templates(restarted)[home.id], captured)
    }

    func testClosureRetainsTemplateButNewBundleReplacesIt() throws {
        try engine.refresh()
        let captured = try XCTUnwrap(templates(engine)[home.id])
        backend.setWindows(try XCTUnwrap(backend.screen.windows).filter { $0.id != 2 })
        try engine.refresh()
        XCTAssertEqual(try templates(engine)[home.id], captured)
        backend.setWindows(try XCTUnwrap(backend.screen.windows) + [WindowInfo(id: 4, workspace: home.workspace, bundleID: "app.chat")])
        try engine.refresh()
        XCTAssertEqual(try templates(engine)[home.id]?.slots, [
            TemplateSlot(bundleID: "app.editor", ordinal: 0),
            TemplateSlot(bundleID: "app.browser", ordinal: 0),
            TemplateSlot(bundleID: "app.chat", ordinal: 0)
        ])
    }

    func testUserReorderAndUndoRebuildContractedTemplateOnlyForChangedSpaces() throws {
        let other = config.grids[1].cells[5]
        backend.setWindows(try XCTUnwrap(backend.screen.windows) + [WindowInfo(id: 4, workspace: other.workspace, bundleID: "app.chat")])
        try engine.refresh()
        let untouched = try XCTUnwrap(templates(engine)[other.id])
        backend.setWindows(try XCTUnwrap(backend.screen.windows).filter { $0.id != 2 })
        try engine.refresh()
        XCTAssertEqual(try templates(engine)[home.id]?.slots.count, 3)
        let remaining = try XCTUnwrap(backend.screen.windows)
        try engine.reorderWindow(XCTUnwrap(remaining.first { $0.id == 3 }).identity, before: XCTUnwrap(remaining.first { $0.id == 1 }).identity)
        XCTAssertEqual(try templates(engine)[home.id]?.slots.map(\.bundleID), ["app.browser", "app.editor"])
        XCTAssertEqual(try templates(engine)[other.id], untouched)
        try engine.undo()
        XCTAssertEqual(try templates(engine)[home.id]?.slots.map(\.bundleID), ["app.editor", "app.browser"])
        XCTAssertEqual(try templates(engine)[other.id], untouched)
    }

    func testExplicitMoveClearsVacatedTemplateAndUndoRebuildsBothSpaces() throws {
        let other = config.grids[1].cells[5]
        backend.setWindows([WindowInfo(id: 1, workspace: home.workspace, bundleID: "app.editor")])
        try engine.refresh()
        let identity = try XCTUnwrap(backend.screen.windows?.first?.identity)
        try engine.moveWindow(identity, to: other.id)
        XCTAssertNil(try templates(engine)[home.id])
        XCTAssertEqual(try templates(engine)[other.id]?.slots, [TemplateSlot(bundleID: "app.editor", ordinal: 0)])
        try engine.undo()
        XCTAssertEqual(try templates(engine)[home.id]?.slots, [TemplateSlot(bundleID: "app.editor", ordinal: 0)])
        XCTAssertNil(try templates(engine)[other.id])
    }

    func testOwnHomeFullscreenUsesSortedOrdinalsAndExclusiveHasNoTemplate() throws {
        try engine.refresh()
        let other = config.grids[1].cells[5], shared = config.grids[1].cells[3]
        backend.setWindows([
            WindowInfo(id: 10, workspace: other.workspace, bundleID: "app.editor", nativeFullscreen: true, nativeMonitor: 2),
            WindowInfo(id: 1, workspace: home.workspace, bundleID: "app.editor", nativeFullscreen: true, nativeMonitor: 2),
            WindowInfo(id: 2, workspace: shared.workspace, bundleID: "app.editor", nativeFullscreen: true, nativeMonitor: 2),
            WindowInfo(id: 4, workspace: shared.workspace, bundleID: "app.chat")
        ])
        backend.screen.nativeVisible = [2: 1]
        try engine.refresh()
        let captured = try templates(engine)
        XCTAssertEqual(captured[home.id]?.fullscreen, TemplateSlot(bundleID: "app.editor", ordinal: 0))
        XCTAssertEqual(captured[home.id]?.slots.count, 1)
        XCTAssertEqual(captured[other.id]?.fullscreen, TemplateSlot(bundleID: "app.editor", ordinal: 1))
        let exclusive = try XCTUnwrap(engine.map.fullscreens.first { $0.identity.id == 2 })
        XCTAssertNotEqual(exclusive.spaceID, exclusive.homeID)
        XCTAssertNil(captured[exclusive.spaceID])
    }

    func testRefreshPrunesTemplateOfDeletedSpace() throws {
        try engine.refresh()
        let removed = config.grids[1].cells[0]
        var saved = engine.state
        saved.dynamicMap?.placeTemplates?[removed.id] = try XCTUnwrap(templates(engine)[home.id])
        saved.dynamicMap?.spaces.removeAll { $0.id == removed.id }
        let restarted = try DynamicEngine(configuration: config, state: saved, backend: backend)
        XCTAssertNotNil(try templates(restarted)[removed.id])
        try restarted.refresh()
        XCTAssertNil(try templates(restarted)[removed.id])
        XCTAssertNotNil(try templates(restarted)[home.id])
    }

    func testLegacyStateWithoutTemplatesDecodes() throws {
        try engine.refresh()
        let data = try JSONEncoder().encode(engine.state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var map = try XCTUnwrap(object["dynamicMap"] as? [String: Any])
        map.removeValue(forKey: "placeTemplates")
        object["dynamicMap"] = map
        let decoded = try JSONDecoder().decode(RuntimeState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.dynamicMap?.placeTemplates)
        XCTAssertEqual(decoded.dynamicMap?.spaces, engine.map.spaces)
        let restarted = try DynamicEngine(configuration: config, state: decoded, backend: backend)
        try restarted.refresh()
        XCTAssertEqual(try templates(restarted)[home.id]?.slots.count, 3)
    }

    func testNilCaptureAndEmptyInventoryPreserveTemplateWithoutIdleChurn() throws {
        try engine.refresh()
        let captured = try XCTUnwrap(templates(engine)[home.id])
        try engine.refresh()
        XCTAssertEqual(try templates(engine)[home.id], captured)
        backend.setWindows(try XCTUnwrap(backend.screen.windows).map { window in
            var window = window; window.bundleID = ""; return window
        })
        try engine.refresh()
        XCTAssertEqual(try templates(engine)[home.id], captured)
        backend.setWindows([])
        for _ in 0...DynamicEngine.blackoutLimit { try engine.refresh() }
        XCTAssertEqual(try templates(engine)[home.id], captured)
    }

    func testCapturePreservesNestedTreeAndFloatingSlotsWithoutWindowContent() throws {
        backend.setWindows(try XCTUnwrap(backend.screen.windows) + [
            WindowInfo(id: 4, workspace: home.workspace, floating: true, title: "private-title", appName: "Private App", bundleID: "app.editor"),
            WindowInfo(id: 5, workspace: home.workspace, bundleID: "")
        ])
        backend.trees[home.workspace] = LayoutSnapshot(boot: "test", tree: .root([
            .root([LayoutNode(id: 2, pid: 1, weight: 2), LayoutNode(id: 1, pid: 1, weight: 3)], layout: "accordion", orientation: "v"),
            LayoutNode(id: 3, pid: 1), LayoutNode(id: 5, pid: 1)
        ]), floating: [FloatingLayout(id: 4, pid: 1, x: 10, y: 20, width: 300, height: 200)])
        try engine.refresh()
        let captured = try XCTUnwrap(templates(engine)[home.id])
        XCTAssertEqual(captured.tree.children?.first?.layout, "accordion")
        XCTAssertEqual(captured.tree.children?.first?.orientation, "v")
        XCTAssertEqual(captured.tree.children?.first?.children?.map(\.weight), [2, 3])
        XCTAssertEqual(captured.floating, [TemplateFloating(slot: TemplateSlot(bundleID: "app.editor", ordinal: 2), x: 10, y: 20, width: 300, height: 200)])
        XCTAssertEqual(captured.slots.count, 4)
        let serialized = String(decoding: try JSONEncoder().encode(captured), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private-title"))
        XCTAssertFalse(serialized.contains("Private App"))
    }
}
