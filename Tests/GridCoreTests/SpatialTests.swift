import XCTest
@testable import GridCore

final class SpatialTests: XCTestCase {
    private func drawing() -> [Space] {
        func cell(_ id: String, _ row: Int, _ column: Int, _ width: Int = 1, _ height: Int = 1) -> Space {
            var space = Space(id: id, name: id, row: row, column: column, workspace: id, preferredRole: "external")
            space.rect = SpaceRect(row: row, column: column, width: width, height: height)
            return space
        }
        return [cell("chat2",0,0),cell("chat",1,0),cell("browser",0,1,1,2),cell("code",0,2),cell("ai",1,2),cell("terminal",2,1,2,1)]
    }
    private func next(_ at: NavigationAnchor, _ direction: Direction, spaces: [Space]) throws -> NavigationAnchor {
        let source = try XCTUnwrap(spaces.first { $0.id == at.spaceID })
        let target = try XCTUnwrap(SpatialNavigation.candidates(from: source, anchor: at, direction: direction, spaces: spaces, eligible: Set(spaces.map(\.id))).first)
        return at.entering(target, direction: direction)
    }
    func testTallSpaceKeepsBothEntryHeights() throws {
        let spaces = drawing()
        for (origin, expected) in [("chat2","code"),("chat","ai")] {
            let start = NavigationAnchor(space: try XCTUnwrap(spaces.first { $0.id == origin }))
            XCTAssertEqual(try next(next(start,.right,spaces:spaces),.right,spaces:spaces).spaceID, expected)
        }
    }
    func testIntentSurvivesSmallerDestinationAndWideTerminal() throws {
        let spaces = drawing().filter { $0.id != "code" }
        let start = NavigationAnchor(space: spaces[0])
        let browser = try next(start,.right,spaces:spaces)
        let ai = try next(browser,.right,spaces:spaces)
        XCTAssertEqual(ai.y,0.5)
        XCTAssertEqual(try next(next(ai,.left,spaces:spaces),.left,spaces:spaces).spaceID,"chat2")
        let terminal = try next(NavigationAnchor(space: XCTUnwrap(spaces.first { $0.id == "ai" })),.down,spaces:spaces)
        XCTAssertEqual(try next(terminal,.up,spaces:spaces).spaceID,"ai")
    }
    func testVacancyIsSkippedWithoutMovingColumnsAndNearbyOverlapWins() throws {
        let spaces = drawing().filter { $0.id != "browser" }
        let chat = try XCTUnwrap(spaces.first { $0.id == "chat" })
        XCTAssertEqual(try next(NavigationAnchor(space:chat),.right,spaces:spaces).spaceID,"ai")
        var origin = chat; origin.rect = SpaceRect(row:0,column:0,width:1,height:2)
        let close = Space(id:"close",name:"Close",row:0,column:1,workspace:"close",preferredRole:"external")
        let far = Space(id:"far",name:"Far",row:1,column:3,workspace:"far",preferredRole:"external")
        XCTAssertEqual(SpatialNavigation.candidates(from:origin,anchor:NavigationAnchor(spaceID:origin.id,x:0.5,y:1.5),direction:.right,spaces:[origin,close,far],eligible:[close.id,far.id]).first?.id,close.id)
    }
    func testMigrationUsesBoardOwnershipAndIsIdempotent() throws {
        let config = Configuration(backendPath:"/unused")
        var map = SpaceMap(configuration:config)
        let original = map.spaces
        try map.migrateSpatial(configuration:config,desktop:nil)
        XCTAssertEqual(map.version,3)
        XCTAssertEqual(map.spaces.map(\.id),original.map(\.id))
        XCTAssertEqual(map.spaces.map(\.workspace),original.map(\.workspace))
        XCTAssertEqual(map.spaces[9].column,0)
        let once = map
        try map.migrateSpatial(configuration:config,desktop:nil)
        XCTAssertEqual(map,once)
    }
    func testResizeRejectsOverlapAndAutomaticGrowthPreservesHoles() throws {
        var map = SpaceMap(configuration:Configuration(backendPath:"/unused"));map.version=3;map.spaces=drawing()
        let browser = try XCTUnwrap(map.spaces.first { $0.id == "browser" })
        XCTAssertFalse(map.fits(SpaceRect(row:0,column:1,width:2,height:2),board:browser.board,excluding:[browser.id]))
        let old = map.spaces
        XCTAssertGreaterThanOrEqual(map.frontier(near:browser).column,3)
        XCTAssertEqual(map.spaces,old)
        var duplicate = browser;duplicate.id="duplicate";duplicate.workspace="duplicate";map.spaces.append(duplicate)
        XCTAssertThrowsError(try map.validate())
    }
    func testCombinedProjectionKeepsCanonicalCoordinatesAndColumns() throws {
        var map = SpaceMap(configuration:Configuration(backendPath:"/unused"));map.version=3;map.spaces=drawing()
        map.spaces.append(Space(id:"local",name:"Local",row:0,column:0,workspace:"local",preferredRole:"builtin"))
        let before=map.spaces
        let projected=map.projectedSpaces(combined:true)
        XCTAssertEqual(projected.first { $0.id=="browser" }?.column,1)
        XCTAssertEqual(projected.first { $0.id=="code" }?.column,2)
        XCTAssertEqual(map.spaces,before)
        for a in projected { for b in projected where a.id != b.id { XCTAssertFalse(a.rect.overlaps(b.rect)) } }
    }
}

final class ContactGestureTests: XCTestCase {
    private func touches(_ x:Double,_ y:Double=0,fingers:Int=3)->[TouchSample] {
        (0..<fingers).map { TouchSample(id:String($0),x:x+Double($0)*0.01,y:y) }
    }
    func testHoldRepeatsOnlyOnMotionAndEndsExplicitly() {
        var recognizer=ContactGestureRecognizer()
        func feed(_ x:Double,phase:ContactPhase = .active)->ContactGestureEvent? {
            recognizer.feed(touches(x),phase:phase,modifiers:0,displayID:"one",threshold:0.05,invert:false,timestamp:x >= 0.12 ? 1 : 0)
        }
        XCTAssertNil(feed(0))
        guard case .step(let first)? = feed(0.06) else { return XCTFail("No first step") }
        XCTAssertEqual(first.direction,.right)
        XCTAssertNil(feed(0.06))
        guard case .step? = feed(0.12) else { return XCTFail("No second step") }
        XCTAssertNil(recognizer.feed([],modifiers:0,displayID:"two",threshold:0.05,invert:false))
        guard case .ended? = feed(0.12,phase:.ended) else { return XCTFail("No explicit end") }
    }
    func testScopeFrozenAndFingerChangesCancelWithoutCommit() {
        var recognizer=ContactGestureRecognizer()
        _=recognizer.feed(touches(0),modifiers:4,displayID:"one",threshold:0.05,invert:false)
        guard case .step(let step)?=recognizer.feed(touches(0.06),modifiers:0,displayID:"two",threshold:0.05,invert:false) else { return XCTFail() }
        XCTAssertEqual(step.modifiers,4);XCTAssertEqual(step.displayID,"one")
        guard case .cancelled?=recognizer.feed(touches(0.08,fingers:4),modifiers:0,displayID:"two",threshold:0.05,invert:false) else { return XCTFail() }
        XCTAssertNil(recognizer.feed([],phase:.ended,modifiers:0,displayID:nil,threshold:0.05,invert:false))
    }
}

extension SpatialTests {
    func testEveryOccupiedSubsetOfDrawingRemainsReachableAfterClosures() throws {
        let all = drawing()
        for mask in 1..<(1 << all.count) {
            let spaces = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let eligible = Set(spaces.map(\.id))
            for source in spaces {
                var queue = [NavigationAnchor(space: source)], seen = Set<String>(), reachable = Set<String>()
                while !queue.isEmpty {
                    let entry = queue.removeFirst(), key = "\(entry.spaceID):\(entry.x):\(entry.y)"
                    guard seen.insert(key).inserted else { continue }
                    reachable.insert(entry.spaceID)
                    let origin = try XCTUnwrap(spaces.first { $0.id == entry.spaceID })
                    for direction in Direction.allCases {
                        if let target = SpatialNavigation.candidates(from: origin, anchor: entry, direction: direction, spaces: spaces, eligible: eligible).first {
                            queue.append(entry.entering(target,direction:direction))
                        }
                    }
                }
                XCTAssertEqual(reachable,eligible,"Closure subset \(mask), start \(source.id)")
            }
        }
    }
}

extension DynamicEngineTests {
    func testSpatialResizeIsUndoableWithoutChangingWindowArrangement() throws {
        let source = try XCTUnwrap(engine.map.spaces.first { $0.id == external.id })
        let layout = backend.trees[external.workspace]
        try engine.setSpaceRect(source.id,rect:SpaceRect(row:source.row,column:source.column,width:1,height:2))
        XCTAssertEqual(engine.map.spaces.first { $0.id == source.id }?.rect.height,2)
        XCTAssertEqual(backend.trees[external.workspace],layout)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces.first { $0.id == source.id }?.rect,source.rect)
        XCTAssertEqual(backend.trees[external.workspace],layout)
    }
    func testHeldSelectionDoesNotActivateAndRejectsReusedOwnersAtCommit() throws {
        let upper=config.grids[1].cells[0]
        backend.setWindows((backend.screen.windows ?? [])+[WindowInfo(id:9,workspace:upper.workspace)])
        try engine.refresh()
        var selection=try NavigationSelection(map:engine.map,configuration:config,desktop:backend.screen,scope:.active,displayID:ultra.id)
        XCTAssertTrue(selection.step(.up))
        XCTAssertTrue(backend.activations.isEmpty)
        let before=backend.screen.visible
        let reusedIndex = try XCTUnwrap(backend.screen.windows?.firstIndex { $0.id == 9 })
        backend.screen.windows?[reusedIndex].pid = 99
        XCTAssertThrowsError(try engine.commitNavigation(selection))
        XCTAssertEqual(backend.screen.visible,before)
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testHeldSelectionCommitsOneFinalTargetAndReverseCancels() throws {
        let upper=config.grids[1].cells[0]
        backend.setWindows((backend.screen.windows ?? [])+[WindowInfo(id:9,workspace:upper.workspace)])
        try engine.refresh()
        var selection=try NavigationSelection(map:engine.map,configuration:config,desktop:backend.screen,scope:.active,displayID:ultra.id)
        XCTAssertTrue(selection.step(.up));XCTAssertTrue(selection.step(.down));XCTAssertTrue(selection.isAtOrigin)
        try engine.commitNavigation(selection);XCTAssertTrue(backend.activations.isEmpty)
        XCTAssertTrue(selection.step(.up));try engine.commitNavigation(selection)
        XCTAssertEqual(backend.activations.count,1)
        XCTAssertEqual(backend.screen.visible[2],upper.workspace)
    }
    func testNativeSpaceCannotBeTransferredByCrossBoardSwap() throws {
        backend.screen.windows?[0].nativeFullscreen=true;backend.screen.windows?[0].nativeMonitor=2
        backend.screen.nativeVisible=[2:1];try engine.refresh()
        let full=try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id==1 })
        let before=engine.map.spaces
        XCTAssertThrowsError(try engine.moveSpace(full.id,to:chat.id))
        XCTAssertEqual(engine.map.spaces,before)
    }
}

final class WindowPlacementTests: XCTestCase {
    func testNestedPlacementPreservesOtherSubtreesWeightsAndPreview() throws {
        let a = LayoutNode(id:1,pid:1,weight:3)
        let b = LayoutNode(id:2,pid:1,weight:1)
        let stack = LayoutNode(orientation:"v",layout:"accordion",children:[LayoutNode(id:3,pid:1),LayoutNode(id:4,pid:1)])
        let snapshot = LayoutSnapshot(boot:"test",tree:.root([a,.root([b,stack],orientation:"v")]))
        let result = try snapshot.placing(LayoutNode(id:9,pid:2),beside:[2],placement:.left)
        XCTAssertEqual(result.tree.children?[0],a)
        XCTAssertEqual(result.tree.children?[1].children?[1],stack)
        XCTAssertEqual(result.tree.children?[1].children?[0].ids,[9,2])
        XCTAssertEqual(snapshot.tree.ids,[1,2,3,4])
        XCTAssertThrowsError(try snapshot.placing(LayoutNode(id:9,pid:2),beside:[999],placement:.stack))
    }
    func testMovingWithinStackExtractsOnlyChosenMember() throws {
        let snapshot = LayoutSnapshot(boot:"test",tree:.root([.root([LayoutNode(id:1,pid:1),LayoutNode(id:2,pid:1)],layout:"accordion"),LayoutNode(id:3,pid:1,weight:2)]))
        let result = try snapshot.placing(LayoutNode(id:2,pid:1),beside:[3],placement:.bottom)
        XCTAssertEqual(result.tree.ids,[1,3,2])
        XCTAssertEqual(result.tree.children?[0].layout,"accordion")
        XCTAssertEqual(result.tree.children?[1].orientation,"v")
        XCTAssertEqual(result.tree.children?[1].weight,2)
    }
}
extension ContactGestureTests {
    func testStaggeredLiftWaitsForLastContactAndCommitsOnlyOnce() {
        var recognizer=ContactGestureRecognizer()
        _=recognizer.feed(touches(0),modifiers:0,displayID:"one",threshold:0.05,invert:false)
        guard case .step?=recognizer.feed(touches(0.06),modifiers:0,displayID:"one",threshold:0.05,invert:false) else { return XCTFail() }
        XCTAssertNil(recognizer.feed(touches(0.06,fingers:2),phase:.releasing,modifiers:0,displayID:nil,threshold:0.05,invert:false))
        XCTAssertNil(recognizer.feed(touches(0.06,fingers:1),phase:.releasing,modifiers:0,displayID:nil,threshold:0.05,invert:false))
        guard case .ended?=recognizer.feed([],phase:.ended,modifiers:0,displayID:nil,threshold:0.05,invert:false) else { return XCTFail() }
        XCTAssertNil(recognizer.feed([],phase:.ended,modifiers:0,displayID:nil,threshold:0.05,invert:false))
    }
}
extension DynamicEngineTests {
    func testFoldedGeometryEditKeepsConnectedMapAndOtherPositionsStable() throws {
        try unplug()
        let projected = engine.map.projectedSpaces(combined:true)
        let source = try XCTUnwrap(projected.first { $0.id == chat.id })
        let canonical = engine.map.spaces
        var frame = source.rect; frame.column = (projected.map { $0.rect.right }.max() ?? 0) + 1
        try engine.setSpaceRect(source.id,rect:frame)
        XCTAssertEqual(engine.map.projectedSpaces(combined:true).first { $0.id == source.id }?.rect,frame)
        for space in canonical { XCTAssertEqual(engine.map.spaces.first { $0.id == space.id }?.rect,space.rect) }
        for space in projected where space.id != source.id { XCTAssertEqual(engine.map.projectedSpaces(combined:true).first { $0.id == space.id }?.rect,space.rect) }
        try engine.undo()
        XCTAssertEqual(engine.map.projectedSpaces(combined:true).first { $0.id == source.id }?.rect,source.rect)
        try reconnect()
        XCTAssertEqual(engine.map.spaces.first { $0.id == source.id }?.rect,canonical.first { $0.id == source.id }?.rect)
    }
}

extension DynamicEngineTests {
    func testLocalPlacementAndUndoPreserveOtherPaneAndRejectStaleGroup() throws {
        let incoming = try XCTUnwrap(backend.screen.windows?.first { $0.id == 3 })
        let before = try XCTUnwrap(backend.trees[external.workspace])
        let oldHomes = backend.screen.windowHomes
        XCTAssertThrowsError(try engine.placeWindow(incoming.identity,in:external.id,group:[999],placement:.left))
        XCTAssertEqual(backend.screen.windowHomes,oldHomes)
        try engine.placeWindow(incoming.identity,in:external.id,group:[1],placement:.right,expectedTarget:before.tree,expectedSourceWorkspace:chat.workspace)
        let changed = try XCTUnwrap(backend.trees[external.workspace])
        XCTAssertEqual(changed.tree.children?[1],before.tree.children?[1])
        XCTAssertEqual(changed.tree.children?[0].ids,[1,3])
        XCTAssertEqual(engine.map.undo.count,1)
        try engine.undo()
        XCTAssertEqual(backend.trees[external.workspace]?.tree,before.tree)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 3 }?.workspace,chat.workspace)
        var stale = before.tree; stale.orientation = "v"
        XCTAssertThrowsError(try engine.placeWindow(incoming.identity,in:external.id,group:[1],placement:.left,expectedTarget:stale))
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 3 }?.workspace,chat.workspace)
    }
    func testClosedTechnicalSpaceBecomesVacancyWithoutRepositioningOthers() throws {
        let frames = engine.map.spaces.map(\.rect)
        backend.setWindows((backend.screen.windows ?? []).filter { $0.id != 3 })
        backend.screen.visible[1] = config.grids[0].cells[0].workspace
        try engine.refresh()
        XCTAssertTrue(try XCTUnwrap(engine.map.spaces.first { $0.id == chat.id }).isDormant)
        XCTAssertEqual(engine.map.spaces.map(\.rect),frames)
    }
}

extension DynamicEngineTests {
    func testGestureCanLeaveAnEmptyVisibleSpaceWithoutChangingCapturedDisplay() throws {
        let empty = config.grids[1].cells[0]
        backend.screen.visible[2] = empty.workspace
        try engine.refresh()
        var selection = try NavigationSelection(map:engine.map,configuration:config,desktop:backend.screen,scope:.active,displayID:ultra.id)
        XCTAssertNoThrow(try selection.validate(map:engine.map,configuration:config,desktop:backend.screen))
        XCTAssertTrue(selection.step(.down))
        try engine.commitNavigation(selection)
        XCTAssertEqual(backend.screen.visible[2],external.workspace)
        XCTAssertThrowsError(try NavigationSelection(map:engine.map,configuration:config,desktop:backend.screen,scope:.active,displayID:"removed-display"))
    }
}

extension DynamicEngineTests {
    func testInactiveBoardLayoutIsCapturedForTheOrganizerWithoutActivation() throws {
        let inactive = config.grids[1].cells[0]
        backend.setWindows((backend.screen.windows ?? [])+[WindowInfo(id:9,workspace:inactive.workspace),WindowInfo(id:10,workspace:inactive.workspace)])
        let tree = LayoutNode.root([LayoutNode(id:9,pid:1,weight:2),LayoutNode(id:10,pid:1)],orientation:"v")
        backend.trees[inactive.workspace] = LayoutSnapshot(boot:"test",tree:tree)
        let visible = backend.screen.visible
        try engine.refresh()
        XCTAssertEqual(try LayoutSnapshot(json:XCTUnwrap(engine.map.layouts[inactive.id])).tree,tree)
        XCTAssertEqual(backend.screen.visible,visible)
        XCTAssertTrue(backend.activations.isEmpty)
    }
}
