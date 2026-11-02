import AppKit
import Combine
import GridCore
import XCTest
@testable import AeroGrid

@MainActor final class IdlePerformanceTests: XCTestCase {
    func model() throws -> AppModel {
        let config = Configuration(backendPath: "/usr/bin/false")
        let display = Display(id: "idle-test", monitor: 1, name: "Test", builtin: false, width: 3440, height: 1440)
        var desktop = Desktop(displays: [display], visible: [1:config.grids[1].cells[4].workspace], focusedMonitor: 1)
        desktop.nativeVisible = [:]
        desktop.windows = [WindowInfo(id: 1, workspace: config.grids[1].cells[4].workspace)]
        return try AppModel(preview: desktop, previewConfiguration: config)
    }
    func waitForWork(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.hasPendingWork { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Preview refresh failed to finish")
    }
    func testRepeatedUnchangedPollsAndCancellationsDoNotInvalidateUI() async throws {
        let model = try model()
        defer { model.stop(); try? FileManager.default.removeItem(at: model.directory) }
        model.refresh(); try await waitForWork(model)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<12 {
            model.refresh(); try await waitForWork(model)
            model.handleContact(.cancelled)
        }
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(model.inputReady) // The fixture never installed an event tap.
        model.focusWindow(WindowIdentity(id: 1, pid: 1, boot: "test"))
        try await waitForWork(model)
        XCTAssertEqual(model.desktop?.focusedWindow, 1)
        XCTAssertGreaterThan(publications, 0, "Real changes must still reach the UI")
    }
    func testClosedSettingsDetachHostingGraphAndCanReopen() throws {
        _ = NSApplication.shared
        let model = try model()
        defer { model.stop(); try? FileManager.default.removeItem(at: model.directory) }
        let delegate = ApplicationDelegate(); delegate.model = model
        delegate.openSettings()
        let first = try XCTUnwrap(NSApp.windows.first { $0.title == "AeroGrid Settings" && $0.isVisible })
        XCTAssertNotNil(first.contentView)
        first.close()
        XCTAssertNil(first.contentView)
        delegate.openSettings()
        let second = try XCTUnwrap(NSApp.windows.first { $0.title == "AeroGrid Settings" && $0.isVisible })
        XCTAssertFalse(first === second)
        XCTAssertNotNil(second.contentView)
        second.close()
    }
    func testReleaseTimerRunsOnlyForCorroboratedPartialLiftAndStopsAfterSettlement() async throws {
        let input = GestureInput(configuration: Configuration(backendPath: "/unused"))
        defer { input.stop() }
        func contacts(_ phases: [TouchPhase], x: Double) -> [TouchContact] {
            phases.enumerated().map { TouchContact(sample: TouchSample(id: String($0.offset), x: x, y: 0.5), phase: $0.element) }
        }
        let time = ProcessInfo.processInfo.systemUptime - 0.1
        XCTAssertFalse(input.hasSettlementTimer)
        _ = input.recognizeContacts(contacts([.began,.began,.began], x: 0.2), displayID: "test", timestamp: time)
        let moved = input.recognizeContacts(contacts([.moved,.moved,.moved], x: 0.3), displayID: "test", timestamp: time + 0.02)
        XCTAssertTrue(moved.contains { if case .step = $0 { return true }; return false })
        XCTAssertFalse(input.hasSettlementTimer, "A held gesture needs no release timer")
        _ = input.recognizeContacts(contacts([.ended,.ended], x: 0.3), displayID: "test", timestamp: time + 0.04)
        XCTAssertFalse(input.hasSettlementTimer, "Partial lift alone must not become a timeout commit")
        let ended = expectation(description: "Missing final lift settles exactly once")
        var ends = 0
        input.onContact = { event in if case .ended = event { ends += 1; ended.fulfill() } }
        _ = input.recognizeContacts([], ended: true, displayID: "test", timestamp: time + 0.06)
        XCTAssertTrue(input.hasSettlementTimer)
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(input.hasSettlementTimer)
        input.reset()
        XCTAssertFalse(input.hasSettlementTimer)
    }
}
