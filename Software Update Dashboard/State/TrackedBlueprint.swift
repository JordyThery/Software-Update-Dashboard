import Foundation
import JTKit

/// The unit of work: a Blueprint with a software update, on one connection.
/// Its devices are those of the groups it is scoped to, read again on every
/// refresh, each device once.
nonisolated struct TrackedBlueprint: Sendable, Hashable, Codable, Identifiable {
    /// Also the name of its history folder.
    var id: UUID
    var connectionID: UUID
    var blueprintID: String
    var blueprintName: String
    /// A group to check coverage against: its devices the Blueprint doesn’t reach.
    var compareGroup: GroupReference?
    /// The “Update started” date set by hand: overrides the start the
    /// target rules give (reports and errors before it don’t count).
    var updateStarted: Date?

    init(id: UUID = UUID(), connectionID: UUID, blueprintID: String, blueprintName: String,
         compareGroup: GroupReference? = nil, updateStarted: Date? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.blueprintID = blueprintID
        self.blueprintName = blueprintName
        self.compareGroup = compareGroup
        self.updateStarted = updateStarted
    }
}

/// A Jamf Pro group by kind and number, with its name when it was chosen.
nonisolated struct GroupReference: Sendable, Hashable, Codable, Identifiable {
    var key: JamfPro.DeviceGroup.ID
    var name: String
    var isSmart: Bool

    var id: JamfPro.DeviceGroup.ID { key }

    init(_ group: JamfPro.DeviceGroup) {
        key = group.id
        name = group.name
        isSmart = group.isSmart
    }

    init(key: JamfPro.DeviceGroup.ID, name: String, isSmart: Bool) {
        self.key = key
        self.name = name
        self.isSmart = isSmart
    }

    var group: JamfPro.DeviceGroup {
        JamfPro.DeviceGroup(groupID: key.groupID, name: name, isSmart: isSmart, kind: key.kind)
    }
}

/// What the first pre-release build saved: a group with its Blueprint. Read once, to move it
/// to a tracked Blueprint.
nonisolated struct SavedTrackedGroup: Codable {
    var id: UUID
    var connectionID: UUID
    var groupID: String
    var groupName: String
    var isSmart: Bool
    var isComputerGroup: Bool
    var blueprintID: String
    var blueprintName: String
}

/// The tracked Blueprints, saved in the app’s settings. Demo mode has its own
/// two, kept in memory only.
nonisolated enum TrackedBlueprintList {
    static let key = "trackedBlueprints"
    /// Where the first version kept its tracked groups; read once, never removed.
    static let legacyKey = "trackedGroups"

    /// The saved list; the first time, the tracked groups of the earlier
    /// version moved over, each keeping its ID and so its history.
    static func load(from defaults: UserDefaults) -> [TrackedBlueprint] {
        read(from: defaults).list
    }

    /// The saved list, and where a list that can’t be read was copied: as
    /// JTKit keeps unreadable saved connections, under
    /// `trackedBlueprints.unreadable-<date and time>`, an earlier copy never
    /// replaced. The list itself must then never be saved over.
    static func read(from defaults: UserDefaults, now: Date = .now) -> (list: [TrackedBlueprint], unreadableCopy: String?) {
        if let value = defaults.object(forKey: key) {
            if let data = value as? Data, let list = try? JSONDecoder().decode([TrackedBlueprint].self, from: data) {
                return (list, nil)
            }
            // the same value copied at an earlier launch: that copy is enough
            let copies = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("\(key).unreadable") }
            if let earlier = copies.first(where: { ($0.value as? NSObject) == (value as? NSObject) }) {
                return ([], earlier.key)
            }
            let stamp = "\(key).\(FileCopies.unreadableStamp(now))"
            var copyKey = stamp
            var number = 2
            while defaults.object(forKey: copyKey) != nil {
                copyKey = "\(stamp)-\(number)"
                number += 1
            }
            defaults.set(value, forKey: copyKey)
            return ([], copyKey)
        }
        guard let data = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([SavedTrackedGroup].self, from: data) else { return ([], nil) }
        let moved = migrated(legacy)
        save(moved, to: defaults)
        return (moved, nil)
    }

    /// The earlier tracked groups as tracked Blueprints: the same ID (and so
    /// history), connection and Blueprint, one per Blueprint. The group isn’t
    /// kept: the Blueprint’s scope says which devices count.
    static func migrated(_ legacy: [SavedTrackedGroup]) -> [TrackedBlueprint] {
        var seen = Set<String>()
        return legacy.compactMap { old in
            guard seen.insert("\(old.connectionID)/\(old.blueprintID)").inserted else { return nil }
            return TrackedBlueprint(id: old.id, connectionID: old.connectionID, blueprintID: old.blueprintID,
                                    blueprintName: old.blueprintName)
        }
    }

    static func save(_ tracked: [TrackedBlueprint], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(tracked) { defaults.set(data, forKey: key) }
    }

    /// Demo mode’s tracked Blueprints: the iPad update and the Mac update.
    static func demo(connectionID: UUID) -> [TrackedBlueprint] {
        [
            TrackedBlueprint(id: UUID(uuidString: "D0D50001-0000-4000-8000-000000000001")!, connectionID: connectionID,
                             blueprintID: DemoSoftwareUpdate.iPadBlueprintID, blueprintName: "Contoso – iPad Update"),
            TrackedBlueprint(id: UUID(uuidString: "D0D50001-0000-4000-8000-000000000002")!, connectionID: connectionID,
                             blueprintID: DemoSoftwareUpdate.macBlueprintID, blueprintName: "Contoso – Mac Update"),
        ]
    }
}
