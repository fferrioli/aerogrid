import XCTest
@testable import GridCore

final class HeldExplorationTests:XCTestCase {
    private func touches(_ x:Double,phase:TouchPhase = .moved,count:Int = 3,base:Int = 0) -> [TouchContact] {
        (base..<(base+count)).map { TouchContact(sample:TouchSample(id:String($0),x:x,y:0.5),phase:phase) }
    }
    private func feed(_ input:inout ContactFrameRecognizer,_ contacts:[TouchContact],_ timestamp:Double,invert:Bool = false) -> [ContactGestureEvent] {
        input.feed(contacts,modifiers:0,displayID:"one",threshold:0.05,invert:invert,timestamp:timestamp)
    }
    private func steps(_ events:[ContactGestureEvent]) -> [RecognizedSwipe] { events.compactMap { if case .step(let swipe) = $0 { return swipe };return nil } }
    func testContinuousHeldMotionExploresWithoutPausesForBothScopesAndInversions() {
        for count in [3,4] { for invert in [false,true] {
            var input = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
            _ = feed(&input,touches(0,phase:.began,count:count),0,invert:invert)
            for frame in 1...90 {
                events += feed(&input,touches(Double(frame)*0.008,count:count),Double(frame)/60,invert:invert)
                if frame == 25 { XCTAssertEqual(steps(events).count,1) }
            }
            let result = steps(events)
            XCTAssertGreaterThanOrEqual(result.count,4)
            XCTAssertTrue(result.allSatisfy { $0.fingers == count && $0.direction == (invert ? .left : .right) })
        } }
    }
    func testKeepingStillAfterFirstStepDoesNotAutoRepeat() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,touches(0,phase:.began),0)
        XCTAssertEqual(steps(feed(&input,touches(0.06),0.05)).count,1)
        for frame in 1...100 { XCTAssertTrue(feed(&input,touches(0.06,phase:.stationary),Double(frame)*0.02+0.05).isEmpty) }
        XCTAssertEqual(steps(feed(&input,touches(0.12),2.2)).count,1)
    }
    func testReplacingOneFingerWhileTwoRemainDoesNotCloseHeldGestureOrJump() {
        for newID in [false,true] {
            var input = ContactFrameRecognizer()
            _ = feed(&input,touches(0,phase:.began),0)
            _ = feed(&input,touches(0.06),0.05)
            let release = touches(0.1,count:2)+touches(0.1,phase:.ended,count:1,base:2)
            XCTAssertTrue(feed(&input,release,0.7).isEmpty)
            let replacement = touches(0.2,count:2)+touches(0.2,phase:.began,count:1,base:newID ? 3 : 2)
            XCTAssertTrue(feed(&input,replacement,0.72).isEmpty,"Repositioning must rebase, not create a swipe")
            let moved = touches(0.27,count:2)+touches(0.27,count:1,base:newID ? 3 : 2)
            XCTAssertEqual(steps(feed(&input,moved,0.9)).count,1)
        }
    }
    func testFreshMotionIsRequiredWhenRepeatCooldownExpires() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,touches(0,phase:.began),0)
        _ = feed(&input,touches(0.06),0.05)
        XCTAssertEqual(steps(feed(&input,touches(0.12),0.65)).count,1)
        XCTAssertTrue(feed(&input,touches(0.2),0.7).isEmpty)
        XCTAssertTrue(feed(&input,touches(0.2,phase:.stationary),0.82).isEmpty)
    }
    func testRecordedShortFlicksRetainExactlyOneStepAndOneCommit() throws {
        for index in 0..<6 {
            let result = try replay("quick-flick-\(index)")
            XCTAssertEqual(result.events.filter { $0.kind == "step" }.count,1,"capture \(index)")
            XCTAssertEqual(result.events.filter { $0.kind == "ended" }.count,1,"capture \(index)")
            XCTAssertFalse(result.events.contains { $0.kind == "cancelled" })
        }
    }
    func testRecordedHeldGestureContinuesAfterTrackpadEdgeRelanding() throws {
        let result = try replay("held-edge-contact")
        XCTAssertGreaterThanOrEqual(result.events.filter { $0.kind == "step" && $0.time > 4 }.count,4)
        XCTAssertGreaterThanOrEqual(result.repositions,2)
        XCTAssertEqual(result.events.filter { $0.kind == "ended" }.count,1)
        XCTAssertFalse(result.events.contains { $0.kind == "cancelled" })
    }
    private func replay(_ name:String) throws -> (events:[(time:Double,kind:String)],repositions:Int) {
        let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"jsonl",subdirectory:"Fixtures"))
        let data = try String(contentsOf:url,encoding:.utf8)
        var input = ContactFrameRecognizer(), events:[(time:Double,kind:String)] = [], repositions = 0, lastTime = 0.0
        func record(_ output:[ContactGestureEvent],time:Double) {
            for event in output {
                switch event { case .step:events.append((time,"step"));case .ended:events.append((time,"ended"));case .cancelled:events.append((time,"cancelled")) }
            }
        }
        for line in data.split(separator:"\n") {
            let packet = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
            let time = try XCTUnwrap(packet["timestamp"] as? Double);lastTime = time
            let raw = try XCTUnwrap(packet["touches"] as? [[String:Any]])
            let contacts = try raw.map { touch -> TouchContact in
                let phase:TouchPhase
                switch touch["phase"] as? String {
                case "began":phase = .began
                case "ended":phase = .ended
                case "cancelled":phase = .cancelled
                case "stationary":phase = .stationary
                default:phase = .moved
                }
                return TouchContact(sample:TouchSample(id:String(describing:try XCTUnwrap(touch["id"])),x:try XCTUnwrap(touch["x"] as? Double),y:try XCTUnwrap(touch["y"] as? Double)),phase:phase,resting:touch["resting"] as? Bool ?? false)
            }
            let output:[ContactGestureEvent]
            if packet["kind"] as? String == "settlement" { output = input.advance(timestamp:time) }
            else { output = input.feed(contacts,ended:contacts.isEmpty && ((packet["phase"] as? Int ?? 0)&8 != 0),modifiers:packet["modifiers"] as? Int ?? 0,displayID:"fixture",threshold:try XCTUnwrap(packet["threshold"] as? Double),invert:packet["invert"] as? Bool ?? false,timestamp:time) }
            record(output,time:time)
            if input.decisionReason == "held-contact-repositioned" { repositions += 1 }
        }
        // A new algorithm can require a settlement poll absent from the previous build's capture.
        record(input.advance(timestamp:lastTime+0.2),time:lastTime+0.2)
        return (events,repositions)
    }
}
