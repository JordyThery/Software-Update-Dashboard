import Foundation
import JTKit

/// When a deadline falls for the devices in one time zone. A Blueprint’s
/// deadline is each device’s local time, so devices in different zones
/// reach it at different moments; devices with different targets have
/// different deadlines.
nonisolated struct DeadlineZone: Sendable, Hashable, Identifiable {
    /// An IANA name; nil for devices that report no time zone.
    var zone: String?
    /// The deadline in the devices’ local time.
    var localDeadline: String
    var deviceCount: Int
    /// The moment the deadline falls there; nil without a zone.
    var deadline: Date?
    /// Why the zone stands out; nil when it doesn’t.
    var unusual: String?

    var id: String { "\(zone ?? "")|\(localDeadline)" }
}

nonisolated enum DeadlineZones {
    /// Per zone and deadline, most devices first, with the moment the
    /// deadline falls. A zone stands out when its offset differs from the
    /// most common zone’s, when it isn’t a whole hour from UTC, or when the
    /// device reports none. Devices without a deadline are left out.
    static func zones(devices: [DeviceStatus]) -> [DeadlineZone] {
        let withDeadline = devices.filter { $0.deadlineLocal != nil }
        guard !withDeadline.isEmpty else { return [] }
        let zoneCounts = Dictionary(grouping: withDeadline, by: \.timeZone).mapValues(\.count)
        let common = zoneCounts.filter { $0.key != nil }
            .max { $0.value != $1.value ? $0.value < $1.value : ($0.key ?? "") > ($1.key ?? "") }?.key
        func offset(_ zone: String?, at local: String) -> Int? {
            guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
            return timeZone.secondsFromGMT(for: JamfPlatform.SoftwareUpdateBlock.deadline(local, in: timeZone) ?? Date())
        }
        let groups = Dictionary(grouping: withDeadline) { "\($0.timeZone ?? "")|\($0.deadlineLocal ?? "")" }
        return groups.values.map { group -> DeadlineZone in
            let zone = group[0].timeZone
            let local = group[0].deadlineLocal ?? ""
            var unusual: String?
            if zone == nil {
                unusual = group[0].isComputer
                    ? "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"
                    : "No time zone reported"
            } else if TimeZone(identifier: zone!) == nil {
                unusual = "Not a time zone the Mac knows"
            } else if let seconds = offset(zone, at: local), seconds % 3_600 != 0 {
                unusual = "Not a whole hour from UTC"
            } else if let commonOffset = offset(common, at: local), let seconds = offset(zone, at: local), seconds != commonOffset {
                let hours = Double(seconds - commonOffset) / 3_600
                unusual = "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the devices"
            }
            return DeadlineZone(zone: zone, localDeadline: local, deviceCount: group.count,
                                deadline: TargetRules.deadlineDate(local, timeZone: zone), unusual: unusual)
        }
        .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount
                  : ($0.zone ?? "~", $0.localDeadline) < ($1.zone ?? "~", $1.localDeadline) }
    }
}

/// Hardware to replace, by model: devices with no release they can run, and
/// devices measured against an older major because they can’t run the newest.
nonisolated struct Replacement: Sendable, Hashable, Identifiable {
    var modelIdentifier: String
    var model: String
    var deviceCount: Int
    /// The newest version the model can run, from Apple’s release data.
    var lastSupportedVersion: String?
    /// How these devices are counted, e.g. “Measured against 26.7.2, the newest it can run”.
    var note: String

    var id: String { modelIdentifier }

    static func list(_ devices: [DeviceStatus], lastSupported: (String, Bool) -> String?) -> [Replacement] {
        Dictionary(grouping: devices.filter { $0.category == .unsupported || $0.limitedByHardware == true }, by: \.modelIdentifier)
            .map { identifier, group in
                let unsupported = group.filter { $0.category == .unsupported }.count
                let targets = Set(group.filter { $0.category != .unsupported }.compactMap(\.targetVersion)).sorted()
                var notes: [String] = []
                if unsupported > 0 { notes.append("\(unsupported) unsupported: no release it can run applies") }
                if !targets.isEmpty {
                    notes.append("measured against \(targets.joined(separator: ", ")), the newest it can run")
                }
                return Replacement(modelIdentifier: identifier, model: group.first?.model ?? "", deviceCount: group.count,
                                   lastSupportedVersion: lastSupported(identifier, group[0].isComputer),
                                   note: notes.joined(separator: "; ").capitalizedFirst)
            }
            .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount : $0.modelIdentifier < $1.modelIdentifier }
    }
}

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
