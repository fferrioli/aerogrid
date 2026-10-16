import XCTest
@testable import GridCore

final class ModelTests: XCTestCase {
    func testFourDirectionsAndWrap() {
        var g = Grid(id: "test", name: "Test", displayRole: "builtin")
        XCTAssertEqual(g.neighbor(of: g.cells[4].id, direction: .up)?.id, g.cells[1].id)
        XCTAssertEqual(g.neighbor(of: g.cells[4].id, direction: .down)?.id, g.cells[7].id)
        XCTAssertEqual(g.neighbor(of: g.cells[4].id, direction: .left)?.id, g.cells[3].id)
        XCTAssertEqual(g.neighbor(of: g.cells[4].id, direction: .right)?.id, g.cells[5].id)
        XCTAssertNil(g.neighbor(of: g.cells[0].id, direction: .up))
        g.wrap = true
        XCTAssertEqual(g.neighbor(of: g.cells[0].id, direction: .up)?.id, g.cells[6].id)
        g.cells.remove(at: 6)
        XCTAssertNil(g.neighbor(of: g.cells[0].id, direction: .up))
    }
    func testConfigRejectsCollisionsAndMalformedBindings() throws {
        var c = Configuration(backendPath: "/unused"); try c.validate()
        c.grids[1].cells[0].workspace = c.grids[0].cells[0].workspace
        XCTAssertThrowsError(try c.validate())
        c = Configuration(backendPath: "/unused"); c.bindings.append(c.bindings[0])
        XCTAssertThrowsError(try c.validate())
        c = Configuration(backendPath: "/unused"); c.threshold = .nan
        XCTAssertThrowsError(try c.validate())
    }
    func testAtomicStoreKeepsPreviousVersionAndRejectsCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(directory: dir)
        var c = Configuration(backendPath: "/unused")
        try store.save(c, name: "config.json")
        c.invert = true; try store.save(c, name: "config.json")
        XCTAssertEqual(try store.load(Configuration.self, name: "config.json")?.invert, true)
        XCTAssertEqual(try store.load(Configuration.self, name: "config.json.backup")?.invert, false)
        try Data("broken".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try store.load(Configuration.self, name: "config.json"))
    }
}

final class GestureTests: XCTestCase {
    private func touches(_ x: Double, _ y: Double, count: Int = 3) -> [TouchSample] { (0..<count).map { TouchSample(id: String($0), x: x, y: y) } }
    func testDirectionOneShotAndFrozenTarget() {
        var r = SwipeRecognizer()
        XCTAssertNil(r.feed(touches(0,0), modifiers: 4, displayID: "a", threshold: 0.05, invert: false))
        let swipe = r.feed(touches(0.08,0), modifiers: 0, displayID: "b", threshold: 0.05, invert: false)
        XCTAssertEqual(swipe?.direction, .right); XCTAssertEqual(swipe?.modifiers, 4); XCTAssertEqual(swipe?.displayID, "a")
        XCTAssertNil(r.feed(touches(0.2,0), modifiers: 0, displayID: "a", threshold: 0.05, invert: false))
        _ = r.feed([], modifiers: 0, displayID: nil, threshold: 0.05, invert: false)
        _ = r.feed(touches(0,0), modifiers: 0, displayID: "a", threshold: 0.05, invert: false)
        XCTAssertEqual(r.feed(touches(0,-0.08), modifiers: 0, displayID: "a", threshold: 0.05, invert: false)?.direction, .down)
    }
    func testDiagonalFingerChangeTwoFingerAndInvert() {
        var r = SwipeRecognizer()
        _ = r.feed(touches(0,0), modifiers: 0, displayID: nil, threshold: 0.05, invert: false)
        XCTAssertNil(r.feed(touches(0.08,0.08), modifiers: 0, displayID: nil, threshold: 0.05, invert: false))
        XCTAssertNil(r.feed(touches(0.2,0.08,count: 4), modifiers: 0, displayID: nil, threshold: 0.05, invert: false))
        r.reset()
        _ = r.feed(touches(0,0,count: 2), modifiers: 0, displayID: nil, threshold: 0.05, invert: false)
        XCTAssertNil(r.feed(touches(0.2,0,count: 2), modifiers: 0, displayID: nil, threshold: 0.05, invert: false))
        r.reset()
        _ = r.feed(touches(0,0,count: 4), modifiers: 0, displayID: nil, threshold: 0.05, invert: true)
        XCTAssertEqual(r.feed(touches(0,0.08,count: 4), modifiers: 0, displayID: nil, threshold: 0.05, invert: true)?.direction, .down)
    }
    func testStaggeredFingerLandingStillRecognizesFourFingers() {
        var r = SwipeRecognizer()
        _ = r.feed(touches(0,0,count: 1), modifiers: 4, displayID: "original", threshold: 0.05, invert: false)
        _ = r.feed(touches(0,0,count: 3), modifiers: 0, displayID: "other", threshold: 0.05, invert: false)
        _ = r.feed(touches(0,0,count: 4), modifiers: 0, displayID: "other", threshold: 0.05, invert: false)
        let swipe = r.feed(touches(0.08,0,count: 4), modifiers: 0, displayID: "other", threshold: 0.05, invert: false)
        XCTAssertEqual(swipe?.fingers, 4)
        XCTAssertEqual(swipe?.modifiers, 4)
        XCTAssertEqual(swipe?.displayID, "original")
    }
}
