import Foundation
import XCTest
@testable import AeroGrid

final class BufferedLogTests: XCTestCase {
    func testRotationReadsNewFileSizeInsteadOfCachedResourceValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.log")
        try Data(repeating: 65, count: 1024).write(to: url)
        let log = BufferedLog(url: url, limit: 512)
        for index in 0..<4 { log.text("entry-\(index)"); log.flush() }
        let current = try String(contentsOf: url, encoding: .utf8)
        for index in 0..<4 { XCTAssertTrue(current.contains("entry-\(index)")) }
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("previous")).count, 1024)
    }
    func testRotationStillKeepsThePreviousBatchWhenTheActualLimitIsReached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.log")
        let log = BufferedLog(url: url, limit: 512)
        for index in 0..<3 { log.text("entry-\(index) " + String(repeating: "x", count: 180)); log.flush() }
        let previous = try String(contentsOf: url.appendingPathExtension("previous"), encoding: .utf8)
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(previous.contains("entry-0")); XCTAssertTrue(previous.contains("entry-1"))
        XCTAssertFalse(current.contains("entry-0")); XCTAssertTrue(current.contains("entry-2"))
    }
}
