import Foundation
import JTKit

/// One row of the dashboard’s table per platform and major release.
nonisolated struct MajorRow: Sendable, Hashable, Identifiable {
    var osName: String
    /// Nil for devices whose version isn’t known.
    var major: Int?
    var devices: Int
    /// The targets of its devices, lowest first (usually one).
    var targets: [String]
    var onTarget: Int
    var updatable: Int
    /// Each distinct deadline once, as shown everywhere (`DeadlineZones.text`).
    var deadlines: [String]
    var pastDeadline: Int

    var id: String { "\(osName) \(major.map(String.init) ?? "?")" }

    /// Reported moments first by time, then computed local times; each once
    /// (to the minute: devices report the same deadline a few seconds apart).
    static func deadlines(_ devices: [DeviceStatus]) -> [String] {
        let reported = Set(devices.compactMap { $0.deadlineDate.map { Int($0.timeIntervalSince1970 / 60) } }).sorted()
            .compactMap { DeadlineZones.text(local: nil, reported: Date(timeIntervalSince1970: Double($0) * 60)) }
        let computed = Set(devices.filter { $0.deadlineDate == nil }.compactMap(\.deadlineLocal)).sorted()
            .compactMap { DeadlineZones.text(local: $0, reported: nil) }
        return reported + computed
    }

    static func rows(_ devices: [DeviceStatus]) -> [MajorRow] {
        Dictionary(grouping: devices) { "\($0.osName)|\(OSVersion($0.currentOS)?.major.description ?? "")" }
            .map { _, group in
                let counts = CategoryCounts(group)
                return MajorRow(
                    osName: group[0].osName, major: OSVersion(group[0].currentOS)?.major, devices: group.count,
                    targets: Set(group.compactMap(\.targetVersion)).sorted { (OSVersion($0) ?? OSVersion(major: 0)) < (OSVersion($1) ?? OSVersion(major: 0)) },
                    onTarget: counts[.onTarget], updatable: counts.updatable,
                    deadlines: Self.deadlines(group),
                    pastDeadline: group.filter { $0.pastDeadline == true }.count)
            }
            .sorted { $0.osName != $1.osName ? $0.osName < $1.osName : ($0.major ?? -1) > ($1.major ?? -1) }
    }
}

/// The comparison group’s devices the Blueprint doesn’t reach.
nonisolated struct Coverage: Sendable, Hashable {
    var group: GroupReference
    var members: Int
    var notReached: [JamfPro.GroupMember]
}

/// What a refresh of a tracked Blueprint found.
nonisolated struct RefreshResult: Sendable {
    var date: Date
    var tracked: TrackedBlueprint
    var blueprintName: String
    var blueprintChanged: Date?
    /// Every software update block of the Blueprint, and its update settings.
    var blocks: [JamfPlatform.SoftwareUpdateBlock]
    var settings: [JamfPlatform.SoftwareUpdateSettings]
    /// The Blueprint’s rule in plain language, e.g. “Minor updates, 14 days after their release”.
    var rule: String
    /// The Blueprint’s scope as Jamf Pro groups, and its Platform groups that aren’t one.
    var scope: [GroupReference]
    var unmatchedScope: Int
    var scopeChange: ScopeChange?
    var members: [JamfPro.GroupMember]
    var devices: [DeviceStatus]
    var majors: [MajorRow]
    var zones: [DeadlineZone]
    var replacements: [Replacement]
    var coverage: Coverage?
    /// What couldn’t be read but didn’t stop the refresh, e.g. Apple’s release data.
    var problems: [String]

    var counts: CategoryCounts { CategoryCounts(devices) }
    var pastDeadline: Int { devices.filter { $0.pastDeadline == true }.count }
}

/// Apple’s release data couldn’t be read at all: no device’s target is
/// known, so the refresh stops and the previous one is kept.
nonisolated struct AppleDataUnavailable: LocalizedError, Equatable {
    var errorDescription: String? {
        "Apple’s release data couldn’t be read, so no device’s target is known. The previous refresh is kept; try again later."
    }
}

/// A refresh: reads the Blueprint’s software update and scope, the scope
/// groups’ members with their inventory and each one’s status report (all
/// GETs, through JTKit), gives every device its own target and sorts it.
nonisolated struct RefreshWorkflow: Sendable {
    let client: JamfPlatform.Client
    /// Apple’s release data; nil when it couldn’t be read (the refresh stops).
    let catalog: AppleReleases.Catalog?
    let serverTimeZone: TimeZone
    var staleDays = 30
    /// Status reports read at the same time.
    var parallel = 4

    func run(_ tracked: TrackedBlueprint, previousScope: [GroupReference]? = nil, now: Date = Date(),
             progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RefreshResult {
        guard let catalog else { throw AppleDataUnavailable() }
        let (blueprint, blocks) = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: tracked.blueprintID)
        var problems = catalog.problems
        if blocks.isEmpty { problems.append("The Blueprint has no software update.") }

        // the scope, read on every refresh
        let platformGroups = try await client.platformGroups()
        let groups = try await client.jamfProGroups()
        let keys = GroupChoice.scope(platformGroupIDs: blueprint.scopeDeviceGroups, platformGroups: platformGroups)
        let scope = keys.compactMap { key in groups.first { $0.id == key }.map(GroupReference.init) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let unmatched = blueprint.scopeDeviceGroups.count - scope.count
        if unmatched > 0 {
            problems.append("\(unmatched) of the Blueprint’s scope groups \(unmatched == 1 ? "isn’t" : "aren’t") a Jamf Pro mobile device or computer group.")
        }

        // each device once, also when it is in several scope groups
        var members: [JamfPro.GroupMember] = []
        var seen = Set<String>()
        for group in scope {
            for member in try await client.members(of: group.group) where seen.insert(Self.key(member)).inserted {
                members.append(member)
            }
        }

        let inputs = try await statuses(members, progress: progress)
        let devices = inputs.map { input in classify(input, blocks: blocks, blueprint: blueprint, tracked: tracked, now: now) }

        var coverage: Coverage?
        if let compare = tracked.compareGroup {
            let compared = try await client.members(of: compare.group)
            coverage = Coverage(group: compare, members: compared.count,
                                notReached: compared.filter { !seen.contains(Self.key($0)) })
        }
        return RefreshResult(
            date: now, tracked: tracked, blueprintName: blueprint.overview.name, blueprintChanged: blueprint.overview.updatedDate,
            blocks: blocks, settings: blueprint.softwareUpdateSettings, rule: Self.rule(blocks),
            scope: scope, unmatchedScope: unmatched, scopeChange: ScopeChange(from: previousScope, to: scope),
            members: members, devices: devices, majors: MajorRow.rows(devices),
            zones: DeadlineZones.zones(devices: devices),
            replacements: Replacement.list(devices) { device in
                // the same rule as the targets: the newest release the device can run
                TargetRules.newestRelease(catalog, device.isComputer ? .macOS : .iOS, model: device.modelIdentifier,
                                          boardID: device.boardID, knownOnly: true)?.version.description
            },
            coverage: coverage, problems: problems)
    }

    /// One device against its own target.
    func classify(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                  tracked: TrackedBlueprint, now: Date) -> DeviceStatus {
        let member = input.member
        let platform: AppleReleases.Platform = member.kind == .computer ? .macOS : .iOS
        let model = member.modelIdentifier ?? input.status?.modelIdentifier
        let osName = Classifier.osName(isComputer: member.kind == .computer, modelIdentifier: model ?? "")
        let os = input.status?.osVersion ?? member.osVersion
        let rule = TargetRules.target(
            os: os, model: model, boardID: input.status?.deviceID, osName: osName,
            context: TargetRules.Context(block: Self.block(for: osName, in: blocks), catalog: catalog, platform: platform,
                                         blueprintChanged: blueprint.overview.updatedDate, updateStarted: tracked.updateStarted,
                                         now: now))
        // what Jamf actually sent the device comes first, when it reports it
        var target = TargetRules.fromDevice(rule, status: input.status, os: os, osName: osName, catalog: catalog,
                                            platform: platform, serverTimeZone: serverTimeZone, model: model,
                                            boardID: input.status?.deviceID, blueprintChanged: blueprint.overview.updatedDate)
        // hardware that can't run the newest major stays on the list to
        // replace, whichever source gave its target
        if target.unknown == nil, !target.noApplicableRelease, let catalog {
            target.limitedByHardware = target.limitedByHardware
                || TargetRules.cannotRunNewestMajor(catalog, platform, model: model, boardID: input.status?.deviceID)
        }
        let base = ClassificationContext(target: nil, since: nil, serverTimeZone: serverTimeZone, now: now, staleDays: staleDays,
                                         catalog: catalog, platform: platform)
        return Classifier.classify(input, target: target, context: base)
    }

    /// Each member’s status report, a few at a time, in the members’ order.
    /// A report that can’t be read is noted on the device, not thrown.
    func statuses(_ members: [JamfPro.GroupMember], progress: @Sendable (Int, Int) -> Void) async throws -> [DeviceInput] {
        var inputs: [Int: DeviceInput] = [:]
        try await withThrowingTaskGroup(of: (Int, DeviceInput).self) { group in
            var next = 0
            func start() {
                guard next < members.count else { return }
                let index = next
                let member = members[index]
                next += 1
                group.addTask {
                    guard let managementID = member.managementID, !managementID.isEmpty else {
                        return (index, DeviceInput(member: member, statusProblem: "No management ID in Jamf Pro"))
                    }
                    do {
                        let status = try await client.softwareUpdateStatus(managementID: managementID, kind: member.kind)
                        return (index, DeviceInput(member: member, status: status))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, DeviceInput(member: member, statusProblem: error.localizedDescription))
                    }
                }
            }
            for _ in 0..<max(1, parallel) { start() }
            while let (index, input) = try await group.next() {
                inputs[index] = input
                progress(inputs.count, members.count)
                start()
            }
        }
        return members.indices.compactMap { inputs[$0] }
    }

    /// A device by kind and Jamf Pro number: a Mac and an iPad can share a number.
    static func key(_ member: JamfPro.GroupMember) -> String { "\(member.kind.rawValue)/\(member.id)" }

    /// The block for a device: the one whose activation predicate asks for
    /// its OS (`== 'iPadOS'`; never `!= 'iPadOS'`), else one without a
    /// predicate, else the first.
    static func block(for osName: String, in blocks: [JamfPlatform.SoftwareUpdateBlock]) -> JamfPlatform.SoftwareUpdateBlock? {
        blocks.first { $0.activationPredicate?.range(of: "==\\s*'\(osName)'", options: .regularExpression) != nil }
            ?? blocks.first { $0.activationPredicate == nil }
            ?? blocks.first
    }

    /// The Blueprint’s rule in plain language; several blocks joined.
    static func rule(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String {
        let rules = blocks.map { block -> String in
            switch block.enforcement {
            case .specific(let version, let deadline, _):
                "Version \(version)" + (deadline.map { " by \(TargetRules.readable($0))" } ?? "")
            case .latest(let days, _):
                (days ?? 0) == 0 ? "The newest release, without delay" : "The newest release, \(days ?? 0) days after its release"
            case .semantic(let days, _):
                (days ?? 0) == 0 ? "Minor updates, without delay" : "Minor updates, \(days ?? 0) days after their release"
            case .unknown:
                "A software update this app doesn’t read"
            }
        }
        return rules.isEmpty ? "No software update" : Array(NSOrderedSet(array: rules)).compactMap { $0 as? String }.joined(separator: "; ")
    }
}
