import Common

// A conservative, read-only projection of WindowDetectedCallback.matches for status.
// Only app identity/name constrain a match; AX and command conditions remain unknown.
@MainActor func gridWindowHasWorkspaceRule(_ window: Window) -> Bool {
    config.onWindowDetected.contains { callback in
        guard callback.run.flatten().contains(where: { $0 is MoveNodeToWorkspaceCommand }) else { return false }
        switch callback.matcher {
            case .legacy(let matcher):
                if let appId = matcher.appId, appId != window.app.rawAppBundleId { return false }
                if let regex = matcher.appNameRegexSubstring,
                   !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) { return false }
                return true
            case .command:
                // Running a matcher can query AX or mutate state; never execute it during inventory.
                return true
        }
    }
}
