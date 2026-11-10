import Foundation

/// Find a Device: a device by serial number or name across the tracked
/// Blueprints, from each one’s last refresh (this session’s, else the
/// newest in its history). Sends nothing to Jamf.
nonisolated enum DeviceSearch {
    struct Source: Sendable {
        var tracked: TrackedBlueprint
        var devices: [DeviceStatus]
        /// When that refresh was read.
        var date: Date?
    }

    struct Match: Sendable, Hashable, Identifiable {
        var trackedID: UUID
        var blueprintName: String
        var device: DeviceStatus
        var date: Date?

        /// A device in several tracked Blueprints is listed once per Blueprint.
        var id: String { "\(trackedID.uuidString)|\(device.id)" }
    }

    /// Devices whose serial number or name contains the text (ignoring case
    /// and spaces around it); an exact serial number first, then by name and
    /// Blueprint. Nothing for an empty text.
    static func matches(_ text: String, in sources: [Source]) -> [Match] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let found = sources.flatMap { source in
            source.devices
                .filter { $0.serial.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
                .map { Match(trackedID: source.tracked.id, blueprintName: source.tracked.blueprintName, device: $0, date: source.date) }
        }
        return found.sorted { one, two in
            let exactOne = one.device.serial.caseInsensitiveCompare(query) == .orderedSame
            let exactTwo = two.device.serial.caseInsensitiveCompare(query) == .orderedSame
            if exactOne != exactTwo { return exactOne }
            if one.device.name != two.device.name { return one.device.name.localizedStandardCompare(two.device.name) == .orderedAscending }
            return one.blueprintName.localizedStandardCompare(two.blueprintName) == .orderedAscending
        }
    }
}
