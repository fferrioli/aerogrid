import Foundation
import GridCore
import XCTest
@testable import AeroGrid

final class DiagnosticPlacementTests: XCTestCase {
    func testReportedFramesAndNativeSpacesAreSeparateFromLogicalCellsAndKeepUnknownOccupancy() throws {
        let config = Configuration(backendPath: "/PRIVATE_CLI")
        let display = Display(id: "PRIVATE_DISPLAY", monitor: 1, name: "PRIVATE_DISPLAY_NAME", builtin: true, width: 1600, height: 900)
        let occupied = "PRIVATE_WORKSPACE"
        let empty = "PRIVATE_EMPTY"
        let pending = "PRIVATE_PENDING"
        let actual = WindowInfo(id: 123456, pid: 987654, boot: "PRIVATE_BOOT", workspace: occupied,
            title: "PRIVATE_TITLE", appName: "PRIVATE_APP", bundleID: "PRIVATE_BUNDLE", nativeSpace: "fullscreen")
        var desktop = Desktop(displays: [display], visible: [1: empty], focusedMonitor: 1, focusedWindow: actual.id)
        desktop.windows = [actual]
        desktop.windowHomes = [WindowHome(id: 123457, pid: actual.pid, boot: actual.boot, workspace: pending)]
        let frame = DiagnosticFrame(x: -200, y: 10, width: 350, height: 400)
        var placement = BackendPlacementDiagnostics(
            windows: [actual.id: .init(source: "windowTree", frame: frame, onScreen: false, nativeSpaceIDs: [900])],
            workspaces: [.init(name: occupied, monitor: 2), .init(name: empty, monitor: 1), .init(name: pending, monitor: 1)],
            displayFrames: [1: .init(x: -1600, y: 0, width: 1600, height: 940)],
            nativeDisplays: [.init(monitor: 1, current: 900, spaces: [.init(id: 900, type: 4), .init(id: 901, type: 4), .init(id: 902, type: 0)])],
            locked: false, pendingWindowIDs: [123457], focusHoldWorkspace: empty, frontmostMatchesFocusedWindowOwner: false)
        let aliases = DiagnosticAliases()
        let backend = DiagnosticSnapshot(desktop: desktop, placement: placement, aliases: aliases)
        let key = aliases.window(actual.identity)
        guard case .window(let observed) = backend.tables["windows"]?[key] else { return XCTFail("Observed window missing") }
        XCTAssertEqual(observed.frame, frame)
        XCTAssertEqual(observed.onScreen, false)
        XCTAssertEqual(observed.nativeSpaceKind, "fullscreen")
        XCTAssertFalse(observed.backendFullscreen)
        XCTAssertEqual(observed.nativeSpaces, [aliases.id("nativeSpace", "900")])
        func occupancy(_ snapshot: DiagnosticSnapshot, _ name: String) -> String? {
            guard case .workspace(let workspace) = snapshot.tables["workspaces"]?[aliases.id("workspace", name)] else { return nil }
            return workspace.occupancy
        }
        XCTAssertEqual(occupancy(backend, occupied), "trackedWindows")
        XCTAssertEqual(occupancy(backend, empty), "reportedEmpty")
        XCTAssertEqual(occupancy(backend, pending), "pendingHomes")
        XCTAssertEqual(occupancy(.init(desktop: desktop, placement: nil, aliases: aliases), empty), "unavailable")
        placement.locked = true
        XCTAssertEqual(occupancy(.init(desktop: desktop, placement: placement, aliases: aliases), empty), "unavailable")
        guard case .nativeSpace(let unowned) = backend.tables["nativeSpaces"]?["0:\(aliases.id("nativeSpace", "901"))"] else {
            return XCTFail("Native fullscreen Space without a window missing")
        }
        XCTAssertEqual(unowned.occupancy, "unattributed")
        XCTAssertTrue(unowned.trackedWindows.isEmpty)

        var map = SpaceMap(configuration: config)
        let full = Space(id: "PRIVATE_CELL", name: "PRIVATE_CELL_NAME", row: 3, column: 2, workspace: occupied, preferredRole: "builtin")
        var cell = full
        cell.nativeWindow = actual.identity
        map.spaces.append(cell)
        map.anchors = [display.id: NavigationAnchor(spaceID: cell.id, x: 3.5, y: 4.5)]
        let logical = DiagnosticSnapshot(map: map, configuration: config, desktop: desktop, activeGrids: [:], aliases: aliases)
        guard case .cell(let desired) = logical.tables["cells"]?[aliases.id("cell", cell.id)],
              case .cursor(let cursor) = logical.tables["cursors"]?[aliases.id("display", display.id)] else { return XCTFail("Map placement missing") }
        XCTAssertEqual(desired.rect, cell.rect)
        XCTAssertEqual(desired.workspace, observed.workspace)
        XCTAssertEqual(desired.fullscreenWindow, key)
        XCTAssertEqual(cursor.x, 3.5)
        XCTAssertEqual(cursor.anchorSpace, aliases.id("cell", cell.id))
        XCTAssertNotEqual(aliases.window(.init(id: actual.id, pid: 9, boot: actual.boot)), key)

        let encoded = try JSONEncoder().encode([backend.tables, logical.tables])
        let raw = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(raw.contains("PRIVATE_"))
        XCTAssertFalse(raw.contains("123456"))
        XCTAssertFalse(raw.contains("987654"))
    }
}
