// Event-tap/NSTouch input adapted from MIT SwipeAeroSpace, pinned in UPSTREAM.md.
import Cocoa
import GridCore

final class GestureInput {
    var configuration: Configuration
    var onContact: ((ContactGestureEvent) -> Void)?
    var onSwipe: ((RecognizedSwipe) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onTrace: ((String) -> Void)?
    var onPacket: (([String:Any]) -> Void)?
    var target: (() -> String?)?
    var shouldSuppressScroll: (() -> Bool)?
    var enabled = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var settlementTimer:DispatchSourceTimer?
    private var contact = ContactFrameRecognizer()
    private var scrollGuard = GestureScrollGuard()
    private var reportedSwipe = false
    private var generation = 0
    private var lastContactSummary = ""
    private var aliases:[String:Int] = [:]
    private var sequence = 0
    private var nextAlias = 0
    init(configuration: Configuration) { self.configuration = configuration }
    var running: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }
    func start() -> Bool {
        stop()
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue | NSEvent.EventTypeMask.scrollWheel.rawValue,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<GestureInput>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { onDiagnostic?("Gesture input needs Accessibility permission. Grant it, then Recover."); return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = DispatchSource.makeTimerSource(queue:.main)
        timer.schedule(deadline:.now()+0.02,repeating:0.02)
        timer.setEventHandler { [weak self] in self?.settleRelease() }
        timer.resume(); settlementTimer = timer
        onDiagnostic?("Gesture input ready · swipe to inspect recognition")
        return true
    }
    func stop() {
        settlementTimer?.cancel(); settlementTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; source = nil; reset()
    }
    func reset() {
        generation += 1; contact.reset(); scrollGuard.reset(); reportedSwipe = false; lastContactSummary = ""; onContact?(.cancelled)
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        let suppressScroll = shouldSuppressScroll?() ?? false
        if type == .scrollWheel {
            if !suppressScroll { scrollGuard.reset() }
            let suppress = scrollGuard.suppress(precise:nsEvent.hasPreciseScrollingDeltas,began:nsEvent.phase.contains(.began),
                momentum:!nsEvent.momentumPhase.isEmpty,momentumEnded:nsEvent.momentumPhase.contains(.ended) || nsEvent.momentumPhase.contains(.cancelled),timestamp:nsEvent.timestamp)
            if suppress {
                onPacket?(["kind":"suppressed-scroll","timestamp":nsEvent.timestamp,"scrollPhase":nsEvent.phase.rawValue,
                    "momentumPhase":nsEvent.momentumPhase.rawValue,"generation":generation])
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        let all = nsEvent.allTouches()
        let contacts = all.map { touch -> TouchContact in
            let phase:TouchPhase
            switch touch.phase {
            case .began: phase = .began
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            case .stationary: phase = .stationary
            default: phase = .moved
            }
            return TouchContact(sample:TouchSample(id:String(describing:touch.identity),x:touch.normalizedPosition.x,y:touch.normalizedPosition.y),phase:phase,resting:touch.isResting)
        }
        let flags = nsEvent.modifierFlags
        let modifiers = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) | (flags.contains(.option) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
        let displayID = target?()
        let events = contact.feed(contacts,ended:contacts.isEmpty && nsEvent.phase.contains(.ended),modifiers:modifiers,displayID:displayID,
            threshold:configuration.threshold,invert:configuration.invert,timestamp:nsEvent.timestamp)
        scrollGuard.observe(contact.scrollContext,events:events,bindings:configuration.bindings,enabled:suppressScroll,timestamp:nsEvent.timestamp)
        // Preserve complete packet evidence for replay, including empty/foreign-phase packets
        // that must never control a contact cohort. No window content or raw touch IDs is stored.
        sequence += 1
        let samples:[[String:Any]] = contacts.map { touch in
            if aliases[touch.sample.id] == nil { nextAlias += 1; aliases[touch.sample.id] = nextAlias }
            return ["id":aliases[touch.sample.id]!,"x":touch.sample.x,"y":touch.sample.y,
                "phase":String(describing:touch.phase),"resting":touch.resting]
        }
        let decisions = events.map { event -> String in
            switch event { case .step(let swipe):return "step:\(swipe.fingers):\(swipe.direction.rawValue)";case .ended:return "ended";case .cancelled:return "cancelled" }
        }
        var packet:[String:Any] = ["seq":sequence,"timestamp":nsEvent.timestamp,"cgType":type.rawValue,
            "type":nsEvent.type.rawValue,"subtype":nsEvent.subtype.rawValue,"phase":nsEvent.phase.rawValue,
            "momentumPhase":nsEvent.momentumPhase.rawValue,"touches":samples,"events":decisions,
            "modifiers":modifiers,"invert":configuration.invert,"threshold":configuration.threshold,"generation":self.generation]
        if let reason = contact.cancellationReason { packet["cancellation"] = reason }
        if let reason = contact.decisionReason { packet["decision"] = reason }
        onPacket?(packet)
        if aliases.count > 256 && contacts.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) { aliases.removeAll() }
        let generation = self.generation
        let moving = contacts.filter { !$0.resting && $0.phase != .ended && $0.phase != .cancelled }.count
        let resting = contacts.filter(\.resting).count
        let lifted = contacts.filter { $0.phase == .ended }.count
        let summary = "active=\(moving) resting=\(resting) lifted=\(lifted) phase=\(nsEvent.phase.rawValue)"
        if summary != lastContactSummary || !events.isEmpty {
            lastContactSummary = summary
            let trace = "Input t=\(String(format:"%.3f",nsEvent.timestamp)) \(summary) recognized=\(events.count)"
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onTrace?(trace)
            }
        }
        deliver(events)
        // Touch packets still reach macOS; only scroll events belonging to our assigned
        // contact cohort are consumed. Native Mission Control conflicts remain explicit settings.
        return Unmanaged.passUnretained(event)
    }
    private func settleRelease() {
        guard contact.needsSettlement else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let events = contact.advance(timestamp:timestamp)
        sequence += 1
        var packet:[String:Any] = ["seq":sequence,"timestamp":timestamp,"kind":"settlement","touches":[],
            "generation":generation,"invert":configuration.invert,"threshold":configuration.threshold]
        if let reason = contact.decisionReason { packet["decision"] = reason; onTrace?("Input settlement: \(reason)") }
        scrollGuard.observe(contact.scrollContext,events:events,bindings:configuration.bindings,
            enabled:shouldSuppressScroll?() ?? false,timestamp:timestamp)
        onPacket?(packet); deliver(events)
    }
    private func deliver(_ events:[ContactGestureEvent]) {
        let generation = self.generation
        for event in events {
            switch event {
            case .step(let swipe):
                let report = !reportedSwipe; reportedSwipe = true
                // Return from the event tap before rendering SwiftUI or starting backend work.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onContact?(event)
                    if report {
                        self.onDiagnostic?("\(swipe.fingers) fingers · \(swipe.direction.rawValue) · modifiers \(swipe.modifiers) · \(swipe.displayID ?? "focused display")")
                        self.onSwipe?(swipe)
                    }
                }
            case .ended, .cancelled:
                reportedSwipe = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onContact?(event)
                }
            }
        }
    }

}
