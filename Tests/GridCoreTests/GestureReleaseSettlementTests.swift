import XCTest
@testable import GridCore

final class GestureReleaseSettlementTests:XCTestCase {
    private func touches(_ x:Double,_ phases:[TouchPhase]) -> [TouchContact] {
        phases.enumerated().map { TouchContact(sample:TouchSample(id:String($0.offset),x:x,y:0.5),phase:$0.element) }
    }
    private func feed(_ r:inout ContactFrameRecognizer,_ contacts:[TouchContact],_ time:Double,end:Bool = false) -> [ContactGestureEvent] {
        r.feed(contacts,ended:end,modifiers:0,displayID:"d",threshold:0.04,invert:true,timestamp:time)
    }
    private func began(_ r:inout ContactFrameRecognizer) {
        _ = feed(&r,touches(0.2,[.began,.began,.began]),0)
        _ = feed(&r,touches(0.26,[.moved,.moved,.moved]),0.03)
    }
    private func ends(_ events:[ContactGestureEvent]) -> Int { events.filter { if case .ended = $0 { return true };return false }.count }
    func testMissingLastLiftSettlesOnlyAfterExplicitMajorityAndNativeEndMarker() {
        var r = ContactFrameRecognizer();began(&r)
        _ = feed(&r,touches(0.26,[.ended,.ended]),0.06)
        XCTAssertTrue(r.advance(timestamp:1).isEmpty) // Timeout alone never ends a gesture.
        _ = feed(&r,[],1.01,end:true)
        XCTAssertTrue(r.advance(timestamp:1.02).isEmpty)
        XCTAssertEqual(ends(r.advance(timestamp:1.2)),1)
        XCTAssertTrue(r.advance(timestamp:2).isEmpty)
    }
    func testEmptyGlobalEndWithAllFingersDownCannotSettleOrCommit() {
        var r = ContactFrameRecognizer();began(&r)
        _ = feed(&r,[],0.06,end:true)
        XCTAssertFalse(r.needsSettlement);XCTAssertTrue(r.advance(timestamp:20).isEmpty)
    }
    func testSingleLiftAndForeignEndIsInsufficientToConfirm() {
        var r = ContactFrameRecognizer();began(&r)
        _ = feed(&r,touches(0.26,[.ended,.moved,.moved]),0.06)
        _ = feed(&r,[],0.07,end:true)
        XCTAssertFalse(r.needsSettlement);XCTAssertTrue(r.advance(timestamp:20).isEmpty)
    }
    func testRemainingFingerEvidenceExtendsQuietGrace() {
        var r = ContactFrameRecognizer();began(&r)
        _ = feed(&r,touches(0.26,[.ended,.ended]),0.06)
        _ = feed(&r,[],0.07,end:true)
        let remaining = TouchContact(sample:TouchSample(id:"2",x:0.26,y:0.5),phase:.moved)
        _ = feed(&r,[remaining],0.13)
        XCTAssertTrue(r.advance(timestamp:0.14).isEmpty)
        XCTAssertEqual(ends(r.advance(timestamp:0.25)),1)
    }
    func testResetInvalidatesPendingSettlement() {
        var r = ContactFrameRecognizer();began(&r)
        _ = feed(&r,touches(0.26,[.ended,.ended]),0.06)
        _ = feed(&r,[],0.07,end:true)
        XCTAssertTrue(r.needsSettlement);r.reset()
        XCTAssertFalse(r.needsSettlement);XCTAssertTrue(r.advance(timestamp:20).isEmpty)
    }
}
