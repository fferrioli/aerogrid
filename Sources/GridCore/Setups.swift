import Foundation

public struct Setup: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var spaces: [SetupSpace]

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), spaces: [SetupSpace]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.spaces = spaces
    }
}

public struct SetupSpace: Codable, Equatable {
    public var spaceID: String
    public var name: String
    public var rect: SpaceRect
    public var foldedRect: SpaceRect?
    public var boardID: String?
    public var preferredRole: String
    public var workspace: String
    public var template: PlaceTemplate?

    public init(spaceID: String, name: String, rect: SpaceRect, foldedRect: SpaceRect? = nil,
                boardID: String? = nil, preferredRole: String, workspace: String, template: PlaceTemplate? = nil) {
        self.spaceID = spaceID
        self.name = name
        self.rect = rect
        self.foldedRect = foldedRect
        self.boardID = boardID
        self.preferredRole = preferredRole
        self.workspace = workspace
        self.template = template
    }
}

public struct SetupApplyResult: Equatable {
    public var moved: Int
    public var missingBundleIDs: [String]

    public init(moved: Int, missingBundleIDs: [String]) {
        self.moved = moved
        self.missingBundleIDs = missingBundleIDs
    }
}

extension Store {
    public func loadSetups() throws -> [Setup] { try load([Setup].self, name: "setups.json") ?? [] }
    public func saveSetups(_ setups: [Setup]) throws { try save(setups, name: "setups.json") }

    public func renameSetup(id: String, name: String) throws {
        var setups = try loadSetups()
        guard let index = setups.firstIndex(where: { $0.id == id }) else { throw GridError.stale }
        setups[index].name = name
        try saveSetups(setups)
    }

    public func deleteSetup(id: String) throws {
        var setups = try loadSetups()
        setups.removeAll { $0.id == id }
        try saveSetups(setups)
    }
}
