import XCTest
@testable import GridCore

final class MapBackend: Backend {
    var screen: Desktop
    var trees: [String: LayoutSnapshot] = [:]
    var failWindow: UInt32?
    var failActivation: String?
    var activations: [(String, UInt32?)] = []
    var calls: [String] = []
    var failValidation: String?
    var failSnapshot: String?
    var onSnapshot: ((String) -> Void)?
    init(_ screen: Desktop) { self.screen = screen }
    func desktop() throws -> Desktop { calls.append("desktop"); return screen }
    func validate(workspace: String, monitor: Int) throws {}
    func place(workspace: String, monitor: Int) throws { screen.visible[monitor] = workspace }
    func activate(workspace: String) throws {}
    func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
        calls.append("validate:\(workspace)")
        if failValidation == workspace { throw GridError.unavailable("Injected validation failure") }
        if let window, screen.windows?.first(where: { $0.id == window })?.nativeMonitor != monitor { throw GridError.stale }
    }
    func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
        calls.append("activate:\(workspace)")
        if workspace == failActivation { throw GridError.unavailable("Injected activation failure") }
        activations.append((workspace, window)); screen.focusedMonitor = monitor
        if let window { screen.nativeVisible?[monitor] = window; screen.focusedWindow = window }
        else { screen.nativeVisible?.removeValue(forKey: monitor); screen.visible[monitor] = workspace; screen.focusedWindow = screen.windows?.first(where: { $0.workspace == workspace && !$0.nativeFullscreen })?.id }
    }
    func focus(monitor: Int, window: UInt32?) throws { screen.focusedMonitor = monitor; if let window { screen.focusedWindow = window } }
    func focus(window: UInt32) throws { screen.focusedWindow = window }
    func windows(workspace: String) throws -> [UInt32] { (screen.windows ?? []).filter { $0.workspace == workspace }.map(\.id) }
    func move(window: UInt32, workspace: String) throws {
        if failWindow == window { throw GridError.unavailable("Injected move failure") }
        guard let index = screen.windows?.firstIndex(where: { $0.id == window }) else { return }
        screen.windows?[index].workspace = workspace
        screen.windowHomes = screen.windows?.map { WindowHome(id: $0.id, pid: $0.pid, boot: $0.boot, workspace: $0.workspace, floating: $0.floating) }
    }
    func recoverWindowHomes(_ homes: [WindowHome]) throws {
        for home in homes where screen.windows?.contains(where: { $0.identity == WindowIdentity(id: home.id, pid: home.pid, boot: home.boot) }) == true {
            let failed = failWindow; failWindow = nil; try move(window: home.id, workspace: home.workspace); failWindow = failed
        }
    }
    func snapshot(workspace: String) throws -> String {
        calls.append("snapshot:\(workspace)")
        if failSnapshot == workspace { throw GridError.unavailable("Injected snapshot failure") }
        onSnapshot?(workspace)
        let items = (screen.windows ?? []).filter { $0.workspace == workspace }
        let identities = Set(items.map(\.identity))
        var saved = trees[workspace] ?? LayoutSnapshot(boot: "test", tree: .root([]))
        saved.tree = saved.tree.retaining(identities, boot: saved.boot) ?? .root([])
        for item in items where !saved.tree.ids.contains(item.id) && !item.floating {
            saved.tree.children?.append(LayoutNode(id: item.id, pid: item.pid))
        }
        return try saved.json()
    }
    func restore(workspace: String, snapshot: String) throws { trees[workspace] = try LayoutSnapshot(json: snapshot) }
    func layout(workspace: String, profile: String) throws {}
    func setWindows(_ windows: [WindowInfo]) {
        screen.windows = windows
        screen.windowHomes = windows.map { WindowHome(id: $0.id, pid: $0.pid, boot: $0.boot, workspace: $0.workspace, floating: $0.floating) }
    }
}

final class DynamicEngineTests: XCTestCase {
    let laptop = Display(id: "laptop", monitor: 1, name: "MacBook", builtin: true, width: 1710, height: 1073)
    let ultra = Display(id: "ultra", monitor: 2, name: "Ultrawide", builtin: false, width: 5120, height: 1410)
    var config: Configuration!
    var backend: MapBackend!
    var engine: DynamicEngine!
    var external: Cell { config.grids[1].cells[4] }
    var chat: Cell { config.grids[0].cells[4] }
    override func setUpWithError() throws {
        config = Configuration(backendPath: "/unused")
        var desktop = Desktop(displays: [laptop, ultra], visible: [1: chat.workspace, 2: external.workspace], focusedMonitor: 2, focusedWindow: 1)
        desktop.nativeVisible = [:]; desktop.backendSession = "one"
        backend = MapBackend(desktop)
        backend.setWindows([WindowInfo(id: 1, workspace: external.workspace, appName: "Editor"), WindowInfo(id: 2, workspace: external.workspace, appName: "Browser"), WindowInfo(id: 3, workspace: chat.workspace, appName: "Chat")])
        backend.trees[external.workspace] = LayoutSnapshot(boot: "test", tree: .root([LayoutNode(id: 1, pid: 1, weight: 2), LayoutNode(id: 2, pid: 1, weight: 3)]), focus: 1)
        engine = try DynamicEngine(configuration: config, backend: backend)
        try engine.refresh()
    }
    func unplug() throws { backend.screen.displays = [laptop]; backend.screen.visible.removeValue(forKey: 2); try engine.refresh() }
    func reconnect() throws { backend.screen.displays = [laptop, ultra]; try engine.refresh() }
    func testMigrationPreservesIdentityAndRestartsWithoutDuplicates() throws {
        XCTAssertEqual(Set(engine.map.spaces.map(\.id)), Set(config.grids.flatMap(\.cells).map(\.id)))
        XCTAssertEqual(Set(engine.map.spaces.map { "\($0.board):\($0.row):\($0.column)" }).count, 18)
        let restarted = try DynamicEngine(configuration: config, state: engine.state, backend: backend)
        XCTAssertEqual(restarted.map, engine.map)
    }
    func testParallelBlocksSeparateAndRecomposeWithWeights() throws {
        try unplug()
        let family = try XCTUnwrap(engine.map.families.first)
        XCTAssertEqual(family.childIDs.count, 2)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 1 }?.workspace, external.workspace)
        XCTAssertNotEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, external.workspace)
        XCTAssertEqual(engine.eligibleSpaces(on: laptop).count, 3)
        try reconnect()
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.map(\.weight), [2,3])
    }
    func testMixedLayoutPreservesAccordionAsOneBlock() throws {
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: external.workspace)])
        backend.trees[external.workspace] = LayoutSnapshot(boot: "test", tree: .root([LayoutNode(id: 1, pid: 1), .root([LayoutNode(id: 2, pid: 1), LayoutNode(id: 4, pid: 1)], layout: "accordion")]))
        try engine.refresh(); try unplug()
        XCTAssertEqual(engine.map.families.first?.childIDs.count, 2)
        let group = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        XCTAssertEqual(Set(try backend.windows(workspace: group.workspace)), [2,4])
        XCTAssertEqual(backend.trees[group.workspace]?.tree.layout, "accordion")
    }
    func testAlreadyStackedWindowsStayTogether() throws {
        backend.trees[external.workspace]?.tree.layout = "accordion"
        try engine.refresh(); try unplug()
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
    }
    func testManualReorderingSurvivesReconnectAndCanBeUndone() throws {
        try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        try engine.moveSpace(child.id, to: chat.id)
        let moved = engine.map.spaces.first { $0.id == child.id }
        try reconnect()
        XCTAssertEqual(engine.map.spaces.first { $0.id == child.id }, moved)
        XCTAssertEqual(engine.map.families.first?.manuallyEdited, true)
    }
    func testUndoRetainsArrangementAndWindowIdentity() throws {
        let before = backend.trees[external.workspace]
        try engine.moveSpace(external.id, to: chat.id)
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace], before)
        XCTAssertEqual(engine.map.spaces.first { $0.id == external.id }?.column, config.grids[1].cells[4].column)
    }
    func testFailedSplitRollsBackAllMembershipAndMap() throws {
        backend.failWindow = 2
        XCTAssertThrowsError(try unplug())
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
        XCTAssertNil(engine.map.pending)
    }
    func testFullscreenCreatesIndependentTargetsAndReturnsToArrangement() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2: 1]
        try engine.refresh()
        let full = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        XCTAssertEqual(engine.map.fullscreens.count, 1)
        try engine.jump(cellID: external.id, displayID: ultra.id)
        XCTAssertNil(backend.screen.nativeVisible?[2])
        XCTAssertEqual(backend.screen.focusedWindow, 2)
        try engine.jump(cellID: full.id, displayID: ultra.id)
        XCTAssertEqual(backend.screen.nativeVisible?[2], 1)
        backend.screen.windows?[0].nativeFullscreen = false; backend.screen.nativeVisible = [:]
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == full.id })
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.map(\.weight), [2,3])
    }
    func testFullscreenOnlyWindowUsesExistingCell() throws {
        backend.setWindows([WindowInfo(id: 1, workspace: external.workspace, nativeFullscreen: true, nativeMonitor: 2)])
        backend.screen.nativeVisible = [2: 1]
        try engine.refresh()
        XCTAssertEqual(engine.map.spaces.count, 18)
        XCTAssertEqual(engine.map.fullscreens.first?.spaceID, external.id)
        try engine.refresh(); XCTAssertEqual(engine.map.fullscreens.count, 1)
    }
    func testSparseNavigationGoesToOnlyOccupiedCellInNextRow() throws {
        let upper = config.grids[1].cells[0]
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: upper.workspace)])
        try engine.navigate(.up, scope: .active, displayID: ultra.id)
        XCTAssertEqual(backend.screen.visible[2], upper.workspace)
        XCTAssertEqual(backend.screen.visible[1], chat.workspace)
    }
    func testAllDisplayBoundaryDoesNotPartiallyMove() throws {
        let upper = config.grids[1].cells[0]
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: upper.workspace)])
        let before = backend.screen.visible
        XCTAssertThrowsError(try engine.navigate(.up, scope: .all, displayID: ultra.id))
        XCTAssertEqual(backend.screen.visible, before)
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testNewAndClosedWindowsReconcileOnRecomposition() throws {
        try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        backend.setWindows((backend.screen.windows ?? []).filter { $0.id != 1 } + [WindowInfo(id: 4, workspace: child.workspace)])
        try engine.refresh(); try reconnect()
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [2,4])
        XCTAssertFalse(engine.map.spaces.contains { $0.id == child.id })
    }
    func testReusedWindowNumberDoesNotActivateOldFullscreen() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        try engine.refresh()
        backend.screen.windows?[0].pid = 99; backend.screen.windows?[0].nativeFullscreen = false
        try engine.refresh()
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }
    func testUndoRejectsChangedTopology() throws {
        try engine.moveSpace(external.id, to: chat.id)
        try unplug()
        XCTAssertThrowsError(try engine.undo())
    }
    func testCreatingSpaceWithWindowIsOneUndoAndFailedMoveLeavesNoSpace() throws {
        let window = try XCTUnwrap(backend.screen.windows?.first { $0.id == 2 })
        let id = try engine.createSpace(nearID: external.id, displayID: ultra.id, moving: window.identity)
        XCTAssertEqual(engine.map.undo.count, 1)
        XCTAssertNotEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, external.workspace)
        try engine.undo()
        XCTAssertFalse(engine.map.spaces.contains { $0.id == id })
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, external.workspace)
        backend.failWindow = 2
        XCTAssertThrowsError(try engine.createSpace(nearID: external.id, displayID: ultra.id, moving: window.identity))
        XCTAssertEqual(engine.map.spaces.count, 18)
    }
    func testNewNormalWindowWhileOnlyWindowIsFullscreenCreatesSeparateTarget() throws {
        backend.setWindows([WindowInfo(id: 1, workspace: external.workspace, nativeFullscreen: true, nativeMonitor: 2)])
        backend.screen.nativeVisible = [2: 1]; try engine.refresh()
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 2, workspace: external.workspace)])
        try engine.refresh()
        XCTAssertEqual(engine.map.spaces.count, 19)
        XCTAssertNil(engine.map.spaces.first { $0.id == external.id }?.nativeWindow)
        XCTAssertNotEqual(engine.map.fullscreens.first?.spaceID, external.id)
        try engine.jump(cellID: external.id, displayID: ultra.id)
        XCTAssertEqual(backend.screen.focusedWindow, 2)
    }
    func testPendingSplitIsRolledBackOnRestart() throws {
        try unplug()
        let beforeState = engine.state
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        let window = try XCTUnwrap(backend.screen.windows?.first { $0.id == 2 })
        _ = try engine.createSpace(nearID: child.id, displayID: laptop.id, moving: window.identity)
        let action = try XCTUnwrap(engine.map.undo.last)
        var interrupted = engine.state
        interrupted.dynamicMap?.pending = PendingOrganization(before: action.before, desiredHomes: [])
        engine = try DynamicEngine(configuration: config, state: interrupted, backend: backend)
        try engine.refresh()
        XCTAssertEqual(engine.map.spaces, beforeState.dynamicMap?.spaces)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, child.workspace)
        XCTAssertNil(engine.map.pending)
    }
    func testMetadataUndoDoesNotOverwriteDirectLayoutEdits() throws {
        try engine.moveSpace(external.id, to: chat.id)
        backend.trees[external.workspace]?.tree.children?[0].weight = 7
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.first?.weight, 7)
    }
    func testReunitePreviewIncludesCurrentWindowsAndRejectsStaleMembership() throws {
        try unplug()
        let preview = try engine.makeReunitePreview(sourceID: external.id)
        XCTAssertEqual(Set(preview.result.tree.ids), [1, 2])
        XCTAssertEqual(preview.result.tree.children?.map(\.weight), [2, 3])
        backend.setWindows((backend.screen.windows ?? []).filter { $0.id != 2 })
        XCTAssertThrowsError(try engine.reunite(sourceID: external.id, expectedOwners: Set(preview.windows.map(\.identity))))
        XCTAssertEqual(engine.map.families.count, 1)
        let updated = try engine.makeReunitePreview(sourceID: external.id)
        XCTAssertEqual(updated.result.tree.ids, [1])
    }
    func testManualReuniteStaysJoinedUntilTheNextConnectedSession() throws {
        try unplug()
        let childIDs = engine.map.families[0].childIDs
        try engine.reunite(sourceID: external.id)
        try engine.refresh()
        XCTAssertTrue(engine.map.families.isEmpty)
        let restarted = try DynamicEngine(configuration: config, state: engine.state, backend: backend)
        try restarted.refresh()
        XCTAssertTrue(restarted.map.families.isEmpty)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1, 2])
        engine = restarted
        try reconnect()
        XCTAssertNil(engine.map.spaces.first { $0.id == external.id }?.joinedWhileFolded)
        try unplug()
        XCTAssertEqual(engine.map.families.first?.childIDs, childIDs)
    }
    func testManualReuniteCanBeUndoneWhileStillUndocked() throws {
        try unplug()
        let family = engine.map.families[0]
        try engine.reunite(sourceID: external.id)
        try engine.undo()
        XCTAssertEqual(engine.map.families, [family])
        XCTAssertEqual(Set((backend.screen.windows ?? []).filter { [1, 2].contains($0.id) }.map(\.workspace)).count, 2)
    }
    func testLayoutUndoRejectsSubsequentDirectLayoutEdit() throws {
        try engine.arrange(external.id, layout: "accordion", orientation: "h")
        backend.trees[external.workspace]?.tree.children?[0].weight = 7
        XCTAssertThrowsError(try engine.undo())
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.first?.weight, 7)
    }
    func testLayoutUndoDoesNotOverwriteASeparateFloatingWindowMove() throws {
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: external.workspace, floating: true)])
        backend.trees[external.workspace]?.floating = [FloatingLayout(id: 4, pid: 1, x: 0.2, y: 0.3, width: 0.2, height: 0.2)]
        try engine.arrange(external.id, layout: "accordion", orientation: "h")
        backend.trees[external.workspace]?.floating[0].x = 0.6
        XCTAssertThrowsError(try engine.undo())
        XCTAssertEqual(backend.trees[external.workspace]?.floating[0].x, 0.6)
    }
    func testReorderSiblingsPreservesTheirWeightsAndMaximizeState() throws {
        backend.trees[external.workspace]?.tree.children?[1].fullscreen = true
        let before = backend.trees[external.workspace]!
        try engine.reorderWindow(WindowIdentity(id: 2, pid: 1, boot: "test"), before: WindowIdentity(id: 1, pid: 1, boot: "test"))
        let children = backend.trees[external.workspace]!.tree.children!
        XCTAssertEqual(children.map(\.id), [2, 1])
        XCTAssertEqual(children.map(\.weight), [3, 2])
        XCTAssertEqual(children[0].fullscreen, true)
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace]?.tree, before.tree)
    }
    func testReorderIntoAnotherContainerUsesTheTargetPaneWeight() throws {
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: external.workspace)])
        backend.trees[external.workspace]?.tree = .root([
            LayoutNode(id: 1, pid: 1, weight: 2000),
            LayoutNode(weight: 3000, orientation: "v", layout: "accordion", children: [LayoutNode(id: 2, pid: 1), LayoutNode(id: 4, pid: 1)])
        ])
        try engine.reorderWindow(WindowIdentity(id: 2, pid: 1, boot: "test"), before: WindowIdentity(id: 1, pid: 1, boot: "test"))
        let children = backend.trees[external.workspace]!.tree.children!
        XCTAssertEqual(children[0].id, 2)
        XCTAssertEqual(children[0].weight, 2000)
        XCTAssertEqual(children[1].weight, 2000)
    }
    func testReorderFromAnotherWorkspaceDoesNotReuseTheDefaultTinyWeight() throws {
        backend.trees[external.workspace]?.tree.children?[0].weight = 2000
        backend.trees[external.workspace]?.tree.children?[1].weight = 3000
        try engine.reorderWindow(WindowIdentity(id: 3, pid: 1, boot: "test"), before: WindowIdentity(id: 1, pid: 1, boot: "test"))
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.first?.id, 3)
        XCTAssertEqual(backend.trees[external.workspace]?.tree.children?.first?.weight, 2000)
    }
    func testCreatingAtAnImportedEmptyCellMakesItVisibleAndCanBeUndone() throws {
        let empty = config.grids[1].cells[2]
        let count = engine.map.spaces.count
        try engine.revealEmptySpace(empty.id)
        XCTAssertEqual(engine.map.spaces.count, count)
        XCTAssertEqual(engine.map.spaces.first { $0.id == empty.id }?.userCreated, true)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces.first { $0.id == empty.id }?.userCreated, false)
    }

    func testReconnectRestoresBothIndependentCursors() throws {
        let old = engine.map.connectedCursors
        try unplug()
        try engine.jump(cellID: external.id, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], external.workspace)
        try reconnect()
        XCTAssertEqual(engine.map.cursors[laptop.id], old[laptop.id])
        XCTAssertEqual(engine.map.cursors[ultra.id], old[ultra.id])
        XCTAssertEqual(backend.screen.visible[1], chat.workspace)
        XCTAssertEqual(backend.screen.visible[2], external.workspace)
    }
    func testFoldedNavigationReachesSpacesFromBothOriginalGridsWithoutSelector() throws {
        try unplug()
        try engine.jump(cellID: chat.id, displayID: laptop.id)
        try engine.navigate(.down, scope: .active, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], external.workspace)
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        try engine.navigate(.right, scope: .active, displayID: laptop.id)
        XCTAssertEqual(backend.screen.visible[1], child.workspace)
    }
    func testBackendRestartRecoversDerivedMembershipAndArrangement() throws {
        try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        backend.screen.backendSession = "two"
        try backend.move(window: 2, workspace: "backend-default")
        try engine.refresh()
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, child.workspace)
        XCTAssertEqual(engine.map.families.count, 1)
    }
    func testRecompositionDeferredByFullscreenRunsAfterExit() throws {
        try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        if let index = backend.screen.windows?.firstIndex(where: { $0.id == 2 }) {
            backend.screen.windows?[index].nativeFullscreen = true; backend.screen.windows?[index].nativeMonitor = 1
        }
        backend.screen.nativeVisible = [1: 2]; try engine.refresh()
        try reconnect()
        XCTAssertEqual(engine.map.families.count, 1)
        if let index = backend.screen.windows?.firstIndex(where: { $0.id == 2 }) { backend.screen.windows?[index].nativeFullscreen = false }
        backend.screen.nativeVisible = [:]; try engine.refresh()
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == child.id })
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
    }

    func testDeferredNativeDiscoveryDoesNotDeleteFullscreenDestination() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        try engine.refresh()
        let link = try XCTUnwrap(engine.map.fullscreens.first)
        // The backend still knows this home but macOS hasn't exposed its AX window yet.
        backend.screen.windows?.removeAll { $0.id == 1 }
        try engine.refresh()
        XCTAssertEqual(engine.map.fullscreens.first, link)
        XCTAssertTrue(engine.map.spaces.contains { $0.id == link.spaceID })
    }

    func testNewWindowInUnmappedWorkspaceIsAdoptedAndReachable() throws {
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 9, workspace: "1", appName: "New app")])
        backend.screen.visible[2] = "1"
        try engine.refresh()
        let adopted = try XCTUnwrap(engine.map.spaces.first { $0.workspace == "1" })
        XCTAssertEqual(adopted.name, "New app")
        XCTAssertEqual(engine.currentSpace(on: ultra)?.id, adopted.id)
        try engine.jump(cellID: external.id, displayID: ultra.id)
        try engine.jump(cellID: adopted.id, displayID: ultra.id)
        XCTAssertEqual(backend.screen.visible[2], "1")
    }

    func testManuallyMovedFullscreenRemainsIndependentAndVisibleOnExit() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2: 1]; try engine.refresh()
        let full = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        try engine.moveSpace(full.id, to: config.grids[1].cells[0].id)
        let position = engine.map.spaces.first { $0.id == full.id }
        backend.screen.windows?[0].nativeFullscreen = false; backend.screen.nativeVisible = [:]
        try engine.refresh()
        let independent = try XCTUnwrap(engine.map.spaces.first { $0.id == full.id })
        XCTAssertEqual(independent.row, position?.row); XCTAssertEqual(independent.column, position?.column)
        XCTAssertNil(independent.nativeWindow)
        XCTAssertNotEqual(independent.workspace, external.workspace)
        XCTAssertEqual(backend.screen.visible[2], independent.workspace)
        XCTAssertEqual(Set(try backend.windows(workspace: independent.workspace)), [1])
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }

    func testFloatingWindowFollowsItsUnambiguousOwningBlock() throws {
        var items = backend.screen.windows ?? []
        items[1].pid = 2
        items.append(WindowInfo(id: 9, pid: 2, workspace: external.workspace, floating: true))
        backend.setWindows(items)
        backend.trees[external.workspace]?.tree.children?[1].pid = 2
        backend.trees[external.workspace]?.floating = [FloatingLayout(id: 9, pid: 2, x: 0.1, y: 0.1, width: 0.3, height: 0.3)]
        try engine.refresh(); try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 9 }?.workspace, child.workspace)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 9 }?.floating, true)
        XCTAssertEqual(backend.trees[child.workspace]?.floating.first?.id, 9)
        try reconnect()
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 9 }?.workspace, external.workspace)
    }

    func testDropWithArrangementIsOneUndoAndPreservesSourceTree() throws {
        let window = try XCTUnwrap(backend.screen.windows?.first { $0.id == 2 })
        let before = backend.trees[external.workspace]
        try engine.moveWindow(window.identity, to: chat.id, layout: "accordion", orientation: "h")
        XCTAssertEqual(engine.map.undo.count, 1)
        XCTAssertEqual(backend.trees[chat.workspace]?.tree.layout, "accordion")
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace], before)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 2 }?.workspace, external.workspace)
    }

    func testImportPreservesVisibleStackAndSeedsDisplayCursors() throws {
        backend.trees[external.workspace]?.tree.layout = "accordion"
        try engine.importVisibleLayouts()
        let imported = try LayoutSnapshot(json: XCTUnwrap(engine.map.layouts[external.id]))
        XCTAssertEqual(imported.tree.layout, "accordion")
        XCTAssertEqual(engine.map.connectedCursors[ultra.id], external.id)
        XCTAssertEqual(engine.map.connectedCursors[laptop.id], chat.id)
    }

    func testDerivedIdentityAndWorkspaceAreReusedAcrossDockCycles() throws {
        try unplug()
        let first = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        try reconnect()
        XCTAssertNil(engine.map.layouts[first.id])
        try unplug()
        let second = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        XCTAssertEqual(second.id, first.id); XCTAssertEqual(second.workspace, first.workspace)
        XCTAssertEqual(second.row, first.row); XCTAssertEqual(second.column, first.column)
    }
    func testDerivedIdentityCollisionFailsWithoutPartialMapOrMoves() throws {
        var saved = engine.state
        let reserved = SpaceMap.derivedIdentity(sourceID: external.id, component: "block-1")
        saved.dynamicMap?.spaces.append(Space(id: reserved.id, name: "Reserved", row: 10, column: 10, workspace: "reserved", preferredRole: "external"))
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend)
        let before = engine.map.spaces
        XCTAssertThrowsError(try unplug())
        XCTAssertEqual(engine.map.spaces, before)
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
    }
    func testNormalHomeArrangementEditDoesNotMakeFullscreenPermanent() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2: 1]; try engine.refresh()
        let full = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        try engine.arrange(external.id, layout: "accordion", orientation: "h")
        XCTAssertEqual(engine.map.fullscreens.first?.homeEdited, true)
        XCTAssertFalse(engine.map.fullscreens.first?.manuallyEdited ?? true)
        backend.screen.windows?[0].nativeFullscreen = false; backend.screen.nativeVisible = [:]
        try engine.refresh()
        XCTAssertFalse(engine.map.spaces.contains { $0.id == full.id })
        XCTAssertEqual(backend.trees[external.workspace]?.tree.layout, "accordion")
    }
    func testMergePreservesNestedGroupsAndCanBeUndone() throws {
        let before = backend.trees[external.workspace]
        let preview = try engine.makeMergePreview(external.id, into: chat.id)
        XCTAssertEqual(preview.result.tree.children?.count, 2)
        try engine.mergeSpaces(external.id, into: chat.id,
            expectedSource: Set(preview.sourceWindows.map(\.identity)), expectedTarget: Set(preview.targetWindows.map(\.identity)))
        XCTAssertEqual(Set(try backend.windows(workspace: chat.workspace)), [1,2,3])
        XCTAssertEqual(backend.trees[chat.workspace]?.tree.children?.last?.children?.map(\.weight), [2,3])
        XCTAssertTrue(try backend.windows(workspace: external.workspace).isEmpty)
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace], before)
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
        XCTAssertEqual(try backend.windows(workspace: chat.workspace), [3])
    }
    func testMergeRejectsChangedPreviewAndRollsBackFailedMoves() throws {
        let preview = try engine.makeMergePreview(external.id, into: chat.id)
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: chat.workspace)])
        XCTAssertThrowsError(try engine.mergeSpaces(external.id, into: chat.id,
            expectedSource: Set(preview.sourceWindows.map(\.identity)), expectedTarget: Set(preview.targetWindows.map(\.identity))))
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
        backend.failWindow = 2
        XCTAssertThrowsError(try engine.mergeSpaces(external.id, into: chat.id))
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
        XCTAssertEqual(Set(try backend.windows(workspace: chat.workspace)), [3,4])
        XCTAssertNil(engine.map.pending)
    }
    func testCoordinatedDestinationsFindAlternativeInsteadOfFalseBoundary() throws {
        XCTAssertEqual(CoordinatedDestinations.resolve(["a": ["x", "y"], "b": ["x"]]), ["a": "y", "b": "x"])
        XCTAssertNil(CoordinatedDestinations.resolve(["a": ["x"], "b": ["x"]]))
        XCTAssertEqual(CoordinatedDestinations.resolve(["b": ["x", "y"], "a": ["x", "y"]]),
                       CoordinatedDestinations.resolve(["a": ["x", "y"], "b": ["x", "y"]]))
    }
    func testAllScopeResolvesSharedExternalCandidates() throws {
        let second = Display(id: "second-ultra", monitor: 3, name: "Second external", builtin: false, width: 3440, height: 1400)
        let other = config.grids[1].cells[3]
        let firstTarget = config.grids[1].cells[5]
        let extra = Space(id: "extra", name: "Extra", row: 1, column: 7, workspace: "extra", preferredRole: "external")
        var saved = engine.state; saved.dynamicMap?.spaces.append(extra)
        backend.screen.displays = [ultra, second]; backend.screen.visible = [2: external.workspace, 3: other.workspace]
        backend.setWindows((backend.screen.windows ?? []) + [WindowInfo(id: 4, workspace: firstTarget.workspace), WindowInfo(id: 5, workspace: extra.workspace), WindowInfo(id: 9, workspace: other.workspace)])
        engine = try DynamicEngine(configuration: config, state: saved, backend: backend)
        try engine.navigate(.right, scope: .all, displayID: ultra.id)
        XCTAssertEqual(Set(backend.screen.visible.values), [firstTarget.workspace, extra.workspace])
        XCTAssertEqual(backend.screen.focusedMonitor, ultra.monitor)
    }

    func testMovingSoleWindowOutOfSpaceCanBeUndone() throws {
        let window = try XCTUnwrap(backend.screen.windows?.first { $0.id == 3 })
        try engine.moveWindow(window.identity, to: external.id)
        XCTAssertTrue(try backend.windows(workspace: chat.workspace).isEmpty)
        try engine.undo()
        XCTAssertEqual(try backend.windows(workspace: chat.workspace), [3])
        XCTAssertEqual(Set(try backend.windows(workspace: external.workspace)), [1,2])
    }

    func testExclusiveFullscreenIdentityIsReusedOnReentry() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2: 1]; try engine.refresh()
        let first = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        backend.screen.windows?[0].nativeFullscreen = false; backend.screen.nativeVisible = [:]; try engine.refresh()
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.nativeVisible = [2: 1]; try engine.refresh()
        let second = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.row, first.row); XCTAssertEqual(second.column, first.column)
    }

}
