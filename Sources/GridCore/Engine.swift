import Foundation

public protocol Backend: AnyObject {
    func desktop() throws -> Desktop
    func validate(workspace: String, monitor: Int) throws
    func place(workspace: String, monitor: Int) throws
    func activate(workspace: String) throws
    func focus(monitor: Int, window: UInt32?) throws
    func windows(workspace: String) throws -> [UInt32]
    func minimumWidths(workspace: String) throws -> [String: Double]
    func recoverWindowHomes(_ homes: [WindowHome]) throws
    func focus(window: UInt32) throws
    func move(window: UInt32, workspace: String) throws
    func moveVerified(window: WindowIdentity, workspace: String) throws
    func snapshot(workspace: String) throws -> String
    func restore(workspace: String, snapshot: String) throws
    func layout(workspace: String, profile: String) throws
    func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws
    func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws
}
public extension Backend {
    func moveVerified(window: WindowIdentity, workspace: String) throws { try move(window: window.id, workspace: workspace) }
    func validateTarget(workspace: String, monitor: Int, window: UInt32?) throws { try validate(workspace: workspace, monitor: monitor) }
    func activateTarget(workspace: String, monitor: Int, window: UInt32?) throws {
        try place(workspace: workspace, monitor: monitor)
        try activate(workspace: workspace)
        if let window { try focus(window: window) }
    }
    func minimumWidths(workspace: String) throws -> [String: Double] { [:] }
    func recoverWindowHomes(_ homes: [WindowHome]) throws {
        throw GridError.unavailable("The backend does not support window membership recovery")
    }
}
public final class Engine {
    public private(set) var configuration: Configuration
    public private(set) var state: RuntimeState
    public private(set) var observed: Desktop?
    public let backend: Backend
    private let store: Store?
    private var lastTopology: String?
    private var profilesBootstrapped = false
    private struct SelectedProfile {
        let name: String
        let key: String
    }
    public init(configuration: Configuration, state: RuntimeState = RuntimeState(), backend: Backend, store: Store? = nil) throws {
        try configuration.validate()
        guard state.version == 1 else { throw GridError.invalid("Unsupported runtime state version") }
        self.configuration = configuration; self.state = state; self.backend = backend; self.store = store
        if self.state.minimumWidthDetectionVersion != 2 {
            // Earlier observations could mistake docking/fullscreen frames for minimum sizes.
            self.state.windowMinimumWidths = nil
            self.state.minimumWidthDetectionVersion = 2
        }
        observed = state.lastDesktop
        lastTopology = state.lastDesktop?.topology
    }
    public func persist() throws { try store?.save(state, name: "state.json") }
    public func updateConfiguration(_ config: Configuration, removedCellDestinations: [String: String] = [:]) throws {
        try config.validate()
        let next = config.grids.flatMap(\.cells)
        let oldCells = configuration.grids.flatMap(\.cells)
        let removed = oldCells.filter { old in !next.contains { $0.id == old.id } }
        for old in oldCells {
            if let edited = next.first(where: { $0.id == old.id }), edited.workspace != old.workspace {
                throw GridError.invalid("A cell's workspace is stable. Create a replacement and supply a destination to migrate it.")
            }
        }
        // Validate every removal before moving any windows.
        var migrations: [(window: UInt32, destination: String, source: String)] = []
        for cell in removed {
            let windows = try backend.windows(workspace: cell.workspace)
            if !windows.isEmpty {
                guard let id = removedCellDestinations[cell.id], let target = next.first(where: { $0.id == id }) else { throw GridError.invalid("Choose a destination for windows in \(cell.name) before removing it") }
                migrations += windows.map { ($0, target.workspace, cell.workspace) }
            }
        }
        var moved: [(window: UInt32, destination: String, source: String)] = []
        do {
            for migration in migrations {
                try backend.move(window: migration.window, workspace: migration.destination)
                moved.append(migration)
            }
            try store?.save(config, name: "config.json")
        } catch {
            for migration in moved.reversed() { try? backend.move(window: migration.window, workspace: migration.source) }
            throw error
        }
        configuration = config; try persist()
    }
    public func grid(for display: Display, desktop: Desktop) -> Grid? {
        let visible = desktop.visible[display.monitor]
        if let grid = configuration.grids.first(where: { $0.cells.contains(where: { $0.workspace == visible }) }) { return grid }
        if let id = state.activeGrids[display.id], let g = configuration.grids.first(where: { $0.id == id }) { return g }
        return preferredGrid(for: display, displays: desktop.displays)
    }
    private func preferredGrid(for display: Display, displays: [Display]) -> Grid? {
        if let role = configuration.displayAssignments.first(where: { $0.value == display.id })?.key,
           let g = configuration.grids.first(where: { $0.displayRole == role }) { return g }
        let role = display.builtin ? "builtin" : "external"
        // Auto assignment is safe only for an unambiguous display role.
        if displays.filter({ $0.builtin == display.builtin }).count == 1,
           let g = configuration.grids.first(where: { $0.displayRole == role }) { return g }
        return displays.count == 1 ? configuration.grids.first : nil
    }
    public func sync(_ desktop: Desktop) {
        for display in desktop.displays {
            if let g = configuration.grids.first(where: { $0.cells.contains { $0.workspace == desktop.visible[display.monitor] } }),
               let cell = g.cells.first(where: { $0.workspace == desktop.visible[display.monitor] }) {
                state.cursors[g.id] = cell.id; state.activeGrids[display.id] = g.id
            }
        }
        observed = desktop
        state.lastDesktop = desktop
    }
    private func currentCell(_ grid: Grid) -> Cell {
        grid.cells.first { $0.id == state.cursors[grid.id] } ?? grid.cells.first { $0.row == grid.rows / 2 && $0.column == grid.columns / 2 } ?? grid.cells[0]
    }
    public func refresh() throws {
        var desktop = try backend.desktop()
        let backendRestarted = observed != nil && desktop.backendSession != nil && observed?.backendSession != desktop.backendSession
        if backendRestarted, var previous = observed {
            let managed = Set(configuration.grids.flatMap(\.cells).map(\.workspace))
            let homes = observed?.windowHomes?.filter { managed.contains($0.workspace) } ?? []
            if !homes.isEmpty {
                try backend.recoverWindowHomes(homes)
                desktop = try backend.desktop()
            }
            if let id = previous.focusedWindow, let savedHomes = previous.windowHomes {
                let saved = savedHomes.first { $0.id == id }
                let current = desktop.windowHomes?.first { $0.id == id }
                if saved == nil || saved?.pid != current?.pid || saved?.boot != current?.boot {
                    previous.focusedWindow = nil
                }
            }
            try rollback(previous)
            desktop = try backend.desktop()
            // Window IDs remain valid through an engine restart, but the live tree may have reset.
            // Restore the saved profiles before capturing any replacement layout.
            state.appliedProfiles.removeAll()
            profilesBootstrapped = true
        }
        if backendRestarted || (lastTopology != nil && lastTopology != desktop.topology) || observed?.nativeHomes != desktop.nativeHomes {
            try reconcileTopology(desktop)
        }
        lastTopology = desktop.topology
        sync(try backend.desktop())
        if !profilesBootstrapped {
            // Don't apply a layout to the user's existing windows at startup.
            for d in desktop.displays {
                if let g = grid(for: d, desktop: desktop) {
                    let cell = currentCell(g)
                    if state.appliedProfiles[cell.id] == nil {
                        let snapshot = try backend.snapshot(workspace: cell.workspace)
                        state.appliedProfiles[cell.id] = existingProfile(snapshot)
                    }
                }
            }
            profilesBootstrapped = true
        } else {
            try adaptVisibleProfiles()
        }
        try captureVisibleProfiles()
        try persist()
    }
    public func navigate(_ direction: Direction, scope: Scope, displayID: String?) throws {
        let before = try backend.desktop(); sync(before)
        if let displayID, !before.displays.contains(where: { $0.id == displayID }) { throw GridError.stale }
        let origin = displayID.flatMap { id in before.displays.first { $0.id == id } }
            ?? before.displays.first { $0.monitor == before.focusedMonitor }
        guard let origin else { throw GridError.unavailable("No display available") }
        let displays = scope == .all ? before.displays : [origin]
        var moves: [(Display, Grid, Cell)] = []
        for d in displays {
            guard let g = grid(for: d, desktop: before), let destination = g.neighbor(of: currentCell(g).id, direction: direction) else { throw GridError.boundary }
            moves.append((d, g, destination))
        }
        guard Set(moves.map { $0.2.workspace }).count == moves.count else { throw GridError.invalid("Two displays would show the same workspace; select separate grids") }
        for (display, _, cell) in moves { try backend.validate(workspace: cell.workspace, monitor: display.monitor) }
        // Snapshot every affected display before any mutation.
        try captureVisibleProfiles()
        do {
            for (display, _, cell) in moves {
                guard try backend.desktop().topology == before.topology else { throw GridError.stale }
                try show(cell, on: display)
            }
            let actual = try backend.desktop()
            guard actual.topology == before.topology else { throw GridError.stale }
            for (d, _, cell) in moves where actual.visible[d.monitor] != cell.workspace { throw GridError.unavailable("AeroSpace did not show \(cell.name) on \(d.name)") }
            // Original window belongs to the departing cell. Restore origin display, not that window.
            try backend.focus(monitor: origin.monitor, window: nil)
            sync(try backend.desktop()); try persist()
        } catch {
            try? rollback(before)
            if let actual = try? backend.desktop() { sync(actual) }
            try? persist(); throw error
        }
    }
    public func jump(gridID: String, cellID: String, displayID: String?) throws {
        let desktop = try backend.desktop(); sync(desktop)
        guard let g = configuration.grids.first(where: { $0.id == gridID }), let cell = g.cells.first(where: { $0.id == cellID }),
              let display = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }) else { throw GridError.invalid("Unknown grid, cell, or display") }
        if desktop.displays.contains(where: { $0.id != display.id && grid(for: $0, desktop: desktop)?.id == g.id }) {
            throw GridError.invalid("This grid is already visible on another display")
        }
        try backend.validate(workspace: cell.workspace, monitor: display.monitor)
        try captureVisibleProfiles()
        do { try show(cell, on: display); state.activeGrids[display.id] = g.id; state.cursors[g.id] = cell.id; sync(try backend.desktop()); try persist() }
        catch { try? rollback(desktop); throw error }
    }
    public func selectGrid(offset: Int, displayID: String?) throws {
        let desktop = try backend.desktop(); sync(desktop)
        guard let display = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }) else { throw GridError.unavailable("No display") }
        let occupied = Set(desktop.displays.filter { $0.id != display.id }.compactMap { grid(for: $0, desktop: desktop)?.id })
        let available = configuration.grids.filter { !occupied.contains($0.id) }
        guard !available.isEmpty else { throw GridError.unavailable("All grids are in use") }
        let index = available.firstIndex { $0.id == grid(for: display, desktop: desktop)?.id } ?? 0
        let g = available[(index + offset % available.count + available.count) % available.count]
        try jump(gridID: g.id, cellID: currentCell(g).id, displayID: display.id)
    }
    public func cycleWindow(offset: Int, displayID: String?) throws {
        let desktop = try backend.desktop()
        guard let d = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }), let ws = desktop.visible[d.monitor] else { throw GridError.unavailable("No workspace") }
        let windows = try backend.windows(workspace: ws)
        guard !windows.isEmpty else { return }
        let i = windows.firstIndex(of: desktop.focusedWindow ?? 0) ?? (offset > 0 ? -1 : 0)
        try backend.focus(window: windows[(i + offset + windows.count) % windows.count])
    }
    public func moveFocusedWindow(gridID: String, cellID: String, windowOverride: UInt32? = nil) throws {
        let desktop = try backend.desktop()
        guard let window = windowOverride ?? desktop.focusedWindow, let cell = configuration.grids.first(where: { $0.id == gridID })?.cells.first(where: { $0.id == cellID }) else { throw GridError.unavailable("Select a window and destination") }
        try backend.move(window: window, workspace: cell.workspace)
    }
    public func saveProfile(displayID: String?) throws {
        let desktop = try backend.desktop(); sync(desktop)
        guard let d = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }), let g = grid(for: d, desktop: desktop) else { return }
        let cell = currentCell(g)
        let count = try backend.windows(workspace: cell.workspace).count
        let key: String
        if let applied = state.appliedProfiles[cell.id] { key = applied }
        else { key = try chosenProfile(cell, display: d, count: count).key }
        state.snapshots["\(cell.id):\(key)"] = try backend.snapshot(workspace: cell.workspace); try persist()
    }
    private func chosenProfile(_ cell: Cell, display: Display, count: Int) throws -> SelectedProfile {
        let override = cell.displayProfiles?[display.id]
        let requested = override ?? cell.profile
        let name: String
        if requested != .automatic { name = requested.rawValue }
        else {
            let reported = try backend.minimumWidths(workspace: cell.workspace)
            var known = state.windowMinimumWidths ?? [:]
            for (identity, width) in reported where width.isFinite && width > 0 { known[identity] = width }
            state.windowMinimumWidths = known.isEmpty ? nil : known
            let minimum = reported.keys.compactMap { known[$0] }.max() ?? 0
            let required = max(configuration.compactMinimumWidth, minimum)
            name = display.width / Double(max(2, count)) < required ? "compact" : "wide"
        }
        let key = override == nil ? name : "display-\(display.id):\(name)"
        return SelectedProfile(name: name, key: key)
    }
    private func existingProfile(_ snapshot: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any]
        let tree = object?["tree"] as? [String: Any]
        if tree?["layout"] as? String == "accordion" { return "compact" }
        if tree?["orientation"] as? String == "v" { return "vertical" }
        return "wide"
    }
    private func adaptVisibleProfiles() throws {
        guard configuration.automaticLayouts, let desktop = observed else { return }
        for display in desktop.displays {
            guard let workspace = desktop.visible[display.monitor],
                  let cell = configuration.grids.flatMap(\.cells).first(where: { $0.workspace == workspace }) else { continue }
            let profile = try chosenProfile(cell, display: display, count: backend.windows(workspace: workspace).count)
            guard state.appliedProfiles[cell.id] != profile.key else { continue }
            // Snapshot the old profile before adapting; keep its edits separate from the new one.
            if let old = state.appliedProfiles[cell.id] {
                state.snapshots["\(cell.id):\(old)"] = try backend.snapshot(workspace: workspace)
            }
            try applyProfile(profile, cell: cell)
        }
    }
    private func applyProfile(_ profile: SelectedProfile, cell: Cell) throws {
        if let snapshot = state.snapshots["\(cell.id):\(profile.key)"] {
            do { try backend.restore(workspace: cell.workspace, snapshot: snapshot) }
            catch {
                if error.localizedDescription.contains("expired after reboot") {
                    try backend.layout(workspace: cell.workspace, profile: profile.name)
                } else { throw error }
            }
        } else {
            try backend.layout(workspace: cell.workspace, profile: profile.name)
        }
        state.appliedProfiles[cell.id] = profile.key
    }
    private func captureVisibleProfiles() throws {
        guard let desktop = observed else { return }
        let actual = try backend.desktop()
        guard desktop.topology == actual.topology else { return }
        for d in desktop.displays {
            guard let g = configuration.grids.first(where: { $0.cells.contains { $0.workspace == desktop.visible[d.monitor] } }), let cell = g.cells.first(where: { $0.workspace == desktop.visible[d.monitor] }), let p = state.appliedProfiles[cell.id] else { continue }
            state.snapshots["\(cell.id):\(p)"] = try backend.snapshot(workspace: cell.workspace)
        }
    }
    private func show(_ cell: Cell, on display: Display) throws {
        try backend.place(workspace: cell.workspace, monitor: display.monitor)
        if configuration.automaticLayouts {
            let profile = try chosenProfile(cell, display: display, count: backend.windows(workspace: cell.workspace).count)
            if state.appliedProfiles[cell.id] != profile.key {
                try applyProfile(profile, cell: cell)
            }
        }
        try backend.activate(workspace: cell.workspace)
    }
    private func rollback(_ before: Desktop) throws {
        let actual = try backend.desktop()
        for d in before.displays {
            guard let survivor = actual.displays.first(where: { $0.id == d.id }), let ws = before.visible[d.monitor] else { continue }
            try backend.place(workspace: ws, monitor: survivor.monitor); try backend.activate(workspace: ws)
        }
        if let origin = before.displays.first(where: { $0.monitor == before.focusedMonitor }), let survivor = actual.displays.first(where: { $0.id == origin.id }) { try backend.focus(monitor: survivor.monitor, window: before.focusedWindow) }
    }
    private func reconcileTopology(_ desktop: Desktop) throws {
        var claimed = Set<String>()
        var assignments: [String: Grid] = [:]
        // A native fullscreen Space can follow macOS's primary display on dock/undock.
        // Keep its grid on that physical display while the current cell is fullscreen.
        for g in configuration.grids {
            let cell = currentCell(g)
            if let monitor = desktop.nativeHomes?[cell.workspace], let d = desktop.displays.first(where: { $0.monitor == monitor }), assignments[d.id] == nil {
                assignments[d.id] = g; claimed.insert(g.id)
            }
        }
        for d in desktop.displays {
            if assignments[d.id] != nil { continue }
            let preferred = preferredGrid(for: d, displays: desktop.displays)
            if preferred == nil, desktop.displays.count > 1 { throw GridError.invalid("Assign ambiguous display roles in Settings") }
            let g = preferred.flatMap { claimed.contains($0.id) ? nil : $0 } ?? configuration.grids.first { !claimed.contains($0.id) }
            guard let g, claimed.insert(g.id).inserted else { throw GridError.invalid("Assign display roles in Settings") }
            assignments[d.id] = g
        }
        for d in desktop.displays {
            guard let g = assignments[d.id] else { continue }
            let cell = currentCell(g)
            try backend.validate(workspace: cell.workspace, monitor: d.monitor)
            try show(cell, on: d)
            state.activeGrids[d.id] = g.id
        }
        // Hidden grids retain their own cursors and profiles; selection rehosts their cells on demand.
        if let old = observed?.displays.first(where: { $0.monitor == observed?.focusedMonitor }), let survivor = desktop.displays.first(where: { $0.id == old.id }) { try backend.focus(monitor: survivor.monitor, window: nil) }
    }
}
