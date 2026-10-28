import Foundation
import XCTest
@testable import GridCore

extension DynamicEngineTests {
    private func overlappingState() -> RuntimeState {
        var saved = engine.state
        for index in saved.dynamicMap!.spaces.indices where [chat.id, external.id].contains(saved.dynamicMap!.spaces[index].id) {
            saved.dynamicMap!.spaces[index].foldedRect = SpaceRect(row: 4, column: 2)
        }
        return saved
    }
    func testPersistedAdaptedOverlapCanStartWithoutLosingLayoutsOrIdentities() throws {
        let saved = overlappingState()
        let recovered = try DynamicEngine(configuration: config, state: saved, backend: backend)
        XCTAssertNoThrow(try recovered.map.validate())
        XCTAssertEqual(recovered.map.spaces.map(\.id), saved.dynamicMap!.spaces.map(\.id))
        XCTAssertEqual(recovered.map.spaces.map(\.rect), saved.dynamicMap!.spaces.map(\.rect))
        XCTAssertEqual(recovered.map.spaces.map(\.workspace), saved.dynamicMap!.spaces.map(\.workspace))
        XCTAssertEqual(recovered.map.layouts, saved.dynamicMap!.layouts)
        XCTAssertEqual(recovered.map.families, saved.dynamicMap!.families)
        XCTAssertEqual(recovered.map.undo, saved.dynamicMap!.undo)
        XCTAssertTrue(backend.activations.isEmpty)
        try recovered.refresh()
        let created = try recovered.createSpace(nearID: chat.id, displayID: laptop.id)
        try recovered.moveWindow(XCTUnwrap(backend.screen.windows?.first { $0.id == 3 }?.identity), to: created)
        XCTAssertEqual(backend.screen.windows?.first { $0.id == 3 }?.workspace, recovered.map.spaces.first { $0.id == created }?.workspace)
    }
    func testDormantWorkspaceReactivationDoesNotReuseAnOccupiedAdaptedPosition() throws {
        let unused = config.grids[0].cells[0]
        var saved = engine.state
        for index in saved.dynamicMap!.spaces.indices {
            let id = saved.dynamicMap!.spaces[index].id
            if id == chat.id || id == unused.id {
                saved.dynamicMap!.spaces[index].foldedRect = SpaceRect(row: 4, column: 2)
            }
        }
        let recovered = try DynamicEngine(configuration: config, state: saved, backend: backend)
        let basePositions = recovered.map.spaces.map(\.rect)
        backend.setWindows(backend.screen.windows! + [WindowInfo(id: 9, workspace: unused.workspace)])
        try recovered.refresh()
        XCTAssertNoThrow(try recovered.map.validate())
        XCTAssertFalse(try XCTUnwrap(recovered.map.spaces.first { $0.id == unused.id }).isDormant)
        XCTAssertEqual(recovered.map.spaces.map(\.rect), basePositions)
        XCTAssertEqual(recovered.map.spaces.first { $0.id == chat.id }?.foldedRect, SpaceRect(row: 4, column: 2))
        XCTAssertTrue(backend.activations.isEmpty)
    }
    func testAdaptedRepairRetainsAnExactBackupAndIsIdempotentOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        try store.save(overlappingState(), name: "state.json")
        let original = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let recovered = try DynamicEngine(configuration: config, state: overlappingState(), backend: backend, store: store)
        let repaired = try XCTUnwrap(store.load(RuntimeState.self, name: "state.json"))
        XCTAssertNoThrow(try repaired.dynamicMap!.validate())
        let backups = FileManager.default.enumerator(at: directory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "state.json" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        let restarted = try DynamicEngine(configuration: config, state: repaired, backend: backend, store: store)
        XCTAssertEqual(recovered.state, restarted.state)
    }
    func testPendingCheckpointWithAdaptedOverlapCanRollBack() throws {
        var saved = engine.state
        let damaged = overlappingState().dynamicMap!
        let checkpoint = MapCheckpoint(spaces: damaged.spaces, families: damaged.families, fullscreens: damaged.fullscreens, homes: backend.screen.windowHomes!, layouts: damaged.layouts)
        saved.dynamicMap!.pending = PendingOrganization(before: checkpoint, desiredHomes: [])
        let recovered = try DynamicEngine(configuration: config, state: saved, backend: backend)
        try recovered.refresh()
        XCTAssertNil(recovered.map.pending)
        XCTAssertNoThrow(try recovered.map.validate())
    }
}
