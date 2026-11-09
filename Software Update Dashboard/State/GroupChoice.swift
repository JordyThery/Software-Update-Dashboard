import Foundation
import JTKit

/// What the Track a Group sheet offers: the groups the chosen Blueprint is
/// scoped to first, then every other group by kind, all filtered by the
/// search. Groups are told apart by kind and number together.
nonisolated struct GroupChoice: Sendable {
    var groups: [JamfPro.DeviceGroup]
    /// The Blueprint’s scope as Jamf Pro groups; nil until it is known.
    var scope: Set<JamfPro.DeviceGroup.ID>?
    var search = ""

    init(groups: [JamfPro.DeviceGroup], scope: Set<JamfPro.DeviceGroup.ID>? = nil, search: String = "") {
        self.groups = groups
        self.scope = scope
        self.search = search
    }

    /// The Blueprint’s scope from its Platform API group IDs, through the
    /// Platform API’s list of groups (`pro/v2/groups`).
    static func scope(platformGroupIDs: [String], platformGroups: [JamfPlatform.PlatformGroup]) -> Set<JamfPro.DeviceGroup.ID> {
        let wanted = Set(platformGroupIDs.map { $0.lowercased() })
        return Set(platformGroups.filter { wanted.contains($0.id.lowercased()) }.compactMap(JamfPro.DeviceGroup.ID.init))
    }

    private var matching: [JamfPro.DeviceGroup] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return groups
            .filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The groups in the Blueprint’s scope.
    var inScope: [JamfPro.DeviceGroup] {
        guard let scope else { return [] }
        return matching.filter { scope.contains($0.id) }
    }

    /// Every other mobile device group.
    var mobileDeviceGroups: [JamfPro.DeviceGroup] { others(.mobileDevice) }

    /// Every other computer group.
    var computerGroups: [JamfPro.DeviceGroup] { others(.computer) }

    private func others(_ kind: MDMCommand.DeviceKind) -> [JamfPro.DeviceGroup] {
        matching.filter { $0.kind == kind && !(scope?.contains($0.id) ?? false) }
    }

    /// The group with this kind and number.
    func group(_ id: JamfPro.DeviceGroup.ID?) -> JamfPro.DeviceGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// Why the chosen group may not get the update; nil when it’s in scope
    /// or the scope isn’t known yet.
    func scopeWarning(for id: JamfPro.DeviceGroup.ID?) -> String? {
        guard let id, let scope, !scope.contains(id) else { return nil }
        return scope.isEmpty
            ? "The Blueprint isn’t scoped to any group, so it doesn’t reach these devices."
            : "This group isn’t in the Blueprint’s scope, so its devices may not get this update."
    }
}
