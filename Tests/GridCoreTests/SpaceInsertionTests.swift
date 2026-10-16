import XCTest
@testable import GridCore

final class SpaceInsertionTests: XCTestCase {
    private func cell(_ id:String,_ rect:SpaceRect) -> Space {
        var space = Space(id:id,name:id,row:rect.row,column:rect.column,workspace:id,preferredRole:"external")
        space.rect = rect; return space
    }
    func testEveryHorizontalAndVerticalReorderKeepsTheRunCompact() throws {
        for horizontal in [true,false] {
            let spaces = (0..<4).map { index in
                cell(String(index),horizontal ? SpaceRect(row:2,column:index*2,width:2) : SpaceRect(row:index*2,column:2,height:2))
            }
            for source in spaces { for target in spaces where source.id != target.id {
                for after in [true,false] {
                    let edge:Direction = horizontal ? (after ? .right : .left) : (after ? .down : .up)
                    let plan = try SpaceInsertion.plan(spaces:spaces,sourceID:source.id,targetID:target.id,edge:edge)
                    var expected = spaces.map(\.id).filter { $0 != source.id }
                    expected.insert(source.id,at:expected.firstIndex(of:target.id)! + (after ? 1 : 0))
                    let actual = spaces.sorted { horizontal ? plan[$0.id]!.column < plan[$1.id]!.column : plan[$0.id]!.row < plan[$1.id]!.row }.map(\.id)
                    XCTAssertEqual(actual,expected)
                    XCTAssertEqual(Set(plan.values),Set(spaces.map(\.rect)))
                }
            } }
        }
    }
    func testDifferentWidthsKeepTheirFootprintsWhileReordering() throws {
        let spaces = [cell("a",SpaceRect(row:0,column:0,width:2)),cell("b",SpaceRect(row:0,column:2)),cell("c",SpaceRect(row:0,column:3,width:3))]
        let plan = try SpaceInsertion.plan(spaces:spaces,sourceID:"a",targetID:"c",edge:.right)
        XCTAssertEqual(plan["b"],SpaceRect(row:0,column:0))
        XCTAssertEqual(plan["c"],SpaceRect(row:0,column:1,width:3))
        XCTAssertEqual(plan["a"],SpaceRect(row:0,column:4,width:2))
    }
    func testInsertionPushesCollisionChainWithoutDisturbingOtherRowsOrIntentionalHoles() throws {
        let spaces = [cell("source",SpaceRect(row:3,column:0,width:2)),cell("a",SpaceRect(row:0,column:0)),
                      cell("tall",SpaceRect(row:0,column:1,height:2)),cell("b",SpaceRect(row:1,column:2)),
                      cell("far",SpaceRect(row:0,column:8)),cell("unrelated",SpaceRect(row:4,column:0))]
        let plan = try SpaceInsertion.plan(spaces:spaces,sourceID:"source",targetID:"tall",edge:.left)
        XCTAssertEqual(plan["source"],SpaceRect(row:0,column:1,width:2))
        XCTAssertEqual(plan["tall"],SpaceRect(row:0,column:3,height:2))
        XCTAssertEqual(plan["b"],SpaceRect(row:1,column:4))
        for id in ["a","far","unrelated"] { XCTAssertEqual(plan[id],spaces.first { $0.id == id }?.rect) }
        for (id,rect) in plan { for (otherID,other) in plan where id != otherID { XCTAssertFalse(rect.overlaps(other)) } }
    }
    func testSeparateBoardSourceDoesNotCloseADestinationGap() throws {
        let spaces = [cell("a",SpaceRect(row:0,column:0)),cell("b",SpaceRect(row:0,column:1)),cell("source",SpaceRect(row:0,column:2))]
        let plan = try SpaceInsertion.plan(spaces:spaces,sourceID:"source",targetID:"a",edge:.left,closesSourceGap:false)
        XCTAssertEqual(plan["source"]?.column,0)
        XCTAssertEqual(plan["a"]?.column,1)
        XCTAssertEqual(plan["b"]?.column,2)
    }
    func testOutOfBoundsInsertionIsRejected() {
        let spaces = [cell("source",SpaceRect(row:0,column:0)),cell("target",SpaceRect(row:0,column:100000))]
        XCTAssertThrowsError(try SpaceInsertion.plan(spaces:spaces,sourceID:"source",targetID:"target",edge:.right))
    }
}

extension DynamicEngineTests {
    func testWholeSpaceInsertionAndUndoPreserveAllWindowsAndNestedArrangement() throws {
        try engine.setSpaceRect(external.id,rect:SpaceRect(row:0,column:0))
        let middle = try engine.createSpace(nearID:external.id,displayID:ultra.id,row:0,column:1)
        let last = try engine.createSpace(nearID:external.id,displayID:ultra.id,row:0,column:2)
        let before = engine.map.spaces, homes = backend.screen.windowHomes, tree = backend.trees[external.workspace]
        let undoCount = engine.map.undo.count
        try engine.insertSpace(external.id,beside:middle,edge:.right)
        XCTAssertEqual(engine.map.spaces.first { $0.id == middle }?.column,0)
        XCTAssertEqual(engine.map.spaces.first { $0.id == external.id }?.column,1)
        XCTAssertEqual(engine.map.spaces.first { $0.id == last }?.column,2)
        XCTAssertEqual(engine.map.undo.count,undoCount+1)
        XCTAssertEqual(backend.screen.windowHomes,homes)
        XCTAssertEqual(backend.trees[external.workspace],tree)
        XCTAssertTrue(backend.activations.isEmpty)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces,before)
        XCTAssertEqual(backend.screen.windowHomes,homes)
        XCTAssertEqual(backend.trees[external.workspace],tree)
    }
    func testFoldedInsertionFreezesNeighborsAndKeepsConnectedCoordinates() throws {
        try unplug()
        let canonical = engine.map.spaces
        let source = try XCTUnwrap(engine.map.projectedSpaces(combined:true).first { $0.id == chat.id })
        let target = try XCTUnwrap(engine.map.projectedSpaces(combined:true).first { $0.id == external.id })
        let projected = engine.map.projectedSpaces(combined:true).filter { !$0.isDormant }
        let plan = try SpaceInsertion.plan(spaces:projected,sourceID:source.id,targetID:target.id,edge:.left)
        try engine.insertSpace(source.id,beside:target.id,edge:.left)
        for space in engine.map.projectedSpaces(combined:true) where !space.isDormant { XCTAssertEqual(space.rect,plan[space.id]) }
        for space in canonical { XCTAssertEqual(engine.map.spaces.first { $0.id == space.id }?.rect,space.rect) }
        try engine.undo()
        XCTAssertEqual(engine.map.projectedSpaces(combined:true).filter { !$0.isDormant }.map(\.rect),projected.map(\.rect))
    }
    func testCrossDisplayInsertionKeepsContentsAndCanBeUndone() throws {
        let before = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        let homes = backend.screen.windowHomes
        try engine.insertSpace(external.id,beside:chat.id,edge:.right)
        let after = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        XCTAssertEqual(after.preferredRole,"builtin")
        XCTAssertEqual(after.board,try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id }).board)
        XCTAssertEqual(backend.screen.windowHomes,homes)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces.first { $0.id == external.id },before)
    }
    func testNativeFullscreenCannotBeInsertedOnAnotherDisplay() throws {
        backend.screen.windows?[0].nativeFullscreen = true; backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2:1]; try engine.refresh()
        let full = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
        let before = engine.map.spaces
        XCTAssertThrowsError(try engine.insertSpace(full.id,beside:chat.id,edge:.left))
        XCTAssertEqual(engine.map.spaces,before)
    }
}
