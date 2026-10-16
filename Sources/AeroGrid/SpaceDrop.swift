import SwiftUI
import GridCore

struct SpaceDropTarget: Equatable {
    var id: String
    var edge: Direction?
    init(id:String,point:CGPoint,size:CGSize) {
        self.id = id
        let x = point.x / max(1,size.width), y = point.y / max(1,size.height)
        let edges: [(CGFloat,Direction)] = [(x,.left),(1-x,.right),(y,.up),(1-y,.down)]
        edge = edges.min { $0.0 < $1.0 }.flatMap { $0.0 < 0.25 ? $0.1 : nil }
    }
}

struct SpaceDropHighlight: View {
    let target: SpaceDropTarget?
    var body: some View {
        ZStack {
            Color.clear
            if let target {
                RoundedRectangle(cornerRadius:10).fill(Color.accentColor.opacity(0.12))
                if let edge = target.edge {
                    let horizontal = edge == .up || edge == .down
                    Capsule().fill(Color.accentColor)
                        .frame(width:horizontal ? nil : 5,height:horizontal ? 5 : nil)
                        .padding(horizontal ? .horizontal : .vertical,12)
                        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:alignment(edge))
                } else {
                    RoundedRectangle(cornerRadius:10).stroke(Color.accentColor,lineWidth:2)
                }
                Text(target.edge == nil ? "Intercambiar espacios" : "Insertar espacio completo")
                    .font(.caption.weight(.medium)).padding(7).background(.regularMaterial,in:Capsule())
            }
        }
    }
    private func alignment(_ edge: Direction) -> Alignment {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .up: return .top
        case .down: return .bottom
        }
    }
}
