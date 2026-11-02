import XCTest
@testable import GridCore

extension DynamicEngineTests {
    func testUnchangedRefreshPreservesSnapshotBytesAndRuntimeState() throws {
        let previous = engine.state
        for _ in 0..<10 { try engine.refresh() }
        XCTAssertEqual(engine.state, previous)
        backend.trees[external.workspace]?.tree.children?[0].weight = 9
        try engine.refresh()
        let layout = try LayoutSnapshot(json: XCTUnwrap(engine.map.layouts[external.id]))
        XCTAssertEqual(layout.tree.children?.first?.weight, 9)
        XCTAssertNotEqual(engine.state, previous)
    }
}
