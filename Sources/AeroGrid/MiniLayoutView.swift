import AppKit
import SwiftUI
import GridCore

struct MiniLayoutView: View {
    let snapshot: LayoutSnapshot
    let windows: [WindowInfo]
    var model: AppModel? = nil
    var spaceID: String? = nil
    var onOpen: ((WindowInfo) -> Void)? = nil
    @State private var preview: LayoutSnapshot?
    @State private var previewLabel = ""
    private var owners: Set<WindowIdentity> { Set(windows.map(\.identity)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let tree = snapshot.tree.retaining(owners, boot: snapshot.boot) {
                    node(tree, size: geometry.size, depth: 0)
                } else {
                    Text(windows.isEmpty ? "Arrastrá una app acá" : "Flotantes")
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(snapshot.floating.enumerated()), id: \.offset) { _, frame in
                    if let window = windows.first(where: { $0.id == frame.id && $0.pid == frame.pid }) {
                        windowTile(window, size: CGSize(width: max(28,geometry.size.width * frame.width), height: max(24,geometry.size.height * frame.height)))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .offset(x: geometry.size.width * min(0.8,max(0,frame.x)), y: geometry.size.height * min(0.8,max(0,frame.y)))
                    }
                }
                if let preview {
                    MiniLayoutView(snapshot: preview, windows: windows + incomingWindows)
                        .background(.regularMaterial).overlay(alignment: .bottom) {
                            Text(previewLabel).font(.caption2.weight(.medium)).padding(4).background(.regularMaterial, in: Capsule())
                        }.allowsHitTesting(false)
                }
            }.clipped()
        }
    }
    private var incomingWindows: [WindowInfo] {
        guard let incoming = model?.draggedWindow else { return [] }
        return (model?.desktop?.windows ?? []).filter { $0.identity == incoming && !owners.contains(incoming) }
    }
    private func node(_ value: LayoutNode, size: CGSize, depth: Int) -> AnyView {
        if let id = value.id, let window = windows.first(where: { $0.id == id && $0.pid == value.pid && $0.boot == snapshot.boot }) {
            return AnyView(dropTarget(windowTile(window,size:size), group:Set([id])))
        }
        let children = value.children ?? []
        if value.layout == "accordion" || depth >= 12 {
            let members = windows.filter { value.ids.contains($0.id) }
            return AnyView(dropTarget(VStack(spacing: 3) {
                HStack(spacing: 3) { Image(systemName:"rectangle.on.rectangle"); Text("\(members.count)") }.font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(members) { window in windowTile(window,size:CGSize(width:max(30,min(55,size.width / 2)),height:max(24,size.height - 27))) }
                    }
                }.scrollIndicators(.hidden)
            }.padding(3).frame(width:max(0,size.width),height:max(0,size.height)).background(.quaternary,in:RoundedRectangle(cornerRadius:5)), group:Set(value.ids)))
        }
        guard !children.isEmpty else { return AnyView(Color.clear) }
        let vertical = value.orientation == "v"
        let total = children.reduce(0) { $0 + max(0.001,$1.weight) }
        let length = max(0,(vertical ? size.height : size.width) - CGFloat(children.count - 1) * 3)
        let panes = ForEach(Array(children.enumerated()),id: \.offset) { _, child in
            let extent = length * CGFloat(max(0.001,child.weight) / total)
            node(child,size:CGSize(width:vertical ? size.width : extent,height:vertical ? extent : size.height),depth:depth+1)
        }
        if vertical { return AnyView(VStack(spacing:3) { panes }) }
        return AnyView(HStack(spacing:3) { panes })
    }
    @ViewBuilder private func windowTile(_ window: WindowInfo, size: CGSize) -> some View {
        let image = ApplicationIcon.image(window)
        let tile = VStack(spacing:3) {
            Image(nsImage:image).resizable().scaledToFit().frame(width:min(28,max(12,size.width-8)),height:min(28,max(12,size.height-8)))
            if size.width > 62 && size.height > 53 { Text(window.appName).font(.system(size:10)).lineLimit(1) }
        }.frame(width:max(0,size.width),height:max(0,size.height))
            .background(Color.accentColor.opacity(0.09),in:RoundedRectangle(cornerRadius:5))
            .contentShape(Rectangle()).help("\(window.appName) · \(window.title)")
            .onTapGesture { onOpen?(window) }
            .accessibilityLabel("\(window.appName), \(window.title)")
        if let model, !window.nativeFullscreen {
            tile.overlay {
                WindowDragSource(model:model,window:window,spaceID:spaceID,open:{ onOpen?(window) })
            }.opacity(model.draggedWindow == window.identity ? 0.45 : 1)
        } else { tile }
    }
    private func dropTarget<V:View>(_ view: V, group: Set<UInt32>) -> some View {
        view.overlay {
            if let model, let spaceID {
                WindowDropSurface(model:model,priority:2,spaceID:spaceID,group:group,acceptsFloating:false,hover:{ placement in
                    guard let placement, let incoming = model.draggedWindow,
                          let result = model.placementPreview(incoming,in:spaceID,group:group,placement:placement) else {
                        preview = nil; return
                    }
                    preview = result; previewLabel = placement.label
                },drop:{ window,placement in model.placeWindow(window,in:spaceID,group:group,placement:placement) })
            }
        }
    }
}

private enum ApplicationIcon {
    static let cache = NSCache<NSString,NSImage>()
    static func image(_ window:WindowInfo) -> NSImage {
        let key = "\(window.bundleID):\(window.pid)" as NSString
        if let image = cache.object(forKey:key) { return image }
        let running = NSRunningApplication(processIdentifier:window.pid)?.icon
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier:window.bundleID).map { NSWorkspace.shared.icon(forFile:$0.path) }
        let image = running ?? installed ?? NSImage(systemSymbolName:"macwindow",accessibilityDescription:window.appName)!
        cache.setObject(image,forKey:key)
        return image
    }
}
