import AppKit

struct GridServerWindow {
    let id: UInt32
    let pid: Int32
    let frame: [String: Double]?
    let onScreen: Bool?

    init?(_ entry: [String: Any], includeGeometry: Bool) {
        guard let id = entry[kCGWindowNumber as String] as? NSNumber,
              let pid = entry[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        self.id = id.uint32Value
        self.pid = pid.int32Value
        if includeGeometry, let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            frame = gridDiagnosticFrame(rect)
        } else {
            frame = nil
        }
        onScreen = includeGeometry ? entry[kCGWindowIsOnscreen as String] as? Bool : nil
    }
}

func gridDiagnosticFrame(_ rect: CGRect) -> [String: Double]? {
    let frame = ["x": rect.origin.x, "y": rect.origin.y, "width": rect.size.width, "height": rect.size.height]
    guard !rect.isInfinite, rect.size.width > 0, rect.size.height > 0, frame.values.allSatisfy(\.isFinite) else { return nil }
    return frame.mapValues(Double.init)
}

func gridWindowPlacement(serverWindow: GridServerWindow?, pid: Int32, spaceIDs: [UInt64]?, deferred: Bool) -> [String: Any] {
    var result: [String: Any] = ["source": deferred ? "retainedHome" : "windowTree"]
    // Window numbers may be reused. Only attribute native evidence when the owner matches.
    guard let serverWindow else {
        result["ownerEvidence"] = "unavailable"
        return result
    }
    guard serverWindow.pid == pid else {
        result["ownerEvidence"] = "mismatched"
        return result
    }
    result["ownerEvidence"] = "matched"
    result["frame"] = serverWindow.frame
    result["onScreen"] = serverWindow.onScreen
    if let spaceIDs, !spaceIDs.isEmpty { result["nativeSpaceIDs"] = spaceIDs.sorted() }
    return result
}

func gridDiagnosticNativeCatalog(_ nativeDisplays: [GridNativeDisplay], monitorsByID: [String: Int], physicalDisplayCount: Int) -> [[String: Any]] {
    nativeDisplays.map { display in
        var row: [String: Any] = ["current": display.current,
            "spaces": display.spaces.map { ["id": $0.id, "type": $0.type] as [String: Any] }]
        let sharedOnSingleDisplay = display.id == "Main" && physicalDisplayCount == 1 && nativeDisplays.count == 1
        row["monitor"] = monitorsByID[display.id.lowercased()] ?? (sharedOnSingleDisplay ? monitorsByID.values.first : nil)
        return row
    }
}
