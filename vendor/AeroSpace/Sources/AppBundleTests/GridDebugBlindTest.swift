@testable import AppBundle
import XCTest
import Common

final class GridDebugBlindTest: XCTestCase {
    @MainActor func testStandaloneRejectsOperation() async {
        XCTAssertFalse(gridOwnsBackendUI())
        let io = CmdIoImpl(stdin: .emptyStdin)
        _ = await parseCommand(["grid-layout", "--data", "{\"windowID\":2,\"seconds\":1,\"forget\":false}", "debug-blind"]).cmdOrDie.run(.defaultEnv, io)
        XCTAssertEqual(io.stderr.joined(), "Unknown grid-layout operation")
    }
    func testFilteringExpiryAndForget() {
        let result = gridFilterBlindWindows([1: [UInt32(2), 3, 4]], blindness: [
            2: GridDebugBlindness(expires: 11, forget: true),
            3: GridDebugBlindness(expires: 10, forget: false),
        ], now: 10)
        XCTAssertEqual(result.lists[1], [3, 4])
        XCTAssertEqual(result.blindness, [2: GridDebugBlindness(expires: 11, forget: true)])
    }
    func testCancellationAndRange() throws {
        let active = try gridUpdatedBlindness([:], windowID: 2, seconds: 600, forget: true, now: 10)
        XCTAssertTrue(try gridUpdatedBlindness(active, windowID: 2, seconds: 0, forget: false, now: 11).isEmpty)
        for seconds in [-1.0, 0.5, 601, .infinity, .nan] {
            XCTAssertThrowsError(try gridUpdatedBlindness([:], windowID: 2, seconds: seconds, forget: false, now: 10))
        }
    }
}
