import XCTest
@testable import GridCore

final class LayoutPresentationTests: XCTestCase {
    func testCompleteNestedLayoutAndFloatingGeometryStayUnchanged() {
        let tree = LayoutNode.root([.root([LayoutNode(id: 1, pid: 1, weight: 3), LayoutNode(id: 2, pid: 1)], layout: "accordion", orientation: "v")])
        let floating = FloatingLayout(id: 3, pid: 1, x: 0.2, y: 0.1, width: 0.4, height: 0.5)
        let snapshot = LayoutSnapshot(boot: "test", tree: tree, floating: [floating], focus: 2)
        let windows = [WindowInfo(id: 1, workspace: "test"), WindowInfo(id: 2, workspace: "test"),
                       WindowInfo(id: 3, workspace: "test", floating: true)]
        XCTAssertEqual(snapshot.presenting(windows: windows), snapshot)
    }
    func testStaleOwnerAndBootCannotHideAReplacementWindow() {
        let saved = LayoutSnapshot(boot: "old", tree: .root([LayoutNode(id: 1, pid: 4)]),
                                   floating: [FloatingLayout(id: 2, pid: 4, x: 0, y: 0, width: 1, height: 1)])
        for (pid, boot) in [(Int32(5), "old"), (Int32(4), "new")] {
            let windows = [WindowInfo(id: 1, pid: pid, boot: boot, workspace: "test"),
                           WindowInfo(id: 2, pid: pid, boot: boot, workspace: "test", floating: true)]
            let result = saved.presenting(windows: windows)
            XCTAssertEqual(result.boot, boot)
            XCTAssertEqual(result.tree.ids, [1, 2])
            XCTAssertEqual(result.tree.children?.map(\.pid), [pid, pid])
            XCTAssertTrue(result.floating.isEmpty)
        }
    }
    func testClosedAndOtherSpaceWindowsArePrunedAndNewFloatingWindowIsReachable() {
        let saved = LayoutSnapshot(boot: "test", tree: .root([LayoutNode(id: 1, pid: 1), LayoutNode(id: 2, pid: 1)]), focus: 2)
        let windows = [WindowInfo(id: 1, workspace: "test"), WindowInfo(id: 3, workspace: "test", floating: true)]
        let result = saved.presenting(windows: windows)
        XCTAssertEqual(result.tree.ids, [1, 3])
        XCTAssertNil(result.focus)
        XCTAssertEqual(saved.tree.ids, [1, 2], "Presentation must not modify the saved arrangement")
        XCTAssertTrue(saved.presenting(windows: []).tree.ids.isEmpty)
    }
}
