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
    /// The row’s moment when it is placed by its moment (no time zone, or a
    /// reported deadline): shown in this Mac’s time zone; nil for a zone’s row.
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
    /// Why a Mac’s row has no time zone: shown once under the table.
    static let macNote = "Jamf Pro has no time zone for Macs: the deadline is each Mac’s own local time"

    /// One row per target and deadline moment, most devices first. A device
    /// with a time zone and a computed deadline gets its zone’s row; one
    /// without a zone (a Mac) or with a reported moment is placed by its
    /// moment: a computed deadline in this Mac’s time zone, a reported one
    /// as reported (written in UTC, so its offset says nothing about where
    /// the device is). So a computed 23:59 and a reported 23:59 here are one
    /// row. A row stands out when its zone’s offset differs from the most
    /// common one, when it isn’t a whole hour from UTC, when its moment is
    /// hours off the most common one for its target, or when it has no zone.
    static func zones(devices: [DeviceStatus], here: TimeZone = .current, now: Date = Date()) -> [DeadlineZone] {
        // a device past its earlier step's own deadline is counted at that step and its deadline,
        // whatever the step's major and whether it is still installing
        let shown = devices.map { device -> DeviceStatus in
            // the target pending with the earlier step's deadline: listed at that deadline, labeled
            if device.carriedStepVersion != nil, let target = device.targetVersion,
               let due = device.carriedDeadline
                   ?? TargetRules.deadlineDate(device.carriedDeadlineLocal, timeZone: device.timeZone ?? here.identifier), due <= now {
                var carried = device
                carried.targetVersion = "\(target), with the deadline of earlier step \(device.carriedStepVersion ?? "")"
                carried.deadlineDate = device.carriedDeadline
                carried.deadlineLocal = device.carriedDeadlineLocal ?? device.carriedDeadline.map { TargetRules.localText($0, offset: 0) }
                return carried
            }
            guard let step = device.earlierStepVersion,
                  let due = device.earlierStepDeadline
                      ?? TargetRules.deadlineDate(device.earlierStepLocal, timeZone: device.timeZone ?? here.identifier),
                  device.earlierStepLapsed == true || due <= now else { return device }
            var stepped = device
            stepped.targetVersion = "\(step), earlier step"
            stepped.deadlineDate = device.earlierStepDeadline
            stepped.deadlineLocal = device.earlierStepLocal ?? device.earlierStepDeadline.map { TargetRules.localText($0, offset: 0) }
            return stepped
        }
        let withDeadline = shown.filter { $0.deadlineLocal != nil || $0.deadlineDate != nil }
        guard !withDeadline.isEmpty else { return [] }
        func offset(_ zone: String?, at local: String) -> Int? {
            guard let zone, let timeZone = TimeZone(identifier: zone) else { return nil }
            return timeZone.secondsFromGMT(for: JamfPlatform.SoftwareUpdateBlock.deadline(local, in: timeZone) ?? Date())
        }
        // the zone a device’s row belongs to: its own for a computed deadline, none when placed by its moment
        func rowZone(_ device: DeviceStatus) -> String? { device.deadlineDate == nil ? device.timeZone : nil }
        func moment(_ device: DeviceStatus) -> Date? {
            device.deadlineDate ?? TargetRules.deadlineDate(device.deadlineLocal, timeZone: rowZone(device) ?? here.identifier)
        }
        let zoned = withDeadline.filter { rowZone($0) != nil }
        let common = Dictionary(grouping: zoned.compactMap { offset($0.timeZone, at: $0.deadlineLocal ?? "") }) { $0 }
            .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
        let groups = Dictionary(grouping: withDeadline) { device -> String in
            let minute = moment(device).map { String(Int($0.timeIntervalSince1970 / 60)) } ?? device.deadlineLocal ?? ""
            return "\(rowZone(device) ?? "")|\(device.targetVersion ?? "")|\(minute)"
        }
        // per target, the moment most devices without a zone share
        let placed = groups.values.filter { rowZone($0[0]) == nil }
        var usual: [String: Date] = [:]
        // most devices first; on a tie, the earliest moment
        for group in placed.sorted(by: { $0.count != $1.count ? $0.count > $1.count
                                         : (moment($0[0]) ?? .distantFuture) < (moment($1[0]) ?? .distantFuture) }) {
            let target = group[0].targetVersion ?? ""
            if usual[target] == nil, let at = moment(group[0]) { usual[target] = at }
        }
        func hoursText(_ seconds: Double) -> String {
            let hours = seconds / 3_600
            return "\(hours > 0 ? "+" : "")\(hours.formatted(.number.precision(.fractionLength(0...1)))) h from most of the devices"
        }
        return groups.values.map { group -> DeadlineZone in
            let first = group[0]
            let zone = rowZone(first)
            let local = group.first { $0.deadlineDate == nil }?.deadlineLocal ?? first.deadlineLocal ?? ""
            let at = moment(first)
            var unusual: String?
            if zone == nil {
                // placed by its moment: hours off the rest for its target (in some other zone),
                // else a Mac’s note; days off is another deadline, not another zone
                if let at, let reference = usual[first.targetVersion ?? ""],
                   (3_600...(26 * 3_600)).contains(abs(at.timeIntervalSince(reference))) {
                    unusual = hoursText(at.timeIntervalSince(reference))
                } else if group.contains(where: { $0.deadlineDate == nil }) {
                    unusual = first.isComputer ? macNote : "No time zone reported"
                }
            } else if TimeZone(identifier: zone!) == nil {
                unusual = "Not a time zone the Mac knows"
            } else if let seconds = offset(zone, at: local), seconds % 3_600 != 0 {
                unusual = "Not a whole hour from UTC"
            } else if let seconds = offset(zone, at: local), let common, seconds != common {
                unusual = hoursText(Double(seconds - common))
            }
            return DeadlineZone(zone: zone, localDeadline: local, reported: zone == nil ? at : nil,
                                target: zone == nil || first.targetVersion?.contains("earlier step") == true ? first.targetVersion : nil,
                                deviceCount: group.count,
                                deadline: at, unusual: unusual)
        }
        .sorted { $0.deviceCount != $1.deviceCount ? $0.deviceCount > $1.deviceCount
                  : ($0.label, $0.deadline ?? .distantFuture, $0.localDeadline, $0.target ?? "")
                    < ($1.label, $1.deadline ?? .distantFuture, $1.localDeadline, $1.target ?? "") }
    }

    /// A deadline as it is shown everywhere, with its time basis in
    /// parentheses: a reported moment in this Mac’s time zone, “(this Mac’s
    /// time)”; a local date-time as “(device’s local time)”. Where it comes
    /// from is said apart (`DeadlineSource`).
    static func text(local: String?, reported: Date?, timeZone: TimeZone = .current) -> String? {
        if let reported {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.timeZone = timeZone
            return "\(reported.formatted(style)) (this Mac’s time)"
        }
        return local.map { "\(TargetRules.readable($0)) (device’s local time)" }
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
