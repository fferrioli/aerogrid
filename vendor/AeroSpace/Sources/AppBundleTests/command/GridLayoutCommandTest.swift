@testable import AppBundle
import Common
import XCTest

@MainActor final class GridLayoutCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    private func execute(_ args: [String]) async -> CmdIoImpl {
        let io = CmdIoImpl(stdin: .emptyStdin)
        _ = await parseCommand(args).cmdOrDie.run(.defaultEnv, io)
        return io
    }
    func testManagementStatusRemainsReadOnlyWhileDisabled() async throws {
        let previous = TrayMenuModel.shared.isEnabled
        defer { TrayMenuModel.shared.isEnabled = previous }
        let ws = Workspace.get(byName:name)
        let window = TestWindow.new(id:77,parent:ws.rootTilingContainer)
        TrayMenuModel.shared.isEnabled = false
        let result = await execute(["grid-layout","management-status"])
        XCTAssertTrue(result.stderr.isEmpty)
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.stdout.joined().utf8)) as? [String:Bool])
        XCTAssertEqual(status["enabled"],false); XCTAssertEqual(status["ready"],true)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertTrue(window.nodeWorkspace === ws)
        XCTAssertNil(RunSessionGuard.isServerEnabled)
    }
    func testBackendMenuIsOwnedOnlyByAeroGridBundles() {
        XCTAssertTrue(gridOwnsBackendUI(bundleIdentifier:"local.AeroGrid.Backend"))
        XCTAssertTrue(gridOwnsBackendUI(bundleIdentifier:"local.AeroGrid.Backend.debug"))
        XCTAssertFalse(gridOwnsBackendUI(bundleIdentifier:"bobko.aerospace"))
        XCTAssertFalse(gridOwnsBackendUI(bundleIdentifier:nil))
    }
    func testNormalAndNativeTargetsInSharedWorkspaceAreIndependent() async throws {
        let ws = Workspace.get(byName: name)
        let full = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let normal = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        full.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        _ = ws.focusWorkspace()
        let monitor = ws.workspaceMonitor.monitorId_oneBased!
        let normalResult = await execute(["grid-layout", "--data", "{\"monitor\":\(monitor)}", "activate-target"])
        XCTAssertTrue(normalResult.stderr.isEmpty)
        XCTAssertEqual(focus.windowOrNil?.windowId, normal.windowId)
        let nativeResult = await execute(["grid-layout", "--data", "{\"monitor\":\(monitor),\"window\":1}", "activate-target"])
        XCTAssertTrue(nativeResult.stderr.isEmpty)
        XCTAssertEqual(focus.windowOrNil?.windowId, full.windowId)
        XCTAssertTrue(full.parent is MacosFullscreenWindowsContainer)
        XCTAssertTrue(normal.parent is TilingContainer)
    }
    func testInvalidNativeTargetDoesNotFallBackToAnotherWindow() async {
        let ws = Workspace.get(byName: name)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let monitor = ws.workspaceMonitor.monitorId_oneBased!
        let result = await execute(["grid-layout", "--data", "{\"monitor\":\(monitor),\"window\":999}", "activate-target"])
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertEqual(focus.windowOrNil?.windowId, 2)
    }
    func testVerifiedMoveRejectsOwnerMismatchAndNativeFullscreen() async throws {
        let ws = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let snapshot = await execute(["grid-layout", "snapshot"])
        let saved = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(snapshot.stdout.joined().utf8))
        func identity(_ pid: Int32) throws -> String {
            String(decoding: try JSONEncoder().encode(GridMoveIdentity(id: 1, pid: pid, boot: saved.boot)), as: UTF8.self)
        }
        let wrongOwner = await execute(["grid-layout", "--workspace", "grid-owner-check", "--data", try identity(window.app.pid + 1), "move-window"])
        XCTAssertFalse(wrongOwner.stderr.isEmpty)
        XCTAssertTrue(window.nodeWorkspace === ws)
        window.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let native = await execute(["grid-layout", "--workspace", "grid-owner-check", "--data", try identity(window.app.pid), "move-window"])
        XCTAssertFalse(native.stderr.isEmpty)
        XCTAssertTrue(window.parent is MacosFullscreenWindowsContainer)
    }
    func testNestedOrderWeightsAndFullscreenRestore() async throws {
        let ws = Workspace.get(byName: name)
        let root = ws.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 2)
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: nested, adaptiveWeight: 3)
        TestWindow.new(id: 3, parent: nested, adaptiveWeight: 1)
        first.isFullscreen = true
        _ = ws.focusWorkspace()
        let saved = await execute(["grid-layout", "snapshot"])
        XCTAssertTrue(saved.stderr.isEmpty)
        let json = saved.stdout.joined()
        let snapshot = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tree.children?.first?.id, 1)
        XCTAssertEqual(snapshot.tree.children?.first?.weight, 2)
        _ = await execute(["grid-layout", "compact"])
        XCTAssertEqual(ws.rootTilingContainer.layout, .accordion)
        XCTAssertEqual(ws.rootTilingContainer.children.count, 3)
        let restored = await execute(["grid-layout", "--data", json, "restore"])
        XCTAssertTrue(restored.stderr.isEmpty)
        let children = ws.rootTilingContainer.children
        XCTAssertEqual((children[0] as? Window)?.windowId, 1)
        XCTAssertEqual(children[0].getWeight(.h), 2)
        XCTAssertEqual((children[1] as? TilingContainer)?.orientation, .v)
        XCTAssertEqual(children[1].allLeafWindowsRecursive.map(\.windowId), [2,3])
        XCTAssertEqual(first.isFullscreen, true)
    }
    func testReconcileClosedAndNewWindows() async throws {
        let ws = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let saved = await execute(["grid-layout", "snapshot"])
        closing.unbindFromParent()
        TestWindow.new(id: 3, parent: ws.rootTilingContainer)
        _ = await execute(["grid-layout", "--data", saved.stdout.joined(), "restore"])
        XCTAssertEqual(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1,3])
    }
    func testExplicitGroupsSurviveNormalizationWithoutRotationOrFlattening() async throws {
        let ws = Workspace.get(byName: name)
        let group = TilingContainer.newHTiles(parent: ws.rootTilingContainer, adaptiveWeight: 2, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: group, adaptiveWeight: 3)
        let stack = TilingContainer(parent: ws.rootTilingContainer, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: stack, adaptiveWeight: 2)
        let closing = TestWindow.new(id: 3, parent: stack, adaptiveWeight: 1)
        _ = ws.focusWorkspace()
        let saved = await execute(["grid-layout", "snapshot"])
        _ = await execute(["grid-layout", "--data", saved.stdout.joined(), "restore"])
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        ws.normalizeContainers()
        let children = ws.rootTilingContainer.children
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual((children[0] as? TilingContainer)?.orientation, .h)
        XCTAssertEqual(children[0].getWeight(.h), 2)
        XCTAssertEqual((children[1] as? TilingContainer)?.orientation, .h)
        XCTAssertEqual((children[1] as? TilingContainer)?.layout, .accordion)
        closing.unbindFromParent()
        ws.normalizeContainers()
        XCTAssertTrue(ws.rootTilingContainer.children[1] is TilingContainer)
        XCTAssertEqual(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1, 2])
    }
    func testRestoredNestedGroupsRetainProportionsWhenAllocatedDifferentWidths() async throws {
        let ws = Workspace.get(byName: name)
        let group = TilingContainer.newHTiles(parent: ws.rootTilingContainer, adaptiveWeight: 2, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 1, parent: group, adaptiveWeight: 3)
        let second = TestWindow.new(id: 2, parent: group, adaptiveWeight: 1)
        let sibling = TestWindow.new(id: 3, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        _ = ws.focusWorkspace()
        let saved = await execute(["grid-layout", "snapshot"])
        _ = await execute(["grid-layout", "--data", saved.stdout.joined(), "restore"])
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.enableNormalizationFlattenContainers = true
        ws.normalizeContainers()
        try await ws.layoutWorkspace()
        XCTAssertEqual(first.hWeight / second.hWeight, 3, accuracy: 0.0001)
        let restored = ws.rootTilingContainer.children[0] as! TilingContainer
        XCTAssertEqual(restored.hWeight / sibling.hWeight, 2, accuracy: 0.0001)
        let stableWeights = [first.hWeight, second.hWeight, sibling.hWeight]
        for _ in 0..<3 { try await ws.layoutWorkspace() }
        XCTAssertEqual([first.hWeight, second.hWeight, sibling.hWeight], stableWeights)
        let oldWidth = try await first.getAxRect(.nonCancellable)!.width
        restored.setWeight(.h, 1)
        sibling.setWeight(.h, 3)
        try await ws.layoutWorkspace()
        XCTAssertEqual(first.hWeight / second.hWeight, 3, accuracy: 0.0001)
        XCTAssertEqual(restored.hWeight / sibling.hWeight, 1.0 / 3, accuracy: 0.0001)
        let newWidth = try await first.getAxRect(.nonCancellable)!.width
        XCTAssertLessThan(newWidth, oldWidth)
    }
    func testFloatingSnapshotUsesUnhiddenGeometryInsteadOfCornerEmulation() async throws {
        let ws = Workspace.get(byName: name)
        let rect = ws.workspaceMonitor.visibleRect
        let window = TestWindow.new(id: 1, parent: ws.floatingWindowsContainer,
            rect: Rect(topLeftX: rect.maxX - 1, topLeftY: rect.maxY, width: 300, height: 200))
        window.gridSnapshotRect = Rect(topLeftX: rect.minX + rect.width * 0.2,
            topLeftY: rect.minY + rect.height * 0.3, width: 300, height: 200)
        _ = ws.focusWorkspace()
        let output = await execute(["grid-layout", "snapshot"])
        let snapshot = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(output.stdout.joined().utf8))
        XCTAssertEqual(snapshot.floating.first!.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.floating.first!.y, 0.3, accuracy: 0.0001)
    }
    func testUnhiddenFloatingGeometryClampsOnTheCurrentDisplay() {
        let workspace = Rect(topLeftX: -1710, topLeftY: 100, width: 1710, height: 1000)
        let frame = gridUnhiddenFloatingRect(position: CGPoint(x: 0.9, y: -0.2),
            size: CGSize(width: 600, height: 400), workspace: workspace)
        XCTAssertEqual(frame.topLeftX, -600)
        XCTAssertEqual(frame.topLeftY, 100)
        XCTAssertEqual(frame.width, 600)
        XCTAssertEqual(frame.height, 400)
    }
    func testInvalidSnapshotDoesNotMutateTree() async {
        let ws = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let result = await execute(["grid-layout", "--data", "{\"version\":99}", "restore"])
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertEqual(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1])
    }
    func testExpiredBootDoesNotBindReusedWindowID() async throws {
        let ws = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let saved = await execute(["grid-layout", "snapshot"])
        var value = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(saved.stdout.joined().utf8))
        value.boot = "previous-boot"
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let result = await execute(["grid-layout", "--data", json, "restore"])
        XCTAssertTrue(result.stderr.joined().contains("expired after reboot"))
        XCTAssertEqual(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1])
    }
    func testNativeFullscreenExitRestoresHomeTree() async {
        let ws = Workspace.get(byName: name)
        let first = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 2)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        await gridRememberNativeLayout(ws)
        first.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        first.bind(to: ws.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        gridRestoreAfterNativeExit(ws)
        XCTAssertEqual(ws.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1,2])
        XCTAssertEqual(first.getWeight(.h), 2)
    }
    func testClosedNativeWindowDoesNotLeaveAnExpiredSnapshot() async throws {
        let ws = Workspace.get(byName: name)
        let old = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        await gridRememberNativeLayout(ws)
        old.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        old.unbindFromParent()
        let fresh = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        _ = ws.focusWorkspace()
        let result = await execute(["grid-layout", "snapshot"])
        let saved = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(result.stdout.joined().utf8))
        XCTAssertEqual(saved.tree.children?.first?.id, fresh.windowId)
    }
    func testNewNativeEntryReplacesAClosedWindowCacheWithoutAnExitHook() async throws {
        let ws = Workspace.get(byName: name)
        let old = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        await gridRememberNativeLayout(ws)
        old.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        old.unbindFromParent()
        let fresh = TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        await gridRememberNativeLayout(ws)
        fresh.bind(to: ws.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        _ = ws.focusWorkspace()
        let result = await execute(["grid-layout", "snapshot"])
        let saved = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(result.stdout.joined().utf8))
        XCTAssertEqual(saved.tree.children?.first?.id, fresh.windowId)
    }
    func testPendingEmptyDestinationSurvivesGarbageCollection() {
        let ws = Workspace.get(byName: "grid-pending-empty")
        gridPendingWorkspaces.insert(ws.name)
        Workspace.garbageCollectUnusedWorkspaces()
        XCTAssertTrue(Workspace.get(byName: ws.name) === ws)
        gridPendingWorkspaces.remove(ws.name)
    }
    func testConstraintsRecognizeAnAppClampingRequestedWidth() async throws {
        let ws = Workspace.get(byName: name)
        let w = TestWindow.new(id: 1, parent: ws.rootTilingContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 500))
        w.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 500)
        _ = ws.focusWorkspace()
        let result = await execute(["grid-layout", "constraints"])
        let values = try JSONDecoder().decode([String: Double].self, from: Data(result.stdout.joined().utf8))
        XCTAssertEqual(Array(values.values), [0], "A single asynchronous frame isn't a confirmed constraint")
    }
    func testMinimumWidthRequiresASettledRepeatedRejection() {
        var tracker = GridMinimumWidthTracker()
        let display = Rect(topLeftX: 0, topLeftY: 0, width: 1710, height: 1073)
        let request = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 500)
        let clamped = request.copy(\.width, 900)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: clamped, display: display, now: 0), 0)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: clamped, display: display, now: 0.5), 0)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: clamped, display: display, now: 1.1), 900)
    }
    func testTransientOrRehostedFramesDoNotBecomeMinimumWidths() {
        var tracker = GridMinimumWidthTracker()
        let laptop = Rect(topLeftX: 0, topLeftY: 0, width: 1710, height: 1073)
        let wide = laptop.copy(\.width, 5120)
        let request = laptop.copy(\.width, 500)
        let stale = request.copy(\.width, 2560)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: stale, display: laptop, now: 0), 0)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: stale, display: wide, now: 2), 0)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: request, display: wide, now: 2.1), 0)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: stale, display: wide, now: 4), 0)
        tracker.forget(windowID: 1)
        XCTAssertEqual(tracker.observe(identity: "boot:pid:1", requested: request, actual: stale, display: wide, now: 6), 0)
    }
    func testReturningToCellFocusesNativeFullscreenDespiteNormalWindowMRU() async {
        let workspace = Workspace.get(byName: "grid-native-return-test")
        let normal = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 2, parent: workspace.macOsNativeFullscreenWindowsContainer)
        _ = normal.focusWindow()
        XCTAssertTrue(workspace.mostRecentWindowRecursive === normal)
        let result = await execute(["grid-layout", "--workspace", workspace.name, "activate"])
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertTrue(focus.windowOrNil === fullscreen)
    }
    func testRestartRecoveryPreservesFullscreenAndRejectsReusedIdentities() async throws {
        let current = Workspace.get(byName: "grid-restart-default")
        let normal = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 2, parent: current.macOsNativeFullscreenWindowsContainer)
        let wrongOwner = TestWindow.new(id: 3, parent: current.rootTilingContainer)
        let expired = TestWindow.new(id: 4, parent: current.rootTilingContainer)
        _ = normal.focusWindow()
        let saved = await execute(["grid-layout", "snapshot"])
        let boot = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(saved.stdout.joined().utf8)).boot
        let homes = [
            GridWindowHome(id: 1, pid: normal.app.pid, boot: boot, workspace: "grid-restart-home", floating: false),
            GridWindowHome(id: 2, pid: fullscreen.app.pid, boot: boot, workspace: "grid-restart-home", floating: true),
            GridWindowHome(id: 3, pid: wrongOwner.app.pid + 1, boot: boot, workspace: "grid-restart-home", floating: false),
            GridWindowHome(id: 4, pid: expired.app.pid, boot: "old-boot", workspace: "grid-restart-home", floating: false),
        ]
        let data = String(decoding: try JSONEncoder().encode(homes), as: UTF8.self)
        let result = await execute(["grid-layout", "--data", data, "recover-homes"])
        XCTAssertTrue(result.stderr.isEmpty)
        let home = Workspace.get(byName: "grid-restart-home")
        XCTAssertTrue(normal.parent === home.rootTilingContainer)
        XCTAssertTrue(fullscreen.parent === home.macOsNativeFullscreenWindowsContainer)
        XCTAssertEqual(fullscreen.layoutReason, .macos(prevParentKind: .floatingWindowsContainer))
        XCTAssertTrue(wrongOwner.visualWorkspace === current)
        XCTAssertTrue(expired.visualWorkspace === current)
    }
    func testRestartRecoveryRetainsHomeUntilFullscreenWindowBecomesVisible() async throws {
        let current = Workspace.get(byName: "grid-delayed-default")
        let known = TestWindow.new(id: 1, parent: current.rootTilingContainer)
        _ = known.focusWindow()
        let saved = await execute(["grid-layout", "snapshot"])
        let boot = try JSONDecoder().decode(GridLayoutSnapshot.self, from: Data(saved.stdout.joined().utf8)).boot
        let home = GridWindowHome(id: 99, pid: known.app.pid, boot: boot, workspace: "grid-delayed-home", floating: false)
        let data = String(decoding: try JSONEncoder().encode([home]), as: UTF8.self)
        _ = await execute(["grid-layout", "--data", data, "recover-homes"])
        let status = await execute(["grid-layout", "status"])
        let object = try JSONSerialization.jsonObject(with: Data(status.stdout.joined().utf8)) as! [String: Any]
        let homes = object["windowHomes"] as! [[String: Any]]
        XCTAssertTrue(homes.contains { ($0["id"] as? Int) == 99 && ($0["workspace"] as? String) == home.workspace })
        let fullscreen = TestWindow.new(id: 99, parent: current.macOsNativeFullscreenWindowsContainer)
        gridApplyRecoveredWindowHome(fullscreen)
        XCTAssertTrue(fullscreen.parent === Workspace.get(byName: home.workspace).macOsNativeFullscreenWindowsContainer)
    }
}
