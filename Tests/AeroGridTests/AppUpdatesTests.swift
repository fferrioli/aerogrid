import AppKit
import Combine
import XCTest
@testable import AeroGrid

private final class UpdateURLProtocol: URLProtocol {
    static var responses: [(Int, String)] = []
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (code, body) = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdateServiceTests: XCTestCase {
    let old = String(repeating: "a", count: 40)
    let new = String(repeating: "b", count: 40)
    func service(_ replies: [(Int, String)]) -> GitHubUpdateService {
        UpdateURLProtocol.responses = replies; UpdateURLProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateURLProtocol.self]
        return GitHubUpdateService(session: URLSession(configuration: config))
    }
    func commit(_ sha: String) -> String { "{\"sha\":\"\(sha)\",\"commit\":{\"message\":\"Improve AeroGrid\\nDetails\"}}" }
    func testCurrentRevisionNeedsOneReadOnlyRequest() async throws {
        let found = try await service([(200, commit(old))]).latest(after: old)
        XCTAssertNil(found)
        XCTAssertEqual(UpdateURLProtocol.requests.count, 1)
        XCTAssertEqual(UpdateURLProtocol.requests[0].url?.host, "api.github.com")
        XCTAssertEqual(UpdateURLProtocol.requests[0].httpMethod, "GET")
        XCTAssertNil(UpdateURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
    }
    func testOffersOnlyAnAheadRevisionAndUsesPinnedComparison() async throws {
        let found = try await service([(200, commit(new)), (200, "{\"status\":\"ahead\"}")]).latest(after: old)
        XCTAssertEqual(found, UpdateCandidate(revision: new, title: "Improve AeroGrid"))
        XCTAssertTrue(UpdateURLProtocol.requests[1].url!.path.hasSuffix("compare/\(old)...\(new)"))
        for status in ["behind", "identical", "diverged"] {
            let result = try await service([(200, commit(new)), (200, "{\"status\":\"\(status)\"}")]).latest(after: old)
            XCTAssertNil(result)
        }
    }
    func testInvalidRevisionAndHTTPFailureDoNotOfferAnUpdate() async {
        do { _ = try await service([(200, commit("bad/ref"))]).latest(after: old); XCTFail("Accepted malformed remote revision") } catch {}
        do { _ = try await service([(403, "{}")]).latest(after: old); XCTFail("Accepted rate limit response") } catch {}
        let noRequests = service([])
        do { _ = try await noRequests.latest(after: "main; command"); XCTFail("Accepted an unpinned local revision") } catch {}
        XCTAssertTrue(UpdateURLProtocol.requests.isEmpty)
    }
}

@MainActor final class AppUpdatesTests: XCTestCase {
    var directory: URL!
    var preferences: UserDefaults!
    var suite: String!
    let old = String(repeating: "a", count: 40)
    let new = String(repeating: "b", count: 40)
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "AeroGrid.UpdateTests.\(UUID().uuidString)"; preferences = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    func fixture(phase: String, revision: String? = nil) throws -> URL {
        let job = directory.appendingPathComponent("updates/test-job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["phase": phase, "message": "Fixture progress"]).write(to: job.appendingPathComponent("status.json"))
        preferences.set(job.path, forKey: "updates.job")
        preferences.set(try JSONEncoder().encode(UpdateCandidate(revision: revision ?? new, title: "Fixture update")), forKey: "updates.candidate")
        return job
    }
    func testAutomaticPreferenceAndKnownCandidateSurviveRelaunch() throws {
        preferences.set(false, forKey: "updates.automatic")
        preferences.set(try JSONEncoder().encode(UpdateCandidate(revision: new, title: "Update")), forKey: "updates.candidate")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertFalse(updates.automatic); XCTAssertTrue(updates.hasUpdate); XCTAssertTrue(updates.canInstall)
        updates.automatic = true
        XCTAssertTrue(preferences.bool(forKey: "updates.automatic"))
    }
    func testAlreadyInstalledCandidateDoesNotReappear() throws {
        preferences.set(try JSONEncoder().encode(UpdateCandidate(revision: old, title: "Old update")), forKey: "updates.candidate")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertFalse(updates.hasUpdate); XCTAssertFalse(updates.canInstall)
    }
    func testPreparingIsCancellableWithoutTouchingInstalledApps() throws {
        let job = try fixture(phase: "building")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertTrue(updates.canCancel); XCTAssertFalse(updates.canInstall)
        updates.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("cancel").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("install").path))
        updates.stop()
    }
    func testOnlyReadyJobCanHandOffAndQuitDoesNotCancelInstallation() throws {
        let job = try fixture(phase: "ready")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        try updates.handOff()
        XCTAssertEqual(updates.phase, .installing); XCTAssertFalse(updates.canCancel)
        updates.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("install").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("cancel").path))
        XCTAssertThrowsError(try updates.handOff())
    }
    func testFailedUpdateKeepsCandidateAndCompletedUpdateClearsIt() throws {
        let job = try fixture(phase: "failed")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertEqual(updates.phase, .failed); XCTAssertTrue(updates.canInstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("install").path))
        try JSONSerialization.data(withJSONObject: ["phase": "complete", "message": "Updated"]).write(to: job.appendingPathComponent("status.json"))
        updates.readWorkerStatus()
        XCTAssertFalse(updates.hasUpdate); XCTAssertNil(preferences.data(forKey: "updates.candidate"))
        XCTAssertNil(preferences.string(forKey: "updates.job"))
        preferences.set(try JSONEncoder().encode(UpdateCandidate(revision: new, title: "Next update")), forKey: "updates.candidate")
        let restarted = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertTrue(restarted.hasUpdate)
    }
    func testRestoringJobOutsideUpdateDirectoryDoesNotReadOrInstallIt() throws {
        preferences.set(directory.path, forKey: "updates.job")
        try JSONSerialization.data(withJSONObject: ["phase": "ready", "message": "Invalid location"]).write(to: directory.appendingPathComponent("status.json"))
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertNil(updates.job); XCTAssertEqual(updates.phase, .idle)
        XCTAssertThrowsError(try updates.handOff())
    }
    func testDeadWorkerDoesNotLeaveUpdatePermanentlyBlocked() throws {
        let job = try fixture(phase: "building")
        try JSONSerialization.data(withJSONObject: ["phase": "building", "message": "Interrupted", "workerPID": Int32.max]).write(to: job.appendingPathComponent("status.json"))
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        XCTAssertEqual(updates.phase, .failed)
        XCTAssertTrue(updates.canInstall)
        XCTAssertFalse(updates.canCancel)
        XCTAssertTrue(updates.detail.contains("interrumpió"))
    }
    func testDropdownShowsUpdateAndCancellationAtTheRightStage() throws {
        _ = NSApplication.shared
        let job = try fixture(phase: "building")
        let updates = AppUpdates(directory: directory, revision: old, preferences: preferences)
        defer { updates.stop() }
        let delegate = ApplicationDelegate(); delegate.updates = updates
        let building = delegate.makeActionsMenu()
        XCTAssertEqual(building.items.first { $0.title == "Fixture progress" }?.isEnabled, false)
        XCTAssertEqual(building.items.first { $0.title == "Cancelar actualización" }?.isHidden, false)
        try JSONSerialization.data(withJSONObject: ["phase": "failed", "message": "Build failed"]).write(to: job.appendingPathComponent("status.json"))
        updates.readWorkerStatus()
        let retry = delegate.makeActionsMenu()
        XCTAssertEqual(retry.items.first { $0.title == "Reintentar actualización…" }?.isEnabled, true)
        XCTAssertEqual(retry.items.first { $0.title == "Cancelar actualización" }?.isHidden, true)
    }
}
