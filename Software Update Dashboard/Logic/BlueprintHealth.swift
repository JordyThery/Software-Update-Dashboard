import Foundation
import JTKit

/// How the Blueprint’s update declarations stand across its devices, read
/// once per refresh, one request per declaration (never per device): each
/// declaration by name, never by ID, with how many devices report it
/// applied, pending, awaiting sync, failed or invalid, and the most common
/// reason; and the devices on a version none of its declarations covers.
///
/// The identifiers come from the devices’ own status reports
/// (`management.declarations`); a declaration no device has received isn’t
/// listed. A report is tied to a device by its Platform device ID, which
/// the refresh finds by serial number; a report that can’t be tied is left
/// out and counted in `unmatchedDevices`.
nonisolated struct BlueprintHealth: Sendable, Hashable {
    /// One declaration (a configuration with its own activation).
    struct Declaration: Sendable, Hashable, Identifiable {
        /// Only to tell the rows apart; never shown.
        var id: String
        var name: String
        var applied = 0
        var pending = 0
        var awaitingSync = 0
        var failed = 0
        var invalid = 0
        /// Devices its activation’s predicate leaves out, by design.
        var notForDevice = 0
        /// The reason most failed or invalid devices give, without IDs, and how many give it.
        var commonReason: String?
        var commonReasonCount = 0

        var hasProblems: Bool { failed > 0 || invalid > 0 }
    }

    var declarations: [Declaration] = []
    /// By device (`DeviceStatus.id`): the Blueprint’s version ranges for its
    /// hardware, none of which covers the version it runs.
    var notCovered: [String: String] = [:]
    /// Devices in the reports that couldn’t be tied to a device in the list.
    var unmatchedDevices = 0
    /// Devices in the list whose serial number isn’t in the Platform device list.
    var devicesWithoutPlatformID = 0
    /// What couldn’t be read, e.g. a declaration report that was refused.
    var problems: [String] = []

    /// The Blueprint’s declaration identifiers among those the devices
    /// hold, each once, in the order found.
    static func identifiers(blueprintID: String, statuses: [JamfPro.SoftwareUpdateStatus?]) -> [String] {
        let prefix = "blueprint_\(blueprintID.lowercased())_"
        var seen = Set<String>()
        return statuses.flatMap { $0?.declarationIdentifiers ?? [] }
            .filter { $0.lowercased().hasPrefix(prefix) && seen.insert($0).inserted }
    }

    /// Each device’s reports of the Blueprint’s declarations, by
    /// `DeviceStatus.id`, from the reports per declaration; a report whose
    /// device isn’t in `deviceIDs` (Platform device ID → `DeviceStatus.id`)
    /// is left out and counted.
    static func byDevice(_ reports: [JamfPlatform.DeclarationReport],
                         deviceIDs: [String: String]) -> (reports: [String: [JamfPlatform.DeclarationReport]], unmatched: Int) {
        var byDevice: [String: [JamfPlatform.DeclarationReport]] = [:]
        var unmatched = Set<String>()
        for report in reports {
            guard let platformID = report.deviceID?.lowercased() else { continue }
            if let device = deviceIDs[platformID] {
                byDevice[device, default: []].append(report)
            } else {
                unmatched.insert(platformID)
            }
        }
        return (byDevice, unmatched.count)
    }

    /// Whether the device’s report of the Blueprint’s configurations says
    /// awaiting sync: Jamf sent a new one the device hasn’t fetched.
    static func isAwaitingSync(_ reports: [JamfPlatform.DeclarationReport]) -> Bool {
        reports.contains { $0.status == .awaitingSync }
    }

    static func make(byDevice: [String: [JamfPlatform.DeclarationReport]], devices: [DeviceStatus], blueprintName: String,
                     blueprintID: String, unmatchedDevices: Int = 0, devicesWithoutPlatformID: Int = 0,
                     problems: [String] = []) -> BlueprintHealth {
        let names = [blueprintID.lowercased(): blueprintName]
        let all = byDevice.values.flatMap { $0 }
        // the pairs as Jamf sent them, each with an activation that names its predicate when one does
        let shapes = DeclarationPair.pairs(all).sorted { first, second in
            // in step order, then by number
            let steps = (step(first, all) ?? 0, step(second, all) ?? 0)
            return steps.0 != steps.1 ? steps.0 < steps.1 : (Int(first.number ?? "") ?? 0) < (Int(second.number ?? "") ?? 0)
        }.map { pair -> DeclarationPair in
            let activation = pair.reports.first { report in
                report.type == "ACTIVATION" && report.reasons.contains { reason in
                    reason.details.contains { $0.key?.lowercased() == "predicate" } || (reason.description ?? "").contains("predicate")
                }
            } ?? pair.activation
            return DeclarationPair(key: pair.key, number: pair.number, reports: activation.map { [$0] } ?? [])
        }

        var declarations: [Declaration] = []
        for shape in shapes {
            var row = Declaration(id: shape.key, name: name(shape, blueprintName: blueprintName, all: all))
            var reasons: [String: Int] = [:]
            for reports in byDevice.values {
                let mine = DeclarationPair.pairs(reports).first { $0.key == shape.key }
                guard let mine else { continue }
                let state = mine.state(names: names)
                switch state {
                case "Not for this device": row.notForDevice += 1
                case "Applied": row.applied += 1
                case "Pending": row.pending += 1
                case "Awaiting sync": row.awaitingSync += 1
                default:
                    if state.hasPrefix("Invalid: ") {
                        row.invalid += 1
                        reasons[String(state.dropFirst("Invalid: ".count)), default: 0] += 1
                    } else if state.hasPrefix("Failed: ") {
                        row.failed += 1
                        reasons[String(state.dropFirst("Failed: ".count)), default: 0] += 1
                    }
                }
            }
            if let common = reasons.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                row.commonReason = common.key
                row.commonReasonCount = common.value
            }
            declarations.append(row)
        }
        let named = uniqueNames(declarations.map { DeclarationLine(name: $0.name, state: "") })
        for index in declarations.indices { declarations[index].name = named[index].name }

        var notCovered: [String: String] = [:]
        for device in devices {
            if let ranges = notCoveredRanges(device, shapes: shapes, reports: byDevice[device.id]) { notCovered[device.id] = ranges }
        }
        return BlueprintHealth(declarations: declarations, notCovered: notCovered, unmatchedDevices: unmatchedDevices,
                               devicesWithoutPlatformID: devicesWithoutPlatformID, problems: problems)
    }

    /// A declaration’s name: by its versions or OS family when a device
    /// reported its predicate; otherwise (its condition is true for every
    /// device, so none reports it) by its step: “‹Blueprint›, step 1”.
    static func name(_ shape: DeclarationPair, blueprintName: String, all: [JamfPlatform.DeclarationReport]) -> String {
        if shape.predicate != nil { return shape.label(blueprint: blueprintName, osName: shape.family ?? "", deviceMajor: nil) }
        guard let step = step(shape, all) else { return shape.label(blueprint: blueprintName, osName: "", deviceMajor: nil) }
        return "\(blueprintName), step \(step + 1)" + ((shape.number ?? "1") == "1" ? "" : ", declaration \(shape.number ?? "")")
    }

    /// The Blueprint step (zero-based) a pair is in, from its identifier.
    static func step(_ pair: DeclarationPair, _ all: [JamfPlatform.DeclarationReport]) -> Int? {
        (pair.reports.first ?? all.first { DeclarationPair.pairs([$0]).first?.key == pair.key })?.blueprintStepIndex
    }

    /// The Blueprint’s ranges for this device’s hardware when they all end
    /// below the version it runs while its target is newer: Jamf’s update
    /// doesn’t cover it yet. Nil when one covers it, it applies a declaration
    /// already, it is on target, or the predicates don’t say.
    static func notCoveredRanges(_ device: DeviceStatus, shapes: [DeclarationPair],
                                 reports: [JamfPlatform.DeclarationReport]?) -> String? {
        guard device.category != .onTarget, device.category != .targetUnknown,
              let version = OSVersion(device.currentOS), let target = device.targetVersion.flatMap(OSVersion.init),
              target > version else { return nil }
        // a declaration that applies on the device covers it
        if let reports, DeclarationPair.pairs(reports).contains(where: { $0.isActive && !$0.isNotForThisDevice }) { return nil }
        let ids = [device.boardID, device.modelIdentifier.isEmpty ? nil : device.modelIdentifier].compactMap { $0 }
        let listing = shapes.filter { pair in
            pair.family.map { $0 == device.osName } ?? false && ids.contains { pair.lists($0) }
        }
        let sameMajor = listing.filter { $0.upperBound?.major == version.major }
        guard !sameMajor.isEmpty, sameMajor.allSatisfy({ pair in pair.upperBound.map { $0 < version } ?? false }) else { return nil }
        return sameMajor.compactMap { $0.predicate.flatMap(DeclarationPair.versionRange).map { "\(device.osName) \($0)" } }
            .joined(separator: "; ")
    }

    /// The cause as the device list says it.
    static func notCoveredDiagnosis(_ device: DeviceStatus) -> String {
        "Jamf’s update doesn’t cover \(device.osName) \(device.currentOS) yet"
    }

    /// The categories whose diagnosis the cause replaces: the device isn’t
    /// updating and nothing else explains it better.
    static let explainedCategories: Set<StatusCategory> = [.notStarted, .noActivity]

    /// The dashboard’s line, nil when no device is affected.
    static func dashboardLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 device is on a version the Blueprint’s update doesn’t cover yet"
            : "\(count) devices are on a version the Blueprint’s update doesn’t cover yet"
    }

    /// Names made unique, in order: a second “‹Blueprint›, iPadOS” reads
    /// “‹Blueprint›, iPadOS (2)”.
    static func uniqueNames(_ lines: [DeclarationLine]) -> [DeclarationLine] {
        var seen: [String: Int] = [:]
        return lines.map { line in
            seen[line.name, default: 0] += 1
            let count = seen[line.name] ?? 1
            return count == 1 ? line : DeclarationLine(name: "\(line.name) (\(count))", state: line.state)
        }
    }
}
