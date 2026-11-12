import XCTest
@testable import GridCore

extension DynamicEngineTests {
    private func enterFullscreen(onlyWindow: Bool = false) throws -> Space {
        if onlyWindow { backend.setWindows([WindowInfo(id:1,workspace:external.workspace)]) }
        backend.screen.windows?[0].nativeFullscreen = true
        backend.screen.windows?[0].nativeMonitor = 2
        backend.screen.nativeVisible = [2:1]
        try engine.refresh()
        return try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 1 })
    }

    private func settle(_ n: Int = 3) throws { for _ in 0..<n { try engine.refresh() } }
    func testFullscreenCardMovesToEmptySpaceWithoutMovingOtherAppsAndUndoRestoresIt() throws {
        let full = try enterFullscreen()
        let emptyID = try engine.createSpace(nearID:full.id,displayID:ultra.id)
        let empty = try XCTUnwrap(engine.map.spaces.first { $0.id == emptyID })
        let before = engine.map.spaces, links = engine.map.fullscreens
        let homes = backend.screen.windowHomes, trees = backend.trees
        let undoCount = engine.map.undo.count

        try engine.moveWindow(XCTUnwrap(full.nativeWindow),to:emptyID)

        XCTAssertEqual(engine.map.spaces.first { $0.id == full.id }?.rect,empty.rect)
        XCTAssertEqual(engine.map.spaces.first { $0.id == emptyID }?.rect,full.rect)
        XCTAssertEqual(engine.map.spaces.filter { $0.id != full.id && $0.id != emptyID },before.filter { $0.id != full.id && $0.id != emptyID })
        XCTAssertEqual(backend.screen.windowHomes,homes)
        XCTAssertEqual(backend.trees,trees)
        XCTAssertTrue(backend.activations.isEmpty)
        XCTAssertEqual(engine.map.undo.count,undoCount+1)
        try engine.refresh()
        try engine.jump(cellID:external.id,displayID:ultra.id)
        try engine.jump(cellID:full.id,displayID:ultra.id)
        XCTAssertEqual(backend.screen.nativeVisible?[2],1)
        try engine.undo()
        XCTAssertEqual(engine.map.spaces,before)
        XCTAssertEqual(engine.map.fullscreens,links)
        XCTAssertEqual(backend.screen.windowHomes,homes)
    }

    func testFullscreenCardDropOnPlusCreatesOneEmptySourceAndOneUndo() throws {
        let full = try enterFullscreen()
        let before = engine.map.spaces, homes = backend.screen.windowHomes
        let undoCount = engine.map.undo.count
        let destination = SpaceRect(row:12,column:15)

        let id = try engine.createSpace(nearID:full.id,displayID:ultra.id,row:destination.row,column:destination.column,moving:full.nativeWindow)

        XCTAssertEqual(id,full.id)
        XCTAssertEqual(engine.map.spaces.first { $0.id == id }?.rect,destination)
        let empty = try XCTUnwrap(engine.map.spaces.first { candidate in !before.contains { $0.id == candidate.id } })
        XCTAssertEqual(empty.rect,full.rect)
        XCTAssertTrue(engine.contents(of:empty).isEmpty)
        XCTAssertEqual(engine.map.spaces.count,before.count+1)
        XCTAssertEqual(engine.map.spaces.filter { $0.id != full.id && $0.id != empty.id },before.filter { $0.id != full.id })
        XCTAssertEqual(backend.screen.windowHomes,homes)
        XCTAssertEqual(engine.map.undo.count,undoCount+1)
        try engine.refresh()
        try engine.undo()
        XCTAssertEqual(engine.map.spaces,before)
    }

    func testFullscreenCardRejectsOccupiedNormalOrFullscreenSpace() throws {
        let full = try enterFullscreen()
        backend.screen.windows?[2].nativeFullscreen = true
        backend.screen.windows?[2].nativeMonitor = 1
        try engine.refresh()
        let otherFull = try XCTUnwrap(engine.map.spaces.first { $0.nativeWindow?.id == 3 })
        let before = engine.map.spaces, undoCount = engine.map.undo.count
        for target in [external.id,otherFull.id] {
            XCTAssertThrowsError(try engine.moveWindow(XCTUnwrap(full.nativeWindow),to:target))
            XCTAssertEqual(engine.map.spaces,before)
            XCTAssertEqual(engine.map.undo.count,undoCount)
            XCTAssertNil(engine.map.pending)
        }
    }

    func testFullscreenCardRejectsAnotherPhysicalDisplayAndOccupiedPlus() throws {
        let full = try enterFullscreen()
        let empty = try engine.createSpace(nearID:chat.id,displayID:laptop.id)
        let before = engine.map.spaces, homes = backend.screen.windowHomes
        XCTAssertThrowsError(try engine.moveWindow(XCTUnwrap(full.nativeWindow),to:empty))
        XCTAssertThrowsError(try engine.createSpace(nearID:chat.id,displayID:laptop.id,moving:full.nativeWindow))
        XCTAssertThrowsError(try engine.createSpace(nearID:full.id,displayID:ultra.id,row:full.row,column:full.column,moving:full.nativeWindow))
        XCTAssertEqual(engine.map.spaces,before)
        XCTAssertEqual(backend.screen.windowHomes,homes)
    }

    func testFullscreenCardRejectsDeferredWindowHomeInApparentlyEmptyTarget() throws {
        let full = try enterFullscreen()
        let emptyID = try engine.createSpace(nearID:full.id,displayID:ultra.id)
        let empty = try XCTUnwrap(engine.map.spaces.first { $0.id == emptyID })
        backend.screen.windowHomes?.append(WindowHome(id:99,pid:99,boot:"test",workspace:empty.workspace,floating:false))
        let before = engine.map.spaces
        XCTAssertThrowsError(try engine.moveWindow(XCTUnwrap(full.nativeWindow),to:emptyID))
        XCTAssertEqual(engine.map.spaces,before)
    }

    func testFullscreenExitAfterCardMoveKeepsNewPositionAndOtherAppsInTheirHome() throws {
        let full = try enterFullscreen()
        let id = try engine.createSpace(nearID:full.id,displayID:ultra.id,row:12,column:15,moving:full.nativeWindow)
        let destination = try XCTUnwrap(engine.map.spaces.first { $0.id == id })
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.nativeVisible = [:]
        try settle()
        let normal = try XCTUnwrap(engine.map.spaces.first { $0.id == id })
        XCTAssertNil(normal.nativeWindow)
        XCTAssertEqual(normal.rect,destination.rect)
        XCTAssertEqual(try backend.windows(workspace:normal.workspace),[1])
        XCTAssertEqual(try backend.windows(workspace:external.workspace),[2])
        XCTAssertTrue(engine.map.fullscreens.isEmpty)
    }

    func testFullscreenOnlyWindowMovesAndStaysThereOnExit() throws {
        let full = try enterFullscreen(onlyWindow:true)
        XCTAssertEqual(full.id,external.id)
        let empty = try engine.createSpace(nearID:full.id,displayID:ultra.id)
        let rect = try XCTUnwrap(engine.map.spaces.first { $0.id == empty }?.rect)
        try engine.moveWindow(XCTUnwrap(full.nativeWindow),to:empty)
        backend.screen.windows?[0].nativeFullscreen = false
        backend.screen.nativeVisible = [:]
        try settle()
        XCTAssertEqual(engine.map.spaces.first { $0.id == full.id }?.rect,rect)
        XCTAssertEqual(backend.screen.windows?.first?.workspace,external.workspace)
        XCTAssertNil(engine.map.spaces.first { $0.id == full.id }?.nativeWindow)
    }

    func testFullscreenCardMoveOnFoldedBoardKeepsOtherProjectedPositionsAndUndo() throws {
        let full = try enterFullscreen()
        backend.screen.windows?[0].nativeMonitor = 1
        backend.screen.nativeVisible = [1:1]
        try unplug()
        let before = engine.map.spaces
        let projected = engine.map.projectedSpaces(combined:true).filter { !$0.isDormant }
        let destination = SpaceRect(row:12,column:15)
        let id = try engine.createSpace(nearID:full.id,displayID:laptop.id,row:destination.row,column:destination.column,moving:full.nativeWindow)
        XCTAssertEqual(engine.map.projectedSpaces(combined:true).first { $0.id == id }?.rect,destination)
        for space in projected where space.id != id {
            XCTAssertEqual(engine.map.projectedSpaces(combined:true).first { $0.id == space.id }?.rect,space.rect)
        }
        try engine.refresh()
        try engine.undo()
        XCTAssertEqual(engine.map.spaces,before)
    }
}
