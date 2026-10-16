import Foundation

public enum TouchPhase { case began, moved, stationary, ended, cancelled }
public struct TouchContact {
    public let sample:TouchSample
    public let phase:TouchPhase
    public let resting:Bool
    public init(sample:TouchSample,phase:TouchPhase,resting:Bool = false) {
        self.sample = sample; self.phase = phase; self.resting = resting
    }
}

/// Retains positions and sticky terminal states across subset and stale native packets.
public struct ContactFrameRecognizer {
    private struct Member {
        var sample:TouchSample
        var updated:TimeInterval
        var ended = false
    }
    private struct Context {
        let modifiers:Int
        let displayID:String?
        let threshold:Double
        let invert:Bool
    }
    private var members:[String:Member] = [:]
    private var retired = Set<String>()
    private var restingSeen = Set<String>()
    private var recognizer = ContactGestureRecognizer()
    private var context:Context?
    private var releasing = false
    private struct PendingReposition {
        let contacts: [TouchContact]
        let lifted: Set<String>
        let landings: Set<String>
        let timestamp: TimeInterval
    }
    private var pendingReposition: PendingReposition?
    private var lastFullPacket:TimeInterval?
    private var intervals:[TimeInterval] = []
    private var stationarySince:TimeInterval?
    private var releaseEnd:TimeInterval?
    public private(set) var cancellationReason:String?
    public private(set) var decisionReason:String?
    public var needsSettlement:Bool { releaseEnd != nil }
    public var scrollContext: GestureScrollContext? {
        guard let context, let fingers = recognizer.contactFingerCount else { return nil }
        return GestureScrollContext(fingers:fingers,modifiers:context.modifiers)
    }
    private var cadence:TimeInterval {
        let sorted = intervals.sorted()
        return sorted.isEmpty ? 1/60 : sorted[sorted.count/2]
    }
    private var majorityLifted:Bool { members.values.filter(\.ended).count > members.count/2 }
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func feed(_ contacts:[TouchContact],ended:Bool = false,cancelled:Bool = false,
        modifiers:Int,displayID:String?,threshold:Double,invert:Bool,timestamp:TimeInterval) -> [ContactGestureEvent] {
        cancellationReason = nil; decisionReason = nil
        // A global end alone says nothing about finger lifetime. It can corroborate a cohort
        // already ending through a majority of explicit lifts, followed by bounded quiet.
        if contacts.isEmpty {
            if ended && releasing && majorityLifted { releaseEnd = timestamp }
            return []
        }
        var events:[ContactGestureEvent] = []
        let contacts = resumeRepositionedContacts(contacts,timestamp:timestamp)
        restingSeen.formUnion(contacts.filter { $0.resting && members[$0.sample.id] == nil }.map { $0.sample.id })
        let active = contacts.filter { $0.phase != .ended && $0.phase != .cancelled && !$0.resting }
        for contact in active where contact.phase == .began { retired.remove(contact.sample.id) }
        let fresh = active.filter {
            members[$0.sample.id] == nil && !retired.contains($0.sample.id) && (!releasing || !restingSeen.contains($0.sample.id))
        }
        let knownAlive = contacts.contains { members[$0.sample.id]?.ended == false }
        let staleMembers = members.values.allSatisfy { timestamp-$0.updated > max(0.12,cadence*8) }
        if !members.isEmpty && !fresh.isEmpty {
            if releasing {
                // A new landing starts its own cohort, even while a remnant of the old one is
                // still reported. Complete a mostly lifted gesture; never discard the new one.
                if majorityLifted { events += finish("next-cohort-after-majority-lift") }
                else { events += cancel("overlapping-cohort") }
            } else if !knownAlive && (!recognizer.canEnrollContacts(threshold:threshold) || (staleMembers && fresh.contains { $0.phase == .began })) {
                events += cancel("new-cohort")
            }
        }
        if contacts.contains(where: { members[$0.sample.id]?.ended == false && $0.phase == .cancelled }) {
            events += cancel("touch-cancelled"); return events
        }
        for contact in contacts {
            let id = contact.sample.id
            if var member = members[id] {
                guard !member.ended else { continue }
                member.sample = contact.sample; member.updated = timestamp
                if contact.phase == .ended { member.ended = true; releasing = true }
                members[id] = member
            } else if !contact.resting && contact.phase != .ended && contact.phase != .cancelled && !retired.contains(id) && (!releasing || !restingSeen.contains(id)) {
                if context == nil { context = Context(modifiers:modifiers,displayID:displayID,threshold:threshold,invert:invert) }
                members[id] = Member(sample:contact.sample,updated:timestamp)
            }
        }
        guard !members.isEmpty, let context else { return events }
        if members.values.allSatisfy(\.ended) { events += finish("explicit-lift"); return events }
        updateStroke(contacts,timestamp:timestamp)
        events += recognizer.feedEvents(members.values.map(\.sample),phase:releasing ? .releasing : .active,
            modifiers:context.modifiers,displayID:context.displayID,threshold:context.threshold,invert:context.invert,
            timestamp:timestamp,stationary:false)
        if events.contains(where: { if case .cancelled = $0 { return true }; return false }), cancellationReason == nil {
            cancellationReason = "finger-count-or-identity-change"
        }
        return events
    }
    /// A timeout never ends an active gesture. Settlement requires explicit majority lift AND
    /// a subsequent native end marker, with no remaining member observed during the grace period.
    public mutating func advance(timestamp:TimeInterval) -> [ContactGestureEvent] {
        decisionReason = nil; cancellationReason = nil
        guard releasing, majorityLifted, let end = releaseEnd else { return [] }
        let lastAlive = members.values.filter { !$0.ended }.map(\.updated).max() ?? end
        guard timestamp-max(end,lastAlive) >= max(0.06,min(0.12,cadence*4)) else { return [] }
        return finish("corroborated-lift-settled")
    }
    private mutating func resumeRepositionedContacts(_ contacts: [TouchContact], timestamp: TimeInterval) -> [TouchContact] {
        guard releasing, !majorityLifted else { pendingReposition = nil; return contacts }
        let alive = Set(members.filter { !$0.value.ended }.keys)
        let lifted = Set(members.filter { $0.value.ended }.keys)
        let down = Set(contacts.filter { $0.phase != .ended && $0.phase != .cancelled }.map(\.sample.id))
        if let pending = pendingReposition, pending.lifted == lifted, timestamp > pending.timestamp,
           alive.count >= 2, alive.isSubset(of: down),
           pending.landings.allSatisfy({ id in contacts.contains { $0.sample.id == id && !$0.resting && ($0.phase == .moved || $0.phase == .stationary) } }) {
            // A later contact frame confirms the landing. Rebase to its original positions
            // so the confirming movement is retained, without counting the reposition itself.
            for id in lifted { members.removeValue(forKey: id) }
            retired.formUnion(lifted.subtracting(pending.landings))
            for contact in pending.contacts where alive.contains(contact.sample.id) || pending.landings.contains(contact.sample.id) {
                retired.remove(contact.sample.id)
                members[contact.sample.id] = Member(sample: contact.sample, updated: pending.timestamp)
            }
            pendingReposition = nil
            releasing = false; releaseEnd = nil; stationarySince = nil; lastFullPacket = nil; intervals.removeAll()
            recognizer.resumeContacts(members.values.map(\.sample)); decisionReason = "held-contact-repositioned"
            return contacts
        }
        let landings = contacts.filter {
            $0.phase == .began && !$0.resting && !alive.contains($0.sample.id) && !restingSeen.contains($0.sample.id)
        }
        if alive.count >= 2, alive.isSubset(of: down), !lifted.isEmpty, landings.count == lifted.count {
            let ids = Set(landings.map(\.sample.id))
            if pendingReposition?.landings != ids || pendingReposition?.lifted != lifted {
                pendingReposition = PendingReposition(contacts: contacts, lifted: lifted, landings: ids, timestamp: timestamp)
                decisionReason = "held-contact-recontact-pending"
            }
        }
        // Native delivery can replay .began after .ended. One such snapshot is not
        // proof that a finger landed again: keep its lift sticky until confirmed.
        let unconfirmed = pendingReposition?.landings ?? []
        return contacts.filter { !unconfirmed.contains($0.sample.id) }
    }
    private mutating func updateStroke(_ contacts:[TouchContact],timestamp:TimeInterval) {
        guard !releasing, !contacts.contains(where: { $0.phase == .began || $0.phase == .ended || $0.phase == .cancelled }) else {
            stationarySince = nil; return
        }
        let current = contacts.filter { members[$0.sample.id] != nil }
        guard current.count == members.count else { stationarySince = nil; return }
        let still = current.allSatisfy { $0.phase == .stationary }
        if still {
            if stationarySince == nil { stationarySince = timestamp }
            if let start = stationarySince, timestamp-start >= max(0.06,cadence*4) {
                recognizer.rearmStroke(); decisionReason = "stationary-pause"
            }
        } else { stationarySince = nil }
        if let previous = lastFullPacket, timestamp > previous {
            let interval = timestamp-previous
            if !intervals.isEmpty && interval > max(0.12,cadence*8) {
                recognizer.rearmStroke(); decisionReason = "packet-pause"
            } else if interval <= 0.05 {
                // Long pauses/delivery gaps are not samples of the trackpad's frame rate.
                intervals.append(interval)
                if intervals.count > 8 { intervals.removeFirst() }
            }
        }
        lastFullPacket = timestamp
    }
    private mutating func finish(_ reason:String) -> [ContactGestureEvent] {
        guard let context else { return [] }
        let events = recognizer.feedEvents(members.values.map(\.sample),phase:.ended,
            modifiers:context.modifiers,displayID:context.displayID,threshold:context.threshold,invert:context.invert)
        retireCohort(); decisionReason = reason
        return events
    }
    private mutating func cancel(_ reason:String) -> [ContactGestureEvent] {
        guard let context else { return [] }
        let events = recognizer.feedEvents([],phase:.cancelled,modifiers:context.modifiers,displayID:context.displayID,threshold:context.threshold,invert:context.invert)
        retireCohort(); cancellationReason = reason
        return events
    }
    private mutating func retireCohort() {
        if retired.count > 64 { retired.removeAll() }
        retired.formUnion(members.keys); retired.formUnion(restingSeen)
        members.removeAll(); context = nil; restingSeen.removeAll(); releasing = false; pendingReposition = nil
        lastFullPacket = nil; stationarySince = nil; releaseEnd = nil; intervals.removeAll(); recognizer.reset()
    }
}
