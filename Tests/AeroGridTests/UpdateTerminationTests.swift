import Foundation
import XCTest
@testable import AeroGrid

final class UpdateTerminationTests: XCTestCase {
    func testReadyUpdateTerminatesThroughAppKitWithoutBlockingItsShutdownReply() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AeroGrid")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("update-termination-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("report.json")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--verify-update-termination", report.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            process.terminate(); process.waitUntilExit()
            XCTFail("The updater deadlocked instead of completing AppKit's deferred termination")
            return
        }
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: report))
        XCTAssertEqual(result["installAuthorized"], true)
        XCTAssertEqual(result["cancelRequested"], false)
        XCTAssertEqual(result["usesRealAppKitTermination"], true)
        XCTAssertEqual(result["usesLiveBackend"], false)
        XCTAssertEqual(result["writesUserState"], false)
    }
}
