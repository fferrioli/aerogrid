import SwiftUI
import GridCore

struct NavigationHUDView: View {
    let hint: NavigationHint
    var body: some View {
        VStack(spacing: 10) {
            destination(.up, symbol: "arrow.up")
            HStack(spacing: 12) {
                destination(.left, symbol: "arrow.left").frame(maxWidth: .infinity)
                VStack(spacing: 3) {
                    Text(hint.name).font(.headline).lineLimit(2)
                    Text("\(hint.row + 1), \(hint.column + 1)").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(width: 154).background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                destination(.right, symbol: "arrow.right").frame(maxWidth: .infinity)
            }
            destination(.down, symbol: "arrow.down")
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    private func destination(_ direction: Direction, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(hint.neighbors[direction.rawValue] ?? "Sin destino").lineLimit(2)
        }.font(.caption).foregroundStyle(hint.neighbors[direction.rawValue] == nil ? .secondary : .primary)
    }
}
