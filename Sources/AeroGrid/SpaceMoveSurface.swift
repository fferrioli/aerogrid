import AppKit
import SwiftUI

/// In-panel space movement uses the same direct mouse lifecycle as resizing.
/// App cards use their own source/target surfaces in WindowDragSurface.
struct SpaceMoveSurface: NSViewRepresentable {
    let model: AppModel
    let headers: [(String,CGRect)]
    let open: (String) -> Void
    let move: (CGPoint?,Bool) -> Void
    func makeNSView(context: Context) -> SpaceMoveSurfaceView { SpaceMoveSurfaceView() }
    func updateNSView(_ view: SpaceMoveSurfaceView, context: Context) {
        view.model = model; view.headers = headers; view.open = open; view.move = move
    }
}

final class SpaceMoveSurfaceView: NSView {
    private static let surfaces = NSHashTable<SpaceMoveSurfaceView>.weakObjects()
    weak var model: AppModel?
    var headers: [(String,CGRect)] = []
    var open: ((String) -> Void)?
    var move: ((CGPoint?,Bool) -> Void)?
    private var sourceID: String?
    private var start = CGPoint.zero
    private var dragging = false
    private weak var destination: SpaceMoveSurfaceView?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finish(); sourceID = nil }
        else { Self.surfaces.add(self) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point,from:superview)
        return headers.contains(where: { $0.1.contains(local) }) ? self : nil
    }
    override func resetCursorRects() {
        for (_,rect) in headers { addCursorRect(rect,cursor:.openHand) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        sourceID = headers.first { $0.1.contains(point) }?.0
        start = point
        window?.makeFirstResponder(self)
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDragged(with event: NSEvent) {
        guard let sourceID else { return }
        let point = convert(event.locationInWindow,from:nil)
        if !dragging {
            guard hypot(point.x-start.x,point.y-start.y) >= 3 else { return }
            dragging = true; model?.beginDrag(space:sourceID); NSCursor.closedHand.push()
        }
        autoscroll(with:event)
        updateDestination(event,ended:false)
    }
    private func updateDestination(_ event:NSEvent,ended:Bool) {
        let target = Self.surfaces.allObjects.first { view in
            view.window === window && view.bounds.contains(view.convert(event.locationInWindow,from:nil))
        }
        if destination !== target { destination?.move?(nil,false); destination = target }
        if let target { target.move?(target.convert(event.locationInWindow,from:nil),ended) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { updateDestination(event,ended:true); finish() }
        else if let sourceID { open?(sourceID) }
        sourceID = nil
    }
    override func cancelOperation(_ sender: Any?) { finish(); sourceID = nil }
    private func finish() {
        destination?.move?(nil,false); destination = nil
        if dragging { NSCursor.pop(); model?.endDrag() }
        dragging = false
    }
}
