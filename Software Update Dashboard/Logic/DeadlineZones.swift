import Foundation
import JTKit

/// When the deadline falls for the devices in one time zone. The Blueprint’s
/// deadline is each device’s local time, so devices in different zones
/// reach it at different moments.
nonisolated struct DeadlineZone: Sendable, Hashable, Identifiable {
    /// An IANA name; nil for devices that report no time zone.
    var zone: String?
    var deviceCount: Int
    /// The moment the deadline falls there; nil without a zone.
    var deadline: Date?
    /// Why the zone stands out; nil when it doesn’t.
    var unusual: String?

    var id: String { zone ?? "" }
}

nonisolated enum DeadlineZones {
    /// The devices’ zones, most devices first, each with its moment of the
    /// deadline. A zone stands out when its offset differs from the
    /// group’s most common one, when it isn’t a whole hour from UTC, or
    /// when the device reports none.
    static func zones(deadline localDateTime: String?, devices: [DeviceStatus]) -> [DeadlineZone] {
        let counts = Dictionary(grouping: devices, by: \.timeZone).mapValues(\.count)
        guard !counts.isEmpty else { return [] }
        func moment(_ zone: String?) -> Date? {
            guard let zone, let timeZone = TimeZone(identifier: zone), let localDateTime else { return nil }
            return JamfPlatform.SoftwareUpdateBlock.deadline(localDateTime, in: timeZone)
        }
        func offset(_ zone: String?) -> Int? {
            guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
            return timeZone.secondsFromGMT(for: moment(zone) ?? Date())
        }
        // the most common zone that is known
        let common = counts.filter { $0.key != nil }.max { $0.value != $1.value ? $0.value < $1.value : ($0.key ?? "") > ($1.key ?? "") }?.key
        let commonOffset = offset(common)
        return counts.map { zone, count -> DeadlineZone in
            var unusual: String?
            if zone == nil {
                unusual = devices.first(where: { $0.timeZone == nil })?.isComputer == true
                    ? "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"
                    : "No time zone reported"
            } else if TimeZone(identifier: zone!) == nil {
                unusual = "Not a time zone the Mac knows"
            } else if let seconds = offset(zone), seconds % 3_600 != 0 {
                unusual = "Not a whole hour from UTC"
            } else if let commonOffset, let seconds = offset(zone), seconds != commonOffset {
                let hours = Double(seconds - commonOffset) / 3_600
                unusual = "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the group"
            }
            return DeadlineZone(zone: zone, deviceCount: count, deadline: moment(zone), unusual: unusual)
        }
        .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount : ($0.zone ?? "~") < ($1.zone ?? "~") }
    }
}

/// Hardware that can’t run the target, by model: what to replace.
nonisolated struct Replacement: Sendable, Hashable, Identifiable {
    var modelIdentifier: String
    var model: String
    var deviceCount: Int
    /// The newest version the model can run, from Apple’s release data.
    var lastSupportedVersion: String?

    var id: String { modelIdentifier }

    static func list(_ devices: [DeviceStatus], lastSupported: (String) -> String?) -> [Replacement] {
        Dictionary(grouping: devices.filter { $0.category == .unsupported }, by: \.modelIdentifier)
            .map { identifier, group in
                Replacement(modelIdentifier: identifier, model: group.first?.model ?? "", deviceCount: group.count,
                            lastSupportedVersion: lastSupported(identifier))
            }
            .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount : $0.modelIdentifier < $1.modelIdentifier }
    }
}
