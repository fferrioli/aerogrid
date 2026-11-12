@testable import AppBundle
import XCTest

@MainActor
final class GridFullscreenExitTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func checkExit(bundleIdentifier: String, corroborated: Bool, remains: Bool) async throws {
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
            corroborateFullscreen: { id in
                XCTAssertEqual(id, window.windowId)
                queries += 1
                return corroborated
            }
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
        try await checkExit(bundleIdentifier: "local.AeroGrid.Backend", corroborated: true, remains: true)
    }

    func testFalseAXReadingExitsWithoutCorroboration() async throws {
        try await checkExit(bundleIdentifier: "local.AeroGrid.Backend", corroborated: false, remains: false)
    }

    func testStandaloneIgnoresCorroboration() async throws {
        try await checkExit(bundleIdentifier: "bobko.aerospace", corroborated: true, remains: false)
    }
}
