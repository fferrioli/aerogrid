import SwiftUI
import GridCore

/// A layout diagram uses saved structure and verified owners; it never captures the screen.
struct LayoutDiagramView: View {
    let snapshot: LayoutSnapshot
    let windows: [WindowInfo]
    var body: some View { MiniLayoutView(snapshot:snapshot,windows:windows) }
}

struct MergePreviewView: View {
    @ObservedObject var model: AppModel
    let preview: MergePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fusionar \(preview.sourceName) en \(preview.targetName)").font(.title2)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.targetName).font(.headline)
                    LayoutDiagramView(snapshot: preview.targetLayout, windows: preview.targetWindows).frame(height: 120)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.sourceName).font(.headline)
                    LayoutDiagramView(snapshot: preview.sourceLayout, windows: preview.sourceWindows).frame(height: 120)
                }.frame(maxWidth: .infinity)
            }
            Divider()
            Text("Resultado en \(preview.targetName)").font(.headline)
            LayoutDiagramView(snapshot: preview.result, windows: preview.targetWindows + preview.sourceWindows).frame(height: 170)
            Text("Cada grupo conserva su distribución interna. El espacio de origen queda vacío. Podés usar Deshacer.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { model.mergePreview = nil }
                Button("Fusionar") { model.mergeSpaces(preview) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 590)
    }
}
