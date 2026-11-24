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
    func testDeleteEmptyFullscreenHomeKeepsCardsNavigableAndCanBeUndone() throws {
        backend.screen.windows?[0].nativeFullscreen = true
        backend.screen.windows?[0].nativeMonitor = ultra.monitor
        try engine.refresh()
        backend.screen.windows?[1].nativeFullscreen = true
        backend.screen.windows?[1].nativeMonitor = ultra.monitor
        try engine.refresh()
        backend.screen.nativeVisible?[ultra.monitor] = 1

        let links = engine.map.fullscreens
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.allSatisfy { $0.homeID == external.id })
        let cards = engine.map.spaces.filter { $0.nativeWindow != nil }
        let members = backend.screen.windows
        let moves = backend.windowMoves
        try engine.removeEmptySpace(external.id)
        try engine.refresh()

        let home = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        XCTAssertTrue(home.isDormant)
        XCTAssertEqual(home.hiddenFullscreenHome, true)
        XCTAssertFalse(engine.eligibleSpaces(on: ultra).contains(external.id))
        XCTAssertTrue(Set(cards.map(\.id)).isSubset(of: engine.eligibleSpaces(on: ultra)))
        XCTAssertEqual(engine.map.fullscreens, links)
        XCTAssertEqual(engine.map.spaces.filter { $0.nativeWindow != nil }, cards)
        XCTAssertEqual(backend.screen.windows, members)
        XCTAssertEqual(backend.windowMoves, moves)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .fullscreenHomeHidden })

        try engine.undo()
        XCTAssertFalse(try XCTUnwrap(engine.map.spaces.first { $0.id == external.id }).isDormant)
        XCTAssertEqual(engine.map.fullscreens, links)
        XCTAssertEqual(backend.screen.windows, members)
    }

    func testHiddenFullscreenHomeWakesOnlyAfterAWindowReturnsToNormal() throws {
        backend.screen.windows?[0].nativeFullscreen = true
        backend.screen.windows?[0].nativeMonitor = ultra.monitor
        try engine.refresh()
        backend.setWindows(backend.screen.windows!.filter { $0.id != 2 })
        try engine.refresh()
        backend.screen.nativeVisible?[ultra.monitor] = 1
        try engine.removeEmptySpace(external.id)

        // After native exit the old workspace may be visible before the inventory settles.
        backend.screen.nativeVisible?.removeValue(forKey: ultra.monitor)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.windows?[0].nativeSpace = "normal"
        try engine.refresh()
        XCTAssertTrue(try XCTUnwrap(engine.map.spaces.first { $0.id == external.id }).isDormant)
        try engine.refresh()
        let reoccupiedHome = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        XCTAssertFalse(reoccupiedHome.isDormant)
        XCTAssertNil(reoccupiedHome.hiddenFullscreenHome)
        XCTAssertEqual(engine.contents(of: reoccupiedHome).map(\.id), [1])
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }

    func testHiddenHomeStaysHiddenWhenNewFullscreenWindowsComeAndGo() throws {
        backend.screen.windows?[0].nativeFullscreen = true
        backend.screen.windows?[0].nativeMonitor = ultra.monitor
        try engine.refresh()
        backend.setWindows(backend.screen.windows!.filter { $0.id != 2 })
        try engine.refresh()
        backend.screen.nativeVisible?[ultra.monitor] = 1
        try engine.removeEmptySpace(external.id)

        backend.screen.nativeVisible?.removeValue(forKey: ultra.monitor)
        backend.setWindows(backend.screen.windows!.filter { $0.id != 1 })
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        let replacement = WindowInfo(id: 88, workspace: external.workspace, nativeFullscreen: true, nativeMonitor: ultra.monitor)
        backend.setWindows(backend.screen.windows! + [replacement])
        try engine.refresh()

        let link = try XCTUnwrap(engine.map.fullscreens.first { $0.identity == replacement.identity })
        XCTAssertEqual(link.homeID, external.id)
        XCTAssertNotEqual(link.spaceID, external.id)
        XCTAssertTrue(try XCTUnwrap(engine.map.spaces.first { $0.id == external.id }).isDormant)
        backend.setWindows(backend.screen.windows!.filter { $0.id != replacement.id })
        for _ in 0..<DynamicEngine.absenceConfirmations { try engine.refresh() }
        XCTAssertTrue(try XCTUnwrap(engine.map.spaces.first { $0.id == external.id }).isDormant)
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }

    func testDeleteRejectsEmptyLookingWorkspaceWithAnUnverifiedWindowHome() throws {
        let id = try engine.createSpace(nearID: external.id, displayID: ultra.id)
        let space = try XCTUnwrap(engine.map.spaces.first { $0.id == id })
        backend.screen.windowHomes?.append(WindowHome(id: 99, pid: 42, boot: "test", workspace: space.workspace))
        let before = engine.map.undo
        XCTAssertThrowsError(try engine.removeEmptySpace(id)) { failure in
            XCTAssertEqual((failure as? GridError)?.localizedDescription,
                           GridError.unavailable("AeroGrid todavía está verificando las ventanas de este espacio").localizedDescription)
        }
        XCTAssertEqual(engine.map.undo, before)
        XCTAssertNil(engine.map.pending)
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
