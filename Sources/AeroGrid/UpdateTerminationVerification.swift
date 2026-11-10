import AppKit

/// Runs the real deferred-termination path in a separate process with a sandbox model.
@MainActor final class UpdateTerminationVerification: NSObject, NSApplicationDelegate {
    private let controller = ApplicationDelegate()
    private let output: URL
    private let directory: URL
    private let job: URL
    private let preferences: UserDefaults
    private let suite = "AeroGrid.UpdateTermination.\(UUID().uuidString)"

    private init(output: URL) throws {
        self.output = output
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aerogrid-update-termination-\(UUID().uuidString)")
        job = directory.appendingPathComponent("updates/test-job")
        preferences = UserDefaults(suiteName: suite)!
        super.init()
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["phase": "ready", "message": "Fixture ready"])
            .write(to: job.appendingPathComponent("status.json"))
        preferences.set(job.path, forKey: "updates.job")
        controller.model = try OrganizerSandbox.model()
        controller.updates = AppUpdates(directory: directory, revision: String(repeating: "a", count: 40), preferences: preferences)
        controller.updates?.onReadyToInstall = { [weak controller] in controller?.finishPreparedUpdate() }
    }
    static func run(output: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let verification = try UpdateTerminationVerification(output: output)
        app.delegate = verification
        withExtendedLifetime(verification) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Match the MainActor task used by the updater's polling timer.
        Task { @MainActor in controller.updates?.readWorkerStatus() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.applicationShouldTerminate(sender)
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller.applicationWillTerminate(notification)
        let report: [String: Bool] = [
            "installAuthorized": FileManager.default.fileExists(atPath: job.appendingPathComponent("install").path),
            "cancelRequested": FileManager.default.fileExists(atPath: job.appendingPathComponent("cancel").path),
            "usesRealAppKitTermination": true,
            "usesLiveBackend": false,
            "writesUserState": false,
        ]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { fputs("\(error.localizedDescription)\n", stderr) }
        if let model = controller.model { try? FileManager.default.removeItem(at: model.directory) }
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
