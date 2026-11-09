import Foundation
import JTKit

/// When a deadline falls for the devices in one time zone. A Blueprint’s
/// deadline is each device’s local time, so devices in different zones
/// reach it at different moments; devices with different targets have
/// different deadlines. A device that reports its deadline gives the
/// moment itself (written in UTC, so its offset says nothing about where
/// the device is).
nonisolated struct DeadlineZone: Sendable, Hashable, Identifiable {
    /// An IANA name; nil for devices that report no time zone.
    var zone: String?
    /// The deadline in the devices’ local time (computed from the rule).
    var localDeadline: String
    /// The deadline the devices reported, as a moment; nil when computed.
    var reported: Date?
    /// The devices’ target, which tells rows without a zone apart.
    var target: String?
    var deviceCount: Int
    /// The moment the deadline falls: reported, or from the zone; nil
    /// for a computed deadline without a zone.
    var deadline: Date?
    /// Why the zone stands out; nil when it doesn’t.
    var unusual: String?

    var id: String { "\(zone ?? "")|\(reported.map { String($0.timeIntervalSince1970) } ?? localDeadline)|\(target ?? "")" }

    /// “Europe/Brussels” or “No time zone”.
    var label: String { zone ?? "No time zone" }
}

nonisolated enum DeadlineZones {
    /// Per zone and deadline, most devices first. A reported deadline is
    /// its own row (to the minute); a computed one is per zone and local
    /// time, and without a zone per local time and target. A computed row
    /// stands out when its zone’s offset differs from the most common one,
    /// when it isn’t a whole hour from UTC, or when it has no zone.
    static func zones(devices: [DeviceStatus]) -> [DeadlineZone] {
        let withDeadline = devices.filter { $0.deadlineLocal != nil || $0.deadlineDate != nil }
        guard !withDeadline.isEmpty else { return [] }
        func offset(_ zone: String?, at local: String) -> Int? {
            guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
            return timeZone.secondsFromGMT(for: JamfPlatform.SoftwareUpdateBlock.deadline(local, in: timeZone) ?? Date())
        }
        let computed = withDeadline.filter { $0.deadlineDate == nil }
        let common = Dictionary(grouping: computed.compactMap { offset($0.timeZone, at: $0.deadlineLocal ?? "") }) { $0 }
            .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
        let groups = Dictionary(grouping: withDeadline) { device -> String in
            if let moment = device.deadlineDate {
                return "reported|\(device.timeZone ?? "")|\(Int(moment.timeIntervalSince1970 / 60))"
            }
            let target = device.timeZone == nil ? device.targetVersion ?? "" : ""
            return "computed|\(device.timeZone ?? "")|\(device.deadlineLocal ?? "")|\(target)"
        }
        return groups.values.map { group -> DeadlineZone in
            let first = group[0]
            let zone = first.timeZone
            let local = first.deadlineLocal ?? ""
            if let moment = first.deadlineDate {
                return DeadlineZone(zone: zone, localDeadline: local, reported: moment, target: zone == nil ? first.targetVersion : nil,
                                    deviceCount: group.count, deadline: moment, unusual: nil)
            }
            var unusual: String?
            if zone == nil {
                unusual = first.isComputer
                    ? "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"
                    : "No time zone reported"
            } else if TimeZone(identifier: zone!) == nil {
                unusual = "Not a time zone the Mac knows"
            } else if let seconds = offset(zone, at: local), seconds % 3_600 != 0 {
                unusual = "Not a whole hour from UTC"
            } else if let seconds = offset(zone, at: local), let common, seconds != common {
                let hours = Double(seconds - common) / 3_600
                unusual = "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the devices"
            }
            return DeadlineZone(zone: zone, localDeadline: local, target: zone == nil ? first.targetVersion : nil,
                                deviceCount: group.count, deadline: TargetRules.deadlineDate(local, timeZone: zone), unusual: unusual)
        }
        .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount
                  : ($0.label, $0.deadline ?? .distantFuture, $0.localDeadline, $0.target ?? "")
                    < ($1.label, $1.deadline ?? .distantFuture, $1.localDeadline, $1.target ?? "") }
    }

    /// A deadline as it is shown everywhere: a reported moment in this
    /// Mac’s time zone, “reported by the device”; a computed one in the
    /// device’s local time.
    static func text(local: String?, reported: Date?, timeZone: TimeZone = .current) -> String? {
        if let reported {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.timeZone = timeZone
            return "\(reported.formatted(style)), reported by the device"
        }
        return local.map { "\(TargetRules.readable($0)), device local time" }
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
