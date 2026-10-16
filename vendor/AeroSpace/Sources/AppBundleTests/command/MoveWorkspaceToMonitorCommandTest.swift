@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveWorkspaceToMonitorCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor next"), .relative(.next))
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor main"), .patterns([.main]))
    }

    func testParseDashDash() {
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor -- next"), .patterns([.pattern("next")!]))
        assertEquals(parseCommand("move-workspace-to-monitor --").errorOrNil, "ERROR: Argument \'(left|down|up|right|next|prev|<monitor-pattern>)\' is mandatory")
    }

    func testPlacingInvisibleWorkspacePreservesOtherDisplay() {
        let primary = mainMonitorInfo
        let secondary = PlacementTestMonitor()
        let original = primary.activeWorkspace
        let destination = Workspace.get(byName: "grid-unused-cell")
        defer {
            _ = primary.setActiveWorkspace(secondary.activeWorkspace)
            _ = primary.setActiveWorkspace(original)
        }
        XCTAssertFalse(destination.isVisible)
        XCTAssertTrue(placeWorkspaceOnMonitor(destination, targetMonitor: secondary))
        XCTAssertTrue(secondary.activeWorkspace === destination)
        XCTAssertTrue(primary.activeWorkspace === original)
    }

    func testMovingVisibleWorkspaceFillsVacatedDisplay() {
        let primary = mainMonitorInfo
        let secondary = PlacementTestMonitor()
        let original = primary.activeWorkspace
        defer {
            _ = primary.setActiveWorkspace(secondary.activeWorkspace)
            _ = primary.setActiveWorkspace(original)
        }
        XCTAssertTrue(placeWorkspaceOnMonitor(original, targetMonitor: secondary))
        XCTAssertTrue(secondary.activeWorkspace === original)
        XCTAssertFalse(primary.activeWorkspace === original)
    }
}

private struct PlacementTestMonitor: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Secondary placement test display"
    let rect = Rect(topLeftX: 1920, topLeftY: 0, width: 1440, height: 900)
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain = false
}

@MainActor
private func parseMoveWorkspaceToMonitorTarget(_ raw: String) -> MonitorTarget? {
    guard case .cmd(.cmd(let cmd)) = parseCommand(raw),
          let args = cmd.args as? MoveWorkspaceToMonitorCmdArgs
    else { return nil }
    return args.target.val
}
