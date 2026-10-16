import Foundation

public struct GridPoint: Hashable {
    public let row: Int
    public let column: Int
    public init(row:Int,column:Int) { self.row = row; self.column = column }
}

/// Empty positions are offered only beside existing content. They never reserve an outer row.
public struct BoardOutline {
    public let minRow:Int
    public let minColumn:Int
    public let maxRow:Int
    public let maxColumn:Int
    public let vacancies:[GridPoint]
    public var rows:Int { maxRow-minRow }
    public var columns:Int { maxColumn-minColumn }
    public func nearestVacancy(to rect:SpaceRect) -> GridPoint? {
        func score(_ point:GridPoint) -> (Int,Int,Int,Int) {
            let distance = max(rect.column-point.column,point.column-rect.right+1,0) + max(rect.row-point.row,point.row-rect.bottom+1,0)
            let direction:Int
            if point.column >= rect.right { direction = 0 }
            else if point.row >= rect.bottom { direction = 1 }
            else if point.column < rect.column { direction = 2 }
            else { direction = 3 }
            return (distance,direction,point.row,point.column)
        }
        return vacancies.min { score($0) < score($1) }
    }
    public init(spaces:[Space]) {
        minRow = spaces.map(\.row).min() ?? 0
        minColumn = spaces.map(\.column).min() ?? 0
        maxRow = spaces.map { $0.rect.bottom }.max() ?? 1
        maxColumn = spaces.map { $0.rect.right }.max() ?? 1
        var points = Set<GridPoint>()
        for space in spaces {
            for row in space.row..<space.rect.bottom {
                points.insert(GridPoint(row:row,column:space.column-1))
                points.insert(GridPoint(row:row,column:space.rect.right))
            }
            for column in space.column..<space.rect.right {
                points.insert(GridPoint(row:space.row-1,column:column))
                points.insert(GridPoint(row:space.rect.bottom,column:column))
            }
        }
        if spaces.isEmpty { points.insert(GridPoint(row:0,column:0)) }
        vacancies = points.filter { point in !spaces.contains { $0.rect.contains(row:point.row,column:point.column) } }
            .sorted { ($0.row,$0.column) < ($1.row,$1.column) }
    }
}

public enum SpaceLabels {
    public static func title(windows:[WindowInfo]) -> String {
        let names = Set(windows.map { $0.appName.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.isEmpty ? "Espacio vacío" : names.joined(separator:" · ")
    }
}
