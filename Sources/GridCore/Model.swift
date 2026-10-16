import Foundation

public enum Direction: String, Codable, CaseIterable { case left, right, up, down }
public enum Scope: String, Codable, CaseIterable { case active, all }
public enum Targeting: String, Codable, CaseIterable { case pointer, focused }
public enum Profile: String, Codable, CaseIterable { case automatic, wide, compact, vertical }
public enum GridError: Error, LocalizedError {
    case invalid(String), boundary, unavailable(String), stale
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s): return s
        case .boundary: return "Grid boundary — no displays moved"
        case .stale: return "Displays changed during the operation"
        }
    }
}
public struct Cell: Codable, Equatable, Identifiable {
    public var id: String
    public var row: Int
    public var column: Int
    public var name: String
    public var workspace: String
    public var profile: Profile = .automatic
    public var displayProfiles: [String: Profile]? = nil
    public init(id: String = UUID().uuidString, row: Int, column: Int, name: String, workspace: String) {
        self.id = id; self.row = row; self.column = column; self.name = name; self.workspace = workspace
    }
}
public struct Grid: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var displayRole: String
    public var rows: Int
    public var columns: Int
    public var wrap: Bool
    public var cells: [Cell]
    public init(id: String, name: String, displayRole: String, rows: Int = 3, columns: Int = 3, wrap: Bool = false, cells: [Cell]? = nil) {
        self.id = id; self.name = name; self.displayRole = displayRole; self.rows = rows; self.columns = columns; self.wrap = wrap
        self.cells = cells ?? (0..<rows).flatMap { r in (0..<columns).map { c in
            Cell(row: r, column: c, name: "\(r + 1),\(c + 1)", workspace: "grid-\(id)-\(r + 1)-\(c + 1)")
        } }
    }
    public func neighbor(of id: String, direction: Direction) -> Cell? {
        guard let cell = cells.first(where: { $0.id == id }) else { return nil }
        var r = cell.row, c = cell.column
        switch direction { case .left: c -= 1; case .right: c += 1; case .up: r -= 1; case .down: r += 1 }
        if wrap { r = (r + rows) % rows; c = (c + columns) % columns }
        return cells.first { $0.row == r && $0.column == c }
    }
}
public struct GestureBinding: Codable, Equatable, Identifiable {
    public var id: String { "\(fingers):\(modifiers):\(direction.rawValue)" }
    public var fingers: Int
    public var modifiers: Int // shift=1, control=2, option=4, command=8
    public var direction: Direction
    public var action: String // navigate, next-grid, previous-grid, next-window, previous-window, overview
    public var scope: Scope
    public init(fingers: Int, modifiers: Int = 0, direction: Direction, action: String = "navigate", scope: Scope = .active) {
        self.fingers = fingers; self.modifiers = modifiers; self.direction = direction; self.action = action; self.scope = scope
    }
}
public struct Configuration: Codable, Equatable {
    public var version = 1
    public var grids: [Grid]
    public var displayAssignments: [String: String] = [:] // logical role -> CG display UUID
    public var targeting: Targeting = .pointer
    public var threshold: Double = 0.055
    public var invert = false
    public var bindings: [GestureBinding]
    public var automaticLayouts = true
    public var compactMinimumWidth: Double = 650
    public var backendPath: String
    public init(backendPath: String) {
        self.backendPath = backendPath
        grids = [Grid(id: "laptop", name: "MacBook", displayRole: "builtin"), Grid(id: "external", name: "Ultrawide", displayRole: "external")]
        bindings = Direction.allCases.flatMap { [GestureBinding(fingers: 3, direction: $0), GestureBinding(fingers: 4, direction: $0, scope: .all)] }
        bindings += [GestureBinding(fingers: 3, modifiers: 4, direction: .right, action: "next-grid"), GestureBinding(fingers: 3, modifiers: 4, direction: .left, action: "previous-grid"), GestureBinding(fingers: 3, modifiers: 4, direction: .up, action: "next-window"), GestureBinding(fingers: 3, modifiers: 4, direction: .down, action: "previous-window")]
    }
    public func validate() throws {
        guard version == 1 else { throw GridError.invalid("Unsupported configuration version \(version)") }
        guard !grids.isEmpty, grids.count <= 16 else { throw GridError.invalid("Configure between 1 and 16 grids") }
        guard Set(grids.map(\.id)).count == grids.count else { throw GridError.invalid("Duplicate grid identity") }
        var ids = Set<String>(), workspaces = Set<String>()
        for grid in grids {
            guard (1...20).contains(grid.rows), (1...20).contains(grid.columns), !grid.cells.isEmpty else { throw GridError.invalid("Invalid dimensions or empty grid: \(grid.name)") }
            var positions = Set<String>()
            for cell in grid.cells {
                if cell.displayProfiles?.keys.contains(where: { $0.isEmpty }) == true {
                    throw GridError.invalid("A display layout override needs a display identity")
                }
                guard cell.row >= 0, cell.row < grid.rows, cell.column >= 0, cell.column < grid.columns,
                      positions.insert("\(cell.row):\(cell.column)").inserted, ids.insert(cell.id).inserted,
                      workspaces.insert(cell.workspace).inserted, !cell.workspace.isEmpty,
                      cell.workspace.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                    throw GridError.invalid("Duplicate or invalid cell/workspace in \(grid.name)")
                }
            }
        }
        guard threshold.isFinite, (0.01...0.5).contains(threshold), compactMinimumWidth.isFinite, (200...2000).contains(compactMinimumWidth) else { throw GridError.invalid("Invalid gesture threshold or minimum window width") }
        guard Set(bindings.map(\.id)).count == bindings.count else { throw GridError.invalid("Duplicate gesture binding") }
        for b in bindings {
            guard [3,4].contains(b.fingers), (0...15).contains(b.modifiers), ["navigate","next-grid","previous-grid","next-window","previous-window","overview"].contains(b.action) else { throw GridError.invalid("Invalid gesture binding") }
        }
        guard Set(displayAssignments.values).count == displayAssignments.values.count else { throw GridError.invalid("Assign each display to one logical role") }
    }
}
public struct RuntimeState: Codable, Equatable {
    public var version = 1
    public var cursors: [String: String] = [:]
    public var activeGrids: [String: String] = [:] // stable physical display UUID -> grid ID
    public var snapshots: [String: String] = [:] // cell ID : profile -> backend JSON
    public var appliedProfiles: [String: String] = [:]
    public var lastDesktop: Desktop? = nil
    public var windowMinimumWidths: [String: Double]? = nil
    public var minimumWidthDetectionVersion: Int? = nil
    public var dynamicMap: SpaceMap? = nil
    public init() {}
}
public struct Display: Codable, Equatable {
    public var id: String
    public var monitor: Int
    public var name: String
    public var builtin: Bool
    public var width: Double
    public var height: Double
    public init(id: String, monitor: Int, name: String, builtin: Bool, width: Double, height: Double) {
        self.id = id; self.monitor = monitor; self.name = name; self.builtin = builtin; self.width = width; self.height = height
    }
}
public struct WindowHome: Codable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var boot: String
    public var workspace: String
    public var floating: Bool
    public init(id: UInt32, pid: Int32, boot: String, workspace: String, floating: Bool = false) {
        self.id = id; self.pid = pid; self.boot = boot; self.workspace = workspace; self.floating = floating
    }
}
public struct Desktop: Codable, Equatable {
    public var displays: [Display]
    public var visible: [Int: String]
    public var focusedMonitor: Int
    public var focusedWindow: UInt32?
    public var nativeHomes: [String: Int]? = nil
    public var backendSession: String? = nil
    public var windowHomes: [WindowHome]? = nil
    public var windows: [WindowInfo]? = nil
    public var nativeVisible: [Int: UInt32]? = nil
    public init(displays: [Display], visible: [Int: String], focusedMonitor: Int, focusedWindow: UInt32? = nil) {
        self.displays = displays; self.visible = visible; self.focusedMonitor = focusedMonitor; self.focusedWindow = focusedWindow
    }
    public var topology: String { displays.sorted { $0.id < $1.id }.map { "\($0.id):\($0.monitor):\($0.width):\($0.height)" }.joined(separator: "|") }
}
