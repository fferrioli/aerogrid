import AppKit
import GridCore
import XCTest
@testable import AeroGrid

@MainActor final class FullscreenDropSurfaceTests: XCTestCase {
    func testFullscreenDropsAcceptOnlyEmptySpacesAndVacanciesOnTheirPhysicalDisplay() throws {
        let config = Configuration(backendPath:"/usr/bin/false")
        let laptop = Display(id:"laptop",monitor:1,name:"MacBook",builtin:true,width:1710,height:1073)
        let external = Display(id:"external",monitor:2,name:"External",builtin:false,width:5120,height:1410)
        let home = config.grids[1].cells[4], occupied = config.grids[1].cells[5]
        let empty = config.grids[1].cells[0], otherDisplay = config.grids[0].cells[0]
        let fullscreen = WindowInfo(id:1,workspace:home.workspace,nativeFullscreen:true,nativeMonitor:2)
        let normal = WindowInfo(id:2,workspace:occupied.workspace)
        var desktop = Desktop(displays:[laptop,external],visible:[1:otherDisplay.workspace,2:occupied.workspace],focusedMonitor:2)
        desktop.windows = [fullscreen,normal]
        let model = try AppModel(preview:desktop,previewConfiguration:config)
        defer { model.stop(); try? FileManager.default.removeItem(at:model.directory) }
        // Reserve an explicit empty destination so it appears on the board.
        let emptyIndex = try XCTUnwrap(model.state.dynamicMap?.spaces.firstIndex { $0.id == empty.id })
        model.state.dynamicMap?.spaces[emptyIndex].dormant = false
        model.state.dynamicMap?.spaces[emptyIndex].userCreated = true

        let surface = WindowDropSurfaceView()
        surface.model = model
        surface.spaceID = empty.id
        XCTAssertTrue(surface.accepts(fullscreen.identity))
        surface.group = [normal.id]
        XCTAssertFalse(surface.accepts(fullscreen.identity),"Fullscreen must not enter split or stack targets")
        surface.group = []
        surface.spaceID = occupied.id
        XCTAssertFalse(surface.accepts(fullscreen.identity))
        surface.spaceID = otherDisplay.id
        XCTAssertFalse(surface.accepts(fullscreen.identity))
        surface.spaceID = nil
        surface.displayID = external.id
        XCTAssertTrue(surface.accepts(fullscreen.identity))
        surface.displayID = laptop.id
        XCTAssertFalse(surface.accepts(fullscreen.identity))
        surface.displayID = nil
        XCTAssertFalse(surface.accepts(fullscreen.identity))

        let fullIndex = try XCTUnwrap(model.state.dynamicMap?.spaces.firstIndex { $0.id == empty.id })
        model.state.dynamicMap?.spaces[fullIndex].nativeWindow = fullscreen.identity
        surface.spaceID = empty.id
        XCTAssertFalse(surface.accepts(fullscreen.identity))
        XCTAssertFalse(surface.accepts(normal.identity),"Normal windows must not enter a fullscreen destination")
        var reused = fullscreen.identity
        reused.pid += 1
        XCTAssertFalse(surface.accepts(reused))
    }
}
