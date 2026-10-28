import AppKit

/// macOS can activate a hidden app when a window closes. That fallback is not a
/// request to switch AeroGrid spaces, and must not decide where a relaunch opens.
@MainActor final class GridFocusRecovery {
    private struct ClosedWindow: Equatable {
        var id: UInt32
        var pid: Int32
        init(_ window: Window) { id = window.windowId; pid = window.app.pid }
    }
    private var heldWorkspace: Workspace?
    private var inputAtClose: [UInt32] = []
    private var handledClosure: ClosedWindow?
    private let enabled: () -> Bool
    private let windowExists: @MainActor (Window) async throws -> Bool?
    private let inputCounters: () -> [UInt32]

    init(enabled: @escaping () -> Bool = { gridOwnsBackendUI() },
         windowExists: @escaping @MainActor (Window) async throws -> Bool? = gridWindowStillExists,
         inputCounters: @escaping () -> [UInt32] = gridFocusInputCounters) {
        self.enabled = enabled
        self.windowExists = windowExists
        self.inputCounters = inputCounters
    }

    func shouldFollow(_ native: Window?, current: LiveFocus) async throws -> Bool {
        guard enabled() else { heldWorkspace = nil; return true }
        if let heldWorkspace {
            if !heldWorkspace.isVisible || current.workspace !== heldWorkspace || inputCounters() != inputAtClose {
                self.heldWorkspace = nil
                return true
            }
            if native?.visualWorkspace === heldWorkspace {
                if let native, ClosedWindow(native) != handledClosure { self.heldWorkspace = nil }
                return true
            }
            return false
        }
        guard let closing = current.windowOrNil,
              native?.visualWorkspace !== current.workspace,
              closing.layoutReason == .standard,
              closing.parent is TilingContainer || closing.parent is FloatingWindowsContainer,
              ClosedWindow(closing) != handledClosure else { return true }
        let inputBeforeQuery = inputCounters()
        let exists = try await windowExists(closing)
        // A user command may run while AX responds. Never apply its older native
        // focus sample over that deliberate selection.
        guard focus.workspace === current.workspace, focus.windowOrNil === closing,
              inputCounters() == inputBeforeQuery else { return false }
        guard exists == false else { return true }
        holdAfterClose(closing, workspace: current.workspace)
        return heldWorkspace == nil
    }

    func holdAfterClose(_ closing: Window, workspace: Workspace) {
        guard enabled(), workspace.isVisible, ClosedWindow(closing) != handledClosure else { return }
        handledClosure = ClosedWindow(closing)
        heldWorkspace = workspace
        inputAtClose = inputCounters()
    }

    func willSetFocus(to workspace: Workspace) {
        if workspace !== heldWorkspace { heldWorkspace = nil }
    }
}

@MainActor var gridFocusRecovery = GridFocusRecovery()

private func gridFocusInputCounters() -> [UInt32] {
    // Counts only, never keyboard contents. Mouse-up from the closing click must
    // not release the hold; a new click/key press or explicit navigation does.
    [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].map {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
    }
}

@MainActor private func gridWindowStillExists(_ window: Window) async throws -> Bool? {
    guard let window = window as? MacWindow else { return nil }
    // AX can report destruction before WindowServer's closing animation ends.
    // Use the same liveness check as garbage collection, only on a proposed
    // cross-space fallback. Normal status polling adds no AX query.
    return try await window.macApp.gridWindowIsAlive(window.windowId, .cancellable)
}
