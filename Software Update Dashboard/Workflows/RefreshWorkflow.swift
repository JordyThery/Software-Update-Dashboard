import Foundation
import JTKit

/// What a refresh of a tracked group found.
nonisolated struct RefreshResult: Sendable {
    var date: Date
    var group: TrackedGroup
    var blueprintName: String
    /// Every software update block of the Blueprint.
    var blocks: [JamfPlatform.SoftwareUpdateBlock]
    /// The block the group is measured against.
    var block: JamfPlatform.SoftwareUpdateBlock?
    var target: OSVersion?
    var build: String?
    /// The deadline in each device’s local time, without a zone.
    var deadline: String?
    /// When the update started: the Blueprint’s last change.
    var since: Date?
    var osName: String
    var members: [JamfPro.GroupMember]
    var devices: [DeviceStatus]
    var zones: [DeadlineZone]
    var replacements: [Replacement]
    /// What couldn’t be read but didn’t stop the refresh, e.g. Apple’s release data.
    var problems: [String]

    var counts: CategoryCounts { CategoryCounts(devices) }
}

/// A refresh: reads the Blueprint’s software update, the group’s members
/// with their inventory and each one’s status report (all GETs, through
/// JTKit), and sorts every device into its category.
nonisolated struct RefreshWorkflow: Sendable {
    let client: JamfPlatform.Client
    let catalog: AppleReleases.Catalog?
    let serverTimeZone: TimeZone
    var staleDays = 30
    /// Status reports read at the same time.
    var parallel = 4

    func run(_ group: TrackedGroup, now: Date = Date(), progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RefreshResult {
        let (blueprint, blocks) = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: group.blueprintID)
        let members = try await client.members(of: group.group)
        let block = Self.block(for: members, in: blocks)
        let platform = group.platform
        var problems = catalog?.problems ?? ["Apple’s release data couldn’t be read: unsupported hardware and builds aren’t known."]
        let (target, deadline) = Self.target(of: block, catalog: catalog, platform: platform)
        if block == nil { problems.append("The Blueprint has no software update.") }
        let build = block?.targetBuildVersion ?? target.flatMap { catalog?.build(of: $0, platform) }

        let inputs = try await statuses(members, progress: progress)
        let context = ClassificationContext(target: target, since: blueprint.overview.updatedDate, serverTimeZone: serverTimeZone,
                                            now: now, staleDays: staleDays, catalog: catalog, platform: platform)
        let devices = Classifier.classify(inputs, context: context)
        let osName = group.isComputerGroup ? "macOS"
            : Classifier.osName(isComputer: false, modelIdentifier: Self.mostCommonModel(members) ?? "iPad")
        return RefreshResult(
            date: now, group: group, blueprintName: blueprint.overview.name, blocks: blocks, block: block, target: target,
            build: build, deadline: deadline, since: blueprint.overview.updatedDate, osName: osName, members: members,
            devices: devices, zones: DeadlineZones.zones(deadline: deadline, devices: devices),
            replacements: Replacement.list(devices) { model in
                catalog?.lastSupportedVersion(model: model, boardID: model, platform)?.description
            },
            problems: problems)
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

    /// The block the group is measured against: the one whose activation
    /// predicate names the group’s most common OS (iPadOS, iOS, macOS), else
    /// one without a predicate, else the first.
    static func block(for members: [JamfPro.GroupMember], in blocks: [JamfPlatform.SoftwareUpdateBlock]) -> JamfPlatform.SoftwareUpdateBlock? {
        let family = members.first?.kind == .computer ? "macOS"
            : Classifier.osName(isComputer: false, modelIdentifier: mostCommonModel(members) ?? "iPad")
        return blocks.first { $0.activationPredicate?.contains("'\(family)'") == true }
            ?? blocks.first { $0.activationPredicate == nil }
            ?? blocks.first
    }

    /// The version and deadline a block asks for. An automatic block asks
    /// for the newest release (of the newest major), by its release date
    /// plus its days, at its time.
    static func target(of block: JamfPlatform.SoftwareUpdateBlock?, catalog: AppleReleases.Catalog?,
                       platform: AppleReleases.Platform) -> (OSVersion?, String?) {
        switch block?.enforcement {
        case .specific(let version, let deadline, _)?:
            return (OSVersion(version), deadline)
        case .latest(let days, let time)?, .semantic(let days, let time)?:
            guard let latest = catalog?.latest(platform) else { return (nil, nil) }
            return (latest.version, latest.releaseDate.map { localDeadline($0, days: days ?? 0, time: time) })
        default:
            return (nil, nil)
        }
    }

    /// The release date plus days, at `HH:MM`, as a local date-time text.
    static func localDeadline(_ released: Date, days: Int, time: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = calendar.date(byAdding: .day, value: days, to: released) ?? released
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let clock = time.flatMap { $0.count == 5 ? $0 : nil } ?? "00:00"
        return String(format: "%04d-%02d-%02dT%@:00", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1, clock)
    }

    static func mostCommonModel(_ members: [JamfPro.GroupMember]) -> String? {
        let families = members.compactMap(\.modelIdentifier).map { $0.hasPrefix("iPad") ? "iPad" : $0.hasPrefix("iPhone") ? "iPhone" : $0 }
        return Dictionary(grouping: families, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}
