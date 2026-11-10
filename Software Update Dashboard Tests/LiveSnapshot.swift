import Foundation
import JTKit
import JTKitLiveCheck
import Testing
@testable import Software_Update_Dashboard

// Development tool, not part of the app: one anonymized snapshot of the
// live tenant, for analysis outside Xcode. Runs only through
// Scripts/snapshot.sh (SUD_SNAPSHOT=1 adds it to the release check's live
// steps, as a partial run), never in ⌘U or a full release check.
//
// Read only: the allow-list's read-only production role, on the run's
// guarded network (GET and the sign-in only), through JTKit's readers, with
// the credentials the release check reads (decided by Jordy on 2026-11-10:
// its integration, not SUD's own, which has another client ID), and only
// when that role reaches the tenant of SUD's saved connection (same region
// and environment ID). For every tracked Blueprint of that
// connection it reads what a refresh reads, the raw status items and the
// declaration reports, plus Apple's release data, and adds SUD's own
// result per device. Everything is anonymized (SnapshotAnonymizer) before
// the one file is written to the app's temporary folder; the script moves
// it out of the container. The report holds counts only.

private let snapshotRole = "jamfpro-production"
private let snapshotRequested = LiveCheckRun.isEnabled && ProcessInfo.processInfo.environment["SUD_SNAPSHOT"] == "1"

@Suite("Live: an anonymized snapshot", .enabled(if: snapshotRequested), .serialized)
@MainActor
struct LiveSnapshot {
    /// Where the script picks the file up (inside the app's container).
    static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "SUDSnapshots", directoryHint: .isDirectory) }

    @Test func takeSnapshot() async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(snapshotRole) else {
            run.record(step: "snapshot", passed: false, note: "the production role isn't in this run (--include-production)")
            Issue.record("no production role")
            return
        }
        let keyText = try #require(ProcessInfo.processInfo.environment["SUD_SNAPSHOT_KEY"], "no snapshot key")
        let key = try #require(Self.data(hex: keyText), "the snapshot key isn't hex")
        let anonymizer = SnapshotAnonymizer(key: key)

        // the role must reach the tenant of SUD's saved connection; its tracked Blueprints come from SUD's saved list
        let entry = try run.entry(role: snapshotRole, service: .jamfPlatform)
        let clientID = try run.credential(snapshotRole, "client-id")
        let saved = try Self.savedSUD()
        guard let record = saved.connections.first(where: { record in
            record.connection.service == .jamfPlatform
                && record.connection.environmentID.lowercased() == (entry.environmentID ?? "").lowercased()
                && record.connection.region.rawValue == entry.region
        }) else {
            // which fields differ, never their values
            let compared = saved.connections.map { record in
                "service \(record.connection.service == .jamfPlatform ? "same" : "differs"), "
                    + "environment \(record.connection.environmentID.lowercased() == (entry.environmentID ?? "").lowercased() ? "same" : "differs"), "
                    + "region \(record.connection.region.rawValue == entry.region ? "same" : "differs")"
            }
            run.record(step: "snapshot: SUD's saved connection", passed: false,
                       note: "none of SUD's \(saved.connections.count) saved connections is on the production role's tenant: nothing read ("
                           + compared.joined(separator: "; ") + ")")
            Issue.record("no matching saved connection")
            return
        }
        // the organisation's name, from the role's Jamf Pro host names on the allow-list (read at run time only)
        if let pro = try? run.entry(role: snapshotRole, service: .jamfPro) {
            anonymizer.organisation(fromHosts: [pro.host].compactMap { $0 } + (pro.aliases ?? []))
        }
        let tracked = saved.tracked.filter { $0.connectionID == record.id }
        run.record(step: "snapshot: SUD's saved connection", passed: !tracked.isEmpty,
                   note: "the production role reaches the tenant of SUD's saved connection; \(tracked.count) tracked Blueprints")
        guard !tracked.isEmpty else { return }
        run.neverReport(tracked.flatMap { [$0.blueprintID, $0.blueprintName] })

        let connection = Connection(name: "Snapshot", service: .jamfPlatform, region: record.connection.region,
                                    environmentID: record.connection.environmentID, clientID: clientID)
        let secret = try run.credential(snapshotRole, "client-secret")
        let recorder = RequestRecorder(session: run.network.session, log: nil, category: "Snapshot")
        let client = try JamfPlatform.Client(connection: connection, secret: { secret }, recorder: recorder,
                                             permits: ConnectionsModel.permits)
        let catalog = try await AppleReleases.Client(recorder: recorder, userAgent: "Software Update Dashboard/snapshot").catalog()
        let platformDevices = try await client.devices()
        run.neverReport(platformDevices.flatMap { [$0.id, $0.serialNumber ?? ""] })
        var platformBySerial: [String: String] = [:]
        for device in platformDevices {
            if let serial = device.serialNumber?.uppercased(), !serial.isEmpty { platformBySerial[serial] = device.id }
        }

        // names as labels: Blueprint A, B, …; Group 1, 2, … (in the order of their stable tokens)
        let blueprintLabels = Dictionary(uniqueKeysWithValues: tracked
            .map { ($0.blueprintID, anonymizer.token($0.blueprintID, kind: "ID") ?? "") }
            .sorted { $0.1 < $1.1 }.enumerated()
            .map { ($0.element.0, "Blueprint \(Self.letters($0.offset))") })
        var groupLabels: [String: String] = [:]

        var blueprints: [[String: Any]] = []
        var deviceCount = 0
        let now = Date()
        for item in tracked {
            let label = blueprintLabels[item.blueprintID] ?? "Blueprint"
            let result = try await RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: record.timeZone).run(item, now: now)
            run.neverReport(LiveReadTests.identifiers(result.members) + result.scope.flatMap { [$0.group.groupID, $0.name] })
            anonymizer.alias(result.blueprintName, as: label)
            anonymizer.alias(item.blueprintName, as: label)
            for group in result.scope.sorted(by: { (anonymizer.token($0.id.description, kind: "Group") ?? "")
                                                    < (anonymizer.token($1.id.description, kind: "Group") ?? "") })
            where groupLabels[group.id.description] == nil {
                groupLabels[group.id.description] = "Group \(groupLabels.count + 1)"
                anonymizer.alias(group.name, as: groupLabels[group.id.description] ?? "Group")
            }
            // every identifier first, so free text anywhere can replace it
            for member in result.members { Self.register(member, platformID: member.serialNumber.flatMap { platformBySerial[$0.uppercased()] }, anonymizer) }

            // the raw status items, as Inspect reads them, and the declaration reports of this Blueprint
            let raw = try await Self.statusItems(result.members, client: client)
            let statuses = result.members.map { raw[RefreshWorkflow.key($0)].map(JamfPro.SoftwareUpdateStatus.init(items:)) }
            let identifiers = BlueprintHealth.identifiers(blueprintID: item.blueprintID, statuses: statuses, blocks: result.blocks)
            var reports: [JamfPlatform.DeclarationReport] = []
            for identifier in identifiers {
                reports += try await client.declarationReports(declarationIdentifier: identifier) ?? []
            }
            let rows = Dictionary(result.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var devices: [[String: Any]] = []
            for member in result.members {
                let key = RefreshWorkflow.key(member)
                let platformID = member.serialNumber.flatMap { platformBySerial[$0.uppercased()] }
                var device = Self.inventory(member, anonymizer)
                device["statusItems"] = (raw[key] ?? []).map { item -> [String: Any] in
                    var out: [String: Any] = ["key": item.key]
                    out["value"] = anonymizer.scrub(item.value)
                    out["lastUpdateTime"] = item.lastUpdateTime
                    out["valueKind"] = item.valueKind.map { String(describing: $0) }
                    return out
                }
                device["declarationReports"] = reports.filter { platformID != nil && $0.deviceID?.lowercased() == platformID?.lowercased() }
                    .map { Self.report($0, anonymizer) }
                device["sud"] = rows[key].map { Self.sud($0, anonymizer) }
                devices.append(device)
            }
            deviceCount += devices.count
            blueprints.append([
                "name": label,
                "id": anonymizer.token(item.blueprintID, kind: "ID") ?? "",
                "changed": Self.iso(result.blueprintChanged) as Any,
                "rule": anonymizer.scrub(result.rule) as Any,
                "ruleKey": result.ruleKey as Any,
                "updateStartedByHand": Self.iso(item.updateStarted) as Any,
                "blocks": result.blocks.map { block in
                    ["step": block.stepIndex, "component": block.componentIndex, "stepName": anonymizer.scrub(block.stepName) as Any,
                     "activationPredicate": anonymizer.scrub(block.activationPredicate) as Any,
                     "enforcement": anonymizer.scrub(String(describing: block.enforcement)) as Any,
                     "targetBuildVersion": block.targetBuildVersion as Any,
                     "source": anonymizer.scrub(String(describing: block.source)) as Any] as [String: Any]
                },
                "settings": result.settings.map { anonymizer.scrub(String(describing: $0)) ?? "" },
                "scope": result.scope.map { group in
                    ["name": groupLabels[group.id.description] ?? "Group", "id": anonymizer.token(group.id.description, kind: "Group") ?? "",
                     "kind": group.group.kind.rawValue, "smart": group.group.isSmart] as [String: Any]
                },
                "unmatchedScopeGroups": result.unmatchedScope,
                "problems": result.problems.map { anonymizer.scrub($0) ?? "" },
                "counts": Dictionary(uniqueKeysWithValues: StatusCategory.allCases.map { ($0.rawValue, result.counts[$0]) }),
                "pastDeadline": result.pastDeadline,
                "deadlineZones": result.zones.map { zone in
                    ["zone": zone.zone as Any, "localDeadline": zone.localDeadline, "reported": Self.iso(zone.reported) as Any,
                     "target": zone.target as Any, "devices": zone.deviceCount, "deadline": Self.iso(zone.deadline) as Any,
                     "unusual": zone.unusual as Any] as [String: Any]
                },
                "hardwareToReplace": result.replacements.map {
                    ["modelIdentifier": $0.modelIdentifier, "model": $0.model, "devices": $0.deviceCount,
                     "lastSupportedVersion": $0.lastSupportedVersion as Any, "note": $0.note] as [String: Any]
                },
                "declarationIdentifiers": identifiers.map { anonymizer.scrub($0) ?? "" },
                "devices": devices,
            ])
        }

        let snapshot: [String: Any] = [
            "snapshot": ["taken": Self.iso(now) as Any, "anonymized": true, "tool": "Software Update Dashboard snapshot (0.3)",
                         "serverTimeZone": record.serverTimeZone, "blueprints": blueprints.count, "devices": deviceCount],
            "appleReleases": catalog.releases.map(Self.release),
            "appleReleaseProblems": catalog.problems.map { anonymizer.scrub($0) ?? "" },
            "blueprints": blueprints,
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)

        // nothing it replaced may be left in the file
        // nothing it replaced may be left in the file; a device name only where it isn't a model's name too ("MacBook Air")
        let models = blueprints.flatMap { ($0["devices"] as? [[String: Any]] ?? []).compactMap { $0["model"] as? String } }
        let leaks = anonymizer.leaks(in: text, allowingNamesIn: Array(Set(models)))
        run.record(step: "snapshot: anonymized", passed: leaks.isEmpty,
                   note: leaks.isEmpty ? "no replaced value is left in the file"
                       : "\(leaks.count) replaced values still in the file: not written ("
                           + leaks.map { "\(anonymizer.kinds[$0] ?? "Name") in \(SnapshotAnonymizer.field(of: $0, in: text))" }.joined(separator: ", ") + ")")
        guard leaks.isEmpty else {
            Issue.record("identifiers left in the snapshot")
            return
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var style = Date.ISO8601FormatStyle(timeZone: .current)
        style = style.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted)
        let file = Self.folder.appending(path: "SUD snapshot \(now.formatted(style)).json")
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        run.record(step: "snapshot: written", passed: true,
                   note: "\(file.lastPathComponent): \(blueprints.count) Blueprints, \(deviceCount) devices, \(catalog.releases.count) Apple releases")
        #expect(run.network.refusals.isEmpty)
    }

    // MARK: Reading

    /// SUD's saved connections and tracked Blueprints, read (never written)
    /// from the app's own settings file in its container, through a
    /// throwaway copy.
    static func savedSUD() throws -> (connections: [AppConnection], tracked: [TrackedBlueprint]) {
        let file = URL(filePath: NSHomeDirectory()).appending(path: "Library/Preferences/be.jordythery.softwareupdatedashboard.plist")
        let data = try Data(contentsOf: file)
        let values = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let copy = TestFiles.defaults("snapshot")
        for key in [ConnectionsModel.connectionsKey, TrackedBlueprintList.key, "trackedGroups"] {
            if let value = values[key] { copy.set(value, forKey: key) }
        }
        let connections = try UserDefaultsConnectionStorage<AppConnection>(key: ConnectionsModel.connectionsKey, defaults: copy).load()
        return (connections, TrackedBlueprintList.read(from: copy).list)
    }

    /// Every member's raw status items, a few at a time; none for a device without a report.
    static func statusItems(_ members: [JamfPro.GroupMember], client: JamfPlatform.Client) async throws -> [String: [JamfPro.StatusItem]] {
        var found: [String: [JamfPro.StatusItem]] = [:]
        try await withThrowingTaskGroup(of: (String, [JamfPro.StatusItem]?).self) { group in
            var next = 0
            func start() {
                guard next < members.count else { return }
                let member = members[next]
                next += 1
                group.addTask {
                    guard let managementID = member.managementID, !managementID.isEmpty else { return (RefreshWorkflow.key(member), nil) }
                    return (RefreshWorkflow.key(member), try await client.statusItems(managementID: managementID, kind: member.kind))
                }
            }
            for _ in 0..<4 { start() }
            while let (key, items) = try await group.next() {
                if let items { found[key] = items }
                start()
            }
        }
        return found
    }

    // MARK: Anonymized records

    static func register(_ member: JamfPro.GroupMember, platformID: String?, _ anonymizer: SnapshotAnonymizer) {
        _ = anonymizer.token(member.serialNumber, kind: "Serial")
        _ = anonymizer.token(member.name, kind: "Name")
        _ = anonymizer.token(member.udid, kind: "ID")
        _ = anonymizer.token(member.managementID, kind: "ID")
        _ = anonymizer.token(platformID, kind: "ID")
        _ = anonymizer.token(member.building, kind: "Place")
        _ = anonymizer.token(member.department, kind: "Place")
    }

    static func deviceToken(_ member: JamfPro.GroupMember, _ anonymizer: SnapshotAnonymizer) -> String {
        // not remembered for free text: there the serial stays a Serial token
        anonymizer.token(member.serialNumber ?? member.managementID ?? RefreshWorkflow.key(member), kind: "Device", remember: false) ?? "Device"
    }

    static func inventory(_ member: JamfPro.GroupMember, _ anonymizer: SnapshotAnonymizer) -> [String: Any] {
        var out: [String: Any] = [
            "device": deviceToken(member, anonymizer),
            "kind": member.kind.rawValue,
            "jamfProID": anonymizer.token("\(member.kind.rawValue)/\(member.id)", kind: "JamfID", remember: false) as Any,
            "serial": anonymizer.token(member.serialNumber, kind: "Serial") as Any,
            "name": anonymizer.token(member.name, kind: "Name") as Any,
            "managementID": anonymizer.token(member.managementID, kind: "ID") as Any,
        ]
        let kept: [String: Any?] = [
            "model": member.model, "modelIdentifier": member.modelIdentifier, "osVersion": member.osVersion, "osBuild": member.osBuild,
            "osSupplementalBuild": member.osSupplementalBuild, "osRapidSecurityResponse": member.osRapidSecurityResponse,
            "timeZone": member.timeZone, "lastContact": iso(member.lastContact), "lastInventoryUpdate": iso(member.lastInventoryUpdate),
            "managed": member.managed, "supervised": member.supervised, "ddmEnabled": member.ddmEnabled,
            "deviceOwnershipType": member.deviceOwnershipType, "appleEnrollmentType": member.appleEnrollmentType,
            "passcodePresent": member.passcodePresent, "batteryLevel": member.batteryLevel, "batteryHealth": member.batteryHealth,
            "availableSpaceMB": member.availableSpaceMB, "capacityMB": member.capacityMB, "roaming": member.roaming,
            "mdmProfileExpiration": iso(member.mdmProfileExpiration),
            "bootstrapTokenEscrowedStatus": member.bootstrapTokenEscrowedStatus, "bootstrapTokenAllowed": member.bootstrapTokenAllowed,
            "fileVault": member.diskEncryption?.bootPartitionFileVault2State,
            "building": anonymizer.token(member.building, kind: "Place"), "department": anonymizer.token(member.department, kind: "Place"),
        ]
        for (key, value) in kept { if let value { out[key] = value } }
        return out
    }

    static func report(_ report: JamfPlatform.DeclarationReport, _ anonymizer: SnapshotAnonymizer) -> [String: Any] {
        [
            "declaration": anonymizer.scrub(report.declarationIdentifier) as Any,
            "type": report.type as Any, "channel": report.channel as Any,
            "status": String(describing: report.status), "active": report.active as Any,
            "validity": String(describing: report.validity),
            "dateUpdated": iso(report.dateUpdated) as Any, "lastReportTime": iso(report.lastReportTime) as Any,
            "reasons": report.reasons.map { reason in
                ["code": reason.code as Any, "description": anonymizer.scrub(reason.description) as Any,
                 "details": reason.details.map { ["key": $0.key as Any, "description": anonymizer.scrub($0.description) as Any] }]
                    as [String: Any]
            },
        ]
    }

    static func sud(_ row: DeviceStatus, _ anonymizer: SnapshotAnonymizer) -> [String: Any] {
        let values: [String: Any?] = [
            "category": row.category.rawValue, "diagnosis": anonymizer.scrub(row.diagnosis),
            "target": row.targetVersion, "targetReason": anonymizer.scrub(row.targetReason), "targetSource": row.targetSource,
            "targetFromDevice": row.targetFromDevice, "ruleTarget": row.ruleTarget, "targetDiffersFromRule": row.targetDiffersFromRule,
            "limitedByHardware": row.limitedByHardware, "activityFrom": iso(row.activityFrom),
            "deadlineLocal": row.deadlineLocal, "deadline": iso(row.deadlineDate), "deadlineSource": row.deadlineSource,
            "pastDeadline": row.pastDeadline,
            "staleReportedDeadline": iso(row.staleReportedDeadline), "staleReportedLocal": row.staleReportedLocal,
            "earlierStep": row.earlierStepVersion, "earlierStepDeadline": iso(row.earlierStepDeadline),
            "earlierStepLocal": row.earlierStepLocal, "earlierStepLapsed": row.earlierStepLapsed,
            "keptDeadlineOfStep": row.carriedStepVersion, "keptDeadline": iso(row.carriedDeadline),
            "notCoveredBy": row.notCoveredBy, "notFetched": row.notFetched, "notFetchedSince": iso(row.notFetchedSince),
            "error": anonymizer.scrub(row.error), "errorTime": row.errorTime, "errorSinceUpdate": row.errorSinceUpdate,
            "statusProblem": anonymizer.scrub(row.statusProblem), "statusUpdated": iso(row.statusUpdated),
            "readiness": ReadinessCheck.allCases.filter { $0.applies(to: row) }.map(\.rawValue),
        ]
        return values.compactMapValues { $0 }
    }

    static func release(_ release: AppleReleases.Release) -> [String: Any] {
        [
            "platform": String(describing: release.platform), "version": release.version.description, "build": release.build as Any,
            "releaseDate": iso(release.releaseDate) as Any, "expirationDate": iso(release.expirationDate) as Any,
            "supportedDevices": release.supportedDevices.sorted(),
            "postings": release.postings.map { posting in
                ["build": posting.build as Any, "devices": posting.devices.sorted(), "date": iso(posting.date) as Any,
                 "public": posting.isPublic] as [String: Any]
            },
        ]
    }

    // MARK: Helpers

    static func iso(_ date: Date?) -> String? { date.map { $0.formatted(.iso8601) } }

    /// A, B, … Z, AA, AB, …
    static func letters(_ index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < 26 ? String(alphabet[index]) : letters(index / 26 - 1) + String(alphabet[index % 26])
    }

    static func data(hex: String) -> Data? {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 32, text.count % 2 == 0 else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
