import XCTest
@testable import GridCore

final class ContactFrameTests:XCTestCase {
    private func contacts(_ x:Double,phase:TouchPhase = .moved,count:Int = 3,base:Int = 0) -> [TouchContact] {
        (base..<(base+count)).map { TouchContact(sample:TouchSample(id:String($0),x:x,y:0.5),phase:phase) }
    }
    private var thumb:TouchContact { TouchContact(sample:TouchSample(id:"thumb",x:0.5,y:0.05),phase:.stationary,resting:true) }
    private func feed(_ input:inout ContactFrameRecognizer,_ samples:[TouchContact],_ t:Double,ended:Bool = false) -> [ContactGestureEvent] {
        input.feed(samples,ended:ended,modifiers:0,displayID:"one",threshold:0.05,invert:false,timestamp:t)
    }
    private func steps(_ events:[ContactGestureEvent]) -> [RecognizedSwipe] { events.compactMap { if case .step(let swipe) = $0 { return swipe }; return nil } }
    func testTwoMovingFingersAndRestingThumbNeverSelect() {
        var input = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
        events += feed(&input,contacts(0,phase:.began,count:2)+[thumb],0)
        for index in 1...20 { events += feed(&input,contacts(Double(index)*0.04,count:2)+[thumb],Double(index)*0.05) }
        events += feed(&input,contacts(0.8,phase:.ended,count:2)+[thumb],1.1)
        XCTAssertTrue(events.isEmpty)
    }
    func testRestingThumbDoesNotPreventThreeFingerLiftOrLeakIntoNextTwoFingerGesture() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began)+[thumb],0)
        XCTAssertEqual(steps(feed(&input,contacts(0.08)+[thumb],0.05)).count,1)
        let end = feed(&input,contacts(0.08,phase:.ended)+[thumb],0.1)
        guard case .ended? = end.last else { return XCTFail("Resting thumb blocked real lift") }
        _ = feed(&input,contacts(0,phase:.began,count:2,base:10)+[thumb],0.2)
        XCTAssertTrue(feed(&input,contacts(0.2,count:2,base:10)+[thumb],0.3).isEmpty)
    }
    func testFastLongFlickIsOneStepEvenWithManyMotionPacketsAndLargeFinalMotion() {
        var input = ContactFrameRecognizer(), events:[ContactGestureEvent] = []
        _ = feed(&input,contacts(0,phase:.began),0)
        for index in 1...10 { events += feed(&input,contacts(Double(index)*0.07),Double(index)*0.015) }
        events += feed(&input,contacts(0.95,phase:.ended),0.18)
        XCTAssertEqual(steps(events).count,1)
        guard case .ended? = events.last else { return XCTFail("Flick didn't commit") }
    }
    func testHeldContactExploresOnFreshMotionWithoutReplayingFlickDistance() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began),0)
        XCTAssertEqual(steps(feed(&input,contacts(0.07),0.03)).count,1)
        XCTAssertTrue(feed(&input,contacts(0.6),0.1).isEmpty)
        XCTAssertTrue(feed(&input,contacts(0.6,phase:.stationary),0.5).isEmpty)
        XCTAssertTrue(feed(&input,contacts(0.6,phase:.stationary),0.58).isEmpty)
        XCTAssertEqual(steps(feed(&input,contacts(0.67),0.6)).count,1)
        XCTAssertTrue(feed(&input,contacts(0.67,phase:.stationary),1).isEmpty)
        let reverse = steps(feed(&input,contacts(0.6),1.1))
        XCTAssertEqual(reverse.first?.direction,.left)
    }
    func testFastSwipeWithOnlyFinalDisplacementAndRestingThumbSelectsThenCommits() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began)+[thumb],0)
        let result = feed(&input,contacts(0.1,phase:.ended)+[thumb],0.1)
        XCTAssertEqual(steps(result).count,1)
        guard result.count == 2, case .ended = result[1] else { return XCTFail("Missing final lift") }
    }
    func testCohortCanBecomeStationaryRestingWithoutCommittingUntilLift() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began),0)
        _ = feed(&input,contacts(0.07),0.05)
        let resting = contacts(0.07,phase:.stationary).map { TouchContact(sample:$0.sample,phase:$0.phase,resting:true) }
        XCTAssertTrue(feed(&input,resting,1).isEmpty)
        guard case .ended? = feed(&input,contacts(0.07,phase:.ended),1.1).last else { return XCTFail("Missing lift") }
    }
    func testMissingTerminalPacketCancelsOldCohortWhenNewFingersLand() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began),0)
        _ = feed(&input,contacts(0.07),0.05)
        XCTAssertTrue(feed(&input,[],0.1).isEmpty) // No guessed lift or timer commit.
        let fresh = feed(&input,contacts(0,phase:.began,count:2,base:10),0.3)
        guard case .cancelled? = fresh.first else { return XCTFail("Old preview leaked into a new session") }
        XCTAssertTrue(feed(&input,contacts(0.2,count:2,base:10),0.4).isEmpty)
    }
    func testStaggeredLiftCommitsOnceAndUnrelatedThumbCancellationDoesNotAbort() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began)+[thumb],0)
        _ = feed(&input,contacts(0.07)+[thumb],0.05)
        let cancelledThumb = TouchContact(sample:thumb.sample,phase:.cancelled,resting:true)
        XCTAssertTrue(feed(&input,contacts(0.07)+[cancelledThumb],0.08).isEmpty)
        let first = contacts(0.07,count:2)+contacts(0.07,phase:.ended,count:1,base:2)
        XCTAssertTrue(feed(&input,first,0.1).isEmpty)
        XCTAssertTrue(feed(&input,contacts(0.07,count:2),0.12).isEmpty)
        let end = feed(&input,contacts(0.07,phase:.ended,count:2)+[thumb],0.14)
        guard case .ended? = end.first else { return XCTFail("No final end") }
        XCTAssertTrue(feed(&input,contacts(0.07,phase:.ended,count:2)+[thumb],0.15).isEmpty)
    }
    func testMovingTwoFingerScrollCannotPromoteWhenThirdFingerArrivesLate() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began,count:2),0)
        _ = feed(&input,contacts(0.3,count:2),0.05)
        XCTAssertTrue(feed(&input,contacts(0.3),0.1).isEmpty)
        XCTAssertTrue(feed(&input,contacts(0.5),0.15).isEmpty)
    }
    func testStaggeredFourFingerLandingFreezesOriginalScope() {
        var input = ContactFrameRecognizer()
        _ = input.feed(contacts(0,phase:.began,count:1),modifiers:4,displayID:"first",threshold:0.05,invert:false,timestamp:0)
        _ = feed(&input,contacts(0,phase:.began,count:3),0.01)
        _ = feed(&input,contacts(0,phase:.began,count:4),0.02)
        let result = steps(feed(&input,contacts(0.08,count:4),0.1))
        XCTAssertEqual(result.first?.fingers,4); XCTAssertEqual(result.first?.modifiers,4); XCTAssertEqual(result.first?.displayID,"first")
    }
}

extension ContactFrameTests {
    func testQuickReversalCanReturnToOriginBeforeTheExplorationDelay() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began),0)
        XCTAssertEqual(steps(feed(&input,contacts(0.07),0.02)).first?.direction,.right)
        XCTAssertTrue(feed(&input,contacts(0.05),0.04).isEmpty)
        XCTAssertEqual(steps(feed(&input,contacts(0),0.06)).first?.direction,.left)
    }
    func testGlobalEventEndCannotCommitAStillTouchingCohort() {
        var input = ContactFrameRecognizer()
        _ = feed(&input,contacts(0,phase:.began),0)
        _ = feed(&input,contacts(0.07),0.05)
        XCTAssertTrue(feed(&input,[],0.1).isEmpty)
        XCTAssertTrue(feed(&input,[thumb],0.15,ended:true).isEmpty)
        guard case .ended? = feed(&input,contacts(0.07,phase:.ended),0.2).first else { return XCTFail("Actual finger lift did not close the cohort") }
    }
}
