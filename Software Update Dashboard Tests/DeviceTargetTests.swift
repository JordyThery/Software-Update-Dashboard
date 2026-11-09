import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// What Jamf sent a device first, Apple’s data as the fallback: Intel Macs,
/// pending versions, deadlines with an offset. Made-up data only.
@Suite("Targets from the device and Apple’s lists")
struct DeviceTargetTests {
    // as in Apple's own data: X86LEGACYAP is listed for an old major only,
    // J152FAP (a T2 Intel Mac) for 26; 26.6 has no device list
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
      {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"26.7.1","Build":"25G241","PostingDate":"2026-09-28","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"12.7.9","Build":"21H900","PostingDate":"2025-01-01","SupportedDevices":["X86LEGACYAP","J152FAP"]}]}}
    """#
    static let sofaMacOS = #"""
    {"OSVersions":[{"OSVersion":"Tahoe 26","Latest":{"ProductVersion":"26.7.2","Build":"25G332","ReleaseDate":"2026-10-26T00:00:00Z"},
      "SecurityReleases":[{"ProductVersion":"26.7.1","Build":"25G241","ReleaseDate":"2026-09-28T00:00:00Z"},
                          {"ProductVersion":"26.6","Build":"25F100","ReleaseDate":"2026-07-27T00:00:00Z"}]},
      {"OSVersion":"Golden Gate 27","Latest":{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J314sAP"]}}],
     "Models":{"MacBookPro16,1":{"MarketingName":"MacBook Pro (16-inch, 2019)","OSVersions":[26,15,12]},
               "MacBookPro18,3":{"OSVersions":[27,26]}},
     "Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))
    static let now = Sample.date("2026-11-09T12:00:00")
    static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59")

    static func rule(os: String, model: String, boardID: String?,
                     _ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement = minor) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: boardID, osName: "macOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: catalog, platform: .macOS,
            blueprintChanged: nil, updateStarted: nil, now: now))
    }

    @Test("An Intel T2 Mac gets its major’s newest release, reporting X86LEGACYAP or its board ID",
          arguments: ["X86LEGACYAP", "J152FAP"])
    func intelMac(boardID: String) {
        let target = Self.rule(os: "26.7.1", model: "MacBookPro16,1", boardID: boardID)
        #expect(target.version == "26.7.2")
        #expect(target.unknown == nil)
        // the replacement list uses the same rule
        let newest = TargetRules.newestRelease(Self.catalog, .macOS, model: "MacBookPro16,1", boardID: boardID, knownOnly: true)
        #expect(newest?.version.description == "26.7.2")
    }

    @Test("A device already on a release newer than the rule’s target is Target unknown, never lower")
    func runsNewer() {
        // 26.7.1 is 42 days old; the rule (only 26.6 for this "model") can't fit it
        let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(Self.sofaMacOS.utf8), gdmf: Data(#"""
        {"PublicAssetSets":{"macOS":[
          {"ProductVersion":"26.7.2","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]},
          {"ProductVersion":"26.7.1","PostingDate":"2026-09-28","SupportedDevices":["J314sAP"]}]}}
        """#.utf8))
        let target = TargetRules.target(os: "26.7.1", model: "OddMac1,1", boardID: "J152FAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(Self.minor), catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Self.now))
        // the device is unknown to these lists, so it gets the newest of its major
        #expect(target.version == "26.7.2")
        let picked = try! #require(catalog.release(OSVersion("26.6")!, .macOS))
        let unknown = TargetRules.runsNewer(OSVersion("26.7.1"), than: picked, catalog, .macOS, days: 14, now: Self.now, osName: "macOS")
        #expect(unknown?.unknown == .runsNewerRelease)
        // a version too new for the delay, or a beta, is just ahead
        #expect(TargetRules.runsNewer(OSVersion("27.2"), than: picked, catalog, .macOS, days: 30, now: Self.now, osName: "macOS") == nil)
        #expect(TargetRules.runsNewer(OSVersion("26.9"), than: picked, catalog, .macOS, days: 0, now: Self.now, osName: "macOS") == nil)
    }

    // MARK: The pending version

    static func status(pending: String, reason: String?, os: String = "26.7.1", time: String = "2026-11-02T08:00:00",
                       deadline: String = "2026-11-09 22:59:12 +0000") -> JamfPro.SoftwareUpdateStatus {
        var pairs = [("device.operating-system.version", os), ("softwareupdate.pending-version.os-version", pending),
                     ("softwareupdate.pending-version.build-version", "26C100"),
                     ("softwareupdate.pending-version.target-local-date-time", deadline)]
        if let reason { pairs.append(("softwareupdate.install-reason.reason", reason)) }
        return Sample.status(pairs, time: time)
    }

    static func fromDevice(_ status: JamfPro.SoftwareUpdateStatus, os: String = "26.7.1") -> DeviceTarget {
        let rule = Self.rule(os: os, model: "MacBookPro18,3", boardID: "J314sAP")
        return TargetRules.fromDevice(rule, status: status, os: os, osName: "macOS", catalog: catalog, platform: .macOS,
                                      serverTimeZone: Sample.utc)
    }

    @Test("A version pending from a declaration is the target; when the rule differs, both are kept and flagged")
    func pendingDiffers() {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration,system-settings"))
        #expect(target.fromDevice && target.version == "27.2")
        #expect(target.ruleVersion == "26.7.2" && target.differsFromRule)
        #expect(target.ruleReason?.contains("26.7.2") == true)
        #expect(target.deadlineOffset == 0)
        #expect(target.deadlineDate == Sample.date("2026-11-09T22:59:12"))
        #expect(target.deadlineLocal == "2026-11-09T22:59:12")
        // the same version as the rule: from the device, not flagged
        let same = Self.fromDevice(Self.status(pending: "26.7.2", reason: "declaration"))
        #expect(same.fromDevice && !same.differsFromRule)
    }

    @Test("A stale pending version, equal to or older than the installed one, is ignored", arguments: ["26.7.1", "26.6"])
    func stale(pending: String) {
        let target = Self.fromDevice(Self.status(pending: pending, reason: "declaration"))
        #expect(!target.fromDevice && target.version == "26.7.2")
    }

    @Test("A pending version for another reason, or none, is ignored", arguments: ["notification", "none", nil] as [String?])
    func otherReason(reason: String?) {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: reason))
        #expect(!target.fromDevice && target.version == "26.7.2")
    }

    @Test("A pending version reported before the update started is ignored")
    func beforeStart() {
        // the rule's target was released on 26 October
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration", time: "2026-10-20T08:00:00"))
        #expect(!target.fromDevice)
    }

    @Test("Classified against what Jamf sent, past its deadline by the reported moment")
    func classified() {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration"))
        let device = Sample.classify(Sample.mac(os: "26.7.1", model: "MacBookPro18,3"),
                                     Self.status(pending: "27.2", reason: "declaration"), target: target, now: "2026-11-10T08:00:00")
        #expect(device.targetVersion == "27.2" && device.targetFromDevice == true && device.targetDiffersFromRule == true)
        #expect(device.ruleTarget == "26.7.2")
        #expect(device.pastDeadline == true)
    }

    // MARK: Deadline per time zone

    @Test("A reported deadline is a moment, never a time zone; computed ones stay in local time, told apart by target")
    func zones() {
        func mac(_ id: String, target: String?, local: String, reported: String?) -> DeviceStatus {
            var device = Sample.classify(Sample.mac(id), nil)
            device.targetVersion = target
            device.deadlineLocal = local
            device.deadlineDate = reported.map(Sample.date)
            device.deadlineOffset = reported == nil ? nil : 0
            return device
        }
        let zones = DeadlineZones.zones(devices: [
            // written in UTC by the device: 22:59 UTC is 23:59 in Amsterdam
            mac("1", target: "27.2", local: "2026-11-19T22:59:06", reported: "2026-11-19T22:59:06"),
            mac("2", target: "27.2", local: "2026-11-19T22:59:09", reported: "2026-11-19T22:59:09"),
            mac("3", target: "27.2", local: "2026-11-09T22:59:06", reported: "2026-11-09T22:59:06"),
            mac("4", target: "26.7.2", local: "2026-11-09T23:59:00", reported: nil),
            mac("5", target: "27.2", local: "2026-11-09T23:59:00", reported: nil),
        ])
        #expect(zones.count == 4)
        #expect(zones.allSatisfy { !$0.label.contains("UTC") })
        let reported = zones.filter { $0.reported != nil }
        #expect(reported.map(\.deviceCount).sorted() == [1, 2])
        #expect(reported.allSatisfy { $0.unusual == nil && $0.deadline == $0.reported })
        let computed = zones.filter { $0.reported == nil }
        #expect(Set(computed.compactMap(\.target)) == ["26.7.2", "27.2"])
        #expect(computed.allSatisfy { $0.unusual?.hasPrefix("Jamf Pro has no time zone for Macs") == true })

        // shown the same way everywhere
        let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
        let text = DeadlineZones.text(local: "2026-11-19T22:59:06", reported: Sample.date("2026-11-19T22:59:06"), timeZone: amsterdam)
        #expect(text?.hasSuffix(", reported by the device") == true)
        #expect(text?.contains("23:59") == true)
        #expect(DeadlineZones.text(local: "2026-11-09T23:59:00", reported: nil)?.hasSuffix(", device local time") == true)

        // the macOS 27 row: each distinct deadline once (to the minute)
        let row = MajorRow.deadlines([mac("1", target: "27.2", local: "", reported: "2026-11-19T22:59:06"),
                                      mac("2", target: "27.2", local: "", reported: "2026-11-19T22:59:09"),
                                      mac("3", target: "27.2", local: "", reported: "2026-11-09T22:59:06"),
                                      mac("5", target: "27.2", local: "2026-11-09T23:59:00", reported: nil)])
        #expect(row.count == 3)
        #expect(row.filter { $0.hasSuffix("reported by the device") }.count == 2)
    }

    @Test("Where the target comes from, in plain words")
    func source() {
        #expect(Self.fromDevice(Self.status(pending: "26.7.2", reason: "declaration")).source == "26.7.2, sent by Jamf, matches the Blueprint’s rule")
        #expect(Self.fromDevice(Self.status(pending: "27.2", reason: "declaration")).source == "27.2, sent by Jamf; the Blueprint’s rule gives 26.7.2")
        #expect(Self.rule(os: "26.7.1", model: "MacBookPro18,3", boardID: "J314sAP").source == "26.7.2, from Apple’s data and the Blueprint’s rule")
        #expect(Self.rule(os: "26.7.1", model: "MacBookPro18,3", boardID: nil,
                          .specific(targetOSVersion: "27.2", targetLocalDateTime: nil, detailsURL: nil)).source
                == "27.2, the version the Blueprint names")
    }

    @Test("A Mac that can’t run the newest major stays on the list to replace, with the target Jamf sent")
    func replacement() {
        let rule = Self.rule(os: "26.7.1", model: "MacBookPro16,1", boardID: "X86LEGACYAP")
        #expect(rule.limitedByHardware)
        #expect(TargetRules.cannotRunNewestMajor(Self.catalog, .macOS, model: "MacBookPro16,1", boardID: "X86LEGACYAP"))
        let sent = TargetRules.fromDevice(rule, status: Self.status(pending: "26.7.2", reason: "declaration"), os: "26.7.1",
                                          osName: "macOS", catalog: Self.catalog, platform: .macOS, serverTimeZone: Sample.utc)
        #expect(sent.fromDevice && sent.limitedByHardware)
        var device = Sample.classify(Sample.mac(os: "26.7.1", model: "MacBookPro16,1"), nil, target: sent)
        device.boardID = "X86LEGACYAP"
        let list = Replacement.list([device]) { device in
            TargetRules.newestRelease(Self.catalog, .macOS, model: device.modelIdentifier, boardID: device.boardID, knownOnly: true)?
                .version.description
        }
        #expect(list.map(\.modelIdentifier) == ["MacBookPro16,1"])
        #expect(list.first?.lastSupportedVersion == "26.7.2")
        #expect(list.first?.note.contains("26.7.2") == true)
    }
}

@Suite("Inspect: update declarations by pair, readable, bootstrap token")
struct InspectDeclarationPairTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func report(_ kind: String, _ number: Int, active: Bool, status: String = "SUCCESSFUL",
                reasons: [JamfPlatform.DeclarationReport.Reason] = []) -> JamfPlatform.DeclarationReport {
        JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_\(kind)\(number)",
                                       type: kind == "act" ? "ACTIVATION" : "CONFIGURATION", status: .init(status), active: active,
                                       validity: kind == "act" ? .valid : .unknown, reasons: reasons)
    }

    func notForThisDevice(_ number: Int, range: String) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "\#(range)""#
        return [
            report("act", number, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                code: "Info.Predicate", description: "Activation’s predicate evaluated to false.",
                details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)"),
                          .init(key: "Predicate", description: predicate)])]),
            report("cfg", number, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                code: "Error.ActivationFailed",
                description: "Activation “Blueprint_\(blueprint)_s1_c1_sys_act\(number):9f86d081884c7d659a2feaa0c55ad015” has errors.",
                details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)"),
                          .init(key: "ServerToken", description: "9f86d081884c7d659a2feaa0c55ad015")])]),
        ]
    }

    func evaluate(_ reports: [JamfPlatform.DeclarationReport], member: JamfPro.GroupMember = Sample.mac(os: "26.7.1"),
                  status: JamfPro.SoftwareUpdateStatus? = nil) -> InspectResult {
        let row = Sample.classify(member, status).with(category: .notStarted, diagnosis: "Online, update not started (no error)")
        return InspectFindings.evaluate(InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: reports),
                                        context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates",
                                                                target: OSVersion("26.7.2"), since: Sample.updateStarted, now: Sample.now,
                                                                serverTimeZone: Sample.utc))
    }

    @Test("Declarations for other versions are not for this device, not failures")
    func predicateIsNotAFailure() {
        let reports = notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$") + notForThisDevice(2, range: "^(15[.][0-9]([.][0-9]+)*)$")
            + [report("act", 12, active: true), report("cfg", 12, active: true)]
        let result = evaluate(reports)
        #expect(!result.findings.contains { $0.cause.hasPrefix("Update declaration") || $0.cause.hasPrefix("No update declaration") })
    }

    @Test("Every other Error.* is a failure, named by Blueprint and versions, without IDs or hashes")
    func otherErrorsFail() throws {
        var reports = notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$")
        reports += [report("act", 3, active: true),
                    report("cfg", 3, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                        code: "Error.ConfigurationCannotBeApplied", description: "Can’t apply",
                        details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_cfg3"),
                                  .init(key: "Error", description: "Update to 26.7.2 isn’t possible")])])]
        let result = evaluate(reports)
        let failure = try #require(result.findings.first { $0.cause == "Update declaration failed" })
        #expect(failure.detail.hasPrefix("Test Mac Updates, macOS 26 (applies to this device): Error.ConfigurationCannotBeApplied"))
        #expect(failure.detail.contains("Update to 26.7.2 isn’t possible"))
        let all = result.findings.map { "\($0.cause) \($0.detail)" }.joined(separator: " ")
        #expect(!all.contains(blueprint) && !all.contains("9f86d081"))
    }

    @Test("Nothing applies: said once, with how many are for other versions")
    func noneApplies() throws {
        let result = evaluate(notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$"))
        let finding = try #require(result.findings.first { $0.cause == "No update declaration applies" })
        #expect(finding.detail == "None of Test Mac Updates’s 1 update declarations applies to macOS 26.7.1 (1 is for other versions or models). "
                + "No declaration lists Mac14,2, so the Blueprint doesn’t cover this hardware.")
    }

    @Test("A predicate’s versions read as a range", arguments: [
        (#"x MATCHES "^(27[.][0-1]([.][0-9]+)*)$""#, "27.0–27.1"),
        (#"x MATCHES "^(18[.][0-6]([.][0-9]+)*|18[.]7([.][0-7]([.][0-9]+)*)?)$""#, "18.0–18.7"),
        (#"x MATCHES "^(26[.]7([.][0-9]+)*)$""#, "26.7"),
    ])
    func ranges(predicate: String, range: String) {
        #expect(DeclarationPair.versionRange(predicate) == range)
    }

    @Test("A last error that names the bootstrap token makes it the likely cause")
    func bootstrapCause() {
        var mac = Sample.mac(os: "26.7.1")
        mac.bootstrapTokenEscrowedStatus = "NOT_ESCROWED"
        let status = Sample.status([("device.operating-system.version", "26.7.1"),
                                    ("softwareupdate.failure-reason.reason", "Bootstrap token is required to authorize the update"),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-05T09:00:00")])
        let result = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: mac, status: status)
        #expect(result.cause == "Bootstrap token")
        #expect(result.detail.contains("not escrowed"))
        // without such an error, a missing token is listed but not first
        mac.supervised = true
        let quiet = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: mac)
        #expect(quiet.findings.contains { $0.cause == "Bootstrap token not escrowed" })
    }
}

@Suite("Inspect: stuck updates and stale declaration reports")
struct InspectStaleAndStuckTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func evaluate(_ member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus?, row: DeviceStatus,
                  reports: [JamfPlatform.DeclarationReport] = [], changed: Date? = nil) -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: reports),
                                 context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates", target: nil,
                                                         since: nil, blueprintChanged: changed, now: Sample.now, serverTimeZone: Sample.utc))
    }

    func prepared() -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                       ("softwareupdate.pending-version.os-version", "26.7.2")], time: "2026-11-01T06:00:00")
    }

    @Test("Prepared before the deadline installs at the deadline; after it, it is stuck")
    func stuck() {
        var row = Sample.classify(Sample.mac(os: "26.7.1"), prepared())
        row.pastDeadline = false
        let before = evaluate(Sample.mac(os: "26.7.1"), status: prepared(), row: row)
        #expect(before.findings.contains { $0.cause == "Update downloaded" && $0.detail.hasSuffix("installs at the deadline") })
        #expect(!before.findings.contains { $0.cause == "Update stuck" })
        row.pastDeadline = true
        let after = evaluate(Sample.mac(os: "26.7.1"), status: prepared(), row: row)
        let stuck = after.findings.first { $0.cause == "Update stuck" }
        #expect(stuck?.detail.contains("not installed after its deadline (last change 4 days ago)") == true)
    }

    @Test("An offline device is never stuck")
    func offline() {
        let member = Sample.mac(os: "26.7.1")
        var row = Sample.classify(member, prepared())
        row.pastDeadline = true
        row.category = .offline
        #expect(!evaluate(member, status: prepared(), row: row).findings.contains { $0.cause == "Update stuck" })
    }

    @Test("Up to 48 hours in hours, longer in days")
    func durations() {
        #expect(InspectFindings.ago(Sample.now.addingTimeInterval(-47 * 3_600), now: Sample.now) == "47 h ago")
        #expect(InspectFindings.ago(Sample.now.addingTimeInterval(-50 * 3_600), now: Sample.now) == "2 days ago")
    }

    func pair(_ number: Int, versions: String, lists: [String], reported: String) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.version MATCHES "\#(versions)" AND status.softwareupdate.device-id IN {\#(lists.map { "\"\($0)\"" }.joined(separator: ", "))}"#
        let at = Sample.date(reported)
        return [
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)", type: "ACTIVATION",
                                           status: .unsuccessful, active: false, validity: .valid,
                                           reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])],
                                           lastReportTime: at),
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_cfg\(number)", type: "CONFIGURATION",
                                           status: .unsuccessful, active: false, reasons: [.init(code: "Error.ActivationFailed")],
                                           lastReportTime: at),
        ]
    }

    @Test("A declaration report from before the update started is the likely cause, not “doesn’t apply”")
    func stale() {
        let member = Sample.mac(os: "15.8.1", model: "MacBookAir10,1")
        let status = Sample.status([("device.operating-system.version", "15.8.1"), ("softwareupdate.device-id", "J313AP")])
        var row = Sample.classify(member, status)
        row.activityFrom = Sample.date("2026-10-26T00:00:00")
        let reports = pair(14, versions: "^(15[.][0-8]([.][0-9]+)*)$", lists: ["J313AP"], reported: "2026-10-14T19:08:00")
        let result = evaluate(member, status: status, row: row, reports: reports)
        #expect(result.cause == "Not evaluated since the update started")
        #expect(result.detail.contains("2026-10-14") && result.detail.contains("2026-10-26"))
        #expect(!result.findings.contains { $0.cause == "No update declaration applies" })
        // the Blueprint's last change counts too
        row.activityFrom = Sample.date("2026-10-01T00:00:00")
        #expect(evaluate(member, status: status, row: row, reports: reports, changed: Sample.date("2026-10-20T00:00:00")).cause
                == "Not evaluated since the update started")
    }

    @Test("A current report that excludes the device says so, checking its own device ID")
    func current() throws {
        let member = Sample.mac(os: "15.8.2", model: "MacBookAir10,1")
        let status = Sample.status([("device.operating-system.version", "15.8.2"), ("softwareupdate.device-id", "J313AP")])
        var row = Sample.classify(member, status)
        row.activityFrom = Sample.date("2026-10-26T00:00:00")
        let reports = pair(14, versions: "^(15[.][0-8]([.][0-1])?)$", lists: ["J313AP", "J274AP"], reported: "2026-11-05T09:00:00")
            + pair(2, versions: "^(26[.][0-7]([.][0-9]+)*)$", lists: ["J414sAP"], reported: "2026-11-05T09:00:00")
        let finding = try #require(evaluate(member, status: status, row: row, reports: reports).findings
            .first { $0.cause == "No update declaration applies" })
        #expect(finding.detail.contains("1 list J313AP (Test Mac Updates, macOS 15.0–15.8)"))
        let none = pair(2, versions: "^(26[.][0-7]([.][0-9]+)*)$", lists: ["J414sAP"], reported: "2026-11-05T09:00:00")
        let other = try #require(evaluate(member, status: status, row: row, reports: none).findings
            .first { $0.cause == "No update declaration applies" })
        #expect(other.detail.hasSuffix("No declaration lists J313AP, so the Blueprint doesn’t cover this hardware."))
    }

    @Test("The older predicate form reads too")
    func olderPredicate() {
        #expect(DeclarationPair.versionRange(#"x version < "27.0.1" AND x version BEGINSWITH "27." AND y"#) == "27 below 27.0.1")
    }
}

@Suite("Deadlines from Apple’s posting date")
struct PostingDeadlineTests {
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J314sAP","J413AP"]}],
     "iOS":[{"ProductVersion":"27.1","Build":"24B100","PostingDate":"2026-11-02","SupportedDevices":["iPad14,8"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-10-26","SupportedDevices":["J314sAP","J413AP"]},
       {"ProductVersion":"27.0.1","Build":"26A434","PostingDate":"2026-09-28","SupportedDevices":["J314sAP","J413AP"]}]}}
    """#
    static let sofaMacOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2","Build":"26B8125","ReleaseDate":"2026-10-26T00:00:00Z"}}],
     "Models":{"MacBookPro18,3":{"OSVersions":[27]}},"Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let sofaIOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.1","Build":"24B100","ReleaseDate":"2026-10-20T00:00:00Z"}}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofaIOS.utf8), sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))
    static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59")

    static func rule(os: String, now: String = "2026-11-09T12:00:00", platform: AppleReleases.Platform = .macOS,
                     model: String = "MacBookPro18,3", boardID: String? = "J314sAP",
                     _ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement = minor) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: boardID, osName: platform == .macOS ? "macOS" : "iPadOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: catalog, platform: platform, blueprintChanged: nil,
            updateStarted: nil, now: Sample.date(now)))
    }

    @Test("Posted to the public catalog later than released: the deadline counts from the posting, reports from the release")
    func laterPosting() {
        let target = Self.rule(os: "27.0.1")
        #expect(target.version == "27.2")
        #expect(target.build == "26B123")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00")
        #expect(target.deadlineSource == .postingDate)
        #expect(target.activityFrom == Sample.date("2026-10-26T00:00:00"))
        #expect(target.reason == "The newest public macOS 27 release: 27.2; installs by 19 Nov")
        // the live case: on 6 Nov, the day after Apple's public posting, 27.2 is already the target, due 19 Nov
        let dayAfter = Self.rule(os: "27.0.1", now: "2026-11-06T09:00:00")
        #expect(dayAfter.version == "27.2" && dayAfter.deadlineLocal == "2026-11-19T23:59:00")
        // on 4 Nov, before the posting, it isn't
        #expect(Self.rule(os: "27.0.1", now: "2026-11-04T09:00:00").version == "27.0.1")
        // every platform
        let iPad = Self.rule(os: "27.0", platform: .iOS, model: "iPad14,8", boardID: nil)
        #expect(iPad.deadlineLocal == "2026-11-16T23:59:00" && iPad.deadlineSource == .postingDate)
    }

    @Test("No posting date: the first release date, and the source says so")
    func noPosting() {
        let target = Self.rule(os: "27.0", now: "2026-10-20T12:00:00")
        #expect(target.version == "27.0.1")
        #expect(target.deadlineLocal == "2026-10-12T23:59:00")
        #expect(target.deadlineSource == .releaseDate)
        #expect(target.deadlineSource?.text == "from the release date, no posting date found")
    }

    static func pending(updated: String, deadline: String = "2026-11-09 22:59:06 +0000") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", "prepared"),
                       ("softwareupdate.pending-version.os-version", "27.2"),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: updated)
    }

    static func sent(_ status: JamfPro.SoftwareUpdateStatus, changed: Date? = nil) -> DeviceTarget {
        TargetRules.fromDevice(Self.rule(os: "27.0.1"), status: status, os: "27.0.1", osName: "macOS", catalog: Self.catalog,
                               platform: .macOS, serverTimeZone: Sample.utc, model: "MacBookPro18,3", boardID: "J314sAP",
                               blueprintChanged: changed)
    }

    @Test("A deadline from a current report wins; a specific version’s is the Blueprint’s")
    func currentReportWins() {
        // reported on 7 Nov: after the public posting (5 Nov) and the Blueprint's change (6 Nov)
        let target = Self.sent(Self.pending(updated: "2026-11-07T08:00:00", deadline: "2026-11-19 22:59:06 +0000"),
                               changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-19T22:59:06"))
        #expect(target.staleReportedDeadline == nil)
        let device = Sample.classify(Sample.mac(os: "27.0.1", model: "MacBookPro18,3"), Self.pending(updated: "2026-11-07T08:00:00"),
                                     target: target)
        #expect(device.deadlineSource == "reported by the device")
        let named = Self.rule(os: "27.0.1", .specific(targetOSVersion: "27.2", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil))
        #expect(named.deadlineSource == .blueprint)
        #expect(Sample.classify(Sample.mac(os: "27.0.1"), nil, target: Self.rule(os: "27.0.1")).deadlineSource == "from Apple’s posting date")
    }

    @Test("The live case: 9 Nov reported before a 6 Nov change, the rule gives 19 Nov: not late, not stuck")
    func staleReportLoses() throws {
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.fromDevice && target.version == "27.2")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate && target.deadlineDate == nil)
        #expect(target.staleReportedDeadline == Sample.date("2026-11-09T22:59:06"))
        #expect(target.staleSince == Sample.date("2026-11-06T09:00:00"))
        // on 10 Nov, after the stale 9 Nov but before 19 Nov
        let member = Sample.mac(os: "27.0.1", model: "MacBookPro18,3")
        let device = Sample.classify(member, status, target: target, now: "2026-11-10T08:00:00")
        #expect(device.pastDeadline == false)
        #expect(!device.diagnosis.contains("after the deadline"))
        #expect(device.staleReportedDeadline != nil)
        let inspected = InspectFindings.evaluate(
            InspectInput(member: member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.date("2026-11-10T08:00:00"), serverTimeZone: Sample.utc))
        #expect(!inspected.findings.contains { $0.cause == "Update stuck" })
        let finding = try #require(inspected.findings.first { $0.cause == "Declaration not refreshed since the Blueprint changed" })
        #expect(finding.detail.contains("2026-11-09") && finding.detail.contains("2026-11-06"))
        // the posting alone makes a report stale too
        #expect(Self.sent(status).staleReportedDeadline != nil)
    }

    @Test("A release becomes a target only once Apple offers it publicly, the basis its deadline counts from")
    func eligibility() {
        // 1 Nov, newest release 3 days old: 27.2 is first seen 26 Oct but only posted publicly on 5 Nov
        let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 3, deploymentTime: "23:59")
        let early = Self.rule(os: "27.0", now: "2026-11-01T12:00:00", latest)
        #expect(early.version == "27.0.1")
        #expect(Self.rule(os: "27.0", now: "2026-11-09T12:00:00", latest).version == "27.2")
        // GDMF lists a newer version only outside the public catalog: not offered yet
        let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(Self.sofaMacOS.utf8), gdmf: Data(#"""
        {"PublicAssetSets":{"macOS":[{"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J314sAP"]}]},
         "AssetSets":{"macOS":[{"ProductVersion":"27.3","Build":"26C100","PostingDate":"2026-11-01","SupportedDevices":["J314sAP"]},
                               {"ProductVersion":"27.0.1","Build":"26A434","PostingDate":"2026-09-28","SupportedDevices":["J314sAP"]}]}}
        """#.utf8))
        let release = { (text: String) in catalog.release(OSVersion(text)!, .macOS)! }
        #expect(!TargetRules.isOffered(release("27.3"), catalog, model: "MacBookPro18,3", boardID: "J314sAP"))
        #expect(TargetRules.isOffered(release("27.0.1"), catalog))
        #expect(TargetRules.isOffered(release("27.2"), catalog, model: "MacBookPro18,3", boardID: "J314sAP"))
        // a version newer than every public one is never the target, however old its first date
        let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
        let target = TargetRules.target(os: "27.0.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(minor), catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date("2026-11-20T12:00:00")))
        #expect(target.version == "27.2")
    }
}
