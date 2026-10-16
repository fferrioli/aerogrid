import AppKit
import GridCore

/// Exercises the real AppKit panel lifecycle with fake windows/backend, without an input tap.
enum PanelVerification {
    static func run(output:URL) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { throw GridError.stale }
        let display = Display(id:CFUUIDCreateString(nil,uuid) as String,monitor:1,name:"Verification",builtin:true,width:screen.frame.width,height:screen.frame.height)
        var config = Configuration(backendPath:"/usr/bin/false"); config.invert = true
        let grid = config.grids[0]
        var desktop = Desktop(displays:[display],visible:[1:grid.cells[4].workspace],focusedMonitor:1)
        desktop.windows = [4,5,8].enumerated().map { index,cell in WindowInfo(id:UInt32(index+1),workspace:grid.cells[cell].workspace,appName:"Verification \(index+1)") }
        desktop.nativeVisible = [:]
        let model = try AppModel(preview:desktop,previewConfiguration:config)
        defer { model.handleContact(.cancelled); try? FileManager.default.removeItem(at:model.directory) }
        func spin(_ seconds:Double = 0.06) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
        func panels() -> [NSWindow] { NSApp.windows.filter { $0.title == "AeroGrid · Navegación" && $0.isVisible } }
        func require(_ value:Bool,_ message:String) throws { if !value { throw GridError.invalid(message) } }
        func step(_ direction:Direction) { model.handleContact(.step(RecognizedSwipe(direction:direction,fingers:3,modifiers:0,displayID:display.id))) }
        step(.right); spin()
        let first = panels().first?.windowNumber
        try require(panels().count == 1,"First movement did not show one panel")
        step(.down); spin()
        try require(panels().count == 1 && panels().first?.windowNumber == first,"Continued movement recreated the panel")
        model.handleContact(.ended); spin(0.25)
        try require(panels().isEmpty,"Panel reappeared after the final switch")
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[8].id,"Final selection was not committed")
        model.focusWindow(WindowIdentity(id:1,pid:1,boot:"test")); spin(0.2)
        try require(panels().isEmpty,"Focus restoration opened a navigation panel")
        step(.left); model.handleContact(.ended); spin(0.25)
        try require(panels().isEmpty,"Quick swipe left a delayed/orphaned panel")
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[4].id,"Quick swipe did not reach its neighbor")
        step(.right); model.handleContact(.ended)
        step(.down); model.handleContact(.ended)
        spin(0.5)
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[8].id,"Second quick gesture was dropped or resolved against the old origin")
        try require(panels().isEmpty,"Queued quick gestures left an orphaned panel")
        // A third interrupted contact must not erase the second, completed queued gesture.
        step(.left); model.handleContact(.ended); spin(0.25)
        step(.right); model.handleContact(.ended)
        step(.down); model.handleContact(.ended)
        step(.left); model.handleContact(.cancelled)
        spin(0.5)
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[8].id,"Cancellation discarded a complete queued gesture")
        // Exercise normalized packets with actual inversion through selection, lift and commit.
        var input = ContactFrameRecognizer()
        func packet(_ x:Double,_ phases:[TouchPhase],_ time:Double) {
            let contacts = phases.enumerated().map { index,phase in TouchContact(sample:TouchSample(id:String(index),x:x,y:0.5),phase:phase) }
            for event in input.feed(contacts,modifiers:0,displayID:display.id,threshold:config.threshold,invert:config.invert,timestamp:time) { model.handleContact(event) }
        }
        packet(0.2,[.began,.began,.began],0)
        packet(0.28,[.moved,.moved,.moved],0.02) // Inverted: left, from 8 to 4.
        spin()
        try require(panels().count == 1,"Normalized inverted input did not preview")
        packet(0.29,[.ended,.moved,.moved],0.04)
        packet(0.29,[.moved,.moved,.moved],0.05) // Stale snapshot after explicit lift.
        packet(0.29,[.ended,.ended,.ended],0.06)
        spin(0.25)
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[4].id,"Interleaved inverted packets failed to commit their preview")
        try require(panels().isEmpty,"Normalized packet commit left a panel")
        packet(0.3,[.began,.began,.began],1)
        packet(0.22,[.moved,.moved,.moved],1.02) // Inverted right: 4 to 5.
        packet(0.22,[.ended,.ended,.moved],1.04)
        _ = input.feed([],ended:true,modifiers:0,displayID:display.id,threshold:config.threshold,invert:config.invert,timestamp:1.05)
        for event in input.advance(timestamp:1.2) { model.handleContact(event) }
        spin(0.25)
        try require(model.state.dynamicMap?.cursors[display.id] == grid.cells[5].id,"Corroborated missing-lift settlement failed to commit")
        try require(panels().isEmpty,"Settled release left a panel")
        // A held contact must cross several same-axis neighbors while still previewing,
        // rather than switching intermediate desktops or requiring a stationary pause.
        let lineCells = Array(grid.cells.prefix(6))
        var lineDesktop = Desktop(displays:[display],visible:[1:lineCells[0].workspace],focusedMonitor:1)
        lineDesktop.nativeVisible = [:]
        lineDesktop.windows = lineCells.enumerated().map { index,cell in WindowInfo(id:UInt32(index+20),workspace:cell.workspace,appName:"Held \(index)") }
        var lineMap = SpaceMap(configuration:config)
        try lineMap.migrateSpatial(configuration:config,desktop:lineDesktop)
        for (index,cell) in lineCells.enumerated() {
            if let position = lineMap.spaces.firstIndex(where: { $0.id == cell.id }) { lineMap.spaces[position].rect = SpaceRect(row:0,column:index) }
        }
        let heldModel = try AppModel(preview:lineDesktop,previewConfiguration:config,previewMap:lineMap)
        defer { heldModel.handleContact(.cancelled); try? FileManager.default.removeItem(at:heldModel.directory) }
        var heldInput = ContactFrameRecognizer()
        for frame in 0...90 {
            let x = 0.9-Double(frame)*0.008
            let contacts = (0..<3).map { TouchContact(sample:TouchSample(id:String($0),x:x,y:0.5),phase:frame == 0 ? .began : .moved) }
            for event in heldInput.feed(contacts,modifiers:0,displayID:display.id,threshold:config.threshold,invert:true,timestamp:Double(frame)/60) { heldModel.handleContact(event) }
        }
        spin()
        guard let heldTarget = heldModel.gestureSelection?.selected[display.id]?.spaceID else { throw GridError.invalid("Held contact has no preview") }
        try require(lineCells.dropFirst(3).contains { $0.id == heldTarget },"Held motion did not cross three neighbors")
        try require(heldModel.desktop?.visible[1] == lineCells[0].workspace,"Held exploration activated an intermediate desktop")
        let finalContacts = (0..<3).map { TouchContact(sample:TouchSample(id:String($0),x:0.18,y:0.5),phase:.ended) }
        for event in heldInput.feed(finalContacts,modifiers:0,displayID:display.id,threshold:config.threshold,invert:true,timestamp:1.6) { heldModel.handleContact(event) }
        spin(0.25)
        try require(heldModel.state.dynamicMap?.cursors[display.id] == heldTarget,"Held destination was not committed on lift")
        try require(panels().isEmpty,"Held exploration left an orphaned panel")
        let spacesBeforePause = model.spaces
        model.setPaused(true); spin(0.2)
        try require(model.paused && !model.pauseChanging,"Frontend did not acknowledge engine pause")
        let preferences = try JSONDecoder().decode(WindowManagerPreferences.self,from:Data(contentsOf:model.directory.appendingPathComponent("control.json")))
        try require(preferences.paused,"Pause preference was not persisted")
        model.createSpace(); spin(0.1)
        try require(model.spaces == spacesBeforePause,"Organization mutated the map while paused")
        var edited = model.configuration; edited.threshold = 0.04
        model.apply(edited); spin(0.2)
        try require(model.configuration.threshold == 0.04 && model.paused,"Settings failed while paused or resumed the engine")
        model.setPaused(false); spin(0.25)
        try require(!model.paused && !model.pauseChanging,"Frontend did not acknowledge engine resume")
        let queuedModel = try OrganizerSandbox.model()
        defer { try? FileManager.default.removeItem(at:queuedModel.directory) }
        let queuedCount = queuedModel.spaces.count
        for _ in 0..<9 { queuedModel.createSpace(displayID:"preview-ultra") }
        queuedModel.setPaused(true); spin(0.4)
        try require(queuedModel.paused && !queuedModel.pauseChanging,"A full action queue prevented pause")
        try require(queuedModel.spaces.count == queuedCount+1,"Queued organizations continued after pause was requested")
        let report:[String:Any] = ["pauseTakesPriorityOverQueuedOrganizations":true,"pauseResumeControlsEngine":true,"organizationBlockedWhilePaused":true,"settingsEditableWhilePaused":true,"pausePreferencePersisted":true,"onePanelWhileHeld":true,"sameWindowAcrossSteps":true,"noPanelAfterCommit":true,
            "noPanelAfterFocus":true,"noDelayedQuickSwipePanel":true,"consecutiveQuickGesturesCommitted":true,"cancelPreservesCompletedQueue":true,"normalizedInvertedPacketsCommitted":true,"corroboratedReleaseCommitted":true,"heldCrossesSeveralNeighbors":true,"heldCommitsOnlyOnLift":true,"usesRealAppKitPanels":true,"usesRealPhysicalGestures":false,"writesUserState":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }
}
