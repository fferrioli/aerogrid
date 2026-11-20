import AppKit
import GridCore

/// The runner takes an exclusive lock on this directory after the ordinary controller drains.
/// The active symlink also blocks startup after a runner crash releases its lock.
enum FixtureSession {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/AeroGrid/LiveFixtures", isDirectory: true)
    static let active = root.appendingPathComponent("active")
    static let handoff = Notification.Name("local.AeroGrid.fixture-handoff")
    static let backend = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/AeroGrid Backend.app/Contents/Resources/aerospace").path

    static func admitController() throws -> FileHandle {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw GridError.unavailable("Cannot open the fixture interlock") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_SH | LOCK_NB) == 0,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: active.path)) == nil else {
            throw GridError.unavailable("A live fixture session is active. Run scripts/run-live-smoke.py --recover if it was interrupted.")
        }
        return handle
    }

    static func activeRun() throws -> URL {
        let name = try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
        guard name.hasPrefix("run-"), !name.contains("/") else { throw GridError.invalid("Invalid fixture session") }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    struct Request: Decodable {
        let pid: Int32
        let workspace: String
        let display: Display
        let originalBackend: String
        let allowBackendRestart: Bool

        var workspaces: Set<String> {
            Set([workspace, workspace + "-laptop"] + (0..<2).map {
                SpaceMap.derivedIdentity(sourceID: workspace, component: "block-\($0)").workspace
            })
        }
    }

    static func verificationRequest(token: String) throws -> (URL, Request) {
        let run = try activeRun()
        guard run.lastPathComponent == token else { throw GridError.invalid("Invalid fixture session") }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw GridError.unavailable("Cannot open the fixture interlock") }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) != 0, errno == EWOULDBLOCK,
              FileManager.default.fileExists(atPath: run.appendingPathComponent("handoff-ready").path) else {
            throw GridError.invalid("Start fixture verification from a live smoke runner")
        }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: run.appendingPathComponent("fixture.json")))
        guard request.pid > 1, request.workspace == "grid-fixture-\(run.lastPathComponent)" else {
            throw GridError.invalid("Invalid fixture owner or workspace")
        }
        try JSONEncoder().encode(request.workspaces.sorted())
            .write(to: run.appendingPathComponent("fixture-workspaces.json"), options: .atomic)
        return (run, request)
    }

    /// Headless, using the real AppModel operation queue and history without starting input,
    /// app updates, distributed actions or backend supervision.
    @MainActor static func observe(token: String) throws {
        let (run, request) = try verificationRequest(token: token)
        let model = try AppModel(fixture: (run, request))
        let jump = run.appendingPathComponent("jump.json")
        let stop = run.appendingPathComponent("stop-observer")
        let clock = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.current.add(clock, forMode: .default)
        var refreshAt = Date.distantPast
        defer { clock.invalidate(); model.stop() }
        while !FileManager.default.fileExists(atPath: stop.path) {
            if !model.hasPendingWork {
                if let data = try? Data(contentsOf: jump) {
                    let cell = try JSONDecoder().decode(String.self, from: data)
                    try FileManager.default.removeItem(at: jump)
                    model.openFixtureSpace(cell, display: request.display.id)
                } else if Date() >= refreshAt {
                    refreshAt = Date().addingTimeInterval(2)
                    model.refreshFixture()
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        while model.hasPendingWork { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
}

extension FixtureSession.Request {
    func fixtureDesktop(_ desktop: Desktop) throws -> Desktop {
        let allowed = workspaces
        guard let homes = desktop.windowHomes else { throw GridError.unavailable("Missing fixture window ownership") }
        let recovering = allowBackendRestart && desktop.backendSession != originalBackend && homes.allSatisfy { $0.pid == pid }
        guard recovering || !homes.contains(where: { allowed.contains($0.workspace) != ($0.pid == pid) }) else {
            throw GridError.unavailable("A window crossed the fixture workspace boundary")
        }
        var scoped = desktop
        scoped.windows = desktop.windows?.filter { $0.pid == pid }
        scoped.windowHomes = homes.filter { $0.pid == pid }
        scoped.visible = desktop.visible.filter { allowed.contains($0.value) }
        let ids = Set(scoped.windowHomes?.map(\.id) ?? [])
        scoped.nativeVisible = desktop.nativeVisible?.filter { ids.contains($0.value) }
        if let focused = scoped.focusedWindow, !ids.contains(focused) { scoped.focusedWindow = nil }
        return scoped
    }
}
