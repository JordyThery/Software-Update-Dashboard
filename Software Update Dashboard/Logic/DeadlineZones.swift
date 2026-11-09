import Foundation
import JTKit

/// When a deadline falls for the devices in one time zone. A Blueprint’s
/// deadline is each device’s local time, so devices in different zones
/// reach it at different moments; devices with different targets have
/// different deadlines.
nonisolated struct DeadlineZone: Sendable, Hashable, Identifiable {
    /// An IANA name; nil for devices that report no time zone.
    var zone: String?
    /// Without a zone: the offset from UTC the device reported its deadline
    /// with (a pending update’s target time), in seconds.
    var offset: Int?
    /// The deadline in the devices’ local time.
    var localDeadline: String
    /// The devices’ target, which tells rows without a zone or offset apart.
    var target: String?
    var deviceCount: Int
    /// The moment the deadline falls there; nil without a zone or offset.
    var deadline: Date?
    /// Why the zone stands out; nil when it doesn’t.
    var unusual: String?

    var id: String { "\(zone ?? "")|\(offset.map(String.init) ?? "")|\(localDeadline)|\(target ?? "")" }

    /// “Europe/Brussels”, “UTC+01:00 (from the device’s report)” or “No time zone”.
    var label: String {
        if let zone { return zone }
        if let offset { return "\(Self.offsetText(offset)) (from the device’s report)" }
        return "No time zone"
    }

    /// `UTC+01:00`, `UTC−05:30`, `UTC+00:00`.
    static func offsetText(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", minutes / 60, minutes % 60)
    }
}

nonisolated enum DeadlineZones {
    /// Per zone (or reported offset) and deadline, most devices first, with
    /// the moment the deadline falls. Devices without either are grouped by
    /// deadline and target. A row stands out when its offset differs from
    /// the most common one, when it isn’t a whole hour from UTC, or when it
    /// has neither zone nor offset. Devices without a deadline are left out.
    static func zones(devices: [DeviceStatus]) -> [DeadlineZone] {
        let withDeadline = devices.filter { $0.deadlineLocal != nil }
        guard !withDeadline.isEmpty else { return [] }
        /// The device’s offset at its deadline: from its zone, else the one it reported.
        func offset(_ device: DeviceStatus) -> Int? {
            if let zone = device.timeZone.flatMap(TimeZone.init(identifier:)) {
                return zone.secondsFromGMT(for: JamfPlatform.SoftwareUpdateBlock.deadline(device.deadlineLocal ?? "", in: zone) ?? Date())
            }
            return device.timeZone == nil ? device.deadlineOffset : nil
        }
        let offsets = withDeadline.compactMap(offset)
        let common = Dictionary(grouping: offsets) { $0 }.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
        let groups = Dictionary(grouping: withDeadline) { device -> String in
            let place = device.timeZone ?? device.deadlineOffset.map { "offset \($0)" } ?? ""
            // without a zone or offset, devices with other targets are other rows
            let target = place.isEmpty ? device.targetVersion ?? "" : ""
            return "\(place)|\(device.deadlineLocal ?? "")|\(target)"
        }
        return groups.values.map { group -> DeadlineZone in
            let first = group[0]
            let zone = first.timeZone
            let reportedOffset = zone == nil ? first.deadlineOffset : nil
            let local = first.deadlineLocal ?? ""
            let seconds = offset(first)
            var unusual: String?
            if zone == nil && reportedOffset == nil {
                unusual = first.isComputer
                    ? "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"
                    : "No time zone reported"
            } else if let zone, TimeZone(identifier: zone) == nil {
                unusual = "Not a time zone the Mac knows"
            } else if let seconds, seconds % 3_600 != 0 {
                unusual = "Not a whole hour from UTC"
            } else if let seconds, let common, seconds != common {
                let hours = Double(seconds - common) / 3_600
                unusual = "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the devices"
            }
            let moment = zone.flatMap { TargetRules.deadlineDate(local, timeZone: $0) }
                ?? reportedOffset.flatMap { offset in
                    first.deadlineDate ?? TimeZone(secondsFromGMT: offset).flatMap { JamfPlatform.SoftwareUpdateBlock.deadline(local, in: $0) }
                }
            return DeadlineZone(zone: zone, offset: reportedOffset, localDeadline: local,
                                target: zone == nil && reportedOffset == nil ? first.targetVersion : nil,
                                deviceCount: group.count, deadline: moment, unusual: unusual)
        }
        .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount
                  : ($0.label, $0.localDeadline, $0.target ?? "") < ($1.label, $1.localDeadline, $1.target ?? "") }
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

    static func list(_ devices: [DeviceStatus], lastSupported: (DeviceStatus) -> String?) -> [Replacement] {
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
                                   lastSupportedVersion: lastSupported(group[0]),
                                   note: notes.joined(separator: "; ").capitalizedFirst)
            }
            .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount : $0.modelIdentifier < $1.modelIdentifier }
    }
}

extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
