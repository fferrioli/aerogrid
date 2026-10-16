import XCTest
@testable import GridCore

final class WindowDropGeometryTests: XCTestCase {
    func testDropZonesUseActualTileSizeAndCenterStacks() {
        for (width,height) in [(100.0,100.0),(350.0,80.0),(45.0,300.0)] {
            XCTAssertEqual(WindowDropGeometry.placement(x:0,y:height/2,width:width,height:height),.left)
            XCTAssertEqual(WindowDropGeometry.placement(x:width,y:height/2,width:width,height:height),.right)
            XCTAssertEqual(WindowDropGeometry.placement(x:width/2,y:0,width:width,height:height),.top)
            XCTAssertEqual(WindowDropGeometry.placement(x:width/2,y:height,width:width,height:height),.bottom)
            XCTAssertEqual(WindowDropGeometry.placement(x:width/2,y:height/2,width:width,height:height),.stack)
        }
    }
}

extension DynamicEngineTests {
    func testMoveOneAppToExplicitEmptySpaceAndUndoKeepsOtherAppInSource() throws {
        let identity = try XCTUnwrap(backend.screen.windows?.first { $0.id == 1 }?.identity)
        let original = backend.trees[external.workspace]
        let empty = try engine.createSpace(nearID:external.id,displayID:ultra.id)
        let workspace = try XCTUnwrap(engine.map.spaces.first { $0.id == empty }?.workspace)
        let beforeUndo = engine.map.undo.count
        try engine.moveWindow(identity,to:empty)
        XCTAssertEqual(try backend.windows(workspace:workspace),[1])
        XCTAssertEqual(try backend.windows(workspace:external.workspace),[2])
        XCTAssertEqual(engine.map.undo.count,beforeUndo+1)
        try engine.undo()
        XCTAssertEqual(Set(try backend.windows(workspace:external.workspace)),[1,2])
        XCTAssertEqual(backend.trees[external.workspace],original)
    }
    func testDropOnVacancyCreatesExactlyOneSpaceWithTheAppAndUndoRestoresIt() throws {
        let identity = try XCTUnwrap(backend.screen.windows?.first { $0.id == 1 }?.identity)
        let before = engine.map.spaces
        let id = try engine.createSpace(nearID:external.id,displayID:ultra.id,moving:identity)
        let destination = try XCTUnwrap(engine.map.spaces.first { $0.id == id })
        XCTAssertEqual(try backend.windows(workspace:destination.workspace),[1])
        XCTAssertEqual(try backend.windows(workspace:external.workspace),[2])
        XCTAssertEqual(engine.map.spaces.count,before.count+1)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces,before)
        XCTAssertEqual(Set(try backend.windows(workspace:external.workspace)),[1,2])
    }
}
