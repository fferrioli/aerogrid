import Foundation
import GridCore
import XCTest
@testable import AeroGrid

final class DiagnosticHistoryTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("diagnostics") }
    private var file: URL { directory.appendingPathComponent("history.jsonl") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func records(_ url: URL? = nil) throws -> [[String: Any]] {
        try String(contentsOf: url ?? file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testPersistentDefaultOnAndRuntimeOptOutStartAndStopTheSameRecorder() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = DiagnosticsPreference(defaults: defaults)
        XCTAssertTrue(preference.enabled)
        preference.setEnabled(false)
        let reopened = DiagnosticsPreference(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertFalse(reopened.enabled)

        let history = DiagnosticHistory(directory: directory, enabled: reopened.enabled)
        history.event("test", ["event": "before-enable"])
        history.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        history.setEnabled(true)
        history.observe(.backend, .unavailableBackend)
        history.flush()
        let before = try Data(contentsOf: file)
        history.setEnabled(false)
        history.event("test", ["event": "disabled"])
        history.observe(.backend, .unavailableBackend)
        history.flush()
        XCTAssertEqual(try Data(contentsOf: file), before)
        history.setEnabled(true)
        history.observe(.backend, .unavailableBackend)
        history.flush()
        let rows = try records()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { ($0["payload"] as? [String: Any])?["mode"] as? String }, ["checkpoint", "checkpoint"])
    }

    func testSnapshotsOmitUnchangedSamplesAndUseExactDeltaBases() throws {
        let history = DiagnosticHistory(directory: directory, enabled: true, checkpointInterval: 10)
        var snapshot = DiagnosticSnapshot.unavailableBackend
        let operation = UUID()
        history.observe(.backend, snapshot, uptime: 1)
        history.observe(.backend, snapshot, uptime: 2)
        history.observe(.map, DiagnosticSnapshot(), uptime: 2)
        snapshot = DiagnosticSnapshot()
        history.observe(.backend, snapshot, operation: operation, uptime: 3)
        history.observe(.backend, snapshot, uptime: 11)
        history.flush()

        let rows = try records()
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, [1, 2, 3, 4])
        XCTAssertEqual(rows.compactMap { $0["kind"] as? String }, ["backend", "map", "backend", "backend"])
        let delta = try XCTUnwrap(rows[2]["payload"] as? [String: Any])
        XCTAssertEqual(delta["base"] as? Int, 1)
        XCTAssertEqual(delta["removed"] as? [String: [String]], ["summary": ["backend"]])
        XCTAssertEqual(rows[2]["operation"] as? String, operation.uuidString)
        XCTAssertEqual((rows[3]["payload"] as? [String: Any])?["mode"] as? String, "checkpoint")
    }

    func testPrivateBoundedFilesRecoverAfterPartialWriteAndNeverFollowSymlinks() throws {
        let limit = 1_024
        let first = DiagnosticHistory(directory: directory, enabled: true, limit: limit)
        for index in 0..<40 { first.event("test", ["index": index]) }
        first.flush()
        let previous = file.appendingPathExtension("previous")
        for url in [file, previous] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, limit)
            XCTAssertFalse(try records(url).isEmpty)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)

        try Data("{\"committed\":true}\n{\"partial\":".utf8).write(to: file)
        let restarted = DiagnosticHistory(directory: directory, enabled: true)
        restarted.event("test", ["event": "after-restart"])
        restarted.flush()
        XCTAssertEqual(try records().count, 2)
        XCTAssertEqual(try records().last?["kind"] as? String, "test")

        let foreign = root.appendingPathComponent("unchanged")
        let marker = Data("unchanged".utf8)
        try marker.write(to: foreign)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: foreign)
        let redirected = DiagnosticHistory(directory: directory, enabled: true)
        redirected.event("test", ["event": "must-not-write"])
        redirected.flush()
        XCTAssertEqual(try Data(contentsOf: foreign), marker)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), foreign.path)
    }

    func testRotationForcesCheckpointOnNextUnchangedObservation() throws {
        let history = DiagnosticHistory(directory: directory, enabled: true, limit: 550)
        history.observe(.backend, .unavailableBackend, uptime: 5)
        history.event("test", ["padding": String(repeating: "p", count: 260)])
        history.observe(.backend, .unavailableBackend, uptime: 6)
        history.flush()

        let current = try records()
        XCTAssertEqual(current.last?["sequence"] as? Int, 3)
        XCTAssertEqual((current.last?["payload"] as? [String: Any])?["mode"] as? String, "checkpoint")
        XCTAssertFalse(try records(file.appendingPathExtension("previous")).isEmpty)
    }

    func testBackendStatusRequestsPlacementOnlyWhenOnAndHandlesRejectionAndMalformedEvidence() throws {
        let executable = root.appendingPathComponent("mock-backend")
        let response = root.appendingPathComponent("response")
        let flags = root.appendingPathComponent("flags")
        try Data("""
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            printf '%s\\n' "$*" >> flags
            if [ -f reject ]; then
                printf 'Cannot match native display. PRIVATE_PATH\\n' >&2
                exit 1
            fi
            cat response
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let validDesktop = """
            {"displays":[],"visible":{},"focusedMonitor":1,"windows":[],"placementDiagnostics":{"windows":"unexpected value"}}
            """
        try Data(validDesktop.utf8).write(to: response)
        let backend = AeroSpaceBackend(path: executable.path)
        let history = DiagnosticHistory(directory: directory, enabled: true)
        backend.diagnosticHistory = history
        XCTAssertEqual(try backend.desktop().windows, [])
        try Data().write(to: root.appendingPathComponent("reject"))
        XCTAssertThrowsError(try backend.desktop())
        XCTAssertThrowsError(try backend.desktop())
        history.flush()
        let rows = try records()
        XCTAssertEqual(rows.compactMap { $0["kind"] as? String }, ["backend", "command", "backend"])
        let failure = try XCTUnwrap(rows[1]["payload"] as? [String: Any])
        XCTAssertEqual(failure["outcome"] as? String, "nativeUnavailable")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE_PATH"))
        let withoutPlacement = try XCTUnwrap(rows[0]["payload"] as? [String: Any])
        let tables = try XCTUnwrap(withoutPlacement["rows"] as? [String: [String: [String: Any]]])
        XCTAssertEqual(tables["summary"]?["backend"]?["placement"] as? String, "unavailable")

        history.setEnabled(false)
        try FileManager.default.removeItem(at: root.appendingPathComponent("reject"))
        XCTAssertEqual(try backend.desktop().windows, [])
        history.flush()
        XCTAssertEqual(try records().count, 3)
        XCTAssertEqual(try String(contentsOf: flags, encoding: .utf8).split(separator: "\n").last, "grid-layout status")
    }
}
