@testable import AppBundle
import XCTest

@MainActor final class GridFocusRecoveryTest: XCTestCase {
    private var alive: Set<UInt32> = []
    private var input: UInt32 = 0

    override func setUp() async throws {
        setUpWorkspacesForTests()
        gridFocusRecovery = GridFocusRecovery(enabled: { true }, windowExists: { [unowned self] in
            self.alive.contains($0.windowId)
        }, inputCounters: { [unowned self] in [self.input] })
    }

    override func tearDown() async throws { gridFocusRecovery = GridFocusRecovery() }

    private func pair() async throws -> (Workspace, TestWindow, Workspace, TestWindow) {
        let source = Workspace.get(byName: "grid-source")
        let other = Workspace.get(byName: "grid-other")
        let closing = TestWindow.new(id: 9101, parent: source.rootTilingContainer)
        let fallback = TestWindow.new(id: 9102, parent: other.rootTilingContainer)
        alive = [closing.windowId, fallback.windowId]
        _ = closing.focusWindow()
        try await updateFocusCache(closing)
        return (source, closing, other, fallback)
    }

    func testAutomaticFallbackDoesNotSwitchSpaceAndRelaunchUsesSource() async throws {
        let (source, closing, other, fallback) = try await pair()
        alive.remove(closing.windowId)
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertFalse(other.isVisible)
        closing.unbindFromParent()
        for _ in 0..<5 { try await updateFocusCache(fallback) }
        XCTAssertTrue(focus.workspace === source)
        let reopened = TestWindow.new(id: 9103, parent: focus.workspace.rootTilingContainer)
        alive.insert(reopened.windowId)
        try await updateFocusCache(reopened)
        XCTAssertTrue(reopened.nodeWorkspace === source)
        XCTAssertTrue(focus.windowOrNil === reopened)
    }

    func testNextKeyOrClickReleasesFallbackHold() async throws {
        let (_, closing, other, fallback) = try await pair()
        alive.remove(closing.windowId)
        try await updateFocusCache(fallback)
        input += 1
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
    }

    func testGestureOrExplicitWorkspaceChoiceReleasesHoldWithoutInputEvent() async throws {
        let (_, closing, other, fallback) = try await pair()
        alive.remove(closing.windowId)
        try await updateFocusCache(fallback)
        _ = other.focusWorkspace()
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
    }

    func testBackgroundClosureDoesNotUndoRecentNavigation() async throws {
        let (source, closing, other, fallback) = try await pair()
        _ = fallback.focusWindow()
        closing.unbindFromParent()
        alive.remove(closing.windowId)
        // A closed background window must not resurrect the old one-second
        // previous-workspace heuristic after an intentional workspace change.
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
        XCTAssertFalse(source.isVisible)
    }

    func testLivingWindowStillAllowsCmdTabOrDockActivation() async throws {
        let (_, _, other, fallback) = try await pair()
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
    }

    func testCollectionBeforeNativeFocusAlsoPreservesEmptyWorkspace() async throws {
        let (source, closing, _, fallback) = try await pair()
        closing.unbindFromParent()
        alive.remove(closing.windowId)
        gridFocusRecovery.holdAfterClose(closing, workspace: source)
        try await updateFocusCache(nil)
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertNil(focus.windowOrNil)
    }

    func testSurvivingWindowInSameSpaceIsNotBlocked() async throws {
        let (source, closing, _, fallback) = try await pair()
        let survivor = TestWindow.new(id: 9104, parent: source.rootTilingContainer)
        alive.remove(closing.windowId)
        alive.insert(survivor.windowId)
        try await updateFocusCache(fallback)
        closing.unbindFromParent()
        try await updateFocusCache(survivor)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertTrue(focus.windowOrNil === survivor)
    }

    func testNativeFullscreenExitIsNotIntercepted() async throws {
        let (_, closing, other, fallback) = try await pair()
        closing.bind(to: closing.nodeWorkspace!.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        alive.remove(closing.windowId)
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === other)
    }

    func testUnrelatedAeroSpaceAndUnknownWindowMetadataRetainNormalBehavior() async throws {
        for (enabled, exists) in [(false, false as Bool?), (true, nil)] {
            let (_, _, other, fallback) = try await pair()
            gridFocusRecovery = GridFocusRecovery(enabled: { enabled }, windowExists: { _ in exists }, inputCounters: { [] })
            try await updateFocusCache(fallback)
            XCTAssertTrue(focus.workspace === other)
        }
    }

    func testSameSpaceStatusPollingDoesNotQueryAXLiveness() async throws {
        let (_, current, _, _) = try await pair()
        var queries = 0
        gridFocusRecovery = GridFocusRecovery(enabled: { true }, windowExists: { _ in
            queries += 1
            return true
        }, inputCounters: { [] })
        for _ in 0..<20 { try await updateFocusCache(current) }
        XCTAssertEqual(queries, 0)
    }

    func testUserNavigationWhileLivenessQueryIsPendingWins() async throws {
        let (_, _, _, fallback) = try await pair()
        let chosen = Workspace.get(byName: "grid-chosen")
        gridFocusRecovery = GridFocusRecovery(enabled: { true }, windowExists: { _ in
            _ = chosen.focusWorkspace()
            return false
        }, inputCounters: { [] })
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.workspace === chosen)
    }

    func testSameSpaceWindowChoiceWhileQueryIsPendingAlsoWins() async throws {
        let (source, _, _, fallback) = try await pair()
        let chosen = TestWindow.new(id: 9105, parent: source.rootTilingContainer)
        gridFocusRecovery = GridFocusRecovery(enabled: { true }, windowExists: { _ in
            _ = chosen.focusWindow()
            return true
        }, inputCounters: { [] })
        try await updateFocusCache(fallback)
        XCTAssertTrue(focus.windowOrNil === chosen)
    }
}
