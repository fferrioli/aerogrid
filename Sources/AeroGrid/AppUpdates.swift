import AppKit
import Combine
import Darwin

struct UpdateCandidate: Codable, Equatable {
    let revision: String
    let title: String
    static func validRevision(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

struct GitHubUpdateService {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()
    private struct Commit: Decodable {
        let sha: String
        let commit: Details
        struct Details: Decodable { let message: String }
    }
    private struct Comparison: Decodable { let status: String }
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: "https://api.github.com/repos/fferrioli/aerogrid/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AeroGrid-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message("No se pudo consultar GitHub. Podés volver a intentar más tarde.")
        }
        guard data.count < 4_000_000 else { throw UpdateError.message("GitHub devolvió una respuesta inesperada.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func latest(after revision: String) async throws -> UpdateCandidate? {
        guard UpdateCandidate.validRevision(revision) else { throw UpdateError.message("Esta build no tiene una revisión válida. Instalá una build actual para habilitar las actualizaciones.") }
        let latest: Commit = try await get("commits/main")
        guard UpdateCandidate.validRevision(latest.sha) else { throw UpdateError.message("GitHub devolvió una revisión inválida.") }
        guard latest.sha != revision else { return nil }
        let comparison: Comparison = try await get("compare/\(revision)...\(latest.sha)")
        // Never offer a downgrade or overwrite a diverged development build.
        guard comparison.status == "ahead" else { return nil }
        let title = String((latest.commit.message.split(separator: "\n").first ?? "Actualización de AeroGrid").prefix(160))
        return UpdateCandidate(revision: latest.sha, title: title)
    }
}

@MainActor final class AppUpdates: ObservableObject {
    enum Phase: String, Decodable {
        case idle, checking, current, available, preparing, downloading, building, ready, installing, complete, failed, cancelled
        var isBusy: Bool { [.preparing, .downloading, .building, .ready, .installing].contains(self) }
    }
    private struct WorkerStatus: Decodable { let phase: Phase; let message: String; let workerPID: Int32? }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidate: UpdateCandidate?
    @Published private(set) var detail = ""
    @Published var automatic: Bool { didSet { preferences.set(automatic, forKey: "updates.automatic") } }
    var onReadyToInstall: (() -> Void)?
    let directory: URL
    private let revision: String?
    private let preferences: UserDefaults
    private let lookup: (String) async throws -> UpdateCandidate?
    private let appBundle: URL
    private let workerURL: URL?
    private let python: String
    private var schedule: Timer?
    private var polling: Timer?
    private var task: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var process: Process?
    private(set) var job: URL?
    private var handedOff = false
    var hasUpdate: Bool { candidate != nil || phase == .failed }
    var canInstall: Bool { candidate != nil && !phase.isBusy && phase != .checking }
    var canCancel: Bool { phase.isBusy && phase != .installing && !handedOff }
    var primaryTitle: String {
        if phase.isBusy { return detail }
        if phase == .checking { return "Buscando actualizaciones…" }
        if phase == .failed { return candidate == nil ? "Reintentar búsqueda…" : "Reintentar actualización…" }
        if candidate != nil { return "Actualizar AeroGrid…" }
        if phase == .current || phase == .complete { return "AeroGrid está actualizado" }
        return "Buscar actualizaciones…"
    }

    init(directory: URL, revision: String? = Bundle.main.object(forInfoDictionaryKey: "AeroGridRevision") as? String,
         preferences: UserDefaults = .standard, appBundle: URL = Bundle.main.bundleURL,
         workerURL: URL? = Bundle.main.url(forResource: "update-worker", withExtension: "py"),
         python: String = Bundle.main.object(forInfoDictionaryKey: "AeroGridPythonPath") as? String ?? "/usr/bin/python3",
         lookup: @escaping (String) async throws -> UpdateCandidate? = { try await GitHubUpdateService().latest(after: $0) }) {
        self.directory = directory; self.revision = revision; self.preferences = preferences
        self.appBundle = appBundle; self.workerURL = workerURL; self.python = python; self.lookup = lookup
        automatic = preferences.object(forKey: "updates.automatic") as? Bool ?? true
        if let data = preferences.data(forKey: "updates.candidate"), let saved = try? JSONDecoder().decode(UpdateCandidate.self, from: data),
           UpdateCandidate.validRevision(saved.revision), saved.revision != revision {
            candidate = saved; phase = .available
        }
        if let path = preferences.string(forKey: "updates.job") {
            let saved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if saved.deletingLastPathComponent() == directory.appendingPathComponent("updates").resolvingSymlinksInPath() {
                job = saved
                readWorkerStatus()
                if phase.isBusy { startPolling() }
            }
        }
    }
    func start() {
        schedule = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.automatic { self.check() } }
        }
        RunLoop.main.add(schedule!, forMode: .common)
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.automatic else { return }
            self.check()
        }
    }
    func check() {
        guard !phase.isBusy, phase != .checking else { return }
        guard let revision, UpdateCandidate.validRevision(revision) else {
            detail = "Instalá una build actual para habilitar las actualizaciones desde AeroGrid."
            phase = .failed
            return
        }
        phase = .checking; detail = "Buscando actualizaciones…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await lookup(revision)
                candidate = found
                preferences.set(found.flatMap { try? JSONEncoder().encode($0) }, forKey: "updates.candidate")
                preferences.removeObject(forKey: "updates.job")
                job = nil
                phase = found == nil ? .current : .available
                detail = found?.title ?? "Tenés la última actualización de AeroGrid."
            } catch {
                detail = error.localizedDescription
                phase = candidate == nil ? .idle : .available
            }
        }
    }
    func install() {
        guard canInstall, let candidate else { return }
        do {
            let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AeroGrid.app").resolvingSymlinksInPath()
            guard appBundle.resolvingSymlinksInPath() == expected, let workerURL, FileManager.default.fileExists(atPath: workerURL.path) else {
                throw UpdateError.message("Instalá AeroGrid en ~/Applications para poder actualizarlo desde el menú.")
            }
            let updates = directory.appendingPathComponent("updates", isDirectory: true)
            let folder = updates.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let request: [String: Any] = ["revision": candidate.revision, "controllerPID": ProcessInfo.processInfo.processIdentifier]
            try JSONSerialization.data(withJSONObject: request).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [workerURL.path, "--job", folder.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            process.environment = environment
            let log = folder.appendingPathComponent("worker.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output; process.standardError = output
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.process === process, !self.handedOff else { return }
                    self.readWorkerStatus()
                    if self.phase.isBusy {
                        self.fail("El actualizador terminó antes de completar la preparación. Podés consultar el registro y reintentar.")
                    }
                }
            }
            job = folder; self.process = process; handedOff = false
            preferences.set(folder.path, forKey: "updates.job")
            phase = .preparing; detail = "Preparando actualización…"
            try process.run()
            startPolling()
        } catch { fail(error.localizedDescription) }
    }
    private func startPolling() {
        polling?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readWorkerStatus() }
        }
        RunLoop.main.add(timer, forMode: .common); polling = timer
    }
    func readWorkerStatus() {
        guard let job, let data = try? Data(contentsOf: job.appendingPathComponent("status.json")), data.count < 8192,
              let status = try? JSONDecoder().decode(WorkerStatus.self, from: data) else { return }
        phase = status.phase; detail = status.message
        if phase.isBusy, process == nil, let pid = status.workerPID, pid <= 1 || (kill(pid, 0) != 0 && errno == ESRCH) {
            fail("La preparación se interrumpió. Podés reintentar; la instalación anterior se conserva.")
            return
        }
        if phase == .ready, !handedOff { onReadyToInstall?() }
        if phase == .complete {
            candidate = nil; preferences.removeObject(forKey: "updates.candidate")
            preferences.removeObject(forKey: "updates.job")
        }
        if phase == .cancelled { preferences.removeObject(forKey: "updates.job") }
        if !phase.isBusy { polling?.invalidate(); polling = nil }
    }
    func handOff() throws {
        guard phase == .ready, let job, !handedOff else { throw UpdateError.message("La actualización todavía no está preparada.") }
        try Data().write(to: job.appendingPathComponent("install"), options: .atomic)
        handedOff = true; phase = .installing; detail = "Instalando y reiniciando…"
    }
    func cancel() {
        guard canCancel, let job else { return }
        do {
            try Data().write(to: job.appendingPathComponent("cancel"), options: .atomic)
            detail = "Cancelando actualización…"
        } catch { fail(error.localizedDescription) }
    }
    func stop() {
        if !handedOff { cancel() }
        schedule?.invalidate(); polling?.invalidate(); task?.cancel(); startupTask?.cancel()
    }
    func showDetails() {
        let alert = NSAlert(); alert.messageText = "Actualizaciones de AeroGrid"; alert.informativeText = detail
        alert.addButton(withTitle: "Cerrar")
        if job != nil { alert.addButton(withTitle: "Ver registro") }
        if alert.runModal() == .alertSecondButtonReturn, let job {
            let buildLog = job.appendingPathComponent("build.log")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: buildLog.path) ? buildLog : job.appendingPathComponent("worker.log"))
        }
    }
    func fail(_ message: String) { phase = .failed; detail = message; polling?.invalidate() }
}
