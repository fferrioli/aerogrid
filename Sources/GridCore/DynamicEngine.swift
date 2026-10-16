import Foundation

/// Owns the logical map; AeroSpace continues to own windows and native Spaces.
public final class DynamicEngine {
    public private(set) var configuration: Configuration
    public private(set) var state: RuntimeState
    public private(set) var observed: Desktop?
    public let backend: Backend
    private let store: Store?
    private var reconcilingTopology = false
    public var map: SpaceMap { state.dynamicMap! }
    private var windows: [WindowInfo] { observed?.windows ?? [] }

    public init(configuration: Configuration, state: RuntimeState = RuntimeState(), backend: Backend, store: Store? = nil) throws {
        try configuration.validate()
        self.configuration = configuration; self.state = state; self.backend = backend; self.store = store
        if self.state.dynamicMap == nil {
            try store?.save(state, name: "state-before-dynamic-map.json")
            try store?.save(configuration, name: "config-before-dynamic-map.json")
            var migrated = SpaceMap(configuration: configuration)
            for space in migrated.spaces {
                let keys = ["\(space.id):wide", "\(space.id):vertical", "\(space.id):compact"]
                if let snapshot = keys.compactMap({ state.snapshots[$0] }).first { migrated.layouts[space.id] = snapshot }
            }
            self.state.dynamicMap = migrated
            try persist()
        }
        try upgradeSpatialMap()
        try map.validate()
        observed = state.lastDesktop
    }
    private func upgradeSpatialMap() throws {
        guard map.version < 3, map.pending == nil else { return }
        if let store {
            let backup = store.directory.appendingPathComponent("state-before-spatial-map.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try store.save(state, name: "state-before-spatial-map.json") }
        }
        var next = map
        try next.migrateSpatial(configuration: configuration, desktop: state.lastDesktop)
        state.dynamicMap = next
        try persist()
    }
    private func editMap(_ body: (inout SpaceMap) throws -> Void) rethrows {
        var next = map; try body(&next); state.dynamicMap = next
    }
    public func persist() throws { try map.validate(); try store?.save(state, name: "state.json") }
    public func importVisibleLayouts() throws {
        let desktop = try backend.desktop()
        let visible = Set(desktop.visible.values)
        for space in map.spaces where space.nativeWindow == nil && visible.contains(space.workspace) {
            if desktop.displays.count == 1 && desktop.displays.first?.builtin == true && space.preferredRole != "builtin" { continue }
            let saved = try backend.snapshot(workspace: space.workspace)
            editMap { $0.layouts[space.id] = saved }
        }
        sync(desktop); try persist()
    }
    public func updateConfiguration(_ config: Configuration) throws {
        try config.validate()
        // Grid definitions remain the legacy import source. The live map is edited in the organizer.
        guard config.grids == configuration.grids else { throw GridError.invalid("Organize spaces in the map; legacy grid dimensions are no longer used") }
        try store?.save(config, name: "config.json"); configuration = config; try persist()
    }
    private func role(_ display: Display) -> String {
        configuration.displayAssignments.first(where: { $0.value == display.id })?.key ?? (display.builtin ? "builtin" : "external")
    }
    public func currentSpace(on display: Display, desktop: Desktop? = nil) -> Space? {
        guard let desktop = desktop ?? observed else { return nil }
        if let native = desktop.nativeVisible?[display.monitor] {
            return map.spaces.first { $0.nativeWindow?.id == native }
        }
        return map.spaces.first { $0.workspace == desktop.visible[display.monitor] && $0.nativeWindow == nil }
    }
    public func contents(of space: Space, desktop: Desktop? = nil) -> [WindowInfo] {
        let inventory = (desktop ?? observed)?.windows ?? []
        if let native = space.nativeWindow { return inventory.filter { $0.identity == native && $0.nativeFullscreen } }
        return inventory.filter { $0.workspace == space.workspace && !$0.nativeFullscreen }
    }
    private func sync(_ desktop: Desktop) {
        observed = desktop
        if map.version >= 3 {
            for index in map.spaces.indices where map.spaces[index].isDormant {
                let space = map.spaces[index]
                guard desktop.windows?.contains(where: { $0.workspace == space.workspace }) == true || desktop.visible.values.contains(space.workspace) else { continue }
                var next = map
                if !next.fits(space.rect, board: space.board, excluding: [space.id]) { next.spaces[index].rect = next.frontier(near: space) }
                next.spaces[index].dormant = false
                state.dynamicMap = next
            }
        }
        for display in desktop.displays {
            if let space = currentSpace(on: display, desktop: desktop) {
                editMap { $0.cursors[display.id] = space.id }
                if desktop.displays.count > 1 && !reconcilingTopology { editMap { $0.connectedCursors[display.id] = space.id } }
            }
        }
        state.lastDesktop = desktop
    }
    private func snapshot(_ space: Space) throws -> LayoutSnapshot { try LayoutSnapshot(json: backend.snapshot(workspace: space.workspace)) }
    private func captureVisibleLayouts() throws {
        guard observed != nil else { return }
        // Inactive boards need the same accurate diagrams as the visible destination.
        for space in map.spaces where space.nativeWindow == nil && !contents(of:space).isEmpty {
            let json = try backend.snapshot(workspace:space.workspace)
            editMap { $0.layouts[space.id] = json }
        }
    }
    public func refresh() throws {
        let before = observed
        let desktop = try backend.desktop()
        guard desktop.windows != nil else { throw GridError.unavailable("Update AeroGrid Backend to enable the dynamic map") }
        if let pending = map.pending {
            try restore(pending.before)
            editMap { $0.pending = nil }
        }
        try upgradeSpatialMap()
        let restarted = before?.backendSession != nil && before?.backendSession != desktop.backendSession
        reconcilingTopology = before?.topology != desktop.topology || restarted
        defer { reconcilingTopology = false }
        if restarted, let homes = before?.windowHomes {
            let managed = Set(map.spaces.map(\.workspace))
            try backend.recoverWindowHomes(homes.filter { managed.contains($0.workspace) })
            for space in map.spaces where space.nativeWindow == nil {
                if let saved = map.layouts[space.id], let value = try? LayoutSnapshot(json: saved), value.boot == desktop.windows?.first?.boot {
                    try backend.restore(workspace: space.workspace, snapshot: saved)
                }
            }
        }
        sync(try backend.desktop())
        adoptUnmappedWorkspaces()
        try reconcileFullscreen(previous: before)
        let shouldFold = desktop.displays.count == 1 && desktop.displays[0].builtin
        if shouldFold {
            try foldExternalSpaces()
            editMap { $0.folded = true }
        } else {
            try recomposeUneditedFamilies()
            editMap { map in
                map.folded = false
                for index in map.spaces.indices { map.spaces[index].joinedWhileFolded = nil }
            }
        }
        sync(try backend.desktop())
        if map.initialized != true, let actual = observed {
            for display in actual.displays where actual.nativeVisible?[display.monitor] != nil {
                if let target = currentSpace(on: display) { editMap { $0.connectedCursors[display.id] = target.id; $0.cursors[display.id] = target.id } }
            }
        }
        if let before, before.topology != desktop.topology || restarted { try restoreDisplayPositions(before: before) }
        editMap { $0.initialized = true }
        try captureVisibleLayouts()
        reconcilingTopology = false
        sync(try backend.desktop())
        let actual = observed ?? desktop
        editMap { map in
            for index in map.spaces.indices {
                let space = map.spaces[index]
                let related = map.families.contains { $0.sourceID == space.id || $0.childIDs.contains(space.id) } || map.fullscreens.contains { $0.homeID == space.id }
                if !space.userCreated && space.nativeWindow == nil && !related && !actual.visible.values.contains(space.workspace)
                    && !(actual.windows ?? []).contains(where: { $0.workspace == space.workspace }) {
                    map.spaces[index].dormant = true
                }
            }
        }
        if desktop.displays.count == 1 {
            let projected = map.projectedSpaces(combined: true)
            editMap { map in
                for index in map.spaces.indices where !map.spaces[index].isDormant && map.spaces[index].foldedRect == nil {
                    map.spaces[index].foldedRect = projected.first { $0.id == map.spaces[index].id }?.rect
                }
            }
        }
        try persist()
    }
    private func restoreDisplayPositions(before: Desktop) throws {
        guard let desktop = observed else { return }
        let focusedHome = before.windowHomes?.first { $0.id == before.focusedWindow }
        let oldIdentity = before.windows?.first { $0.id == before.focusedWindow }?.identity
            ?? focusedHome.map { WindowIdentity(id: $0.id, pid: $0.pid, boot: $0.boot) }
        if desktop.displays.count == 1 {
            if let oldIdentity, let live = windows.first(where: { $0.identity == oldIdentity }),
               let target = map.spaces.first(where: { $0.nativeWindow == live.identity || ($0.workspace == live.workspace && $0.nativeWindow == nil && !live.nativeFullscreen) }) {
                try show(target, on: desktop.displays[0])
            } else if let id = map.cursors[desktop.displays[0].id], let target = map.spaces.first(where: { $0.id == id }) {
                try show(target, on: desktop.displays[0])
            }
        } else {
            for display in desktop.displays {
                let remembered = map.connectedCursors[display.id].flatMap { id in map.spaces.first { $0.id == id } }
                let fallback = map.spaces.first { $0.preferredRole == role(display) && $0.nativeWindow == nil && !contents(of: $0).isEmpty }
                if let target = remembered ?? fallback {
                    if let native = target.nativeWindow, windows.first(where: { $0.identity == native })?.nativeMonitor != display.monitor { continue }
                    try show(target, on: display)
                }
            }
            if before.topology == desktop.topology, let oldIdentity, windows.contains(where: { $0.identity == oldIdentity }) {
                try backend.focus(window: oldIdentity.id)
            } else if let origin = before.displays.first(where: { $0.monitor == before.focusedMonitor }), let survivor = desktop.displays.first(where: { $0.id == origin.id }) {
                try backend.focus(monitor: survivor.monitor, window: nil)
            }
        }
        sync(try backend.desktop())
    }
    private func adoptUnmappedWorkspaces() {
        guard let desktop = observed else { return }
        for workspace in Set(windows.map(\.workspace)).union(desktop.visible.values).sorted() where !map.spaces.contains(where: { $0.workspace == workspace }) {
            guard workspace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { continue }
            let window = windows.first { $0.workspace == workspace }
            let display = desktop.displays.first { $0.monitor == (window?.nativeMonitor ?? window?.monitor) }
                ?? desktop.displays.first { desktop.visible[$0.monitor] == workspace }
                ?? desktop.displays.first { $0.monitor == desktop.focusedMonitor } ?? desktop.displays.first
            let preferredRole = display.map(role) ?? "builtin"
            let anchor = map.spaces.last { $0.preferredRole == preferredRole } ?? map.spaces.last!
            let position = map.vacant(near: anchor)
            let name = workspace.allSatisfy(\.isNumber) ? (window?.appName ?? "Espacio") : workspace
            let space = Space(name: name, row: position.row, column: position.column, workspace: workspace, preferredRole: preferredRole)
            editMap { $0.spaces.append(space) }
        }
    }
    private func markEdited(_ id: String) {
        editMap { map in
            for i in map.families.indices where map.families[i].sourceID == id || map.families[i].childIDs.contains(id) { map.families[i].manuallyEdited = true }
            for i in map.fullscreens.indices {
                if map.fullscreens[i].spaceID == id { map.fullscreens[i].manuallyEdited = true }
                if map.fullscreens[i].homeID == id { map.fullscreens[i].homeEdited = true }
            }
        }
    }
    private func exclusiveSpace(home: Space, window: WindowInfo) throws -> Space {
        let position = map.vacant(near: home)
        for suffix in 0...4096 {
            let component = "native-\(window.boot)-\(window.pid)-\(window.id)-\(suffix)"
            let identity = SpaceMap.derivedIdentity(sourceID: home.id, component: component)
            guard !map.spaces.contains(where: { $0.id == identity.id }) else { continue }
            var exclusive = Space(id: identity.id, name: "\(home.name) · \(window.appName)", row: position.row, column: position.column,
                                  workspace: home.workspace, preferredRole: home.preferredRole)
            exclusive.preferredDisplay = home.preferredDisplay; exclusive.nativeWindow = window.identity; exclusive.sourceID = home.id
            return exclusive
        }
        throw GridError.invalid("No se pudo asignar una identidad al fullscreen")
    }
    private func reconcileFullscreen(previous: Desktop?) throws {
        // Entries are matched by owner and boot, not a reusable window number alone.
        for link in map.fullscreens {
            guard let space = map.spaces.first(where: { $0.id == link.spaceID }) else { continue }
            let deferred = observed?.windowHomes?.contains { $0.id == link.identity.id && $0.pid == link.identity.pid && $0.boot == link.identity.boot } == true
            if deferred && !windows.contains(where: { $0.id == link.identity.id }) { continue }
            if let window = windows.first(where: { $0.identity == link.identity }), window.nativeFullscreen {
                if link.spaceID == link.homeID, windows.contains(where: { $0.workspace == space.workspace && $0.identity != window.identity }) {
                    let exclusive = try exclusiveSpace(home: space, window: window)
                    editMap { map in
                        if let i = map.spaces.firstIndex(where: { $0.id == space.id }) { map.spaces[i].nativeWindow = nil }
                        if let i = map.fullscreens.firstIndex(where: { $0.spaceID == link.spaceID }) { map.fullscreens[i].spaceID = exclusive.id }
                        map.spaces.append(exclusive)
                    }
                }
                continue
            }
            if let window = windows.first(where: { $0.identity == link.identity }) {
                if link.manuallyEdited, link.spaceID != link.homeID {
                    let workspace = "grid-space-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                    try backend.moveVerified(window: window.identity, workspace: workspace)
                    editMap { map in
                        if let index = map.spaces.firstIndex(where: { $0.id == space.id }) { map.spaces[index].workspace = workspace; map.spaces[index].nativeWindow = nil; map.spaces[index].sourceID = nil; map.spaces[index].userCreated = true }
                    }
                    if let previous, let oldDisplay = previous.displays.first(where: { previous.nativeVisible?[$0.monitor] == window.id }),
                       let display = observed?.displays.first(where: { $0.id == oldDisplay.id }),
                       let independent = map.spaces.first(where: { $0.id == space.id }) {
                        try show(independent, on: display)
                    }
                } else if link.homeEdited != true, let original = link.original, original.boot == window.boot,
                          let home = map.spaces.first(where: { $0.id == link.homeID }) {
                    try backend.restore(workspace: home.workspace, snapshot: original.json())
                }
            }
            editMap { map in
                map.fullscreens.removeAll { $0.spaceID == link.spaceID }
                if link.spaceID == link.homeID {
                    if let i = map.spaces.firstIndex(where: { $0.id == link.homeID }) { map.spaces[i].nativeWindow = nil }
                } else if !link.manuallyEdited || !windows.contains(where: { $0.identity == link.identity }) {
                    map.spaces.removeAll { $0.id == link.spaceID }; map.layouts.removeValue(forKey: link.spaceID)
                }
            }
        }
        sync(try backend.desktop())
        for window in windows where window.nativeFullscreen && !map.fullscreens.contains(where: { $0.identity == window.identity }) {
            guard let home = map.spaces.first(where: { $0.workspace == window.workspace && $0.nativeWindow == nil }) else { continue }
            let original = try snapshot(home)
            let shared = windows.contains { $0.workspace == window.workspace && $0.identity != window.identity }
            var exclusive = home
            if shared {
                exclusive = try exclusiveSpace(home: home, window: window)
            }
            exclusive.nativeWindow = window.identity
            editMap { map in
                if shared { map.spaces.append(exclusive) }
                else if let i = map.spaces.firstIndex(where: { $0.id == home.id }) { map.spaces[i] = exclusive }
                map.fullscreens.append(FullscreenLink(spaceID: exclusive.id, homeID: home.id, identity: window.identity, original: original))
            }
        }
        sync(try backend.desktop())
    }
    private func foldExternalSpaces() throws {
        let sources = map.spaces.filter { $0.preferredRole != "builtin" && $0.nativeWindow == nil && $0.sourceID == nil && $0.joinedWhileFolded != true }
        for source in sources where !map.families.contains(where: { $0.sourceID == source.id }) {
            guard !contents(of: source).isEmpty else { continue }
            let saved: LayoutSnapshot
            if let json = map.layouts[source.id], let cached = try? LayoutSnapshot(json: json), cached.boot == windows.first?.boot { saved = cached }
            else { saved = try snapshot(source) }
            let identities = Set(contents(of: source).map(\.identity))
            guard let normalTree = saved.tree.retaining(identities, boot: saved.boot) else { continue }
            let blocks = normalTree.blocks
            guard blocks.count > 1 else { continue }
            let before = try checkpoint()
            var next = map
            var childIDs = [source.id]
            var children: [(Space, LayoutSnapshot)] = [(source, saved.block(blocks[0], includeFloating: false))]
            for (index, block) in blocks.dropFirst().enumerated() {
                let position = next.vacant(near: children.last!.0)
                let app = windows.first { block.ids.contains($0.id) }?.appName ?? "Group \(index + 2)"
                let identity = SpaceMap.derivedIdentity(sourceID: source.id, component: "block-\(index + 1)")
                guard !next.spaces.contains(where: { $0.id == identity.id || $0.workspace == identity.workspace }) else { throw GridError.invalid("La identidad de un bloque está ocupada por otro espacio") }
                var child = Space(id: identity.id, name: "\(source.name) · \(app)", row: position.row, column: position.column,
                                  workspace: identity.workspace, preferredRole: source.preferredRole)
                child.sourceID = source.id; child.preferredDisplay = source.preferredDisplay
                next.spaces.append(child)
                childIDs.append(child.id); children.append((child, saved.block(block, includeFloating: false)))
            }
            for floating in saved.floating {
                let owners = blocks.indices.filter { index in
                    blocks[index].ids.contains { id in windows.contains { $0.id == id && $0.pid == floating.pid } }
                }
                let destination = owners.count == 1 ? owners[0] : 0
                children[destination].1.floating.append(floating)
            }
            next.families.append(SplitFamily(sourceID: source.id, original: saved, childIDs: childIDs))
            let moves = children.flatMap { child, layout in
                let ids = layout.tree.ids + layout.floating.map(\.id)
                return ids.compactMap { id in windows.first(where: { $0.id == id }).map { WindowHome(id: id, pid: $0.pid, boot: $0.boot, workspace: child.workspace, floating: $0.floating) } }
            }
            next.pending = PendingOrganization(before: before, desiredHomes: moves)
            try next.validate(); state.dynamicMap = next; try persist()
            do {
                for home in moves { try backend.moveVerified(window: WindowIdentity(id: home.id, pid: home.pid, boot: home.boot), workspace: home.workspace) }
                for (child, layout) in children { try backend.restore(workspace: child.workspace, snapshot: layout.json()); editMap { $0.layouts[child.id] = try? layout.json() } }
                editMap { $0.pending = nil }; try persist()
            } catch { try restore(before); editMap { $0.pending = nil }; try persist(); throw error }
            sync(try backend.desktop())
        }
    }
    private func recomposeUneditedFamilies() throws {
        for family in map.families where !family.manuallyEdited { try reunite(sourceID: family.sourceID, manual: false) }
    }
    public func makeReunitePreview(sourceID: String) throws -> ReunitePreview {
        try refresh()
        guard let family = map.families.first(where: { $0.sourceID == sourceID }),
              let source = map.spaces.first(where: { $0.id == sourceID }) else { throw GridError.stale }
        let members = map.spaces.filter { family.childIDs.contains($0.id) }.flatMap { contents(of: $0) }
        let owners = Set(members.map(\.identity))
        var result = family.original
        result.tree = result.tree.retaining(owners, boot: result.boot) ?? .root([])
        result.floating = result.floating.filter { owners.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: result.boot)) }
        let retained = Set(result.tree.ids + result.floating.map(\.id))
        for window in members where !retained.contains(window.id) {
            if window.floating, let space = map.spaces.first(where: { $0.workspace == window.workspace && $0.nativeWindow == nil }),
               let floating = try snapshot(space).floating.first(where: { $0.id == window.id && $0.pid == window.pid }) {
                result.floating.append(floating)
            } else { result.tree.children?.append(LayoutNode(id: window.id, pid: window.pid)) }
        }
        return ReunitePreview(sourceID: sourceID, name: source.name, windows: members, result: result)
    }
    public func reunite(sourceID: String, manual: Bool = true, expectedOwners: Set<WindowIdentity>? = nil) throws {
        guard let family = map.families.first(where: { $0.sourceID == sourceID }), let source = map.spaces.first(where: { $0.id == sourceID }) else { return }
        guard !map.fullscreens.contains(where: { family.childIDs.contains($0.homeID) }) else {
            if manual { throw GridError.invalid("Salí de fullscreen antes de reunir este grupo") }; return
        }
        let workspaces = Set(map.spaces.filter { family.childIDs.contains($0.id) }.map(\.workspace))
        let discovered = Set(windows.map(\.identity))
        if observed?.windowHomes?.contains(where: { workspaces.contains($0.workspace) && !discovered.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: $0.boot)) }) == true {
            if manual { throw GridError.unavailable("Esperando que macOS vuelva a mostrar las ventanas de este grupo") }; return
        }
        let work = {
            if let expectedOwners {
                let actual = Set(self.map.spaces.filter { family.childIDs.contains($0.id) }.flatMap { self.contents(of: $0) }.map(\.identity))
                guard actual == expectedOwners else { throw GridError.invalid("Las ventanas del grupo cambiaron; abrí la vista previa otra vez") }
            }
            for child in self.map.spaces where family.childIDs.contains(child.id) {
                for window in self.contents(of: child) { try self.backend.moveVerified(window: window.identity, workspace: source.workspace) }
            }
            if family.original.boot == self.windows.first?.boot { try self.backend.restore(workspace: source.workspace, snapshot: family.original.json()) }
            self.editMap { map in
                map.spaces.removeAll { family.childIDs.contains($0.id) && $0.id != source.id }
                map.families.removeAll { $0.sourceID == source.id }
                if let index = map.spaces.firstIndex(where: { $0.id == source.id }) {
                    map.spaces[index].joinedWhileFolded = manual && self.observed?.displays.count == 1 && self.observed?.displays.first?.builtin == true ? true : nil
                }
                map.layouts[source.id] = try? family.original.json()
                for id in family.childIDs where id != source.id { map.layouts.removeValue(forKey: id) }
                for key in map.cursors.keys where family.childIDs.contains(map.cursors[key] ?? "") { map.cursors[key] = source.id }
                for key in map.connectedCursors.keys where family.childIDs.contains(map.connectedCursors[key] ?? "") { map.connectedCursors[key] = source.id }
            }
        }
        if manual { try organize("Reunir grupo", work) }
        else {
            let before = try checkpoint(); editMap { $0.pending = PendingOrganization(before: before, desiredHomes: []) }; try persist()
            do { try work(); editMap { $0.pending = nil }; try persist() }
            catch { try restore(before); editMap { $0.pending = nil }; try persist(); throw error }
        }
        sync(try backend.desktop())
    }
    public func eligibleSpaces(on display: Display, desktop: Desktop? = nil) -> Set<String> {
        guard let desktop = desktop ?? observed else { return [] }
        return NavigationSelection.eligible(map: map, configuration: configuration, display: display, desktop: desktop)
    }
    public var projectedSpaces: [Space] { map.projectedSpaces(combined: observed?.displays.count == 1) }
    public func navigationHints() -> [String: NavigationHint] {
        guard let desktop = observed else { return [:] }
        var result: [String: NavigationHint] = [:]
        for display in desktop.displays {
            guard let current = currentSpace(on: display) else { continue }
            let eligible = eligibleSpaces(on: display)
            let projected = projectedSpaces
            guard let source = projected.first(where: { $0.id == current.id }) else { continue }
            var neighbors: [String: String] = [:]
            for direction in Direction.allCases { neighbors[direction.rawValue] = SpatialNavigation.candidates(from: source, anchor: map.anchors?[display.id], direction: direction, spaces: projected, eligible: eligible).first?.name }
            result[display.id] = NavigationHint(name: current.name, row: current.row, column: current.column, neighbors: neighbors)
        }
        return result
    }
    public func navigate(_ direction: Direction, scope: Scope, displayID: String?) throws {
        try refresh()
        guard let desktop = observed else { throw GridError.stale }
        var selection = try NavigationSelection(map: map, configuration: configuration, desktop: desktop, scope: scope, displayID: displayID)
        guard selection.step(direction) else { throw GridError.boundary }
        try commitNavigation(selection)
    }
    public func commitNavigation(_ selection: NavigationSelection) throws {
        try refresh()
        guard let before = observed else { throw GridError.stale }
        guard !selection.isAtOrigin else { return }
        try selection.validate(map: map, configuration: configuration, desktop: before)
        let moves = try selection.selected.keys.sorted().map { id -> (Display, Space) in
            guard let display = before.displays.first(where: { $0.id == id }),
                  let entry = selection.selected[id], let space = map.spaces.first(where: { $0.id == entry.spaceID }) else { throw GridError.stale }
            return (display, space)
        }
        for (display, space) in moves { try backend.validateTarget(workspace: space.workspace, monitor: display.monitor, window: space.nativeWindow?.id) }
        let oldCursors = map.cursors, oldAnchors = map.anchors
        do {
            for (display, space) in moves {
                guard try backend.desktop().topology == before.topology else { throw GridError.stale }
                try show(space, on: display)
            }
            guard let origin = before.displays.first(where: { $0.id == selection.originDisplayID }),
                  try backend.desktop().topology == before.topology else { throw GridError.stale }
            try backend.focus(monitor: origin.monitor, window: nil)
            sync(try backend.desktop())
            editMap { map in
                if map.anchors == nil { map.anchors = [:] }
                for (id, entry) in selection.selected { map.anchors?[id] = entry }
            }
            try persist()
        } catch {
            let failure = error
            editMap { $0.anchors = oldAnchors }
            do { try restoreVisible(before,cursors:oldCursors) }
            catch {
                if let actual = try? backend.desktop() { sync(actual) }
                throw GridError.unavailable("El cambio falló y la recuperación quedó incompleta: \(error.localizedDescription)")
            }
            sync(try backend.desktop()); try persist()
            throw failure
        }
    }
    private func show(_ space: Space, on display: Display) throws {
        try backend.validateTarget(workspace: space.workspace, monitor: display.monitor, window: space.nativeWindow?.id)
        try backend.activateTarget(workspace: space.workspace, monitor: display.monitor, window: space.nativeWindow?.id)
        let actual = try backend.desktop()
        if space.nativeWindow != nil {
            guard actual.nativeVisible?[display.monitor] == space.nativeWindow?.id else { throw GridError.unavailable("Fullscreen destination did not become visible") }
        } else {
            guard actual.visible[display.monitor] == space.workspace, actual.nativeVisible?[display.monitor] == nil else { throw GridError.unavailable("Normal destination did not become visible") }
            if let layout = map.layouts[space.id], let saved = try? LayoutSnapshot(json: layout), saved.boot == actual.windows?.first?.boot {
                try backend.restore(workspace: space.workspace, snapshot: layout)
            }
        }
        editMap { $0.cursors[display.id] = space.id }
    }
    private func restoreVisible(_ desktop: Desktop, cursors: [String: String]) throws {
        let actual = try backend.desktop()
        for display in actual.displays {
            if let id = cursors[display.id], let space = map.spaces.first(where: { $0.id == id }) { try show(space, on: display) }
            else if let old = desktop.displays.first(where: { $0.id == display.id }), let ws = desktop.visible[old.monitor] {
                try backend.activateTarget(workspace: ws, monitor: display.monitor, window: desktop.nativeVisible?[old.monitor])
            }
        }
        if let origin = desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }), let survivor = actual.displays.first(where: { $0.id == origin.id }) {
            let window = desktop.focusedWindow.flatMap { id in actual.windows?.contains(where: { $0.id == id }) == true ? id : nil }
            try backend.focus(monitor: survivor.monitor, window: window)
        }
    }
    public func jump(gridID: String = "map", cellID: String, displayID: String?) throws {
        try refresh()
        guard let desktop = observed, let space = map.spaces.first(where: { $0.id == cellID }),
              let display = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }) else { throw GridError.stale }
        if desktop.displays.contains(where: { $0.id != display.id && currentSpace(on: $0)?.id == space.id }) { throw GridError.invalid("Este espacio ya está visible en la otra pantalla") }
        let cursors = map.cursors
        do { try show(space, on: display); sync(try backend.desktop()); try persist() }
        catch { try? restoreVisible(desktop, cursors: cursors); throw error }
    }
    public func selectGrid(offset: Int, displayID: String?) throws {
        guard let desktop = observed, let display = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first else { return }
        let candidates = map.spaces.filter { eligibleSpaces(on: display).contains($0.id) }.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        guard !candidates.isEmpty else { return }
        let index = candidates.firstIndex { $0.id == currentSpace(on: display)?.id } ?? 0
        let target = candidates[(index + offset % candidates.count + candidates.count) % candidates.count]
        try jump(cellID: target.id, displayID: display.id)
    }
    public func cycleWindow(offset: Int, displayID: String?) throws {
        try refresh()
        guard let desktop = observed, let display = desktop.displays.first(where: { $0.id == displayID }) ?? desktop.displays.first,
              let space = currentSpace(on: display) else { return }
        let items = contents(of: space)
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == desktop.focusedWindow } ?? 0
        try backend.focus(window: items[(index + offset % items.count + items.count) % items.count].id); sync(try backend.desktop())
    }
    public func saveProfile(displayID: String?) throws { try captureVisibleLayouts(); try persist() }
    public func moveFocusedWindow(gridID: String, cellID: String, windowOverride: UInt32?) throws {
        guard let id = windowOverride ?? observed?.focusedWindow, let window = windows.first(where: { $0.id == id }) else { throw GridError.stale }
        try moveWindow(window.identity, to: cellID)
    }
    public func focusWindow(_ identity: WindowIdentity) throws {
        let desktop = try backend.desktop()
        guard desktop.windows?.contains(where: { $0.identity == identity }) == true else { throw GridError.stale }
        try backend.focus(window: identity.id); sync(try backend.desktop())
    }
    private func checkpoint() throws -> MapCheckpoint {
        let desktop = try backend.desktop()
        var layouts = map.layouts
        let normal = map.spaces.filter { $0.nativeWindow == nil }
        for space in normal {
            if desktop.windows?.contains(where: { $0.workspace == space.workspace }) == true {
                layouts[space.id] = try backend.snapshot(workspace: space.workspace)
            } else if desktop.windowHomes?.contains(where: { $0.workspace == space.workspace }) != true {
                // A vacated workspace must not retain the departing windows in its undo image.
                layouts[space.id] = try LayoutSnapshot(boot: desktop.windows?.first?.boot ?? "", tree: .root([])).json()
            }
        }
        return MapCheckpoint(spaces: map.spaces, families: map.families, fullscreens: map.fullscreens,
                             homes: desktop.windowHomes?.filter { home in Set(normal.map(\.workspace)).contains(home.workspace) && desktop.windows?.contains(where: { $0.id == home.id && $0.pid == home.pid && $0.boot == home.boot }) == true } ?? [], layouts: layouts)
    }
    private func restore(_ checkpoint: MapCheckpoint, restoreWindows: Bool = true) throws {
        let actual = try backend.desktop()
        let live = Set((actual.windows ?? []).map(\.identity))
        let homes = checkpoint.homes.filter { live.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: $0.boot)) }
        if restoreWindows { try backend.recoverWindowHomes(homes) }
        for space in checkpoint.spaces where restoreWindows && space.nativeWindow == nil {
            if let json = checkpoint.layouts[space.id], let saved = try? LayoutSnapshot(json: json), saved.boot == actual.windows?.first?.boot {
                try backend.restore(workspace: space.workspace, snapshot: json)
            }
        }
        editMap { map in map.spaces = checkpoint.spaces; map.families = checkpoint.families; map.fullscreens = checkpoint.fullscreens; if restoreWindows { map.layouts = checkpoint.layouts } }
        sync(try backend.desktop())
    }
    private func organize(_ label: String, _ work: () throws -> Void) throws {
        try refresh()
        guard let desktop = observed else { throw GridError.stale }
        let before = try checkpoint()
        editMap { $0.pending = PendingOrganization(before: before, desiredHomes: []) }; try persist()
        do {
            try work()
            guard try backend.desktop().topology == desktop.topology else { throw GridError.stale }
            sync(try backend.desktop())
            let after = try checkpoint()
            editMap { map in
                map.pending = nil; map.layouts = after.layouts
                map.undo.append(OrganizationUndo(label: label, before: before, after: after, topology: desktop.topology))
                if map.undo.count > 20 { map.undo.removeFirst(map.undo.count - 20) }
            }
            try persist()
        } catch { try restore(before); editMap { $0.pending = nil }; try persist(); throw error }
    }
    public func undo() throws {
        try refresh()
        guard let action = map.undo.last else { return }
        guard observed?.topology == action.topology else { throw GridError.stale }
        let current = try checkpoint()
        let live = Set(windows.map(\.identity))
        func survivingHomes(_ homes: [WindowHome]) -> Set<String> {
            Set(homes.filter { live.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: $0.boot)) }.map { "\($0.boot):\($0.pid):\($0.id):\($0.workspace):\($0.floating)" })
        }
        let expected = Dictionary(uniqueKeysWithValues:action.after.spaces.map { ($0.id,$0) })
        let comparable = current.spaces.map { space -> Space in
            var copy = space; copy.dormant = expected[space.id]?.dormant
            if expected[space.id]?.foldedRect == nil { copy.foldedRect = nil }
            return copy
        }
        guard comparable == action.after.spaces, survivingHomes(current.homes) == survivingHomes(action.after.homes) else { throw GridError.invalid("La organización cambió; Deshacer no sobrescribirá esos cambios") }
        // JSON key order and focus changes are not arrangement edits.
        let layoutOnlyChanged = Set(action.before.layouts.keys).union(action.after.layouts.keys).contains { id in
            let before = action.before.layouts[id].flatMap { try? LayoutSnapshot(json: $0) }
            let after = action.after.layouts[id].flatMap { try? LayoutSnapshot(json: $0) }
            return before?.boot != after?.boot || before?.tree != after?.tree || !floatingGeometryMatches(before?.floating ?? [], after?.floating ?? [])
        }
        if layoutOnlyChanged {
            for (id, json) in action.after.layouts {
                guard let expected = try? LayoutSnapshot(json: json), let currentJSON = current.layouts[id], let actual = try? LayoutSnapshot(json: currentJSON) else { continue }
                let expectedTree = expected.tree.retaining(live, boot: expected.boot)
                let currentTree = actual.tree.retaining(live, boot: actual.boot)
                let expectedFloats = expected.floating.filter { live.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: expected.boot)) }
                let actualFloats = actual.floating.filter { live.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: actual.boot)) }
                guard expectedTree == currentTree, floatingGeometryMatches(expectedFloats, actualFloats) else { throw GridError.invalid("El arrangement cambió; Deshacer no lo sobrescribirá") }
            }
        }
        let movedWindows = action.before.homes != action.after.homes
        try restore(action.before, restoreWindows: movedWindows || layoutOnlyChanged)
        editMap { $0.undo.removeLast() }; try persist()
    }
    private func floatingGeometryMatches(_ first: [FloatingLayout], _ second: [FloatingLayout]) -> Bool {
        guard first.count == second.count else { return false }
        let orderedFirst = first.sorted { ($0.id, $0.pid) < ($1.id, $1.pid) }
        let orderedSecond = second.sorted { ($0.id, $0.pid) < ($1.id, $1.pid) }
        return zip(orderedFirst, orderedSecond).allSatisfy { a, b in
            a.id == b.id && a.pid == b.pid && abs(a.x - b.x) < 0.000001 && abs(a.y - b.y) < 0.000001
                && abs(a.width - b.width) < 0.000001 && abs(a.height - b.height) < 0.000001
        }
    }
    public func createSpace(nearID: String?, displayID: String?, row: Int? = nil, column: Int? = nil, moving: WindowIdentity? = nil) throws -> String {
        let id = UUID().uuidString
        try organize("Crear espacio") {
            let display = self.observed?.displays.first { $0.id == displayID }
                ?? self.observed?.displays.first { $0.monitor == self.observed?.focusedMonitor }
            let preferred = display.map(self.role)
            let anchor = self.map.spaces.first { $0.id == nearID }
                ?? display.flatMap { self.currentSpace(on:$0) }
                ?? self.map.spaces.first { !$0.isDormant && (preferred == nil || $0.preferredRole == preferred) }
                ?? self.map.spaces.last!
            let combined = self.observed?.displays.count == 1
            let board = preferred ?? anchor.board
            let geometry = self.map.projectedSpaces(combined:combined).filter { !$0.isDormant && (combined || $0.board == board) }
            let projectedAnchor = geometry.first { $0.id == anchor.id } ?? geometry.first ?? anchor
            let neighbor = BoardOutline(spaces:geometry).nearestVacancy(to:projectedAnchor.rect)
                ?? GridPoint(row:projectedAnchor.row,column:projectedAnchor.rect.right)
            let targetAnchor = self.map.spaces.first { $0.board == board && !$0.isDormant }
                ?? self.map.spaces.first { $0.board == board } ?? anchor
            let canonical = self.map.frontier(near:targetAnchor)
            let position = combined ? canonical : SpaceRect(row:row ?? neighbor.row,column:column ?? neighbor.column)
            guard self.map.fits(position,board:board) else { throw GridError.invalid("La posición ya está ocupada") }
            var space = Space(id:id,name:"Nuevo espacio",row:position.row,column:position.column,
                workspace:"grid-space-\(id.replacingOccurrences(of:"-",with:""))",preferredRole:preferred ?? anchor.preferredRole)
            space.userCreated = true; space.dormant = false; space.boardID = board
            if combined {
                let frame = SpaceRect(row:row ?? neighbor.row,column:column ?? neighbor.column)
                guard !geometry.contains(where: { $0.rect.overlaps(frame) }) else { throw GridError.invalid("La posición ya está ocupada") }
                space.foldedRect = frame
            }
            self.editMap { $0.spaces.append(space) }
            if let moving {
                guard let window = self.windows.first(where: { $0.identity == moving }), !window.nativeFullscreen else { throw GridError.invalid("Esta ventana ya no está disponible para mover") }
                let sourceID = self.map.spaces.first { $0.workspace == window.workspace && $0.nativeWindow == nil }?.id
                try self.backend.moveVerified(window: moving, workspace: space.workspace)
                if let sourceID { self.markEdited(sourceID) }
            }
        }
        return id
    }
    public func removeEmptySpace(_ id:String) throws {
        let originalDesktop = observed, originalCursors = map.cursors
        var switched = false
        do {
            try organize("Eliminar espacio vacío") {
                guard let space = self.map.spaces.first(where: { $0.id == id }) else { throw GridError.invalid("El espacio ya no existe") }
                guard self.contents(of:space).isEmpty, space.nativeWindow == nil else { throw GridError.invalid("Mové o cerrá sus ventanas antes de eliminar el espacio") }
                guard !self.map.fullscreens.contains(where: { $0.homeID == id }) else {
                    throw GridError.invalid("Este espacio recibe una ventana en fullscreen. Salí de pantalla completa para eliminarlo")
                }
                guard self.map.spaces.count > 1, let desktop = self.observed else { throw GridError.invalid("Creá otro espacio antes de eliminar éste") }
                // Leave a visible empty workspace first, otherwise discovery recreates it on the next poll.
                for display in desktop.displays where self.currentSpace(on:display)?.id == id {
                    let allowed = self.eligibleSpaces(on:display).subtracting([id])
                    guard let target = self.map.spaces.filter({ allowed.contains($0.id) }).min(by: {
                        abs($0.row-space.row)+abs($0.column-space.column) < abs($1.row-space.row)+abs($1.column-space.column)
                    }) else { throw GridError.invalid("Creá o elegí otro espacio en esta pantalla antes de eliminar el actual") }
                    switched = true; try self.show(target,on:display)
                }
                self.editMap { map in
                    for index in map.families.indices.reversed() {
                        var family = map.families[index]
                        guard family.childIDs.contains(id) || family.sourceID == id else { continue }
                        family.childIDs.removeAll { $0 == id }
                        if family.childIDs.count < 2 {
                            for child in map.spaces.indices where family.childIDs.contains(map.spaces[child].id) { map.spaces[child].sourceID = nil }
                            map.families.remove(at:index)
                        } else {
                            if family.sourceID == id { family.sourceID = family.childIDs[0] }
                            family.manuallyEdited = true
                            for child in map.spaces.indices where family.childIDs.contains(map.spaces[child].id) {
                                map.spaces[child].sourceID = map.spaces[child].id == family.sourceID ? nil : family.sourceID
                            }
                            map.families[index] = family
                        }
                    }
                    map.spaces.removeAll { $0.id == id }; map.layouts.removeValue(forKey:id)
                    map.cursors = map.cursors.filter { $0.value != id }
                    map.connectedCursors = map.connectedCursors.filter { $0.value != id }
                    map.anchors = map.anchors?.filter { $0.value.spaceID != id }
                }
            }
        } catch {
            let failure = error
            if switched, let originalDesktop { try restoreVisible(originalDesktop,cursors:originalCursors) }
            throw failure
        }
    }
    public func revealEmptySpace(_ id: String) throws {
        try organize("Crear espacio") {
            guard let index = self.map.spaces.firstIndex(where: { $0.id == id }),
                  self.map.spaces[index].nativeWindow == nil else { throw GridError.stale }
            let space = self.map.spaces[index]
            guard self.map.fits(space.rect, board: space.board, excluding: [space.id]) else { throw GridError.invalid("Este lugar ya está ocupado") }
            self.editMap { $0.spaces[index].userCreated = true; $0.spaces[index].dormant = false }
        }
    }
    public func renameSpace(_ id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw GridError.invalid("Escribí un nombre de hasta 120 caracteres") }
        try organize("Renombrar espacio") {
            guard let index = self.map.spaces.firstIndex(where: { $0.id == id }) else { throw GridError.stale }
            self.editMap { $0.spaces[index].name = name; $0.spaces[index].automaticName = false }; self.markEdited(id)
        }
    }
    public func moveSpace(_ id: String, to targetID: String) throws {
        guard id != targetID else { return }
        try organize("Intercambiar espacios") {
            guard let i = self.map.spaces.firstIndex(where: { $0.id == id }),
                  let j = self.map.spaces.firstIndex(where: { $0.id == targetID }) else { throw GridError.stale }
            let origin = self.map.spaces[i], target = self.map.spaces[j]
            if (self.observed?.displays.count ?? 0) > 1 && origin.preferredRole != target.preferredRole && (origin.nativeWindow != nil || target.nativeWindow != nil) {
                throw GridError.invalid("El fullscreen no se puede intercambiar con otra pantalla")
            }
            if self.observed?.displays.count == 1 {
                let projected = self.map.projectedSpaces(combined: true)
                guard let a = projected.first(where: { $0.id == id }), let b = projected.first(where: { $0.id == targetID }) else { throw GridError.stale }
                var aRect = a.rect, bRect = b.rect
                aRect.row = b.row; aRect.column = b.column; bRect.row = a.row; bRect.column = a.column
                let others = projected.filter { $0.id != id && $0.id != targetID && !$0.isDormant }
                guard !aRect.overlaps(bRect), !others.contains(where: { $0.rect.overlaps(aRect) || $0.rect.overlaps(bRect) }) else { throw GridError.invalid("Los tamaños no permiten ese intercambio") }
                self.editMap { $0.spaces[i].foldedRect = aRect; $0.spaces[j].foldedRect = bRect }
                self.markEdited(id); self.markEdited(targetID); return
            }
            var next = self.map
            next.spaces[i].row = target.row; next.spaces[i].column = target.column
            next.spaces[j].row = origin.row; next.spaces[j].column = origin.column
            next.spaces[i].foldedRect = nil; next.spaces[j].foldedRect = nil
            next.spaces[i].boardID = target.board; next.spaces[i].preferredRole = target.preferredRole; next.spaces[i].preferredDisplay = target.preferredDisplay
            next.spaces[j].boardID = origin.board; next.spaces[j].preferredRole = origin.preferredRole; next.spaces[j].preferredDisplay = origin.preferredDisplay
            try next.validate()
            self.state.dynamicMap = next; self.markEdited(id); self.markEdited(targetID)
        }
    }
    public func insertSpace(_ id: String, beside targetID: String, edge: Direction) throws {
        guard id != targetID else { return }
        try organize("Reordenar espacios") {
            guard let source = self.map.spaces.first(where: { $0.id == id }),
                  let target = self.map.spaces.first(where: { $0.id == targetID }), !target.isDormant else { throw GridError.stale }
            let combined = self.observed?.displays.count == 1
            if !combined, source.nativeWindow != nil, source.preferredDisplay != target.preferredDisplay || source.preferredRole != target.preferredRole {
                let display = self.observed?.displays.first { $0.id == target.preferredDisplay || self.role($0) == target.preferredRole }
                guard let native = source.nativeWindow, let monitor = display?.monitor,
                      self.windows.first(where: { $0.identity == native })?.nativeMonitor == monitor else {
                    throw GridError.invalid("El fullscreen pertenece a otra pantalla física")
                }
            }
            var members = self.map.projectedSpaces(combined:combined).filter { combined || $0.board == target.board }
            if !members.contains(where: { $0.id == id }) { members.append(source) }
            let plan = try SpaceInsertion.plan(spaces:members,sourceID:id,targetID:targetID,edge:edge,closesSourceGap:combined || source.board == target.board)
            let changed = members.filter { plan[$0.id] != $0.rect }.map(\.id)
            var next = self.map
            for index in next.spaces.indices {
                let memberID = next.spaces[index].id
                guard let rect = plan[memberID] else { continue }
                if combined {
                    // Freeze the projection for unaffected members, too: a mixed-board
                    // edit must not make its unedited neighbors jump on the next refresh.
                    next.spaces[index].foldedRect = rect
                } else {
                    next.spaces[index].rect = rect; next.spaces[index].foldedRect = nil
                    if memberID == id {
                        next.spaces[index].boardID = target.board
                        next.spaces[index].preferredRole = target.preferredRole
                        next.spaces[index].preferredDisplay = target.preferredDisplay
                    }
                }
            }
            if let index = next.spaces.firstIndex(where: { $0.id == id }) {
                next.spaces[index].dormant = false; next.spaces[index].userCreated = true
            }
            try next.validate(); self.state.dynamicMap = next
            for memberID in Set(changed + [id]) { self.markEdited(memberID) }
        }
    }
    public func moveSpace(_ id: String, row: Int, column: Int) throws {
        guard let source = map.spaces.first(where: { $0.id == id }) else { throw GridError.stale }
        if let target = map.spaces.first(where: { $0.id != id && !$0.isDormant && $0.board == source.board && $0.rect.contains(row: row, column: column) }) {
            try moveSpace(id, to: target.id); return
        }
        try setSpaceRect(id, rect: SpaceRect(row: row, column: column, width: source.rect.width, height: source.rect.height))
    }
    public func setSpaceRect(_ id: String, rect: SpaceRect, displayID: String? = nil) throws {
        try organize("Cambiar posición o tamaño") {
            guard let index = self.map.spaces.firstIndex(where: { $0.id == id }) else { throw GridError.stale }
            var source = self.map.spaces[index]
            if let displayID, self.observed?.displays.count != 1 {
                guard let display = self.observed?.displays.first(where: { $0.id == displayID }) else { throw GridError.stale }
                if let native = source.nativeWindow, self.windows.first(where: { $0.identity == native })?.nativeMonitor != display.monitor { throw GridError.invalid("El fullscreen pertenece a otra pantalla") }
                source.preferredRole = self.role(display); source.boardID = source.preferredRole; source.preferredDisplay = displayID
            }
            if self.observed?.displays.count == 1 {
                guard (1...64).contains(rect.width), (1...64).contains(rect.height), abs(rect.row) <= 100000, abs(rect.column) <= 100000,
                      !self.map.projectedSpaces(combined: true).contains(where: { $0.id != id && !$0.isDormant && $0.rect.overlaps(rect) }) else { throw GridError.invalid("El casillero completo no cabe") }
                self.editMap { $0.spaces[index].foldedRect = rect; $0.spaces[index].userCreated = true }
                self.markEdited(id); return
            }
            guard self.map.fits(rect, board: source.board, excluding: [id]) else { throw GridError.invalid("El casillero completo no cabe; no se moverán los demás") }
            self.editMap { $0.spaces[index] = source; $0.spaces[index].foldedRect = nil; $0.spaces[index].rect = rect; $0.spaces[index].dormant = false; $0.spaces[index].userCreated = true }
            self.markEdited(id)
        }
    }
    public func assignSpace(_ id: String, displayID: String) throws {
        try organize("Asignar pantalla") {
            guard let display = self.observed?.displays.first(where: { $0.id == displayID }),
                  let index = self.map.spaces.firstIndex(where: { $0.id == id }) else { throw GridError.stale }
            var source = self.map.spaces[index]
            if let native = source.nativeWindow, self.windows.first(where: { $0.identity == native })?.nativeMonitor != display.monitor {
                throw GridError.invalid("El fullscreen pertenece a otra pantalla física")
            }
            source.foldedRect = nil
            source.preferredRole = self.role(display); source.boardID = source.preferredRole; source.preferredDisplay = display.id
            if !self.map.fits(source.rect, board: source.board, excluding: [id]) { source.rect = self.map.frontier(near: source, width: source.rect.width, height: source.rect.height) }
            source.dormant = false; source.userCreated = true
            self.editMap { $0.spaces[index] = source }; self.markEdited(id)
        }
    }
    public func moveWindow(_ identity: WindowIdentity, to destinationID: String, layout: String? = nil, orientation: String? = nil) throws {
        if layout != nil || orientation != nil {
            guard let layout, let orientation, ["tiles", "accordion"].contains(layout), ["h", "v"].contains(orientation) else { throw GridError.invalid("Invalid drop arrangement") }
        }
        try organize("Mover ventana") {
            guard let live = self.windows.first(where: { $0.identity == identity }), let target = self.map.spaces.first(where: { $0.id == destinationID }) else { throw GridError.stale }
            guard !live.nativeFullscreen, target.nativeWindow == nil else { throw GridError.invalid("Salí de fullscreen para reagrupar esta ventana; podés mover su casillero completo") }
            let source = self.map.spaces.first { $0.workspace == live.workspace && $0.nativeWindow == nil }
            try self.backend.moveVerified(window: identity, workspace: target.workspace)
            if let layout, let orientation {
                var saved = try self.snapshot(target); saved.tree.layout = layout; saved.tree.orientation = orientation
                try self.backend.restore(workspace: target.workspace, snapshot: saved.json())
            }
            if let source { self.markEdited(source.id) }
            self.markEdited(target.id)
        }
    }
    public func placeWindow(_ identity: WindowIdentity, in destinationID: String, group: Set<UInt32>, placement: WindowPlacement, expectedTarget: LayoutNode? = nil, expectedSourceWorkspace: String? = nil) throws {
        try organize("Distribuir ventana") {
            guard let live = self.windows.first(where: { $0.identity == identity }) else { throw GridError.invalid("La ventana ya no está disponible con el mismo dueño") }
            guard !live.nativeFullscreen, !live.floating else { throw GridError.invalid("Esta ventana es flotante o fullscreen; movela como ventana completa") }
            guard let target = self.map.spaces.first(where: { $0.id == destinationID }), target.nativeWindow == nil else { throw GridError.invalid("El espacio de destino ya no está disponible") }
            guard expectedSourceWorkspace == nil || live.workspace == expectedSourceWorkspace else { throw GridError.invalid("La ventana cambió de espacio durante la edición") }
            let source = self.map.spaces.first { $0.workspace == live.workspace && $0.nativeWindow == nil }
            let sourceLayout = try source.map(self.snapshot)
            func find(_ node: LayoutNode) -> LayoutNode? {
                if node.id == identity.id && node.pid == identity.pid { return node }
                return (node.children ?? []).compactMap(find).first
            }
            guard let incoming = sourceLayout.flatMap({ find($0.tree) }) else { throw GridError.invalid("La ventana ya no figura en el grupo de origen") }
            let saved = try self.snapshot(target)
            guard saved.boot == identity.boot else { throw GridError.invalid("El backend reinició durante la distribución") }
            guard expectedTarget == nil || saved.tree == expectedTarget else { throw GridError.invalid("La distribución cambió desde la vista previa; elegí de nuevo") }
            let result = try saved.placing(incoming, beside: group, placement: placement)
            if live.workspace != target.workspace { try self.backend.moveVerified(window: identity, workspace: target.workspace) }
            try self.backend.restore(workspace: target.workspace, snapshot: result.json())
            if let source { self.markEdited(source.id) }
            self.markEdited(target.id)
        }
    }
    public func makeMergePreview(_ sourceID: String, into targetID: String) throws -> MergePreview {
        try refresh()
        guard let source = map.spaces.first(where: { $0.id == sourceID }), let target = map.spaces.first(where: { $0.id == targetID }),
              source.id != target.id, source.nativeWindow == nil, target.nativeWindow == nil else { throw GridError.invalid("Seleccioná dos espacios normales diferentes") }
        let moving = contents(of: source), existing = contents(of: target)
        guard !moving.isEmpty else { throw GridError.invalid("El espacio de origen está vacío") }
        let sourceLayout = try snapshot(source), targetLayout = try snapshot(target)
        let result = try targetLayout.merging(sourceLayout, sourceOwners: Set(moving.map(\.identity)),
            targetOwners: Set(windows.filter { $0.workspace == target.workspace }.map(\.identity)), focus: sourceLayout.focus ?? moving.first?.id)
        return MergePreview(sourceID: source.id, targetID: target.id, sourceName: source.name, targetName: target.name,
                            sourceWindows: moving, targetWindows: existing, sourceLayout: sourceLayout, targetLayout: targetLayout, result: result)
    }
    public func mergeSpaces(_ sourceID: String, into targetID: String, expectedSource: Set<WindowIdentity>? = nil, expectedTarget: Set<WindowIdentity>? = nil) throws {
        guard sourceID != targetID else { return }
        try organize("Fusionar espacios") {
            guard let source = self.map.spaces.first(where: { $0.id == sourceID }), let target = self.map.spaces.first(where: { $0.id == targetID }),
                  source.nativeWindow == nil, target.nativeWindow == nil, source.workspace != target.workspace else { throw GridError.invalid("Seleccioná dos espacios normales diferentes") }
            let moving = self.contents(of: source), existing = self.contents(of: target)
            guard !moving.isEmpty else { throw GridError.invalid("El espacio de origen está vacío") }
            if let expectedSource, expectedSource != Set(moving.map(\.identity)) { throw GridError.invalid("Las ventanas cambiaron desde la previsualización; revisá la fusión") }
            if let expectedTarget, expectedTarget != Set(existing.map(\.identity)) { throw GridError.invalid("Las ventanas cambiaron desde la previsualización; revisá la fusión") }
            let sourceLayout = try self.snapshot(source), targetLayout = try self.snapshot(target)
            let focus = sourceLayout.focus.flatMap { id in moving.contains(where: { $0.id == id }) ? id : nil } ?? moving.first?.id
            let merged = try targetLayout.merging(sourceLayout, sourceOwners: Set(moving.map(\.identity)),
                targetOwners: Set(self.windows.filter { $0.workspace == target.workspace }.map(\.identity)), focus: focus)
            for window in moving { try self.backend.moveVerified(window: window.identity, workspace: target.workspace) }
            let json = try merged.json()
            try self.backend.restore(workspace: target.workspace, snapshot: json)
            self.editMap { $0.layouts[target.id] = json }
            self.markEdited(source.id); self.markEdited(target.id)
            if let desktop = self.observed {
                let visible = desktop.displays.first { self.currentSpace(on: $0)?.id == target.id }
                let preferred = desktop.displays.first { $0.id == target.preferredDisplay }
                    ?? desktop.displays.first { self.role($0) == target.preferredRole }
                if let display = visible ?? preferred ?? desktop.displays.first { try self.show(target, on: display) }
            }
        }
    }
    public func arrange(_ spaceID: String, layout: String, orientation: String) throws {
        guard ["tiles", "accordion"].contains(layout), ["h", "v"].contains(orientation) else { throw GridError.invalid("Invalid arrangement") }
        try organize("Cambiar distribución") {
            guard let space = self.map.spaces.first(where: { $0.id == spaceID }), space.nativeWindow == nil else { throw GridError.stale }
            var saved = try self.snapshot(space); saved.tree.layout = layout; saved.tree.orientation = orientation
            try self.backend.restore(workspace: space.workspace, snapshot: saved.json()); self.markEdited(spaceID)
        }
    }
    public func reorderWindow(_ identity: WindowIdentity, before target: WindowIdentity) throws {
        guard identity != target else { return }
        try organize("Ordenar ventanas") {
            guard let window = self.windows.first(where: { $0.identity == identity }), let other = self.windows.first(where: { $0.identity == target }),
                  !window.nativeFullscreen, !other.nativeFullscreen, let space = self.map.spaces.first(where: { $0.workspace == other.workspace && $0.nativeWindow == nil }) else { throw GridError.stale }
            guard !window.floating, !other.floating else { throw GridError.invalid("Mové las ventanas flotantes al casillero; su posición se conserva por separado") }
            if window.workspace != other.workspace {
                if let source = self.map.spaces.first(where: { $0.workspace == window.workspace && $0.nativeWindow == nil }) { self.markEdited(source.id) }
                try self.backend.moveVerified(window: identity, workspace: other.workspace)
            }
            var saved = try self.snapshot(space)
            func leaf(_ node: LayoutNode, matching identity: WindowIdentity) -> LayoutNode? {
                if node.id == identity.id && node.pid == identity.pid { return node }
                return (node.children ?? []).compactMap { leaf($0, matching: identity) }.first
            }
            func shareParent(_ node: LayoutNode) -> Bool {
                let children = node.children ?? []
                if children.contains(where: { $0.id == identity.id }) && children.contains(where: { $0.id == target.id }) { return true }
                return children.contains(where: shareParent)
            }
            guard var incoming = leaf(saved.tree, matching: identity), let destination = leaf(saved.tree, matching: target) else { throw GridError.stale }
            if window.workspace != other.workspace || !shareParent(saved.tree) { incoming.weight = destination.weight }
            func removing(_ node: LayoutNode) -> LayoutNode {
                var node = node; node.children = node.children?.filter { $0.id != identity.id }.map(removing); return node
            }
            func inserting(_ node: LayoutNode) -> LayoutNode {
                var node = node
                if var children = node.children {
                    if let index = children.firstIndex(where: { $0.id == target.id }) { children.insert(incoming, at: index) }
                    else { children = children.map(inserting) }
                    node.children = children
                }
                return node
            }
            saved.tree = inserting(removing(saved.tree)); try self.backend.restore(workspace: space.workspace, snapshot: saved.json()); self.markEdited(space.id)
        }
    }
}
