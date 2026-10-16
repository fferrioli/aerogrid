// Bounded, read-only capability probe. It logs only multi-touch phase/count metadata.
import AppKit
import ApplicationServices
let seconds = min(60, max(1, Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20))
print("trusted=\(AXIsProcessTrusted())")
var observations = 0
let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue, callback: { _, _, event, _ in
        if let value = NSEvent(cgEvent: event) {
            let touches = value.allTouches()
            if touches.count >= 3 || touches.contains(where: { $0.phase == .ended || $0.phase == .cancelled }) {
                observations += 1
                print("gesture count=\(touches.count) phase=\(value.phase.rawValue) touches=\(touches.map { "\($0.phase.rawValue):\($0.isResting)" }.sorted())")
                fflush(stdout)
            }
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
if let tap {
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("probe listening, seconds=\(seconds)");fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    CGEvent.tapEnable(tap: tap, enable: false);CFMachPortInvalidate(tap)
    print("probe complete observations=\(observations)")
} else { print("probe unavailable: event tap not authorized; no permission requested") }
