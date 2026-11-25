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
    /// The Blueprint’s deadlines, each once, as shown everywhere
    /// (`DeadlineZones.text`); the reported ones only when none is computed.
    var deadlines: [String]
    /// Reported deadlines that differ from those, each once, and how many devices report them.
    var otherDeadlines: [String] = []
    var otherDeadlineDevices = 0
    var pastDeadline: Int

    var id: String { "\(osName) \(major.map(String.init) ?? "?")" }

    /// The deadlines shown for a row: the Blueprint’s (computed local times),
    /// each once; a reported moment that is one of them in some zone counts
    /// as it. Reported moments that differ are counted apart (`others`),
    /// each once (to the minute: devices report the same deadline a few
    /// seconds apart). Without a computed deadline, the reported ones show.
    static func deadlineColumn(_ devices: [DeviceStatus]) -> (shown: [String], others: [String], otherDevices: Int) {
        let computedLocal = Set(devices.filter { $0.deadlineDate == nil }.compactMap(\.deadlineLocal)).sorted()
        let reportedDevices = devices.filter { $0.deadlineDate != nil }
        func moments(_ group: [DeviceStatus]) -> [String] {
            Set(group.compactMap { $0.deadlineDate.map { Int($0.timeIntervalSince1970 / 60) } }).sorted()
                .compactMap { DeadlineZones.text(local: nil, reported: Date(timeIntervalSince1970: Double($0) * 60)) }
        }
        guard !computedLocal.isEmpty else { return (moments(reportedDevices), [], 0) }
        let different = reportedDevices.filter { device in
            !computedLocal.contains { TargetRules.sameDeadline(reported: device.deadlineDate, reportedLocal: nil, expected: $0) }
        }
        return (computedLocal.compactMap { DeadlineZones.text(local: $0, reported: nil) }, moments(different), different.count)
    }

    /// Every deadline of a row, each once: the shown ones and the others.
    static func deadlines(_ devices: [DeviceStatus]) -> [String] {
        let column = deadlineColumn(devices)
        return column.shown + column.others
    }

    static func rows(_ devices: [DeviceStatus]) -> [MajorRow] {
        Dictionary(grouping: devices) { "\($0.osName)|\(OSVersion($0.currentOS)?.major.description ?? "")" }
            .map { _, group in
                let counts = CategoryCounts(group)
                let column = Self.deadlineColumn(group)
                return MajorRow(
                    osName: group[0].osName, major: OSVersion(group[0].currentOS)?.major, devices: group.count,
                    targets: Set(group.compactMap(\.targetVersion)).sorted { (OSVersion($0) ?? OSVersion(major: 0)) < (OSVersion($1) ?? OSVersion(major: 0)) },
                    onTarget: counts[.onTarget], updatable: counts.updatable,
                    deadlines: column.shown, otherDeadlines: column.others, otherDeadlineDevices: column.otherDevices,
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
    /// The same by its values (`RefreshWorkflow.ruleKey`), to compare refreshes.
    var ruleKey: String?
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
    /// How the Blueprint’s declarations stand across its devices; nil when
    /// they couldn’t be read. Not kept in the history.
    var health: BlueprintHealth?
    /// What to remember of the devices’ reported deadlines after this
    /// refresh (`ReportedDeadlines`). Not kept in the history.
    var reportedDeadlines = ReportedDeadlines()
    /// The devices’ status times line up with their last contact in UTC,
    /// not in the connection’s server time zone (`ServerTimeZoneCheck`).
    var serverTimeZoneLooksWrong = false

    /// Devices on a version the Blueprint’s update doesn’t cover yet.
    var notCoveredCount: Int { devices.filter { $0.notCoveredBy != nil }.count }

    var counts: CategoryCounts { CategoryCounts(devices) }
    var pastDeadline: Int { devices.filter { $0.pastDeadline == true }.count }
}

/// A refresh of a tracked Blueprint: JTKit’s reader (`SoftwareUpdateRules.Reader`)
/// reads the Blueprint’s software update and scope, the scope groups’
/// members with their inventory and each one’s status report (all GETs)
/// and measures every device; the app adds its comparison group, its
/// tables and the server time zone check, and keeps what it saves.
nonisolated struct RefreshWorkflow: Sendable {
    let client: JamfPlatform.Client
    /// Apple’s release data; nil when it couldn’t be read (the refresh stops).
    let catalog: AppleReleases.Catalog?
    let serverTimeZone: TimeZone
    /// The first public posting date this app saw of each build (`FirstPostings`).
    var firstPosted: [String: Date] = [:]
    /// What earlier refreshes of the tracked Blueprint remembered of its
    /// devices’ reported deadlines (`ReportedDeadlines`).
    var reportedDeadlines = ReportedDeadlines()
    /// Demo Mode: a Blueprint with nothing remembered starts as if earlier
    /// refreshes had seen its Macs report Jamf’s deadline for every version
    /// (`demoReportedDeadlines`), as its history starts with made-up days.
    var seedsDemoDeadlines = false
    var staleDays = 30
    /// Status reports read at the same time.
    var parallel = 4

    /// JTKit’s reader with this refresh’s settings: the one client for every read.
    private var reader: SoftwareUpdateRules.Reader {
        var reader = SoftwareUpdateRules.Reader(client: client, catalog: catalog, serverTimeZone: serverTimeZone)
        reader.firstPosted = firstPosted
        reader.reportedDeadlines = reportedDeadlines
        reader.seedsDemoDeadlines = seedsDemoDeadlines
        reader.staleDays = staleDays
        reader.parallel = parallel
        return reader
    }

    func run(_ tracked: TrackedBlueprint, previousScope: [GroupReference]? = nil, now: Date = Date(),
             progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> RefreshResult {
        let reading = try await reader.read(blueprintID: tracked.blueprintID, updateStarted: tracked.updateStarted, now: now,
                                            progress: progress)
        let scope = reading.scope.map(GroupReference.init)
        let devices = reading.devices
        var coverage: Coverage?
        if let compare = tracked.compareGroup {
            progress(RefreshProgress(step: "Reading the comparison group"))
            let seen = Set(reading.members.map(Self.key))
            let compared = try await client.members(of: compare.group)
            coverage = Coverage(group: compare, members: compared.count,
                                notReached: compared.filter { !seen.contains(Self.key($0)) })
        }
        return RefreshResult(
            date: now, tracked: tracked, blueprintName: reading.blueprint.overview.name,
            blueprintChanged: reading.blueprint.overview.updatedDate,
            blocks: reading.blocks, settings: reading.settings, rule: Self.rule(reading.blocks), ruleKey: Self.ruleKey(reading.blocks),
            scope: scope, unmatchedScope: reading.unmatchedScope, scopeChange: ScopeChange(from: previousScope, to: scope),
            members: reading.members, devices: devices, majors: MajorRow.rows(devices),
            zones: DeadlineZones.zones(devices: devices, now: now),
            replacements: Replacement.list(devices) { [catalog] device in
                // the same rule as the targets: the newest release the device can run
                catalog.flatMap {
                    TargetRules.newestRelease($0, device.isComputer ? .macOS : .iOS, model: device.modelIdentifier,
                                              boardID: device.boardID, knownOnly: true)?.version.description
                }
            },
            coverage: coverage, problems: reading.problems, health: reading.health, reportedDeadlines: reading.reportedDeadlines,
            serverTimeZoneLooksWrong: ServerTimeZoneCheck.looksWrong(reading.inputs.map { ($0.member.lastSeen, $0.status?.newestUpdate) },
                                                                    zone: serverTimeZone,
                                                                    defaultZone: AppConnection.defaultServerTimeZone))
    }

    // What the refresh is made of, from JTKit’s reader (each with the tracked Blueprint’s “Update started”).

    func declarationReports(_ identifiers: [String], inputs: inout [DeviceInput],
                            progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> (reports: [JamfPlatform.DeclarationReport], problem: String?) {
        try await reader.declarationReports(identifiers, inputs: &inputs, progress: progress)
    }

    func postingBasis(_ inputs: [DeviceInput], blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                      tracked: TrackedBlueprint, now: Date) -> PostingBasis {
        reader.postingBasis(inputs, blocks: blocks, blueprint: blueprint, updateStarted: tracked.updateStarted, now: now)
    }

    func deadlineBasis(_ inputs: [DeviceInput], blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                       tracked: TrackedBlueprint, now: Date) -> (known: PostingBasis, remember: ReportedDeadlines) {
        reader.deadlineBasis(inputs, blocks: blocks, blueprint: blueprint, updateStarted: tracked.updateStarted, now: now)
    }

    static func newDeadlineMinutes(_ candidates: [String: [(minute: Int, reportedAt: Date)]],
                                   known: [String: Set<Int>]) -> [String: Set<Int>] {
        SoftwareUpdateRules.Reader.newDeadlineMinutes(candidates, known: known)
    }

    func classify(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                  tracked: TrackedBlueprint, now: Date, known: PostingBasis? = nil, awaitingSync: Bool = false) -> DeviceStatus {
        reader.classify(input, blocks: blocks, blueprint: blueprint, updateStarted: tracked.updateStarted, now: now, known: known,
                        awaitingSync: awaitingSync)
    }

    func statuses(_ members: [JamfPro.GroupMember], progress: @Sendable (Int, Int) -> Void) async throws -> [DeviceInput] {
        try await reader.statuses(members, progress: progress)
    }

    /// A device by kind and Jamf Pro number: a Mac and an iPad can share a number.
    static func key(_ member: JamfPro.GroupMember) -> String { SoftwareUpdateRules.Reader.key(member) }

    static func block(for osName: String, in blocks: [JamfPlatform.SoftwareUpdateBlock]) -> JamfPlatform.SoftwareUpdateBlock? {
        SoftwareUpdateRules.Reader.block(for: osName, in: blocks)
    }

    /// The Blueprint’s rule by its values, to compare refreshes (`HistorySnapshot.ruleKey`).
    static func ruleKey(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String { SoftwareUpdateRules.Reader.ruleKey(blocks) }

    /// The Blueprint’s rule in plain language; several blocks joined.
    static func rule(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String { SoftwareUpdateRules.Reader.rule(blocks) }
}
