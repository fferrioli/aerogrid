import Foundation

/// Geometry belongs to the logical map, not the physical window layout.
public struct SpaceRect: Codable, Equatable, Hashable {
    public var row: Int
    public var column: Int
    public var width: Int
    public var height: Int
    public init(row: Int, column: Int, width: Int = 1, height: Int = 1) {
        self.row = row; self.column = column; self.width = width; self.height = height
    }
    public var isValid: Bool {
        (1...64).contains(width) && (1...64).contains(height) && (-100000...100000).contains(row) && (-100000...100000).contains(column)
    }
    public var right: Int { column + width }
    public var bottom: Int { row + height }
    public func overlaps(_ other: SpaceRect) -> Bool {
        column < other.right && right > other.column && row < other.bottom && bottom > other.row
    }
    public func contains(row: Int, column: Int) -> Bool {
        row >= self.row && row < bottom && column >= self.column && column < right
    }
}

/// Automatic additions use a nearby edge, without moving existing spatial landmarks.
public enum SpacePlacement {
    public static func nearestVacancy(near origin: SpaceRect, occupied: [SpaceRect], width: Int = 1, height: Int = 1) -> SpaceRect {
        var candidates = Set<SpaceRect>()
        for rect in occupied + [origin] {
            for row in (rect.row - height + 1)..<rect.bottom {
                candidates.insert(SpaceRect(row: row, column: rect.right, width: width, height: height))
                candidates.insert(SpaceRect(row: row, column: rect.column - width, width: width, height: height))
            }
            for column in (rect.column - width + 1)..<rect.right {
                candidates.insert(SpaceRect(row: rect.bottom, column: column, width: width, height: height))
                candidates.insert(SpaceRect(row: rect.row - height, column: column, width: width, height: height))
            }
        }
        func score(_ rect: SpaceRect) -> (Int, Int, Int, Int, Int) {
            let gap = max(origin.column - rect.right + 1, rect.column - origin.right + 1, 0)
                + max(origin.row - rect.bottom + 1, rect.row - origin.bottom + 1, 0)
            let direction: Int
            if rect.column >= origin.right { direction = 0 }
            else if rect.row >= origin.bottom { direction = 1 }
            else if rect.right <= origin.column { direction = 2 }
            else { direction = 3 }
            let alignment = abs(rect.row - origin.row) + abs(rect.column - origin.column)
            return (gap, direction, alignment, rect.row, rect.column)
        }
        return candidates.filter { candidate in
            candidate.isValid && !occupied.contains { $0.overlaps(candidate) }
        }.min { score($0) < score($1) } ?? SpaceRect(row: origin.row, column: origin.right, width: width, height: height)
    }
}

/// Intent survives a narrow destination; an effective point can be clamped for drawing only.
public struct NavigationAnchor: Codable, Equatable {
    public var spaceID: String
    public var x: Double
    public var y: Double
    public var frame: SpaceRect? = nil
    public init(space: Space) { frame = space.rect; spaceID = space.id; x = Double(space.column) + 0.5; y = Double(space.row) + 0.5 }
    public init(spaceID: String, x: Double, y: Double) { self.spaceID = spaceID; self.x = x; self.y = y }
    public func entering(_ space: Space, direction: Direction) -> NavigationAnchor {
        var next = self; next.spaceID = space.id; next.frame = space.rect
        switch direction {
        case .right: next.x = Double(space.column) + 0.5
        case .left: next.x = Double(space.rect.right) - 0.5
        case .down: next.y = Double(space.row) + 0.5
        case .up: next.y = Double(space.rect.bottom) - 0.5
        }
        return next
    }
}

extension Space {
    public var board: String { boardID ?? preferredRole }
    public var rect: SpaceRect {
        get { SpaceRect(row: row, column: column, width: spanColumns ?? 1, height: spanRows ?? 1) }
        set { row = newValue.row; column = newValue.column; spanColumns = newValue.width; spanRows = newValue.height }
    }
    public var isDormant: Bool { dormant == true && !userCreated && nativeWindow == nil }
}

public enum SpatialNavigation {
    public static func candidates(from origin: Space, anchor: NavigationAnchor?, direction: Direction, spaces: [Space], eligible: Set<String>) -> [Space] {
        let entry = anchor?.spaceID == origin.id ? anchor! : NavigationAnchor(space: origin)
        let horizontal = direction == .left || direction == .right
        struct Candidate {
            var space: Space
            var gap: Int
            var perpendicularDistance: Double
            var overlaps: Bool
        }
        let ranked = spaces.compactMap { space -> Candidate? in
            guard space.id != origin.id, eligible.contains(space.id) else { return nil }
            let a = origin.rect, b = space.rect
            let gap: Int
            switch direction {
            case .left: gap = a.column - b.right
            case .right: gap = b.column - a.right
            case .up: gap = a.row - b.bottom
            case .down: gap = b.row - a.bottom
            }
            guard gap >= 0 else { return nil }
            let start = Double(horizontal ? b.row : b.column)
            let end = Double(horizontal ? b.bottom : b.right)
            let intent = horizontal ? entry.y : entry.x
            let overlap = horizontal ? b.row < a.bottom && b.bottom > a.row : b.column < a.right && b.right > a.column
            return Candidate(space: space, gap: gap, perpendicularDistance: max(start - intent, intent - end, 0), overlaps: overlap)
        }
        return ranked.sorted { a, b in
            if a.overlaps != b.overlaps { return a.overlaps }
            if a.gap != b.gap { return a.gap < b.gap }
            if a.perpendicularDistance != b.perpendicularDistance { return a.perpendicularDistance < b.perpendicularDistance }
            if a.space.row != b.space.row { return a.space.row < b.space.row }
            if a.space.column != b.space.column { return a.space.column < b.space.column }
            return a.space.id < b.space.id
        }.map(\.space)
    }
}

/// Moves complete footprints. App membership and the window layout are deliberately untouched.
public enum SpaceInsertion {
    public static func plan(spaces: [Space], sourceID: String, targetID: String, edge: Direction, closesSourceGap: Bool = true) throws -> [String: SpaceRect] {
        guard sourceID != targetID,
              let source = spaces.first(where: { $0.id == sourceID }),
              let target = spaces.first(where: { $0.id == targetID }) else { throw GridError.stale }
        let horizontal = edge == .left || edge == .right
        func start(_ rect: SpaceRect) -> Int { horizontal ? rect.column : rect.row }
        func end(_ rect: SpaceRect) -> Int { horizontal ? rect.right : rect.bottom }
        func sameLane(_ rect: SpaceRect) -> Bool {
            horizontal ? rect.row == source.row && rect.height == source.rect.height
                : rect.column == source.column && rect.width == source.rect.width
        }
        func positioned(_ rect: SpaceRect, at value: Int) -> SpaceRect {
            var copy = rect
            if horizontal { copy.column = value } else { copy.row = value }
            return copy
        }
        let members = spaces.filter { !$0.isDormant || $0.id == sourceID }
        var result = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.rect) })
        // Reorder a contiguous lane in place, filling the source's old slot. Deliberate
        // gaps and unrelated rows/columns are never compacted.
        let lane = members.filter { sameLane($0.rect) }.sorted { start($0.rect) < start($1.rect) }
        if closesSourceGap, let a = lane.firstIndex(where: { $0.id == sourceID }), let b = lane.firstIndex(where: { $0.id == targetID }) {
            let low = min(a,b), high = max(a,b)
            var run = Array(lane[low...high])
            if zip(run,run.dropFirst()).allSatisfy({ end($0.rect) == start($1.rect) }) {
                let origin = start(run[0].rect)
                run.removeAll { $0.id == sourceID }
                let targetIndex = run.firstIndex { $0.id == targetID }!
                let after = edge == .right || edge == .down
                run.insert(source,at:targetIndex + (after ? 1 : 0))
                var position = origin
                for space in run {
                    result[space.id] = positioned(space.rect,at:position)
                    position += end(space.rect)-start(space.rect)
                }
                return result
            }
        }
        var incoming = source.rect
        incoming.row = target.row; incoming.column = target.column
        if edge == .right { incoming.column = target.rect.right }
        if edge == .down { incoming.row = target.rect.bottom }
        result[sourceID] = incoming
        var placed: [(original: SpaceRect?, rect: SpaceRect)] = [(nil,incoming)]
        // Outside a contiguous lane, insert locally and push only colliding cells
        // forward along that axis, including any resulting collision chain.
        for space in members.filter({ $0.id != sourceID }).sorted(by: {
            if start($0.rect) != start($1.rect) { return start($0.rect) < start($1.rect) }
            return $0.id < $1.id
        }) {
            var rect = space.rect
            for previous in placed {
                guard let original = previous.original else { continue }
                let overlapsLane = horizontal ? original.row < rect.bottom && original.bottom > rect.row
                    : original.column < rect.right && original.right > rect.column
                if overlapsLane && end(original) <= start(space.rect) {
                    rect = positioned(rect,at:max(start(rect),end(previous.rect)))
                }
            }
            while let boundary = placed.map(\.rect).filter({ $0.overlaps(rect) }).map(end).max() {
                rect = positioned(rect,at:boundary)
            }
            guard rect.isValid else { throw GridError.invalid("No hay lugar para insertar este espacio") }
            result[space.id] = rect; placed.append((space.rect,rect))
        }
        guard incoming.isValid else { throw GridError.invalid("No hay lugar para insertar este espacio") }
        return result
    }
}

extension SpaceMap {
    /// Keep valid adapted positions; rebuild only those that conflict. Window layouts and
    /// the independent display boards are untouched. Projection places cleared entries.
    @discardableResult public mutating func repairAdaptedGeometry() -> [String] {
        var occupied: [SpaceRect] = [], repaired: [String] = []
        for index in spaces.indices where !spaces[index].isDormant {
            guard let frame = spaces[index].foldedRect else { continue }
            if occupied.contains(where: { $0.overlaps(frame) }) {
                spaces[index].foldedRect = nil
                repaired.append(spaces[index].id)
            } else { occupied.append(frame) }
        }
        return repaired
    }
    /// Coordinates are local to a board. Combining displays is a projection, never a rewrite.
    public func projectedSpaces(combined: Bool) -> [Space] {
        guard combined else { return spaces }
        let boardIDs = Set(spaces.filter { !$0.isDormant }.map(\.board)).sorted {
            if ($0 == "builtin") != ($1 == "builtin") { return $0 == "builtin" }
            return $0 < $1
        }
        var result: [Space] = [], nextRow = 0
        for board in boardIDs {
            let members = spaces.filter { $0.board == board }
            let visible = members.filter { !$0.isDormant }
            let minRow = visible.map(\.row).min() ?? 0
            let offset = board == "builtin" ? 0 : nextRow - minRow
            result += members.map { space in var copy = space; copy.row += offset; return copy }
            nextRow = (result.filter { !$0.isDormant }.map { $0.rect.bottom }.max() ?? nextRow)
        }
        // Once adapted, edits on the small display do not shift another board.
        var placed = result.filter { $0.foldedRect != nil && !$0.isDormant }.map { space in
            var copy = space; copy.rect = space.foldedRect!; return copy
        }
        for var space in result where space.foldedRect == nil && !space.isDormant {
            // A generated child follows its source's adapted position, which may
            // differ from the canonical board offset after a laptop edit.
            if let sourceID = space.sourceID,
               let source = result.first(where: { $0.id == sourceID }),
               let adaptedSource = placed.first(where: { $0.id == sourceID }) {
                space.row += adaptedSource.row - source.row
                space.column += adaptedSource.column - source.column
            }
            if placed.contains(where: { $0.rect.overlaps(space.rect) }) {
                let anchor = placed.first { $0.id == space.sourceID }?.rect ?? space.rect
                space.rect = SpacePlacement.nearestVacancy(near: anchor, occupied: placed.map(\.rect), width: space.rect.width, height: space.rect.height)
            }
            placed.append(space)
        }
        return placed + result.filter(\.isDormant)
    }
    public func fits(_ rect: SpaceRect, board: String, excluding: Set<String> = []) -> Bool {
        guard rect.isValid else { return false }
        return !spaces.contains { $0.board == board && !$0.isDormant && !excluding.contains($0.id) && $0.rect.overlaps(rect) }
    }
    /// Automatic discoveries grow the frontier instead of consuming intentional interior gaps.
    public func frontier(near origin: Space, width: Int = 1, height: Int = 1) -> SpaceRect {
        let members = spaces.filter { $0.board == origin.board && !$0.isDormant }
        let column = members.map { $0.rect.right }.max() ?? origin.rect.right
        var candidate = SpaceRect(row: origin.row, column: column, width: width, height: height)
        while !fits(candidate, board: origin.board) && candidate.row < 100000 { candidate.row += 1 }
        return candidate
    }
    /// Version-2 offsets are an import artifact. Ownership is taken from roles, not column ranges.
    public mutating func migrateSpatial(configuration: Configuration, desktop: Desktop?) throws {
        guard version < 3 else { return }
        var offsets: [String: Int] = [:], offset = 0
        for grid in configuration.grids {
            offsets[grid.displayRole] = offsets[grid.displayRole] ?? offset
            offset += grid.columns + 1
        }
        for index in spaces.indices {
            spaces[index].boardID = spaces[index].preferredRole
            spaces[index].column -= offsets[spaces[index].preferredRole] ?? 0
            spaces[index].spanRows = 1; spaces[index].spanColumns = 1
            let occupied = desktop?.windows?.contains { $0.workspace == spaces[index].workspace } == true
                || desktop?.visible.values.contains(spaces[index].workspace) == true
            let saved = layouts[spaces[index].id].flatMap { try? LayoutSnapshot(json: $0) }
            let used = occupied || saved?.tree.ids.isEmpty == false || saved?.floating.isEmpty == false
            spaces[index].dormant = !used && !spaces[index].userCreated && spaces[index].sourceID == nil
        }
        // Old undo checkpoints contain global positions. Keep them in the migration backup.
        undo = []; anchors = [:]; version = 3
        try validate()
    }
}
