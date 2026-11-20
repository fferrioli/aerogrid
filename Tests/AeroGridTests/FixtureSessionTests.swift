import XCTest
@testable import AeroGrid
import GridCore

final class FixtureSessionTests: XCTestCase {
    func testFixtureInventoryUsesOwnedWindowsAndNeverExposesUserWorkspaces() throws {
        let display = Display(id: "built-in", monitor: 1, name: "Laptop", builtin: true, width: 1440, height: 900)
        let request = FixtureSession.Request(pid: 2, workspace: "grid-fixture-test", display: display,
                                             originalBackend: "backend", allowBackendRestart: false)
        var desktop = Desktop(displays: [display], visible: [1: "user"], focusedMonitor: 1, focusedWindow: 10)
        desktop.windowHomes = [WindowHome(id: 10, pid: 42, boot: "boot", workspace: "user"),
                               WindowHome(id: 20, pid: 2, boot: "boot", workspace: request.workspace)]
        desktop.nativeVisible = [1: 10]
        let scoped = try request.fixtureDesktop(desktop)
        XCTAssertEqual(scoped.windowHomes?.map(\.id), [20])
        XCTAssertEqual(scoped.visible, [:])
        XCTAssertEqual(scoped.nativeVisible, [:])
        XCTAssertNil(scoped.focusedWindow)

        desktop.windowHomes?[0].workspace = request.workspace
        XCTAssertThrowsError(try request.fixtureDesktop(desktop))
        desktop.windowHomes?[0].workspace = "user"
        desktop.windowHomes?[1].workspace = "user"
        XCTAssertThrowsError(try request.fixtureDesktop(desktop))
    }
}
