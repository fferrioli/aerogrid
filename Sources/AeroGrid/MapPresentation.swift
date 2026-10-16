import SwiftUI
import GridCore

/// Large, fixed-size mini screens; the viewport scrolls instead of shrinking their contents.
enum MapPresentation {
    static let unit = CGSize(width:230,height:152)
    static let gap:CGFloat = 10
    static let creationRail:CGFloat = 24
    static func boardSize(spaces:[Space],editable:Bool) -> CGSize {
        let outline = BoardOutline(spaces:spaces), rail = editable ? creationRail*2 : 0
        return CGSize(width:CGFloat(outline.columns)*unit.width-gap+rail,height:CGFloat(outline.rows)*unit.height-gap+rail)
    }
    static func panelSize(displays:[Display],model:AppModel,editable:Bool) -> CGSize {
        let sizes = displays.map { boardSize(spaces:model.boardSpaces($0),editable:editable) }
        let width = sizes.map(\.width).reduce(0,+) + CGFloat(max(0,sizes.count-1))*20
        let height = sizes.map(\.height).max() ?? unit.height
        return CGSize(width:max(300,width+20),height:height+(editable ? 88 : 66)+(displays.count > 1 ? 24 : 0))
    }
}

struct MapGlass: View {
    var body:some View {
        RoundedRectangle(cornerRadius:16).fill(.ultraThinMaterial).opacity(0.72)
            .overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.12)))
    }
}
