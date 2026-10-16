import AppKit
import SwiftUI
import GridCore

/// AppKit owns one stable border and its cursor rectangles throughout a drag.
struct ResizeBorder: NSViewRepresentable {
    let rect:SpaceRect
    let unit:CGSize
    let onResize:(SpaceRect,Bool)->Void
    func makeNSView(context:Context) -> ResizeBorderView { ResizeBorderView() }
    func updateNSView(_ view:ResizeBorderView,context:Context) {
        if !view.dragging { view.spaceRect = rect }
        view.unit = unit; view.onResize = onResize
    }
}

final class ResizeBorderView:NSView {
    var spaceRect = SpaceRect(row:0,column:0)
    var unit = CGSize(width:230,height:152)
    var onResize:((SpaceRect,Bool)->Void)?
    private(set) var dragging = false
    private var hovered = false
    private var tracking:NSTrackingArea?
    private var edge = 0
    private var start = NSPoint.zero
    private var original = SpaceRect(row:0,column:0)
    private var preview = SpaceRect(row:0,column:0)
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    private func regions() -> [NSRect] {
        let w = bounds.width, h = bounds.height, corner:CGFloat = 14, border:CGFloat = 8
        return [NSRect(x:0,y:corner,width:border,height:max(0,h-corner*2)),
            NSRect(x:w-border,y:corner,width:border,height:max(0,h-corner*2)),
            NSRect(x:corner,y:0,width:max(0,w-corner*2),height:border),
            NSRect(x:corner,y:h-border,width:max(0,w-corner*2),height:border),
            NSRect(x:0,y:0,width:corner,height:corner),NSRect(x:w-corner,y:0,width:corner,height:corner),
            NSRect(x:0,y:h-corner,width:corner,height:corner),NSRect(x:w-corner,y:h-corner,width:corner,height:corner)]
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let local = convert(point,from:superview)
        return regions().contains { $0.contains(local) } ? self : nil
    }
    override func resetCursorRects() {
        for (index,rect) in regions().enumerated() {
            let cursor:NSCursor
            if index < 2 { cursor = .resizeLeftRight }
            else if index < 4 { cursor = .resizeUpDown }
            else { cursor = ResizeCursor.diagonal(descending:index == 4 || index == 7) }
            addCursorRect(rect,cursor:cursor)
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        let active = hovered || dragging
        (active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).withAlphaComponent(active ? 0.8 : 0.3).setStroke()
        let w = bounds.width, h = bounds.height
        let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .round
        for (x,y,dx,dy) in [(CGFloat(4),CGFloat(4),CGFloat(1),CGFloat(1)),(w-4,4,-1,1),(4,h-4,1,-1),(w-4,h-4,-1,-1)] {
            path.move(to:NSPoint(x:x+dx*8,y:y)); path.line(to:NSPoint(x:x,y:y)); path.line(to:NSPoint(x:x,y:y+dy*8))
        }
        path.stroke()
    }
    override func mouseDown(with event:NSEvent) {
        guard let index = regions().firstIndex(where: { $0.contains(convert(event.locationInWindow,from:nil)) }) else { return }
        edge = index; start = event.locationInWindow; original = spaceRect; preview = original; dragging = true
        window?.makeFirstResponder(self); onResize?(original,false); needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard dragging else { return }
        let dx = Int(((event.locationInWindow.x-start.x)/unit.width).rounded())
        let dy = Int(((start.y-event.locationInWindow.y)/unit.height).rounded())
        var next = original
        if [0,4,6].contains(edge) { let delta = min(dx,next.width-1); next.column += delta; next.width -= delta }
        if [1,5,7].contains(edge) { next.width = max(1,next.width+dx) }
        if [2,4,5].contains(edge) { let delta = min(dy,next.height-1); next.row += delta; next.height -= delta }
        if [3,6,7].contains(edge) { next.height = max(1,next.height+dy) }
        guard next != preview else { return }
        preview = next; onResize?(next,false)
    }
    override func mouseUp(with event:NSEvent) {
        guard dragging else { return }
        mouseDragged(with:event); dragging = false; onResize?(preview,true); needsDisplay = true
        window?.invalidateCursorRects(for:self)
    }
    override func cancelOperation(_ sender:Any?) {
        guard dragging else { return }
        dragging = false; onResize?(original,true); needsDisplay = true; window?.invalidateCursorRects(for:self)
    }
}
