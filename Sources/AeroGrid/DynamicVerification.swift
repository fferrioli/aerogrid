import Foundation
import GridCore

/// Integration checks move only disposable fixture windows. The outer Python harness restores the desktop.
enum DynamicVerification {
    static func run(output: URL, nativeChecks: Bool = true) throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/aerogrid-aerospace").path
        let real = AeroSpaceBackend(path: path)
        let desktop = try real.desktop()
        guard let external = desktop.displays.first(where: { !$0.builtin }), let laptop = desktop.displays.first(where: \.builtin) else { throw GridError.unavailable("Connect both displays for live dynamic checks") }
        let fixtures = (desktop.windows ?? []).filter { $0.title.hasPrefix("AeroGrid Verification ") }.sorted { $0.title < $1.title }
        guard fixtures.count == 3 else { throw GridError.invalid("Start exactly three disposable fixture windows") }
        let adapter = FixtureBackend(real: real, ids: Set(fixtures.map(\.id)))
        var config = Configuration(backendPath: path)
        let source = Cell(id: "verification-source", row: 0, column: 0, name: "Verification", workspace: "grid-dynamic-verification")
        let empty = Cell(id: "verification-laptop", row: 0, column: 0, name: "Laptop verification", workspace: "grid-dynamic-verification-laptop")
        config.grids = [GridCore.Grid(id: "verification-laptop-grid", name: "Laptop", displayRole: "builtin", cells: [empty]), GridCore.Grid(id: "verification-external-grid", name: "External", displayRole: "external", cells: [source])]
        for window in fixtures { try real.move(window: window.id, workspace: source.workspace) }
        let stack = LayoutNode.root(fixtures.dropFirst().map { LayoutNode(id: $0.id, pid: $0.pid) }, layout: "accordion")
        let original = LayoutSnapshot(boot: fixtures[0].boot, tree: .root([LayoutNode(id: fixtures[0].id, pid: fixtures[0].pid, weight: 2), stack]), focus: fixtures[0].id)
        try real.restore(workspace: source.workspace, snapshot: original.json())
        try real.activateTarget(workspace: source.workspace, monitor: external.monitor, window: nil)
        try real.activateTarget(workspace: empty.workspace, monitor: laptop.monitor, window: nil)
        let engine = try DynamicEngine(configuration: config, backend: adapter)
        try engine.refresh()
        var passed: [String] = []
        func record(_ message: String) throws {
            passed.append(message)
            try passed.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
        }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw GridError.unavailable(message) }; try record(message) }
        func settleNative(_ active: Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            var stable = 0
            while Date() < deadline {
                let actual = try real.desktop()
                let members = actual.windows?.filter { adapter.ids.contains($0.id) } ?? []
                let window = members.first { $0.id == fixtures[0].id }
                let visible = actual.nativeVisible?[external.monitor] == fixtures[0].id
                if members.count == 3, window?.nativeFullscreen == active, visible == active { stable += 1 }
                else { stable = 0 }
                if stable >= 3 { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw GridError.unavailable("Fixture native transition did not settle")
        }
        let spatialBefore = try LayoutSnapshot(json:real.snapshot(workspace:source.workspace))
        let sourceFrame = engine.map.spaces.first { $0.id == source.id }!.rect
        try engine.setSpaceRect(source.id,rect:SpaceRect(row:sourceFrame.row,column:sourceFrame.column,width:2,height:2))
        try require(try LayoutSnapshot(json:real.snapshot(workspace:source.workspace)).tree == spatialBefore.tree,"PASS: resizing the map footprint leaves the real arrangement unchanged")
        try engine.undo()
        try require(engine.map.spaces.first { $0.id == source.id }?.rect == sourceFrame,"PASS: footprint Undo restores the original geometry")
        try record("Checking local placement with current fixture owners")
        do { try engine.placeWindow(fixtures[0].identity,in:source.id,group:Set(fixtures.dropFirst().map(\.id)),placement:.top) }
        catch {
            try record("Placement failure: \(error.localizedDescription)")
            try record("Fixture observation: \(String(decoding:try JSONEncoder().encode(adapter.desktop()),as:UTF8.self))")
            try record("Source tree: \(try real.snapshot(workspace:source.workspace))")
            throw error
        }
        let placed = try LayoutSnapshot(json:real.snapshot(workspace:source.workspace))
        try require(placed.tree.orientation == "v" && Set(placed.tree.ids) == Set(fixtures.map(\.id)),"PASS: local edge placement restores a real nested layout")
        try engine.undo()
        try require(try LayoutSnapshot(json:real.snapshot(workspace:source.workspace)).tree == spatialBefore.tree,"PASS: local placement Undo restores the exact previous tree")
        if nativeChecks {
        _ = try real.run(["macos-native-fullscreen", "--window-id", String(fixtures[0].id)])
        Thread.sleep(forTimeInterval: 1.5)
        try settleNative(true)
        try engine.refresh()
        guard let fullscreen = engine.map.spaces.first(where: { $0.nativeWindow?.id == fixtures[0].id }) else { throw GridError.unavailable("Fullscreen virtual cell wasn't discovered") }
        try record("Fullscreen discovered; checking normal target on \(external.id)")
        try engine.jump(cellID: source.id, displayID: external.id)
        try require(try real.desktop().nativeVisible?[external.monitor] == nil, "PASS: normal windows remain reachable beside native fullscreen")
        try record("Checking exact native target")
        try engine.jump(cellID: fullscreen.id, displayID: external.id)
        try require(try real.desktop().nativeVisible?[external.monitor] == fixtures[0].id, "PASS: the exact fullscreen window remains reachable")
        _ = try real.run(["macos-native-fullscreen", "--window-id", String(fixtures[0].id)])
        Thread.sleep(forTimeInterval: 1.5)
        try settleNative(false)
        try engine.refresh()
        try require(engine.map.fullscreens.isEmpty, "PASS: fullscreen exit removes its temporary destination")
        try record("Layout after fullscreen: \(try real.snapshot(workspace: source.workspace))")
        } else { try record("SKIP: native switching, previously rejected by macOS; not certified by this run") }
        adapter.folded = true
        try engine.refresh()
        try record("Folded families: \(String(decoding: try JSONEncoder().encode(engine.map.families), as: UTF8.self))")
        guard let family = engine.map.families.first, let child = engine.map.spaces.first(where: { $0.sourceID == source.id }) else { throw GridError.unavailable("Parallel groups weren't split") }
        try require(family.childIDs.count == 2, "PASS: simulated undock separates visible blocks")
        let compact = try LayoutSnapshot(json: real.snapshot(workspace: child.workspace))
        try require(compact.tree.layout == "accordion" && Set(compact.tree.ids) == Set(fixtures.dropFirst().map(\.id)), "PASS: the nested stack remains intact")
        try engine.jump(cellID: source.id, displayID: laptop.id)
        try engine.navigate(.right, scope: .active, displayID: laptop.id)
        try require(engine.map.cursors[laptop.id] == child.id, "PASS: unmodified navigation reaches the next occupied derived cell")
        adapter.folded = false
        try engine.refresh()
        try require(engine.map.families.isEmpty && Set(try real.windows(workspace: source.workspace)) == Set(fixtures.map(\.id)), "PASS: simulated reconnect reunites the original group")
        adapter.folded = true
        try engine.refresh()
        try require(engine.map.spaces.contains { $0.id == child.id }, "PASS: another simulated undock reuses the derived identity")
        try engine.moveSpace(child.id, to: empty.id)
        adapter.folded = false
        try engine.refresh()
        try require(engine.map.families.first?.manuallyEdited == true, "PASS: simulated reconnect preserves a manually moved family")
        let preview = try engine.makeReunitePreview(sourceID: source.id)
        try engine.reunite(sourceID: source.id, expectedOwners: Set(preview.windows.map(\.identity)))
        try require(engine.map.families.isEmpty, "PASS: explicit reunion restores the original group after manual editing")
        try engine.undo()
        try require(!engine.map.families.isEmpty, "PASS: reunion Undo restores the separated family")
        try engine.reunite(sourceID: source.id)
        adapter.folded = true
        try engine.refresh()
        try engine.reunite(sourceID: source.id)
        try engine.refresh()
        try require(engine.map.families.isEmpty, "PASS: explicit reunion stays joined while still simulated-undocked")
        try engine.undo()
        try require(!engine.map.families.isEmpty, "PASS: undocked reunion Undo restores the separated blocks")
        adapter.folded = false
        try engine.refresh()
        let before = try LayoutSnapshot(json: real.snapshot(workspace: source.workspace))
        try engine.moveSpace(source.id, to: empty.id)
        try engine.undo()
        let after = try LayoutSnapshot(json: real.snapshot(workspace: source.workspace))
        try require(before.tree == after.tree, "PASS: moving a whole cell and undo preserve its arrangement")
        try passed.joined(separator: "\n").appending("\nNOTE: topology folding is simulated; this does not certify physical dock/undock.\n").write(to: output, atomically: true, encoding: .utf8)
    }
}
private final class FixtureBackend: Backend {
    let real: AeroSpaceBackend
    let ids: Set<UInt32>
    var folded = false
    init(real: AeroSpaceBackend, ids: Set<UInt32>) { self.real = real; self.ids = ids }
    func desktop() throws -> Desktop {
        var desktop = try real.desktop()
        desktop.windows = desktop.windows?.filter { ids.contains($0.id) }
        desktop.windowHomes = desktop.windowHomes?.filter { ids.contains($0.id) }
        if folded {
            desktop.displays = desktop.displays.filter(\.builtin)
            let monitors = Set(desktop.displays.map(\.monitor))
            desktop.visible = desktop.visible.filter { monitors.contains($0.key) }
            desktop.nativeVisible = desktop.nativeVisible?.filter { monitors.contains($0.key) }
        }
        return desktop
    }
    func validate(workspace: String, monitor: Int) throws { try real.validate(workspace: workspace, monitor: monitor) }
    func place(workspace: String, monitor: Int) throws { try real.place(workspace: workspace, monitor: monitor) }
    func activate(workspace: String) throws { try real.activate(workspace: workspace) }
    func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws { try real.validateTarget(workspace: workspace, monitor: monitor, window: window) }
    func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws { try real.activateTarget(workspace: workspace, monitor: monitor, window: window) }
    func focus(monitor: Int, window: UInt32?) throws { try real.focus(monitor: monitor, window: window) }
    func focus(window: UInt32) throws { try real.focus(window: window) }
    func windows(workspace: String) throws -> [UInt32] { try real.windows(workspace: workspace).filter(ids.contains) }
    func move(window: UInt32, workspace: String) throws { guard ids.contains(window) else { throw GridError.invalid("Not a fixture") }; try real.move(window: window, workspace: workspace) }
    func moveVerified(window: WindowIdentity, workspace: String) throws { guard ids.contains(window.id) else { throw GridError.invalid("Not a fixture") }; try real.moveVerified(window: window, workspace: workspace) }
    func snapshot(workspace: String) throws -> String { try real.snapshot(workspace: workspace) }
    func restore(workspace: String, snapshot: String) throws { try real.restore(workspace: workspace, snapshot: snapshot) }
    func layout(workspace: String, profile: String) throws { try real.layout(workspace: workspace, profile: profile) }
    func recoverWindowHomes(_ homes: [WindowHome]) throws { try real.recoverWindowHomes(homes.filter { ids.contains($0.id) }) }
}
