import Foundation

extension RuntimeState {
    /// Versions that used kern.boottime can differ by a few seconds within one session.
    /// Require a surviving owner as well as a close boot timestamp before rewriting IDs.
    mutating func migrateBootIdentity(using desktop: Desktop) -> Bool {
        guard var previous = lastDesktop, previous.bootSession == nil,
              let boot = desktop.bootSession, let wallTime = desktop.legacyBootTime.flatMap(Int64.init),
              wallTime > 5, wallTime < Int64.max - 5 else { return false }
        let allowed = (wallTime - 5)...(wallTime + 5)
        func isLegacy(_ value: String) -> Bool { Int64(value).map(allowed.contains) == true }
        let live = Set((desktop.windows ?? []).map(\.identity) + (desktop.windowHomes ?? []).map {
            WindowIdentity(id: $0.id, pid: $0.pid, boot: $0.boot)
        })
        guard previous.windows?.contains(where: { isLegacy($0.boot)
            && live.contains(WindowIdentity(id: $0.id, pid: $0.pid, boot: boot)) }) == true else { return false }

        func identity(_ value: WindowIdentity) -> WindowIdentity {
            isLegacy(value.boot) ? WindowIdentity(id: value.id, pid: value.pid, boot: boot) : value
        }
        func migrate<Value>(_ value: Value, at key: WritableKeyPath<Value, String>) -> Value {
            var result = value
            if isLegacy(result[keyPath: key]) { result[keyPath: key] = boot }
            return result
        }
        func layoutJSON(_ json: String) -> String {
            guard let snapshot = try? LayoutSnapshot(json: json), isLegacy(snapshot.boot) else { return json }
            return (try? migrate(snapshot, at: \.boot).json()) ?? json
        }
        func space(_ value: Space) -> Space {
            var result = value
            result.nativeWindow = value.nativeWindow.map(identity)
            return result
        }
        func link(_ value: FullscreenLink) -> FullscreenLink {
            var result = value
            result.identity = identity(value.identity)
            result.original = value.original.map { migrate($0, at: \.boot) }
            return result
        }
        func family(_ value: SplitFamily) -> SplitFamily {
            var result = value
            result.original = migrate(value.original, at: \.boot)
            return result
        }
        func checkpoint(_ value: MapCheckpoint) -> MapCheckpoint {
            var result = value
            result.spaces = value.spaces.map(space)
            result.fullscreens = value.fullscreens.map(link)
            result.families = value.families.map(family)
            result.homes = value.homes.map { migrate($0, at: \.boot) }
            result.layouts = value.layouts.mapValues(layoutJSON)
            return result
        }

        previous.bootSession = boot
        previous.windows = previous.windows?.map { migrate($0, at: \.boot) }
        previous.windowHomes = previous.windowHomes?.map { migrate($0, at: \.boot) }
        lastDesktop = previous
        snapshots = snapshots.mapValues(layoutJSON)
        guard var map = dynamicMap else { return true }
        map.spaces = map.spaces.map(space)
        map.fullscreens = map.fullscreens.map(link)
        map.families = map.families.map(family)
        map.layouts = map.layouts.mapValues(layoutJSON)
        if let places = map.fullscreenPlaces {
            var seen: Set<WindowIdentity> = []
            map.fullscreenPlaces = places.sorted { $0.removedAt > $1.removedAt }.compactMap { place in
                let migrated = space(place.space)
                guard let window = migrated.nativeWindow, seen.insert(window).inserted else { return nil }
                return FullscreenPlace(space: migrated, manuallyEdited: place.manuallyEdited, removedAt: place.removedAt)
            }
        }
        map.undo = map.undo.map {
            OrganizationUndo(label: $0.label, before: checkpoint($0.before), after: checkpoint($0.after), topology: $0.topology)
        }
        if let pending = map.pending {
            map.pending = PendingOrganization(before: checkpoint(pending.before), desiredHomes: pending.desiredHomes.map { migrate($0, at: \.boot) })
        }
        if let restore = map.placeRestore, isLegacy(restore.boot) {
            map.placeRestore = PlaceRestoreState(boot: boot, restored: restore.restored.map(identity), userPlaced: restore.userPlaced.map(identity))
        }
        dynamicMap = map
        return true
    }
}

extension SpaceMap {
    mutating func recoverEditedFullscreenPositions(live: Set<WindowIdentity>) -> (resolved: Bool, recovered: Int) {
        // A false reboot regenerated a card without its edit flag. Recover its last
        // explicit laptop position only when the same live window and home still match.
        var resolved = true
        var recovered = 0
        for linkIndex in fullscreens.indices where !fullscreens[linkIndex].manuallyEdited {
            let link = fullscreens[linkIndex]
            guard let index = spaces.firstIndex(where: { $0.id == link.spaceID }) else { continue }
            let saved = undo.reversed().lazy.compactMap { action -> SpaceRect? in
                let history = action.after
                guard let edited = history.fullscreens.first(where: {
                    $0.manuallyEdited && $0.homeID == link.homeID && $0.identity == link.identity
                }) else { return nil }
                return history.spaces.first { $0.id == edited.spaceID }?.foldedRect
            }.first
            guard let saved, saved.isValid, !spaces.contains(where: {
                $0.id != link.spaceID && !$0.isDormant && $0.foldedRect?.overlaps(saved) == true
            }) else { continue }
            guard live.contains(link.identity) else {
                resolved = false
                continue
            }
            spaces[index].foldedRect = saved
            fullscreens[linkIndex].manuallyEdited = true
            recovered += 1
        }
        return (resolved, recovered)
    }
}
