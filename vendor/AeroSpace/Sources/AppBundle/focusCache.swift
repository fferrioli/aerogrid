@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) async throws {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    guard try await gridFocusRecovery.shouldFollow(nativeFocused, current: focus) else { return }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    if let app = nativeFocused?.app as? MacApp {
        app.lastNativeFocusedWindowId = nativeFocused?.windowId
    }
}
