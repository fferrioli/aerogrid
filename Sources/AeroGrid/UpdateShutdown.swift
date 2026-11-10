import AppKit

/// Runs from the prepared build, so it can finish an update after the installed UI exits.
@MainActor enum UpdateShutdown {
    struct Application {
        let bundleURL: URL?
        let identifier: String?
        let terminate: () -> Bool
        let isTerminated: () -> Bool
    }
    private struct Request: Decodable {
        let revision: String
        let controllerPID: Int32
    }
    private static let bundles = [
        ("AeroGrid.app", "local.AeroGrid"),
        ("AeroGrid Backend.app", "local.AeroGrid.Backend"),
    ]

    static func run(job: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    timeout: TimeInterval = 20, applications: [Application]? = nil) throws {
        let job = job.resolvingSymlinksInPath()
        let updates = home.appendingPathComponent("Library/Application Support/AeroGrid/updates").resolvingSymlinksInPath()
        guard job.deletingLastPathComponent() == updates,
              job.lastPathComponent.range(of: "^[A-Za-z0-9-]{1,80}$", options: .regularExpression) != nil,
              FileManager.default.fileExists(atPath: job.appendingPathComponent("install").path) else {
            throw UpdateError.message("AeroGrid todavía no autorizó el cierre para instalar la actualización.")
        }
        let data = try Data(contentsOf: job.appendingPathComponent("request.json"))
        guard data.count < 8192 else { throw UpdateError.message("Solicitud de actualización inválida.") }
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard request.controllerPID > 1, UpdateCandidate.validRevision(request.revision) else {
            throw UpdateError.message("Solicitud de actualización inválida.")
        }

        let running = applications ?? bundles.flatMap { _, identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map { app in
                Application(bundleURL: app.bundleURL, identifier: app.bundleIdentifier,
                            terminate: { app.terminate() }, isTerminated: { app.isTerminated })
            }
        }
        let owned = running.filter { app in
            bundles.contains { name, identifier in
                let expected = home.appendingPathComponent("Applications/\(name)").resolvingSymlinksInPath()
                return app.identifier == identifier && app.bundleURL?.resolvingSymlinksInPath() == expected
            }
        }
        // Normal AppKit quit requests retain each app's serialized termination cleanup.
        for app in owned where !app.isTerminated() {
            guard app.terminate() || app.isTerminated() else {
                throw UpdateError.message("AeroGrid o su backend no aceptaron el cierre. No se modificaron las apps.")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while owned.contains(where: { !$0.isTerminated() }) {
            guard Date() < deadline else {
                throw UpdateError.message("AeroGrid o su backend siguen abiertos después de pedir el cierre. No se modificaron las apps.")
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }
}
