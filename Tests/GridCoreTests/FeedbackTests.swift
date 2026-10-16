import XCTest
@testable import GridCore

final class FeedbackGestureTests:XCTestCase {
    private func touches(_ x:Double) -> [TouchSample] {
        (0..<3).map { TouchSample(id:String($0),x:x+Double($0)*0.01,y:0) }
    }
    func testQuickSwipeProcessesLastDisplacementBeforeLift() {
        var input = ContactGestureRecognizer()
        XCTAssertTrue(input.feedEvents(touches(0),modifiers:4,displayID:"first",threshold:0.05,invert:false).isEmpty)
        let events = input.feedEvents(touches(0.08),phase:.ended,modifiers:0,displayID:"second",threshold:0.05,invert:false)
        XCTAssertEqual(events.count,2)
        guard events.count == 2, case .step(let swipe) = events[0], case .ended = events[1] else { return XCTFail("A quick swipe must select and then commit") }
        XCTAssertEqual(swipe.direction,.right); XCTAssertEqual(swipe.displayID,"first"); XCTAssertEqual(swipe.modifiers,4)
        XCTAssertTrue(input.feedEvents([],phase:.ended,modifiers:0,displayID:nil,threshold:0.05,invert:false).isEmpty)
    }
    func testLastMotionAtPartialLiftIsNotLostOrCommittedTwice() {
        var input = ContactGestureRecognizer()
        _ = input.feedEvents(touches(0),modifiers:0,displayID:"first",threshold:0.05,invert:false)
        let release = input.feedEvents(touches(0.06),phase:.releasing,modifiers:0,displayID:"first",threshold:0.05,invert:false)
        XCTAssertEqual(release.count,1)
        guard case .step? = release.first else { return XCTFail("Missing release displacement") }
        let ended = input.feedEvents(Array(touches(0.06).prefix(1)),phase:.ended,modifiers:0,displayID:nil,threshold:0.05,invert:false)
        XCTAssertEqual(ended.count,1)
        guard case .ended? = ended.first else { return XCTFail("Missing final commit") }
    }
}

final class FeedbackMapTests:XCTestCase {
    func testOutlineHasOnlyAdjacentCreationTargetsWithoutReservedOuterRows() {
        var tall = Space(id:"one",name:"old label",row:2,column:4,workspace:"one",preferredRole:"builtin")
        tall.rect = SpaceRect(row:2,column:4,width:1,height:2)
        let outline = BoardOutline(spaces:[tall])
        XCTAssertEqual(outline.columns,1);XCTAssertEqual(outline.rows,2)
        XCTAssertEqual(Set(outline.vacancies),Set([GridPoint(row:2,column:3),GridPoint(row:3,column:3),GridPoint(row:2,column:5),GridPoint(row:3,column:5),GridPoint(row:1,column:4),GridPoint(row:4,column:4)]))
    }
    func testLabelsFollowCurrentAppsAndDeduplicateWindows() {
        let windows = [WindowInfo(id:1,workspace:"W",appName:"Editor"),WindowInfo(id:2,workspace:"W",appName:"Chat"),WindowInfo(id:3,workspace:"W",appName:"Editor")]
        XCTAssertEqual(SpaceLabels.title(windows:windows),"Chat · Editor")
        XCTAssertEqual(SpaceLabels.title(windows:Array(windows.suffix(1))),"Editor")
        XCTAssertEqual(SpaceLabels.title(windows:[]),"Espacio vacío")
    }
}

extension DynamicEngineTests {
    func testExplicitEmptySpaceIsReachableWhileUnusedImportedCellsAreSkipped() throws {
        let id = try engine.createSpace(nearID:external.id,displayID:ultra.id)
        XCTAssertTrue(engine.eligibleSpaces(on:ultra).contains(id))
        XCTAssertFalse(engine.eligibleSpaces(on:ultra).contains(config.grids[1].cells[0].id))
        try engine.navigate(.right,scope:.active,displayID:ultra.id)
        XCTAssertEqual(engine.map.cursors[ultra.id],id)
    }
    func testDeletingVisibleEmptySpaceDoesNotReappearAfterDiscoveryAndCanBeUndone() throws {
        let id = try engine.createSpace(nearID:external.id,displayID:ultra.id)
        let workspace = try XCTUnwrap(engine.map.spaces.first { $0.id == id }).workspace
        try engine.jump(cellID:id,displayID:ultra.id)
        try engine.removeEmptySpace(id)
        try engine.refresh()
        XCTAssertFalse(engine.map.spaces.contains { $0.workspace == workspace })
        XCTAssertEqual(backend.screen.visible[ultra.monitor],external.workspace)
        try engine.undo()
        XCTAssertTrue(engine.map.spaces.contains { $0.id == id })
    }
    func testEmptyFamilyMemberCanBeRemovedWithoutDiscardingSurvivingWindows() throws {
        try unplug()
        let child = try XCTUnwrap(engine.map.spaces.first { $0.sourceID == external.id })
        backend.setWindows((backend.screen.windows ?? []).filter { $0.workspace != child.workspace })
        try engine.refresh()
        let surviving = backend.screen.windows
        try engine.removeEmptySpace(child.id)
        XCTAssertFalse(engine.map.spaces.contains { $0.id == child.id })
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(backend.screen.windows,surviving)
        try engine.undo()
        XCTAssertTrue(engine.map.spaces.contains { $0.id == child.id })
        XCTAssertFalse(engine.map.families.isEmpty)
    }
}

extension DynamicEngineTests {
    func testNewSpaceGrowsBesideCurrentContentInsteadOfUnusedLegacyRows() throws {
        let created = try engine.createSpace(nearID:nil,displayID:ultra.id)
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == created })
        let current = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        XCTAssertEqual(space.row,current.row)
        XCTAssertEqual(space.column,current.rect.right)
    }
    func testFoldedNewSpaceUsesAFreeAdjacentPositionInTheCombinedBoard() throws {
        try unplug()
        let before = engine.map.projectedSpaces(combined:true).filter { !$0.isDormant }
        let id = try engine.createSpace(nearID:external.id,displayID:laptop.id)
        let created = try XCTUnwrap(engine.map.projectedSpaces(combined:true).first { $0.id == id })
        XCTAssertTrue(BoardOutline(spaces:before).vacancies.contains(GridPoint(row:created.row,column:created.column)))
        XCTAssertTrue(engine.eligibleSpaces(on:laptop).contains(id))
    }
}
