import XCTest
@testable import GridCore

final class AppRelaunchTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var processes: Set<Int32> = [10, 20]
    private let original = WindowInfo(id: 1, pid: 10, workspace: "home", bundleID: "test.editor")
    private let neighbor = WindowInfo(id: 2, pid: 20, workspace: "launch", bundleID: "test.neighbor")
    private let laptop = Display(id: "laptop", monitor: 1, name: "Laptop", builtin: true, width: 1710, height: 1073)

    private func fixture(
        fullscreen: Bool = false, shared: Bool = false
    ) throws -> (DynamicEngine, MapBackend) {
        let config = Configuration(backendPath: "/unused")
        var map = SpaceMap(configuration: config)
        map.version = 3
        map.spaces = [
            Space(id: "home", name: "Home", row: 0, column: 0, workspace: original.workspace,
                  preferredRole: shared ? "external" : "builtin"),
            Space(id: "launch", name: "Launch", row: 0, column: 1, workspace: neighbor.workspace,
                  preferredRole: "builtin")
        ]
        var state = RuntimeState()
        state.dynamicMap = map
        let backend = MapBackend(Desktop(displays: [laptop], visible: [1: neighbor.workspace], focusedMonitor: 1))
        var window = original
        window.nativeFullscreen = fullscreen
        window.nativeSpace = fullscreen ? "fullscreen" : "normal"
        let members = shared ? [WindowInfo(id: 3, pid: 20, workspace: "home", bundleID: "test.shared"), neighbor] : [neighbor]
        backend.setWindows(members + [window])
        let engine = try DynamicEngine(configuration: config, state: state, backend: backend,
                                       isProcessAlive: { self.processes.contains($0) }, now: { self.clock })
        try engine.refresh()
        backend.windowMoves.removeAll()
        _ = engine.consumeDiagnosticEvents()
        return (engine, backend)
    }

    private func replacement(workspace: String = "launch", nativeSpace: String = "normal") -> WindowInfo {
        WindowInfo(id: 11, pid: 11, workspace: workspace, bundleID: original.bundleID,
                   nativeMonitor: 1, nativeSpace: nativeSpace)
    }

    private func removeOriginal(from backend: MapBackend, processExited: Bool = true) {
        if processExited { processes.remove(original.pid) }
        backend.setWindows(backend.screen.windows!.filter { $0.id != original.id })
    }

    private func open(_ window: WindowInfo, on backend: MapBackend) {
        processes.insert(window.pid)
        backend.setWindows(backend.screen.windows! + [window])
    }

    func testWindowDisappearsDuringUpdateThenReturnsToItsDormantCard() throws {
        let (engine, backend) = try fixture()
        let saved = try XCTUnwrap(engine.map.spaces.first { $0.id == "home" })
        removeOriginal(from: backend, processExited: false)
        try engine.refresh()
        XCTAssertTrue(engine.map.spaces.first { $0.id == saved.id }?.isDormant == true)

        clock.addTimeInterval(36)
        processes.remove(original.pid)
        open(replacement(), on: backend)
        try engine.refresh()

        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == saved.id })
        XCTAssertEqual(restored.rect, saved.rect)
        XCTAssertEqual(restored.foldedRect, saved.foldedRect)
        XCTAssertEqual(try backend.windows(workspace: "home"), [11])
        XCTAssertEqual(try backend.windows(workspace: "launch"), [2])
        XCTAssertTrue(backend.activations.isEmpty)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .placeRelaunched && $0.space == saved.id })
        try engine.refresh()
        XCTAssertEqual(backend.windowMoves, [11])
    }

    func testWindowedReplacementOfSharedFullscreenReusesCardBeforeLaptopFolding() throws {
        let (engine, backend) = try fixture(fullscreen: true, shared: true)
        let oldLink = try XCTUnwrap(engine.map.fullscreens.first)
        let saved = try XCTUnwrap(engine.map.spaces.first { $0.id == oldLink.spaceID })
        removeOriginal(from: backend)
        try engine.refresh()
        XCTAssertFalse(engine.map.spaces.contains { $0.id == saved.id })

        open(replacement(workspace: "home"), on: backend)
        try engine.refresh()

        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == saved.id })
        XCTAssertNil(restored.nativeWindow)
        XCTAssertEqual(restored.rect, saved.rect)
        XCTAssertEqual(restored.foldedRect, saved.foldedRect)
        XCTAssertNotEqual(restored.workspace, "home")
        XCTAssertEqual(try backend.windows(workspace: restored.workspace), [11])
        XCTAssertEqual(try backend.windows(workspace: "home"), [3])
        XCTAssertTrue(engine.map.families.isEmpty)
        XCTAssertEqual(engine.map.spaces.count, 3)
        XCTAssertEqual(backend.windowMoves, [11])
        try engine.map.validate()
    }

    func testNativeFullscreenReplacementReusesCardAndHomeUsingNativeEvidence() throws {
        let (engine, backend) = try fixture(fullscreen: true, shared: true)
        let oldLink = try XCTUnwrap(engine.map.fullscreens.first)
        let saved = try XCTUnwrap(engine.map.spaces.first { $0.id == oldLink.spaceID })
        removeOriginal(from: backend)
        // The whole update can also occur between samples.
        open(replacement(workspace: "temporary-launch", nativeSpace: "fullscreen"), on: backend)
        try engine.refresh()

        let restored = try XCTUnwrap(engine.map.spaces.first { $0.id == saved.id })
        XCTAssertEqual(restored.rect, saved.rect)
        XCTAssertEqual(restored.foldedRect, saved.foldedRect)
        XCTAssertEqual(restored.nativeWindow, replacement().identity)
        XCTAssertEqual(engine.map.fullscreens.first?.homeID, oldLink.homeID)
        XCTAssertEqual(try backend.windows(workspace: "home").sorted(), [3, 11])
        XCTAssertFalse(engine.map.spaces.contains { $0.workspace == "temporary-launch" })
        XCTAssertTrue((engine.map.fullscreenPlaces ?? []).isEmpty)
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .placeRelaunched && $0.reason == "fullscreen" })
        try engine.map.validate()
    }

    func testReplacementAfterEmptyInventoryStillReturns() throws {
        let (engine, backend) = try fixture()
        backend.setWindows([])
        processes.remove(original.pid)
        try engine.refresh()
        open(replacement(), on: backend)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: "home"), [11])
    }

    func testMultiwindowOldProcessDoesNotMatchItsLastClosingWindow() throws {
        let (engine, backend) = try fixture()
        open(WindowInfo(id: 12, pid: original.pid, workspace: "home", bundleID: original.bundleID), on: backend)
        try engine.refresh()
        backend.setWindows(backend.screen.windows!.filter { $0.id != 12 })
        try engine.refresh()
        removeOriginal(from: backend)
        open(replacement(), on: backend)
        try engine.refresh()
        XCTAssertEqual(try backend.windows(workspace: "launch").sorted(), [2, 11])
        XCTAssertTrue(backend.windowMoves.isEmpty)
    }

    func testRulesExpiryOtherBootsAndStillRunningOwnersTakePrecedence() throws {
        for scenario in ["ruled", "expired", "different boot", "alive", "multiple replacements"] {
            clock = Date(timeIntervalSince1970: 1_800_000_000)
            processes = [10, 20]
            let (engine, backend) = try fixture()
            removeOriginal(from: backend, processExited: scenario != "alive")
            try engine.refresh()

            var window = replacement()
            if scenario == "ruled" { window.ruled = true }
            if scenario == "expired" { clock.addTimeInterval(120) }
            if scenario == "different boot" { window.boot = "after-reboot" }
            if scenario == "multiple replacements" {
                open(WindowInfo(id: 13, pid: window.pid, workspace: window.workspace, bundleID: window.bundleID), on: backend)
            }
            open(window, on: backend)
            try engine.refresh()
            XCTAssertTrue(backend.windowMoves.isEmpty, scenario)
        }
    }

    func testFailedMoveDoesNotCreateACardOrRetryAgainstTheSameWindow() throws {
        let (engine, backend) = try fixture(fullscreen: true, shared: true)
        let cardID = try XCTUnwrap(engine.map.fullscreens.first?.spaceID)
        removeOriginal(from: backend)
        open(replacement(), on: backend)
        backend.failWindow = 11
        try engine.refresh()
        XCTAssertFalse(engine.map.spaces.contains { $0.id == cardID })
        XCTAssertTrue(engine.consumeDiagnosticEvents().contains { $0.kind == .placeRelaunchFailed })
        backend.failWindow = nil
        try engine.refresh()
        XCTAssertEqual(backend.windowMoves, [11])
        XCTAssertEqual(try backend.windows(workspace: "launch").sorted(), [2, 11])
    }
}
