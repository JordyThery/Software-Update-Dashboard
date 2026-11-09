import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// The first version tracked a group with its Blueprint; now the Blueprint
/// is the unit. Made-up IDs only.
@Suite("Moving tracked groups to tracked Blueprints")
struct MigrationTests {
    private func defaults() -> UserDefaults {
        TestFiles.defaults("migration")
    }

    private func legacy(_ entries: [(id: UUID, connection: UUID, blueprint: String)]) -> Data {
        let records = entries.map { entry in
            #"{"id":"\#(entry.id)","connectionID":"\#(entry.connection)","groupID":"12","groupName":"Test iPads","isSmart":true,"isComputerGroup":false,"blueprintID":"\#(entry.blueprint)","blueprintName":"Test Blueprint"}"#
        }
        return Data("[\(records.joined(separator: ","))]".utf8)
    }

    @Test("The saved entry becomes a tracked Blueprint with the same ID, so its history stays")
    func moved() {
        let defaults = defaults()
        let id = UUID(), connection = UUID()
        defaults.set(legacy([(id, connection, "bp-1")]), forKey: TrackedBlueprintList.legacyKey)
        let tracked = TrackedBlueprintList.load(from: defaults)
        #expect(tracked.count == 1)
        #expect(tracked.first?.id == id)
        #expect(tracked.first?.connectionID == connection)
        #expect(tracked.first?.blueprintID == "bp-1")
        #expect(tracked.first?.blueprintName == "Test Blueprint")
        // the group the earlier version saved isn't carried over
        #expect(tracked.first?.compareGroup == nil && tracked.first?.updateStarted == nil)
        // saved under the new key; the old one kept as it was
        #expect(defaults.data(forKey: TrackedBlueprintList.key) != nil)
        #expect(defaults.data(forKey: TrackedBlueprintList.legacyKey) == legacy([(id, connection, "bp-1")]))
    }

    @Test("History under the entry’s ID reads on after the move")
    func history() throws {
        let defaults = defaults()
        let id = UUID()
        let history = StatusHistory(folder: TestFiles.folder("migration"))
        try history.save(HistorySnapshot(date: Sample.now, target: "27.1", devices: []), for: id)
        defaults.set(legacy([(id, UUID(), "bp-1")]), forKey: TrackedBlueprintList.legacyKey)
        let tracked = try #require(TrackedBlueprintList.load(from: defaults).first)
        #expect(history.snapshots(for: tracked.id).count == 1)
    }

    @Test("Two entries with the same Blueprint on one connection become one; a second load doesn’t move them again")
    func once() {
        let defaults = defaults()
        let connection = UUID()
        let first = UUID()
        defaults.set(legacy([(first, connection, "bp-1"), (UUID(), connection, "bp-1"), (UUID(), connection, "bp-2")]),
                     forKey: TrackedBlueprintList.legacyKey)
        let moved = TrackedBlueprintList.load(from: defaults)
        #expect(moved.map(\.blueprintID) == ["bp-1", "bp-2"])
        #expect(moved.first?.id == first)
        // what the new list holds wins from now on
        TrackedBlueprintList.save([], to: defaults)
        #expect(TrackedBlueprintList.load(from: defaults).isEmpty)
    }

    @Test("Nothing saved: nothing to move")
    func nothing() {
        #expect(TrackedBlueprintList.load(from: defaults()).isEmpty)
    }

    @Test("History saved before targets per device reads, without targets or scope")
    func olderHistory() throws {
        let old = #"""
        {"date":"2026-11-05T10:00:00.000Z","target":"27.1","counts":{"on-target":1},"devices":[{"id":"7","isComputer":true,
         "name":"Test Mac","serial":"ZZTESTM7","model":"MacBook Air","modelIdentifier":"Mac14,2","error":"",
         "category":"on-target","diagnosis":"On target"}]}
        """#
        let snapshot = try StatusHistory.decoder.decode(HistorySnapshot.self, from: Data(old.utf8))
        #expect(snapshot.scope == nil)
        #expect(snapshot.devices.first?.jamfID == "7")
        #expect(snapshot.devices.first?.id == "computer/7")
        #expect(snapshot.devices.first?.targetVersion == nil)
    }
}
