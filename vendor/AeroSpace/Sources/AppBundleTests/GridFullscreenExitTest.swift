@testable import AppBundle
import XCTest

@MainActor
final class GridFullscreenExitTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        gridFullscreenUnknownTracker = GridFullscreenUnknownTracker()
    }

    private func checkExit(bundleIdentifier: String, nativeSpace: GridNativeSpaceKind, remains: Bool) async throws {
        let previousConfig = config
        defer { config = previousConfig }
        config.automaticallyUnhideMacosHiddenApps = true
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer)
        window.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        window.isMacosFullscreenForTest = false
        var queries = 0
        try await _normalizeLayoutReason(
            workspace: workspace, windows: [window],
            ownsBackendUI: gridOwnsBackendUI(bundleIdentifier: bundleIdentifier),
            nativeSpaceKind: { id in
                XCTAssertEqual(id, window.windowId)
                queries += 1
                return nativeSpace
            },
            now: 0
        )
        XCTAssertEqual(window.parent is MacosFullscreenWindowsContainer, remains)
        if remains {
            guard case .macos(prevParentKind: .floatingWindowsContainer) = window.layoutReason else {
                return XCTFail("Fullscreen layout reason changed")
            }
        } else {
            guard case .standard = window.layoutReason else { return XCTFail("Window did not exit") }
            XCTAssertTrue(window.parent === workspace.floatingWindowsContainer)
        }
        XCTAssertEqual(queries, bundleIdentifier == "local.AeroGrid.Backend" ? 1 : 0)
    }

    func testFalseAXReadingRetainsCorroboratedFullscreen() async throws {
        try await checkExit(bundleIdentifier: "local.AeroGrid.Backend", nativeSpace: .fullscreen, remains: true)
    }

    func testFailedWindowServerLookupRetainsFullscreen() async throws {
        try await checkExit(bundleIdentifier: "local.AeroGrid.Backend", nativeSpace: .unknown, remains: true)
    }

    func testFalseAXReadingExitsOnNormalSpace() async throws {
        try await checkExit(bundleIdentifier: "local.AeroGrid.Backend", nativeSpace: .normal, remains: false)
    }

    func testStandaloneIgnoresCorroboration() async throws {
        try await checkExit(bundleIdentifier: "bobko.aerospace", nativeSpace: .fullscreen, remains: false)
    }

    func testNativeSpaceClassification() {
        let displays = [
            GridNativeDisplay(id: "display-a", current: 1, spaces: [(1, 0), (2, 4)]),
            GridNativeDisplay(id: "display-b", current: 3, spaces: [(3, 4), (4, 2)]),
        ]
        let cases: [(String, [UInt64]?, [GridNativeDisplay]?, GridNativeSpaceKind)] = [
            ("missing displays", [2], nil, .unknown),
            ("missing window spaces", nil, displays, .unknown),
            ("empty window spaces", [], displays, .unknown),
            ("unlisted space overrides normal", [1, 99], displays, .unknown),
            ("no listed displays", [2], [], .unknown),
            ("all fullscreen across displays", [2, 3], displays, .fullscreen),
            ("non-fullscreen type", [4], displays, .normal),
            ("all desktops window", [1, 2], displays, .normal),
        ]
        for (label, windowSpaces, displays, expected) in cases {
            XCTAssertEqual(gridClassifyNativeSpace(windowSpaces: windowSpaces, displays: displays), expected, label)
        }
    }

    private func checkSamples(_ samples: [(TimeInterval, GridNativeSpaceKind, Bool)]) async throws {
        let previousConfig = config
        defer { config = previousConfig }
        config.automaticallyUnhideMacosHiddenApps = true
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer)
        window.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        window.isMacosFullscreenForTest = false
        for (time, kind, remains) in samples {
            try await _normalizeLayoutReason(workspace: workspace, windows: [window], ownsBackendUI: true,
                nativeSpaceKind: { _ in kind }, now: time)
            XCTAssertEqual(window.parent is MacosFullscreenWindowsContainer, remains, "time=\(time)")
            XCTAssertEqual(window.layoutReason, remains ? .macos(prevParentKind: .floatingWindowsContainer) : .standard)
        }
        XCTAssertFalse(gridFullscreenUnknownTracker.shouldExit(windowID: window.windowId, now: 100), "Exit must clear the timer")
    }

    func testUnknownSpaceExitsAfterTenContinuousSeconds() async throws {
        try await checkSamples([(0, .unknown, true), (9.9, .unknown, true), (10, .unknown, false)])
    }

    func testFullscreenEvidenceRestartsUnknownGrace() async throws {
        try await checkSamples([
            (0, .unknown, true), (9, .fullscreen, true),
            (10, .unknown, true), (19.9, .unknown, true), (20, .unknown, false),
        ])
    }

    func testNormalEvidenceExitsImmediatelyDuringGrace() async throws {
        try await checkSamples([(0, .unknown, true), (1, .normal, false)])
    }

    func testUnknownTrackerIsPerWindowAndClearRestartsGrace() {
        var tracker = GridFullscreenUnknownTracker()
        XCTAssertFalse(tracker.shouldExit(windowID: 1, now: 0))
        XCTAssertFalse(tracker.shouldExit(windowID: 2, now: 9))
        XCTAssertTrue(tracker.shouldExit(windowID: 1, now: 10))
        XCTAssertFalse(tracker.shouldExit(windowID: 2, now: 10))
        tracker.clear(windowID: 1)
        XCTAssertFalse(tracker.shouldExit(windowID: 1, now: 10))
        XCTAssertTrue(tracker.shouldExit(windowID: 1, now: 20))
    }

    func testUnknownTrackerAtCapacityKeepsRunningIntervals() {
        var tracker = GridFullscreenUnknownTracker()
        for id: UInt32 in 1...257 { XCTAssertFalse(tracker.shouldExit(windowID: id, now: 0)) }
        for id: UInt32 in 1...256 { XCTAssertTrue(tracker.shouldExit(windowID: id, now: 10), "id=\(id) keeps its interval") }
        XCTAssertFalse(tracker.shouldExit(windowID: 257, now: 10), "A window beyond capacity waits for room")
        tracker.clear(windowID: 1)
        XCTAssertFalse(tracker.shouldExit(windowID: 257, now: 11))
        XCTAssertTrue(tracker.shouldExit(windowID: 257, now: 21))
    }

    func testForgottenWindowHomeRestartsUnknownGrace() async throws {
        let previousConfig = config
        defer { config = previousConfig }
        config.automaticallyUnhideMacosHiddenApps = true
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer)
        window.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        window.isMacosFullscreenForTest = false
        func sample(_ time: TimeInterval) async throws {
            try await _normalizeLayoutReason(workspace: workspace, windows: [window], ownsBackendUI: true,
                nativeSpaceKind: { _ in .unknown }, now: time)
        }
        try await sample(0)
        XCTAssertTrue(window.parent is MacosFullscreenWindowsContainer)
        // Collection and home recovery both end by forgetting the window's pending home: the observation stream breaks.
        gridForgetRecoveredWindowHome(window.windowId)
        try await sample(11)
        XCTAssertTrue(window.parent is MacosFullscreenWindowsContainer, "A returning window starts a new unknown interval")
        try await sample(21)
        XCTAssertFalse(window.parent is MacosFullscreenWindowsContainer)
    }

    func testNativeEvidenceDoesNotCreateFullscreenWithoutKnownHome() async throws {
        let previousConfig = config
        defer { config = previousConfig }
        config.automaticallyUnhideMacosHiddenApps = true
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await _normalizeLayoutReason(workspace: workspace, windows: [window], ownsBackendUI: true,
            nativeSpaceKind: { _ in XCTFail("Standard windows must not query native evidence"); return .fullscreen }, now: 0)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer)
        XCTAssertEqual(window.layoutReason, .standard)
    }
}
