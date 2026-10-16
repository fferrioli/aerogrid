import Foundation

public enum WindowDropGeometry {
    public static func placement(x:Double,y:Double,width:Double,height:Double) -> WindowPlacement {
        let x = x / max(1,width), y = y / max(1,height)
        let edges: [(Double,WindowPlacement)] = [(x,.left),(1-x,.right),(y,.top),(1-y,.bottom)]
        if let nearest = edges.min(by: { $0.0 < $1.0 }), nearest.0 < 0.26 { return nearest.1 }
        return .stack
    }
}
