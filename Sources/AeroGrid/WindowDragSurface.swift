import AppKit
import SwiftUI
import GridCore

/// Registered independently of hover previews, so rendering cannot replace a drop target.
struct WindowDropSurface: NSViewRepresentable {
    let model: AppModel
    var priority = 0
    var spaceID: String?
    var group: Set<UInt32> = []
    var acceptsFloating = true
    var hover: ((GridCore.WindowPlacement?) -> Void)?
    let drop: (WindowIdentity,GridCore.WindowPlacement) -> Void
    func makeNSView(context:Context) -> WindowDropSurfaceView { WindowDropSurfaceView() }
    func updateNSView(_ view:WindowDropSurfaceView,context:Context) {
        view.model = model; view.priority = priority; view.spaceID = spaceID; view.group = group
        view.acceptsFloating = acceptsFloating; view.hover = hover; view.drop = drop
    }
}

final class WindowDropSurfaceView: NSView {
    private static let surfaces = NSHashTable<WindowDropSurfaceView>.weakObjects()
    weak var model: AppModel?
    var priority = 0
    var spaceID: String?
    var group: Set<UInt32> = []
    var acceptsFloating = true
    var hover: ((GridCore.WindowPlacement?) -> Void)?
    var drop: ((WindowIdentity,GridCore.WindowPlacement) -> Void)?
    private var placement: GridCore.WindowPlacement?
    override var isFlipped: Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.surfaces.add(self) } else { clear() }
    }
    static func target(at point:NSPoint,in window:NSWindow?,identity:WindowIdentity) -> WindowDropSurfaceView? {
        guard let window, let content = window.contentView,
              content.bounds.contains(content.convert(point,from:nil)) else { return nil }
        return surfaces.allObjects.filter { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor, !view.group.contains(identity.id),
                  let live = view.model?.desktop?.windows?.first(where: { $0.identity == identity }), !live.nativeFullscreen,
                  view.acceptsFloating || !live.floating else { return false }
            if view.group.isEmpty, let spaceID = view.spaceID,
               view.model?.spaces.first(where: { $0.id == spaceID })?.workspace == live.workspace { return false }
            let local = view.convert(point,from:nil)
            return view.bounds.contains(local) && view.visibleRect.contains(local)
        }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height
        }.first
    }
    func update(at point:NSPoint) -> GridCore.WindowPlacement {
        let local = convert(point,from:nil)
        let side = WindowDropGeometry.placement(x:local.x,y:local.y,width:bounds.width,height:bounds.height)
        if placement != side { placement = side; hover?(side) }
        return side
    }
    func clear() {
        guard placement != nil else { return }
        placement = nil; hover?(nil)
    }
}

struct WindowDragSource: NSViewRepresentable {
    let model: AppModel
    let window: WindowInfo
    let spaceID: String?
    let open: () -> Void
    func makeNSView(context:Context) -> WindowDragSourceView { WindowDragSourceView() }
    func updateNSView(_ view:WindowDragSourceView,context:Context) {
        view.model = model; view.owner = window; view.spaceID = spaceID; view.open = open
        view.toolTip = "\(window.appName) · \(window.title) · Arrastrá para mover esta ventana"
    }
}

final class WindowDragSourceView: NSView {
    weak var model: AppModel?
    var owner: WindowInfo?
    var spaceID: String?
    var open: (() -> Void)?
    private var start = CGPoint.zero
    private var identity: WindowIdentity?
    private var dragging = false
    private weak var destination: WindowDropSurfaceView?
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finish(); identity = nil }
    }
    override func mouseDown(with event:NSEvent) {
        identity = owner?.identity; start = event.locationInWindow
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let identity else { return }
        if !dragging {
            guard hypot(event.locationInWindow.x-start.x,event.locationInWindow.y-start.y) >= 3 else { return }
            dragging = true; model?.beginDrag(window:identity); NSCursor.closedHand.push()
        }
        autoscroll(with:event)
        updateDestination(event)
    }
    private func updateDestination(_ event:NSEvent) {
        guard let identity else { return }
        let target = WindowDropSurfaceView.target(at:event.locationInWindow,in:window,identity:identity)
        if destination !== target { destination?.clear(); destination = target }
        _ = target?.update(at:event.locationInWindow)
    }
    override func mouseUp(with event:NSEvent) {
        if dragging {
            updateDestination(event)
            if let identity, let destination {
                let placement = destination.update(at:event.locationInWindow)
                model?.recordOrganizationDrag("drop window=\(identity.id) placement=\(placement.rawValue) group=\(destination.group.sorted())")
                destination.drop?(identity,placement)
            }
            finish()
        } else { open?() }
        identity = nil
    }
    override func cancelOperation(_ sender:Any?) { finish(); identity = nil }
    private func finish() {
        let wasDragging = dragging; dragging = false
        let previous = destination; destination = nil; previous?.clear()
        if wasDragging { NSCursor.pop(); model?.endDrag() }
    }
    override func menu(for event:NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title,action) in [("Mover a otro espacio…",#selector(chooseDestination)),("Extraer a nuevo espacio",#selector(extract))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func chooseDestination() { model?.organizationWindowToMove = owner?.identity }
    @objc private func extract() {
        if let owner { model?.createSpace(near:spaceID,moving:owner.identity) }
    }
}
