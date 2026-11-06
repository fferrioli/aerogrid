import AppKit
import GridCore
import XCTest
@testable import AeroGrid

@MainActor final class LayoutPresentationTests: XCTestCase {
    func testInventoryWindowsRemainVisibleWhenSavedLayoutIsIncomplete() throws {
        let config = Configuration(backendPath: "/usr/bin/false")
        let workspace = config.grids[0].cells[0].workspace
        let display = Display(id: "test", monitor: 1, name: "Test", builtin: true, width: 1710, height: 1073)
        var desktop = Desktop(displays: [display], visible: [1: workspace], focusedMonitor: 1)
        desktop.windows = [WindowInfo(id: 1, workspace: workspace, appName: "Editor"),
                           WindowInfo(id: 2, workspace: workspace, appName: "New window")]
        let model = try AppModel(preview: desktop, previewConfiguration: config)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.directory) }
        let space = try XCTUnwrap(model.spaces.first { $0.workspace == workspace })
        model.state.dynamicMap?.layouts[space.id] = try LayoutSnapshot(boot: "test", tree: .root([LayoutNode(id: 1, pid: 1)])).json()
        XCTAssertEqual(Set(model.layout(space).tree.ids), [1, 2])
        XCTAssertEqual(model.displayName(space), "Editor · New window")
    }
}
