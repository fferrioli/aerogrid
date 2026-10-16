import Foundation

/// Deterministic augmenting paths find a distinct destination for every display when one exists.
public enum CoordinatedDestinations {
    public static func resolve(_ candidates: [String: [String]]) -> [String: String]? {
        var owner: [String: String] = [:]
        func assign(_ display: String, seen: inout Set<String>) -> Bool {
            for destination in candidates[display] ?? [] where seen.insert(destination).inserted {
                if let previous = owner[destination], !assign(previous, seen: &seen) { continue }
                owner[destination] = display
                return true
            }
            return false
        }
        for display in candidates.keys.sorted() {
            var seen = Set<String>()
            guard assign(display, seen: &seen) else { return nil }
        }
        return Dictionary(uniqueKeysWithValues: owner.map { ($0.value, $0.key) })
    }
}
