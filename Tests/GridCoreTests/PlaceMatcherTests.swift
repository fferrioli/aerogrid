import XCTest
@testable import GridCore

final class PlaceMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func slot(_ bundle: String = "app.a", _ ordinal: Int = 0) -> TemplateSlot {
        TemplateSlot(bundleID: bundle, ordinal: ordinal)
    }

    private func candidate(_ id: UInt32, _ workspace: String = "elsewhere", bundle: String = "app.a", pid: Int32 = 1) -> CandidateWindow {
        CandidateWindow(identity: WindowIdentity(id: id, pid: pid, boot: "current"), bundleID: bundle, workspace: workspace)
    }

    private func target(_ space: String, _ slots: [TemplateSlot]) -> PlaceTarget {
        PlaceTarget(spaceID: space, workspace: "ws-\(space)", template: PlaceTemplate(
            tree: TemplateNode(orientation: "h", layout: "tiles", children: slots.map { TemplateNode(slot: $0) }),
            capturedAt: now
        ))
    }

    private func assignment(_ candidate: CandidateWindow, _ space: String, _ slot: TemplateSlot, fullscreen: Bool = false) -> PlaceAssignment {
        PlaceAssignment(window: candidate.identity, spaceID: space, slot: slot, fullscreen: fullscreen)
    }

    func testCaptureAssignsOrdinalsInDepthFirstThenFloatingOrder() throws {
        let snapshot = LayoutSnapshot(boot: "old", tree: .root([
            LayoutNode(id: 30, pid: 3, weight: 2),
            LayoutNode(weight: 3, orientation: "v", layout: "accordion", children: [
                LayoutNode(id: 10, pid: 1, weight: 4),
                LayoutNode(id: 20, pid: 2, weight: 5)
            ])
        ]), floating: [FloatingLayout(id: 40, pid: 4, x: 12, y: 34, width: 560, height: 780)])
        let windows = [
            WindowInfo(id: 10, pid: 1, workspace: "w", bundleID: "app.b"),
            WindowInfo(id: 20, pid: 2, workspace: "w", bundleID: "app.a"),
            WindowInfo(id: 30, pid: 3, workspace: "w", bundleID: "app.a"),
            WindowInfo(id: 40, pid: 4, workspace: "w", bundleID: "app.a")
        ]
        let captured = try XCTUnwrap(PlaceTemplate.capture(snapshot: snapshot, windows: windows, now: now))
        XCTAssertEqual(captured.version, 1)
        XCTAssertEqual(captured.capturedAt, now)
        XCTAssertNil(captured.fullscreen)
        XCTAssertEqual(captured.slots, [slot(), slot("app.b"), slot("app.a", 1), slot("app.a", 2)])
        XCTAssertEqual(captured.tree, TemplateNode(orientation: "h", layout: "tiles", children: [
            TemplateNode(weight: 2, slot: slot()),
            TemplateNode(weight: 3, orientation: "v", layout: "accordion", children: [
                TemplateNode(weight: 4, slot: slot("app.b")),
                TemplateNode(weight: 5, slot: slot("app.a", 1))
            ])
        ]))
        XCTAssertEqual(captured.floating, [TemplateFloating(slot: slot("app.a", 2), x: 12, y: 34, width: 560, height: 780)])
        XCTAssertEqual(try JSONDecoder().decode(PlaceTemplate.self, from: JSONEncoder().encode(captured)), captured)
    }

    func testCaptureOmitsUnknownOrBundlelessLeavesAndPrunesEmptyContainers() throws {
        let snapshot = LayoutSnapshot(boot: "old", tree: .root([
            LayoutNode(orientation: "v", layout: "tiles", children: [
                LayoutNode(id: 1, pid: 1), // Empty bundle.
                LayoutNode(id: 2, pid: 2), // Reused window ID, different PID.
                LayoutNode(id: 3, pid: 3), // Unknown window.
                LayoutNode(id: 4) // Missing PID.
            ]),
            LayoutNode(id: 5, pid: 5, weight: 7)
        ]), floating: [FloatingLayout(id: 6, pid: 6, x: 0, y: 0, width: 10, height: 10)])
        let windows = [
            WindowInfo(id: 1, pid: 1, workspace: "w", bundleID: ""),
            WindowInfo(id: 2, pid: 99, workspace: "w", bundleID: "app.a"),
            WindowInfo(id: 4, pid: 4, workspace: "w", bundleID: "app.a"),
            WindowInfo(id: 5, pid: 5, workspace: "w", bundleID: "app.a"),
            WindowInfo(id: 6, pid: 6, workspace: "w", bundleID: "")
        ]
        let captured = try XCTUnwrap(PlaceTemplate.capture(snapshot: snapshot, windows: windows, now: now))
        XCTAssertEqual(captured.tree.children, [TemplateNode(weight: 7, slot: slot())])
        XCTAssertEqual(captured.slots, [slot()])
        XCTAssertTrue(captured.floating.isEmpty)
    }

    func testCaptureReturnsNilWithoutKnownLeaves() {
        for tree in [LayoutNode.root([]), LayoutNode.root([LayoutNode(id: 1, pid: 1)])] {
            XCTAssertNil(PlaceTemplate.capture(snapshot: LayoutSnapshot(boot: "old", tree: tree), windows: [], now: now))
        }
    }

    func testInstantiatePreservesStructureAndGeometryWithNewIdentities() throws {
        let snapshot = LayoutSnapshot(boot: "old", tree: .root([
            LayoutNode(weight: 2, orientation: "v", layout: "accordion", children: [LayoutNode(id: 1, pid: 1, weight: 3)]),
            LayoutNode(id: 2, pid: 2, weight: 4)
        ]), floating: [FloatingLayout(id: 3, pid: 3, x: -20, y: 10, width: 400, height: 300)])
        let windows = (1...3).map { WindowInfo(id: UInt32($0), pid: Int32($0), workspace: "w", bundleID: "app.a") }
        let captured = try XCTUnwrap(PlaceTemplate.capture(snapshot: snapshot, windows: windows, now: now))
        let current = (11...13).map { candidate(UInt32($0), pid: Int32($0)).identity }
        let restored = try XCTUnwrap(captured.instantiate(Dictionary(uniqueKeysWithValues: zip(captured.slots, current)), boot: "current"))
        XCTAssertEqual(restored, LayoutSnapshot(boot: "current", tree: .root([
            LayoutNode(weight: 2, orientation: "v", layout: "accordion", children: [LayoutNode(id: 11, pid: 11, weight: 3)]),
            LayoutNode(id: 12, pid: 12, weight: 4)
        ]), floating: [FloatingLayout(id: 13, pid: 13, x: -20, y: 10, width: 400, height: 300)]))
        XCTAssertEqual(PlaceTemplate.capture(snapshot: restored, windows: (11...13).map {
            WindowInfo(id: UInt32($0), pid: Int32($0), boot: "current", workspace: "w", bundleID: "app.a")
        }, now: now), captured)
    }

    func testInstantiatePrunesMissingSlotsIncludingEntireContainers() throws {
        let template = PlaceTemplate(tree: TemplateNode(orientation: "h", layout: "tiles", children: [
            TemplateNode(orientation: "v", layout: "accordion", children: [TemplateNode(slot: slot())]),
            TemplateNode(weight: 3, slot: slot("app.a", 1))
        ]), floating: [TemplateFloating(slot: slot("app.b"), x: 1, y: 2, width: 3, height: 4)], capturedAt: now)
        let window = candidate(20).identity
        XCTAssertEqual(template.instantiate([slot("app.a", 1): window], boot: "current"),
                       LayoutSnapshot(boot: "current", tree: .root([LayoutNode(id: 20, pid: 1, weight: 3)])))
        XCTAssertNil(template.instantiate([:], boot: "current"))
        let floatingOnly = try XCTUnwrap(template.instantiate([slot("app.b"): window], boot: "current"))
        XCTAssertTrue(floatingOnly.tree.ids.isEmpty)
        XCTAssertEqual(floatingOnly.floating, [FloatingLayout(id: 20, pid: 1, x: 1, y: 2, width: 3, height: 4)])
    }

    func testCaptureAndInstantiateFloatingOnly() throws {
        let snapshot = LayoutSnapshot(boot: "current", tree: .root([], orientation: "v"), floating: [
            FloatingLayout(id: 1, pid: 1, x: 5, y: 6, width: 7, height: 8)
        ])
        let template = try XCTUnwrap(PlaceTemplate.capture(snapshot: snapshot, windows: [
            WindowInfo(id: 1, workspace: "w", bundleID: "app.a")
        ], now: now))
        XCTAssertEqual(template.slots, [slot()])
        XCTAssertEqual(template.instantiate([slot(): candidate(1).identity], boot: "current"), snapshot)
    }

    func testFullscreenTemplateAndInstantiation() throws {
        let template = PlaceTemplate.fullscreen(slot: slot(), capturedAt: now)
        XCTAssertEqual(template.slots, [slot()])
        XCTAssertEqual(template.capturedAt, now)
        XCTAssertEqual(template.fullscreen, slot())
        XCTAssertNil(template.tree.slot)
        XCTAssertTrue((template.tree.children ?? []).isEmpty)
        XCTAssertTrue(template.floating.isEmpty)
        XCTAssertNil(template.instantiate([:], boot: "current"))
        let restored = try XCTUnwrap(template.instantiate([slot(): candidate(8).identity], boot: "current"))
        XCTAssertEqual(restored.boot, "current")
        XCTAssertEqual(restored.tree.ids, [8])
    }

    func testSlotsTraverseTreeThenFloatingThenFullscreen() {
        let template = PlaceTemplate(tree: TemplateNode(children: [TemplateNode(slot: slot())]), floating: [
            TemplateFloating(slot: slot("app.a", 1), x: 0, y: 0, width: 1, height: 1)
        ], fullscreen: slot("app.a", 2), capturedAt: now)
        XCTAssertEqual(template.slots, [slot(), slot("app.a", 1), slot("app.a", 2)])
    }

    func testAssignmentTable() {
        struct Case {
            let name: String
            let candidates: [CandidateWindow]
            let targets: [PlaceTarget]
            var present: [CandidateWindow] = []
            let expected: [PlaceAssignment]
        }
        let first = candidate(10), second = candidate(20), third = candidate(30)
        let local = candidate(30, "ws-b")
        let occupied = candidate(5, "ws-a")
        let cases: [Case] = [
            Case(
                name: "one app across two spaces", candidates: [second, first],
                targets: [target("a", [slot()]), target("b", [slot()])],
                expected: [assignment(first, "a", slot()), assignment(second, "b", slot())]
            ),
            Case(
                name: "two slots sorted by ordinal", candidates: [second, first],
                targets: [target("a", [slot("app.a", 1), slot()])],
                expected: [assignment(first, "a", slot()), assignment(second, "a", slot("app.a", 1))]
            ),
            Case(
                name: "excess windows", candidates: [third, second, first],
                targets: [target("a", [slot()])], expected: [assignment(first, "a", slot())]
            ),
            Case(
                name: "excess slots", candidates: [first],
                targets: [target("a", [slot(), slot("app.a", 1)])], expected: [assignment(first, "a", slot())]
            ),
            Case(
                name: "present noncandidate covers lowest ordinal", candidates: [first],
                targets: [target("a", [slot("app.a", 1), slot()])], present: [occupied],
                expected: [assignment(first, "a", slot("app.a", 1))]
            ),
            Case(
                name: "occupied space produces no assignment", candidates: [first],
                targets: [target("a", [slot()])], present: [occupied], expected: []
            ),
            Case(
                name: "candidate keeps its destination", candidates: [first, local],
                targets: [target("a", [slot()]), target("b", [slot()])], present: [local],
                expected: [assignment(local, "b", slot()), assignment(first, "a", slot())]
            ),
            Case(
                name: "candidate in present is not counted twice", candidates: [candidate(10, "ws-a")],
                targets: [target("a", [slot()])], present: [candidate(10, "ws-a")],
                expected: [assignment(candidate(10, "ws-a"), "a", slot())]
            ),
            Case(
                name: "fullscreen", candidates: [first],
                targets: [PlaceTarget(spaceID: "f", workspace: "ws-f", template: .fullscreen(slot: slot(), capturedAt: now))],
                expected: [assignment(first, "f", slot(), fullscreen: true)]
            ),
            Case(
                name: "target order breaks tie", candidates: [first],
                targets: [target("b", [slot()]), target("a", [slot()])], expected: [assignment(first, "b", slot())]
            ),
            Case(
                name: "target order precedes ordinal", candidates: [first],
                targets: [target("a", [slot("app.a", 5)]), target("b", [slot()])],
                expected: [assignment(first, "a", slot("app.a", 5))]
            ),
            Case(
                name: "different bundles match independently", candidates: [first, candidate(1, bundle: "app.b")],
                targets: [target("a", [slot(), slot("app.b")])],
                expected: [assignment(first, "a", slot()), assignment(candidate(1, bundle: "app.b"), "a", slot("app.b"))]
            ),
            Case(
                name: "wrong bundle and workspace do not cover", candidates: [first],
                targets: [target("a", [slot()])], present: [candidate(1, "ws-a", bundle: "app.b"), candidate(2, "ws-b")],
                expected: [assignment(first, "a", slot())]
            ),
            Case(
                name: "duplicate candidates assigned once", candidates: [first, first],
                targets: [target("a", [slot(), slot("app.a", 1)])], expected: [assignment(first, "a", slot())]
            ),
            Case(
                name: "duplicate present window covers once", candidates: [first],
                targets: [target("a", [slot(), slot("app.a", 1)])], present: [occupied, occupied],
                expected: [assignment(first, "a", slot("app.a", 1))]
            ),
            Case(
                name: "identity includes pid", candidates: [first],
                targets: [target("a", [slot(), slot("app.a", 1)])], present: [candidate(10, "ws-a", pid: 2)],
                expected: [assignment(first, "a", slot("app.a", 1))]
            ),
            Case(
                name: "identity includes boot", candidates: [first],
                targets: [target("a", [slot(), slot("app.a", 1)])],
                present: [CandidateWindow(identity: WindowIdentity(id: 10, pid: 1, boot: "old"), bundleID: "app.a", workspace: "ws-a")],
                expected: [assignment(first, "a", slot("app.a", 1))]
            ),
            Case(name: "no candidates", candidates: [], targets: [target("a", [slot()])], expected: []),
            Case(name: "no targets", candidates: [first], targets: [], expected: [])
        ]
        for item in cases {
            let actual = PlaceMatcher.assign(candidates: item.candidates, targets: item.targets, present: item.present)
            XCTAssertEqual(actual, item.expected, item.name)
            XCTAssertEqual(PlaceMatcher.assign(candidates: item.candidates, targets: item.targets, present: item.present), actual, item.name)
            XCTAssertEqual(PlaceMatcher.assign(candidates: item.candidates.reversed(), targets: item.targets, present: item.present.reversed()), actual, item.name)
            XCTAssertEqual(Set(actual.map(\.window)).count, actual.count, item.name)
        }
    }
}
