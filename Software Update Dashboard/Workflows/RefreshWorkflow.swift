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

    /// Devices on a version the Blueprint’s update doesn’t cover yet.
    var notCoveredCount: Int { devices.filter { $0.notCoveredBy != nil }.count }

    var counts: CategoryCounts { CategoryCounts(devices) }
    var pastDeadline: Int { devices.filter { $0.pastDeadline == true }.count }
}

/// Where a refresh is: the step, and how far it is when it counts something.
nonisolated struct RefreshProgress: Sendable, Hashable {
    var step: String
    var done = 0
    var total = 0
    /// What it counts, in the plural (“devices”, “declarations”, “groups”).
    var unit = ""

    /// “Reading Blueprint health, 3 of 18 declarations”.
    var text: String { total > 0 ? "\(step), \(done) of \(total) \(unit)" : step }
}

/// Apple’s release data couldn’t be read at all: no device’s target is
/// known, so the refresh stops and the previous one is kept.
nonisolated struct AppleDataUnavailable: LocalizedError, Equatable {
    var errorDescription: String? {
        "Apple’s release data couldn’t be read, so no device’s target is known."
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
    /// The first public posting date this app saw of each build (`FirstPostings`).
    var firstPosted: [String: Date] = [:]
    var staleDays = 30
    /// Status reports read at the same time.
    var parallel = 4

    func run(_ tracked: TrackedBlueprint, previousScope: [GroupReference]? = nil, now: Date = Date(),
             progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> RefreshResult {
        guard let catalog else { throw AppleDataUnavailable() }
        progress(RefreshProgress(step: "Reading the Blueprint"))
        let (blueprint, blocks) = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: tracked.blueprintID)
        var problems = catalog.problems
        if blocks.isEmpty { problems.append("The Blueprint has no software update.") }

        // the scope, read on every refresh
        progress(RefreshProgress(step: "Reading the Blueprint’s scope"))
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
        for (number, group) in scope.enumerated() {
            progress(RefreshProgress(step: "Reading group members", done: number, total: scope.count, unit: "groups"))
            for member in try await client.members(of: group.group) where seen.insert(Self.key(member)).inserted {
                members.append(member)
            }
        }

        progress(RefreshProgress(step: "Reading status reports", done: 0, total: members.count, unit: "devices"))
        var inputs = try await statuses(members) { done, total in
            progress(RefreshProgress(step: "Reading status reports", done: done, total: total, unit: "devices"))
        }
        // the Blueprint's update declarations, as the devices list them: each read once, for every device
        let identifiers = BlueprintHealth.identifiers(blueprintID: tracked.blueprintID, statuses: inputs.map(\.status), blocks: blocks)
        let declarations = try await declarationReports(identifiers, inputs: &inputs, progress: progress)
        var deviceIDs: [String: String] = [:]
        for input in inputs {
            if let platformID = input.platformDeviceID?.lowercased() { deviceIDs[platformID] = Self.key(input.member) }
        }
        let tied = BlueprintHealth.byDevice(declarations.reports, deviceIDs: deviceIDs)
        let current = BlueprintHealth.catalogue(declarations.reports, blocks: blocks, blueprintName: blueprint.overview.name)
        let known = postingBasis(inputs, blocks: blocks, blueprint: blueprint, tracked: tracked, now: now)
        var devices = inputs.map { input in
            let osName = Classifier.osName(isComputer: input.member.kind == .computer,
                                           modelIdentifier: input.member.modelIdentifier ?? input.status?.modelIdentifier ?? "")
            return classify(input, blocks: blocks, blueprint: blueprint, tracked: tracked, now: now, known: known,
                            awaitingSync: BlueprintHealth.isAwaitingSync(tied.reports[Self.key(input.member)] ?? [],
                                                                         osName: osName, current: current))
        }
        var health: BlueprintHealth?
        if let problem = declarations.problem {
            problems.append(problem)
        } else {
            let built = BlueprintHealth.make(byDevice: tied.reports, devices: devices, current: current,
                                             blueprintName: blueprint.overview.name, blueprintID: tracked.blueprintID,
                                             unmatchedDevices: tied.unmatched,
                                             devicesWithoutPlatformID: identifiers.isEmpty ? 0 : inputs.filter { $0.platformDeviceID == nil }.count)
            // the cause where nothing else explains it: the list says it
            for index in devices.indices {
                devices[index].declarationsChecked = true
                guard let found = built.coverage[devices[index].id] else {
                    // a failed or invalid update declaration of its own OS explains a device that hasn't started
                    if BlueprintHealth.explainedCategories.contains(devices[index].category),
                       let problem = BlueprintHealth.declarationProblem(tied.reports[devices[index].id] ?? [], osName: devices[index].osName,
                                                                        current: current, names: [tracked.blueprintID.lowercased(): blueprint.overview.name]) {
                        devices[index].diagnosis = problem
                    }
                    continue
                }
                switch found {
                case .notCovered(let ranges): devices[index].notCoveredBy = ranges
                case .notFetched(let last):
                    devices[index].notFetched = true
                    devices[index].notFetchedSince = last
                }
                if BlueprintHealth.explainedCategories.contains(devices[index].category) {
                    devices[index].diagnosis = BlueprintHealth.diagnosis(found, device: devices[index])
                }
            }
            health = built
        }

        var coverage: Coverage?
        if let compare = tracked.compareGroup {
            progress(RefreshProgress(step: "Reading the comparison group"))
            let compared = try await client.members(of: compare.group)
            coverage = Coverage(group: compare, members: compared.count,
                                notReached: compared.filter { !seen.contains(Self.key($0)) })
        }
        return RefreshResult(
            date: now, tracked: tracked, blueprintName: blueprint.overview.name, blueprintChanged: blueprint.overview.updatedDate,
            blocks: blocks, settings: blueprint.softwareUpdateSettings, rule: Self.rule(blocks), ruleKey: Self.ruleKey(blocks),
            scope: scope, unmatchedScope: unmatched, scopeChange: ScopeChange(from: previousScope, to: scope),
            members: members, devices: devices, majors: MajorRow.rows(devices),
            zones: DeadlineZones.zones(devices: devices, now: now),
            replacements: Replacement.list(devices) { device in
                // the same rule as the targets: the newest release the device can run
                TargetRules.newestRelease(catalog, device.isComputer ? .macOS : .iOS, model: device.modelIdentifier,
                                          boardID: device.boardID, knownOnly: true)?.version.description
            },
            coverage: coverage, problems: problems, health: health)
    }

    /// Each of the Blueprint’s update declarations the devices list, read
    /// once (its devices’ reports), a few at a time, and the Platform device
    /// list, read once, to tie each report to a device by serial number. A
    /// refusal or a failed read stops the reading and is returned as the
    /// problem (never as “serial not found”); a declaration nothing reported
    /// gives none. A stop is thrown, so a stopped refresh is never saved.
    func declarationReports(_ identifiers: [String], inputs: inout [DeviceInput],
                            progress: @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> (reports: [JamfPlatform.DeclarationReport], problem: String?) {
        guard !identifiers.isEmpty else { return ([], nil) }
        progress(RefreshProgress(step: "Reading the device list"))
        let platformDevices: [JamfPlatform.Device]
        do {
            platformDevices = try await client.devices()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ([], "The Platform device list couldn’t be read, so the Blueprint’s declaration reports can’t be tied to devices: "
                        + error.localizedDescription)
        }
        var bySerial: [String: String] = [:]
        for device in platformDevices {
            if let serial = device.serialNumber?.uppercased(), !serial.isEmpty { bySerial[serial] = device.id }
        }
        for index in inputs.indices {
            inputs[index].platformDeviceID = inputs[index].member.serialNumber.flatMap { bySerial[$0.uppercased()] }
        }
        do {
            var reports: [JamfPlatform.DeclarationReport] = []
            try await withThrowingTaskGroup(of: [JamfPlatform.DeclarationReport].self) { group in
                var next = 0
                func start() {
                    guard next < identifiers.count else { return }
                    let identifier = identifiers[next]
                    next += 1
                    group.addTask { try await client.declarationReports(declarationIdentifier: identifier) ?? [] }
                }
                for _ in 0..<max(1, parallel) { start() }
                var read = 0
                progress(RefreshProgress(step: "Reading Blueprint health", done: 0, total: identifiers.count, unit: "declarations"))
                while let found = try await group.next() {
                    reports += found
                    read += 1
                    progress(RefreshProgress(step: "Reading Blueprint health", done: read, total: identifiers.count, unit: "declarations"))
                    start()
                }
            }
            return (reports, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ([], "The Blueprint’s declaration reports couldn’t be read: \(error.localizedDescription)")
        }
    }

    /// What the Blueprint’s computed deadlines count from: the first public
    /// posting dates this app saw and, per platform and version, the posting
    /// date the devices’ own reports say Jamf counted from (`TargetRules.reportedPosting`).
    func postingBasis(_ inputs: [DeviceInput], blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                      tracked: TrackedBlueprint, now: Date) -> PostingBasis {
        var known = PostingBasis(remembered: firstPosted)
        let reports = inputs.compactMap { input -> (platform: AppleReleases.Platform, version: OSVersion, posted: Date)? in
            let device = rule(input, blocks: blocks, blueprint: blueprint, tracked: tracked, now: now, known: known)
            guard let version = device.rule.osVersion,
                  let posted = TargetRules.reportedPosting(device.rule, status: input.status, block: device.block, catalog: catalog,
                                                           platform: device.platform, serverTimeZone: serverTimeZone,
                                                           blueprintChanged: blueprint.overview.updatedDate,
                                                           timeZone: input.member.timeZone) else { return nil }
            return (device.platform, version, posted)
        }
        known.reported = TargetRules.reportedPostings(reports)
        return known
    }

    /// The Blueprint’s rule for one device, and what it was read with.
    private func rule(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                      tracked: TrackedBlueprint, now: Date, known: PostingBasis)
        -> (rule: DeviceTarget, block: JamfPlatform.SoftwareUpdateBlock?, platform: AppleReleases.Platform, osName: String, os: String?) {
        let member = input.member
        let platform: AppleReleases.Platform = member.kind == .computer ? .macOS : .iOS
        let model = member.modelIdentifier ?? input.status?.modelIdentifier
        let osName = Classifier.osName(isComputer: member.kind == .computer, modelIdentifier: model ?? "")
        // the newer of what the device reports and its inventory: a device
        // that installed may not have sent a new status report yet
        let os = Classifier.newer(input.status?.osVersion, member.osVersion)
        let block = Self.block(for: osName, in: blocks)
        let rule = TargetRules.target(
            os: os, model: model, boardID: input.status?.deviceID, osName: osName,
            context: TargetRules.Context(block: block, catalog: catalog, platform: platform,
                                         blueprintChanged: blueprint.overview.updatedDate, updateStarted: tracked.updateStarted,
                                         now: now, known: known))
        return (rule, block, platform, osName, os)
    }

    /// One device against its own target.
    func classify(_ input: DeviceInput, blocks: [JamfPlatform.SoftwareUpdateBlock], blueprint: JamfPlatform.BlueprintDetail,
                  tracked: TrackedBlueprint, now: Date, known: PostingBasis? = nil, awaitingSync: Bool = false) -> DeviceStatus {
        let member = input.member
        let model = member.modelIdentifier ?? input.status?.modelIdentifier
        let known = known ?? PostingBasis(remembered: firstPosted)
        let (rule, block, platform, osName, os) = self.rule(input, blocks: blocks, blueprint: blueprint, tracked: tracked, now: now,
                                                            known: known)
        // what Jamf actually sent the device comes first, when it reports it
        let target = TargetRules.fromDevice(rule, status: input.status, os: os, osName: osName, catalog: catalog,
                                            platform: platform, serverTimeZone: serverTimeZone, model: model,
                                            boardID: input.status?.deviceID, blueprintChanged: blueprint.overview.updatedDate,
                                            earlierStepDeadline: { [catalog] version in
                                                TargetRules.ruleDeadline(for: version, block: block, catalog: catalog, platform: platform,
                                                                         model: model, boardID: input.status?.deviceID, known: known)
                                            },
                                            earlierStepWindow: { [catalog] version in
                                                TargetRules.ruleWindow(for: version, block: block, catalog: catalog, platform: platform,
                                                                       model: model, boardID: input.status?.deviceID, now: now, known: known)
                                            },
                                            awaitingSync: awaitingSync,
                                            postingDeadlines: { [catalog] version, build in
                                                TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                             platform: platform).map(\.deadline)
                                            },
                                            known: known,
                                            timeZone: member.timeZone, now: now)
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

    /// The Blueprint’s rule by its values, to compare refreshes: unlike its
    /// text, it doesn’t change with this Mac’s region or clock format.
    static func ruleKey(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String {
        let keys = blocks.map { block -> String in
            switch block.enforcement {
            case .specific(let version, let deadline, _): "specific|\(version)|\(block.targetBuildVersion ?? "")|\(deadline ?? "")"
            case .latest(let days, let time): "latest|\(days ?? 0)|\(time ?? "")"
            case .semantic(let days, let time): "minor|\(days ?? 0)|\(time ?? "")"
            case .unknown(let kind): "unknown|\(kind ?? "")"
            }
        }
        return Array(NSOrderedSet(array: keys)).compactMap { $0 as? String }.joined(separator: ";")
    }

    /// The Blueprint’s rule in plain language; several blocks joined.
    static func rule(_ blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String {
        let rules = blocks.map { block -> String in
            switch block.enforcement {
            case .specific(let version, let deadline, _):
                "Version \(version)" + (deadline.map { " by \(TargetRules.readable($0))" } ?? "")
            case .latest(let days, _):
                (days ?? 0) == 0 ? "The newest release, without delay" : "The newest release, \(Plural.count(days ?? 0, "day")) after its release"
            case .semantic(let days, _):
                (days ?? 0) == 0 ? "Minor updates, without delay" : "Minor updates, \(Plural.count(days ?? 0, "day")) after their release"
            case .unknown:
                "A software update this app doesn’t read"
            }
        }
        return rules.isEmpty ? "No software update" : Array(NSOrderedSet(array: rules)).compactMap { $0 as? String }.joined(separator: "; ")
    }
}
