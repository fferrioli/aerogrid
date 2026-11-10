import AppKit
import XCTest
@testable import AeroGrid

@MainActor final class UpdateShutdownTests: XCTestCase {
    private func job(in home: URL, approved: Bool = true) throws -> URL {
        let job = home.appendingPathComponent("Library/Application Support/AeroGrid/updates/test-job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["controllerPID": 100, "revision": String(repeating: "a", count: 40)])
            .write(to: job.appendingPathComponent("request.json"))
        if approved { try Data().write(to: job.appendingPathComponent("install")) }
        return job
    }
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("update-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    func testNormalQuitTargetsOnlyBothInstalledOwnedBundles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let job = try job(in: home)
        var stopped = Set<String>()
        let targets = [("AeroGrid.app", "local.AeroGrid"), ("AeroGrid Backend.app", "local.AeroGrid.Backend")]
        var apps = targets.map { name, identifier in
            UpdateShutdown.Application(bundleURL: home.appendingPathComponent("Applications/\(name)"), identifier: identifier,
                terminate: { stopped.insert(name); return true }, isTerminated: { stopped.contains(name) })
        }
        apps.append(UpdateShutdown.Application(bundleURL: home.appendingPathComponent("backups/AeroGrid.app"), identifier: "local.AeroGrid",
            terminate: { XCTFail("Must not quit an app from a backup"); return false }, isTerminated: { false }))
        apps.append(UpdateShutdown.Application(bundleURL: home.appendingPathComponent("Applications/AeroGrid Backend.app"), identifier: "bobko.aerospace",
            terminate: { XCTFail("Must not quit standalone AeroSpace"); return false }, isTerminated: { false }))
        try UpdateShutdown.run(job: job, home: home, applications: apps)
        XCTAssertEqual(stopped, Set(targets.map(\.0)))
    }
    func testMissingApprovalOrForeignJobNeverRequestsQuit() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let unapproved = try job(in: home, approved: false)
        let app = UpdateShutdown.Application(bundleURL: home.appendingPathComponent("Applications/AeroGrid.app"), identifier: "local.AeroGrid",
            terminate: { XCTFail("No quit before valid handoff"); return false }, isTerminated: { false })
        XCTAssertThrowsError(try UpdateShutdown.run(job: unapproved, home: home, applications: [app]))
        try Data().write(to: unapproved.appendingPathComponent("install"))
        XCTAssertThrowsError(try UpdateShutdown.run(job: unapproved, home: home.appendingPathComponent("other-home"), applications: [app]))
    }
    func testMalformedRequestNeverRequestsQuit() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let job = try job(in: home)
        try JSONSerialization.data(withJSONObject: ["controllerPID": 0, "revision": "main"])
            .write(to: job.appendingPathComponent("request.json"))
        let app = UpdateShutdown.Application(bundleURL: home.appendingPathComponent("Applications/AeroGrid.app"), identifier: "local.AeroGrid",
            terminate: { XCTFail("No quit for malformed request"); return false }, isTerminated: { false })
        XCTAssertThrowsError(try UpdateShutdown.run(job: job, home: home, applications: [app]))
    }
    func testDeclinedOrUnfinishedQuitReturnsBoundedFailure() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let job = try job(in: home)
        for acceptsQuit in [false, true] {
            var requests = 0
            let app = UpdateShutdown.Application(bundleURL: home.appendingPathComponent("Applications/AeroGrid Backend.app"), identifier: "local.AeroGrid.Backend",
                terminate: { requests += 1; return acceptsQuit }, isTerminated: { false })
            XCTAssertThrowsError(try UpdateShutdown.run(job: job, home: home, timeout: 0, applications: [app]))
            XCTAssertEqual(requests, 1)
        }
    }
}
