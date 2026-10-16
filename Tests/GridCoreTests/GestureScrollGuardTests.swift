import XCTest
@testable import GridCore

final class GestureScrollGuardTests: XCTestCase {
    let bindings = Configuration(backendPath:"/unused").bindings
    func testAssignedThreeAndFourContactsClaimBeforeTheFirstNavigationStep() {
        for fingers in [3,4] {
            var guarder = GestureScrollGuard()
            guarder.observe(.init(fingers:fingers,modifiers:0),events:[],bindings:bindings,enabled:true,timestamp:1)
            XCTAssertTrue(guarder.suppress(precise:true,began:true,momentum:false,momentumEnded:false,timestamp:1.01))
            XCTAssertFalse(guarder.suppress(precise:false,began:false,momentum:false,momentumEnded:false,timestamp:1.02))
            XCTAssertTrue(guarder.suppress(precise:true,began:false,momentum:false,momentumEnded:false,timestamp:20))
        }
    }
    func testTwoContactsUnassignedModifiersAndDisabledModeKeepOrdinaryScrolling() {
        for (fingers,modifiers,enabled) in [(2,0,true),(3,8,true),(3,0,false)] {
            var guarder = GestureScrollGuard()
            guarder.observe(.init(fingers:fingers,modifiers:modifiers),events:[],bindings:bindings,enabled:enabled,timestamp:1)
            XCTAssertFalse(guarder.suppress(precise:true,began:true,momentum:false,momentumEnded:false,timestamp:1.01))
        }
    }
    func testPartialBindingClaimsOnlyAfterItsMatchingStepAndRetainsTheCohort() {
        let partial = [GestureBinding(fingers:3,direction:.up)]
        var guarder = GestureScrollGuard()
        let context = GestureScrollContext(fingers:3,modifiers:0)
        guarder.observe(context,events:[],bindings:partial,enabled:true,timestamp:0)
        XCTAssertFalse(guarder.suppress(precise:true,began:true,momentum:false,momentumEnded:false,timestamp:0.01))
        guarder.observe(context,events:[.step(.init(direction:.up,fingers:3,modifiers:0,displayID:nil))],bindings:partial,enabled:true,timestamp:0.1)
        guarder.observe(context,events:[],bindings:partial,enabled:true,timestamp:0.2)
        XCTAssertTrue(guarder.suppress(precise:true,began:false,momentum:false,momentumEnded:false,timestamp:0.21))
        guarder.observe(.init(fingers:4,modifiers:0),events:[],bindings:partial,enabled:true,timestamp:0.3)
        XCTAssertFalse(guarder.suppress(precise:true,began:false,momentum:false,momentumEnded:false,timestamp:0.31))
    }
    func testReleaseTailAndMomentumDoNotLeakButFreshScrollIsIndependent() {
        var guarder = GestureScrollGuard()
        guarder.observe(.init(fingers:3,modifiers:0),events:[],bindings:bindings,enabled:true,timestamp:1)
        guarder.observe(nil,events:[.ended],bindings:bindings,enabled:true,timestamp:2)
        XCTAssertTrue(guarder.suppress(precise:true,began:false,momentum:false,momentumEnded:false,timestamp:2.01))
        for t in stride(from:2.1,through:2.8,by:0.1) {
            XCTAssertTrue(guarder.suppress(precise:true,began:false,momentum:true,momentumEnded:false,timestamp:t))
        }
        XCTAssertTrue(guarder.suppress(precise:true,began:false,momentum:true,momentumEnded:true,timestamp:2.85))
        XCTAssertFalse(guarder.suppress(precise:true,began:true,momentum:false,momentumEnded:false,timestamp:2.9))
        guarder.observe(.init(fingers:3,modifiers:0),events:[],bindings:bindings,enabled:true,timestamp:3)
        guarder.observe(nil,events:[.ended],bindings:bindings,enabled:true,timestamp:4)
        XCTAssertFalse(guarder.suppress(precise:true,began:true,momentum:false,momentumEnded:false,timestamp:4.01))
    }
    func testTailExpiresAndResetPauseAndNewTwoFingerContactClearOwnership() {
        for ending in 0..<4 {
            var guarder = GestureScrollGuard()
            guarder.observe(.init(fingers:3,modifiers:0),events:[],bindings:bindings,enabled:true,timestamp:1)
            switch ending {
            case 0: guarder.reset()
            case 1: guarder.observe(nil,events:[],bindings:bindings,enabled:false,timestamp:2)
            case 2: guarder.observe(.init(fingers:2,modifiers:0),events:[],bindings:bindings,enabled:true,timestamp:2)
            default: guarder.observe(nil,events:[.cancelled],bindings:bindings,enabled:true,timestamp:2)
            }
            XCTAssertFalse(guarder.suppress(precise:true,began:false,momentum:true,momentumEnded:false,timestamp:2.3))
        }
    }
    func testFrameContextIgnoresRestingThumbAndKeepsPartialReleaseClaimed() {
        var frame = ContactFrameRecognizer()
        func touch(_ id:String,_ phase:TouchPhase,resting:Bool=false) -> TouchContact {
            TouchContact(sample:.init(id:id,x:0,y:0),phase:phase,resting:resting)
        }
        _ = frame.feed([touch("a",.began),touch("b",.began),touch("thumb",.began,resting:true)],modifiers:4,displayID:nil,threshold:0.02,invert:true,timestamp:0)
        XCTAssertEqual(frame.scrollContext?.fingers,2)
        frame.reset()
        _ = frame.feed([touch("a",.began),touch("b",.began),touch("c",.began)],modifiers:4,displayID:nil,threshold:0.02,invert:true,timestamp:1)
        XCTAssertEqual(frame.scrollContext?.fingers,3)
        XCTAssertEqual(frame.scrollContext?.modifiers,4)
        _ = frame.feed([touch("a",.ended)],modifiers:0,displayID:nil,threshold:0.02,invert:true,timestamp:2)
        XCTAssertEqual(frame.scrollContext?.fingers,3)
        _ = frame.feed([touch("b",.ended),touch("c",.ended)],modifiers:0,displayID:nil,threshold:0.02,invert:true,timestamp:3)
        XCTAssertNil(frame.scrollContext)
    }
}
