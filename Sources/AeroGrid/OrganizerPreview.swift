import AppKit
import SwiftUI
import GridCore

/// Renders the production view without starting input, opening windows, or touching user state.
enum OrganizerPreview {
    static func render(to url: URL, merge: Bool = false) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = Configuration(backendPath: "/usr/bin/false")
        let display = Display(id: "preview", monitor: 1, name: "MacBook", builtin: true, width: 1710, height: 1073)
        var desktop = Desktop(displays: [display], visible: [1: config.grids[0].cells[4].workspace], focusedMonitor: 1)
        desktop.windows = [
            WindowInfo(id: 1, workspace: config.grids[0].cells[4].workspace, title: "AeroGrid — implementación del organizador", appName: "Editor"),
            WindowInfo(id: 2, workspace: config.grids[0].cells[4].workspace, title: "Una ventana con un título largo para verificar que se mantiene legible", appName: "Terminal"),
            WindowInfo(id: 3, workspace: config.grids[0].cells[3].workspace, title: "Conversaciones", appName: "Mensajes"),
            WindowInfo(id: 4, workspace: config.grids[1].cells[6].workspace, title: "Investigación", appName: "Navegador")
        ]
        // Match legacy workspace names so the preview uses exactly the same data path as the app.
        let model = try merge ? AppModel(preview:desktop,previewConfiguration:config) : OrganizerSandbox.model()
        defer { try? FileManager.default.removeItem(at: model.directory) }
        let content: AnyView
        if merge {
            let source = model.spaces.first { $0.workspace == config.grids[0].cells[4].workspace }!
            let target = model.spaces.first { $0.workspace == config.grids[0].cells[3].workspace }!
            let moving = model.windows(in: source), existing = model.windows(in: target)
            let sourceLayout = LayoutSnapshot(boot: "test", tree: .root(moving.enumerated().map { index, window in LayoutNode(id: window.id, pid: window.pid, weight: index == 0 ? 2 : 1) }))
            let targetLayout = LayoutSnapshot(boot: "test", tree: .root(existing.map { LayoutNode(id: $0.id, pid: $0.pid) }))
            let result = try targetLayout.merging(sourceLayout, sourceOwners: Set(moving.map(\.identity)), targetOwners: Set(existing.map(\.identity)), focus: moving.first?.id)
            let preview = MergePreview(sourceID: source.id, targetID: target.id, sourceName: "Desarrollo", targetName: "Chat", sourceWindows: moving, targetWindows: existing, sourceLayout: sourceLayout, targetLayout: targetLayout, result: result)
            content = AnyView(MergePreviewView(model: model, preview: preview))
        } else { content = AnyView(OverviewView(model:model)) }
        let view = NSHostingView(rootView: content)
        let size = merge ? CGSize(width:620,height:560) : MapPresentation.panelSize(displays:Array((model.desktop?.displays ?? []).prefix(1)),model:model,editable:true)
        let window = NSWindow(contentRect: NSRect(origin:.zero,size:size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin:.zero,size:size)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GridError.unavailable("Cannot render organizer") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GridError.unavailable("Cannot encode organizer preview") }
        try data.write(to: url, options: .atomic)
    }
}
