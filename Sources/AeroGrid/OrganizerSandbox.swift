import AppKit
import SwiftUI
import GridCore

/// Isolated UI verification: no event tap, real backend, config, or user-state writes.
final class OrganizerSandboxBackend: Backend {
    var screen: Desktop
    var layouts: [String:LayoutSnapshot]
    init(_ desktop:Desktop,layouts:[String:LayoutSnapshot]) { screen = desktop; self.layouts = layouts }
    func desktop() throws -> Desktop { screen }
    func validate(workspace:String,monitor:Int) throws {}
    func place(workspace:String,monitor:Int) throws { screen.visible[monitor] = workspace }
    func activate(workspace:String) throws {}
    func focus(monitor:Int,window:UInt32?) throws { screen.focusedMonitor = monitor; screen.focusedWindow = window }
    func focus(window:UInt32) throws { screen.focusedWindow = window }
    func windows(workspace:String) throws -> [UInt32] { (screen.windows ?? []).filter { $0.workspace == workspace }.map(\.id) }
    func move(window:UInt32,workspace:String) throws {
        guard let index = screen.windows?.firstIndex(where: { $0.id == window }) else { throw GridError.stale }
        screen.windows?[index].workspace = workspace
        screen.windowHomes = screen.windows?.map { WindowHome(id:$0.id,pid:$0.pid,boot:$0.boot,workspace:$0.workspace,floating:$0.floating) }
    }
    func recoverWindowHomes(_ homes:[WindowHome]) throws { for home in homes { try move(window:home.id,workspace:home.workspace) } }
    func snapshot(workspace:String) throws -> String {
        let members = (screen.windows ?? []).filter { $0.workspace == workspace }
        var snapshot = layouts[workspace] ?? LayoutSnapshot(boot:"test",tree:.root([]))
        snapshot.tree = snapshot.tree.retaining(Set(members.map(\.identity)),boot:snapshot.boot) ?? .root([])
        for member in members where !member.floating && !snapshot.tree.ids.contains(member.id) { snapshot.tree.children?.append(LayoutNode(id:member.id,pid:member.pid)) }
        return try snapshot.json()
    }
    func restore(workspace:String,snapshot:String) throws { layouts[workspace] = try LayoutSnapshot(json:snapshot) }
    func layout(workspace:String,profile:String) throws {}
}

enum OrganizerSandbox {
    static func model() throws -> AppModel {
        let config = Configuration(backendPath:"/usr/bin/false")
        let external = Display(id:"preview-ultra",monitor:1,name:"Ultrawide",builtin:false,width:5120,height:1410)
        let builtin = Display(id:"preview-mac",monitor:2,name:"MacBook",builtin:true,width:1710,height:1073)
        var desktop = Desktop(displays:[external,builtin],visible:[1:config.grids[1].cells[2].workspace,2:config.grids[0].cells[4].workspace],focusedMonitor:1)
        let apps = [("Chat 2","com.apple.MobileSMS"),("Chat","com.apple.mail"),("Browser","com.apple.Safari"),("VS Code","com.microsoft.VSCode"),("IA","com.apple.finder"),("Terminal","com.apple.Terminal")]
        desktop.windows = apps.enumerated().map { index,item in
            var window = WindowInfo(id:UInt32(index+1),workspace:config.grids[1].cells[index].workspace,title:item.0,appName:item.0,bundleID:item.1)
            window.pid = NSRunningApplication.runningApplications(withBundleIdentifier:item.1).first?.processIdentifier ?? -1
            return window
        }
        desktop.windows?.append(WindowInfo(id:8,workspace:config.grids[1].cells[5].workspace,title:"Terminal 2",appName:"Terminal",bundleID:"com.apple.Terminal"))
        desktop.windows?.append(WindowInfo(id:9,workspace:config.grids[0].cells[4].workspace,title:"Notas",appName:"Notas",bundleID:"com.apple.Notes"))
        desktop.nativeVisible = [:]
        desktop.windowHomes = desktop.windows?.map { WindowHome(id:$0.id,pid:$0.pid,boot:$0.boot,workspace:$0.workspace,floating:$0.floating) }
        var map = SpaceMap(configuration:config)
        try map.migrateSpatial(configuration:config,desktop:desktop)
        let frames = [SpaceRect(row:0,column:0),SpaceRect(row:1,column:0),SpaceRect(row:0,column:1,height:2),SpaceRect(row:0,column:2),SpaceRect(row:1,column:2),SpaceRect(row:2,column:1,width:2)]
        for index in 0..<6 {
            let id = config.grids[1].cells[index].id
            if let position = map.spaces.firstIndex(where: { $0.id == id }) { map.spaces[position].name = apps[index].0; map.spaces[position].rect = frames[index] }
        }
        return try AppModel(preview:desktop,previewConfiguration:config,previewMap:map)
    }
    static func run() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = try model()
        let panel = OrganizerPanel(contentRect:NSRect(x:0,y:0,width:820,height:520),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title = "AeroGrid · Sandbox de organización"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.contentView = NSHostingView(rootView:OverviewView(model:model))
        model.overviewVisible = true
        let size = MapPresentation.panelSize(displays:Array((model.desktop?.displays ?? []).prefix(1)),model:model,editable:true)
        panel.setContentSize(size)
        model.resizeOverview = { size in
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x:panel.frame.midX-size.width/2,y:top-size.height,width:size.width,height:size.height),display:true)
        }
        panel.center(); panel.makeKeyAndOrderFront(nil)
        model.closeOverview = { _ in panel.orderOut(nil); app.terminate(nil) }
        panel.onCancel = { panel.orderOut(nil); app.terminate(nil) }
        withExtendedLifetime((model,panel)) { app.run() }
        try? FileManager.default.removeItem(at:model.directory)
    }
}

final class OrganizerSandboxManagement: WindowManagerControl {
    private var enabled = true
    func managementStatus() throws -> WindowManagerStatus { WindowManagerStatus(enabled:enabled,ready:true) }
    func setManagementEnabled(_ value:Bool) throws { enabled = value }
}
