import Foundation
import JTKit

/// The unit of work: a Jamf Pro group plus the Blueprint that enforces its
/// software update, on one connection.
nonisolated struct TrackedGroup: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    /// The connection it belongs to.
    var connectionID: UUID
    var groupID: String
    var groupName: String
    var isSmart: Bool
    var isComputerGroup: Bool
    var blueprintID: String
    var blueprintName: String

    init(id: UUID = UUID(), connectionID: UUID, group: JamfPro.DeviceGroup, blueprintID: String, blueprintName: String) {
        self.id = id
        self.connectionID = connectionID
        groupID = group.id
        groupName = group.name
        isSmart = group.isSmart
        isComputerGroup = group.kind == .computer
        self.blueprintID = blueprintID
        self.blueprintName = blueprintName
    }

    var group: JamfPro.DeviceGroup {
        JamfPro.DeviceGroup(id: groupID, name: groupName, isSmart: isSmart, kind: isComputerGroup ? .computer : .mobileDevice)
    }

    var platform: AppleReleases.Platform { isComputerGroup ? .macOS : .iOS }
}

/// The tracked groups, saved in the app’s settings. Demo mode has its own
/// two, kept in memory only.
nonisolated struct TrackedGroupList: Sendable {
    static let key = "trackedGroups"

    static func load(from defaults: UserDefaults) -> [TrackedGroup] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TrackedGroup].self, from: data)) ?? []
    }

    static func save(_ groups: [TrackedGroup], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: key) }
    }

    /// Demo mode’s tracked groups: the field team’s iPads and the studio’s Macs.
    static func demo(connectionID: UUID) -> [TrackedGroup] {
        [
            TrackedGroup(id: UUID(uuidString: "D0D50001-0000-4000-8000-000000000001")!, connectionID: connectionID,
                         group: JamfPro.DeviceGroup(id: DemoSoftwareUpdate.iPadGroupID, name: "Field iPads", isSmart: true, kind: .mobileDevice),
                         blueprintID: DemoSoftwareUpdate.iPadBlueprintID, blueprintName: "Contoso – iPad Update"),
            TrackedGroup(id: UUID(uuidString: "D0D50001-0000-4000-8000-000000000002")!, connectionID: connectionID,
                         group: JamfPro.DeviceGroup(id: DemoSoftwareUpdate.macGroupID, name: "Studio Macs", isSmart: true, kind: .computer),
                         blueprintID: DemoSoftwareUpdate.macBlueprintID, blueprintName: "Contoso – Mac Update"),
        ]
    }
}
