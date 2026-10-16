import Foundation

/// A gesture previews this immutable observation. It never activates intermediate workspaces.
public struct NavigationSelection {
    public let topology: String
    public let originDisplayID: String
    public let origin: [String: NavigationAnchor]
    public private(set) var selected: [String: NavigationAnchor]
    public let spaces: [Space]
    public let eligible: [String: Set<String>]
    public let owners: [String: Set<WindowIdentity>]
    private var history: [(direction: Direction, before: [String: NavigationAnchor])] = []
    public init(map: SpaceMap, configuration: Configuration, desktop: Desktop, scope: Scope, displayID: String?) throws {
        let active: Display
        if let displayID {
            guard let captured = desktop.displays.first(where: { $0.id == displayID }) else { throw GridError.stale }
            active = captured
        } else {
            guard let focused = desktop.displays.first(where: { $0.monitor == desktop.focusedMonitor }) else { throw GridError.stale }
            active = focused
        }
        topology = desktop.topology; originDisplayID = active.id
        spaces = map.projectedSpaces(combined: desktop.displays.count == 1)
        let displays = scope == .all ? desktop.displays : [active]
        var entries: [String: NavigationAnchor] = [:], allowed: [String: Set<String>] = [:]
        var memberships: [String: Set<WindowIdentity>] = [:]
        for space in spaces {
            memberships[space.id] = Set(Self.contents(space, desktop: desktop).map(\.identity))
        }
        for display in displays {
            guard let current = Self.current(map: map, display: display, desktop: desktop),
                  let projected = spaces.first(where: { $0.id == current.id }) else { throw GridError.boundary }
            var remembered = map.anchors?[display.id]
            if let old = remembered?.frame, remembered?.spaceID == current.id {
                remembered?.x += Double(projected.column-old.column)
                remembered?.y += Double(projected.row-old.row)
                remembered?.frame = projected.rect
            }
            entries[display.id] = remembered?.spaceID == current.id ? remembered : NavigationAnchor(space: projected)
            allowed[display.id] = Self.eligible(map: map, configuration: configuration, display: display, desktop: desktop)
        }
        origin = entries; selected = entries; eligible = allowed; owners = memberships
    }
    @discardableResult public mutating func step(_ direction: Direction) -> Bool {
        if let last = history.last, Self.opposite(last.direction) == direction {
            selected = last.before; history.removeLast(); return true
        }
        var candidates: [String: [String]] = [:]
        for display in selected.keys.sorted() {
            guard let entry = selected[display], let source = spaces.first(where: { $0.id == entry.spaceID }) else { return false }
            candidates[display] = SpatialNavigation.candidates(from: source, anchor: entry, direction: direction, spaces: spaces,
                eligible: eligible[display] ?? []).map(\.id)
        }
        guard let destinations = CoordinatedDestinations.resolve(candidates) else { return false }
        var next = selected
        for (display, id) in destinations {
            guard let target = spaces.first(where: { $0.id == id }), let entry = selected[display] else { return false }
            next[display] = entry.entering(target, direction: direction)
        }
        history.append((direction, selected)); selected = next
        return true
    }
    public var isAtOrigin: Bool { selected.mapValues(\.spaceID) == origin.mapValues(\.spaceID) }
    public func validate(map: SpaceMap, configuration: Configuration, desktop: Desktop) throws {
        guard desktop.topology == topology else { throw GridError.stale }
        let actual = map.projectedSpaces(combined: desktop.displays.count == 1)
        for (displayID, entry) in origin {
            guard let display = desktop.displays.first(where: { $0.id == displayID }),
                  Self.current(map: map, display: display, desktop: desktop)?.id == entry.spaceID,
                  let destination = selected[displayID]?.spaceID,
                  (destination == entry.spaceID || Self.eligible(map: map, configuration: configuration, display: display, desktop: desktop).contains(destination)) else { throw GridError.stale }
            for id in Set([entry.spaceID, destination]) {
                guard let before = spaces.first(where: { $0.id == id }), let now = actual.first(where: { $0.id == id }),
                      before.rect == now.rect, before.board == now.board, before.nativeWindow == now.nativeWindow,
                      owners[id] == Set(Self.contents(now, desktop: desktop).map(\.identity)) else {
                    throw GridError.invalid("El mapa cambió durante el gesto; se canceló la selección")
                }
            }
        }
    }
    public static func current(map: SpaceMap, display: Display, desktop: Desktop) -> Space? {
        if let native = desktop.nativeVisible?[display.monitor] { return map.spaces.first { $0.nativeWindow?.id == native } }
        return map.spaces.first { $0.nativeWindow == nil && $0.workspace == desktop.visible[display.monitor] }
    }
    public static func contents(_ space: Space, desktop: Desktop) -> [WindowInfo] {
        if let native = space.nativeWindow { return (desktop.windows ?? []).filter { $0.identity == native && $0.nativeFullscreen } }
        return (desktop.windows ?? []).filter { $0.workspace == space.workspace && !$0.nativeFullscreen }
    }
    public static func eligible(map: SpaceMap, configuration: Configuration, display: Display, desktop: Desktop) -> Set<String> {
        let elsewhere = Set(desktop.displays.filter { $0.id != display.id }.compactMap { current(map: map, display: $0, desktop: desktop)?.id })
        let role = configuration.displayAssignments.first { $0.value == display.id }?.key ?? (display.builtin ? "builtin" : "external")
        return Set(map.spaces.filter { space in
            guard !elsewhere.contains(space.id), (space.userCreated || !contents(space, desktop: desktop).isEmpty) else { return false }
            if let native = space.nativeWindow { return desktop.windows?.first { $0.identity == native }?.nativeMonitor == display.monitor }
            if desktop.displays.count == 1 { return true }
            return space.preferredDisplay.map { $0 == display.id } ?? (space.preferredRole == role)
        }.map(\.id))
    }
    private static func opposite(_ direction: Direction) -> Direction {
        switch direction { case .left: return .right; case .right: return .left; case .up: return .down; case .down: return .up }
    }
}
