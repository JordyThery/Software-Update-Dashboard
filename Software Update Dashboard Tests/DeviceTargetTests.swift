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
    {"AssetSets":{"macOS":[
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
        {"AssetSets":{"macOS":[
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

    @Test("A Mac with a reported offset is grouped by it; rows without a zone are told apart by target")
    func zones() {
        func mac(_ id: String, target: String?, local: String, offset: Int?) -> DeviceStatus {
            var device = Sample.classify(Sample.mac(id), nil)
            device.targetVersion = target
            device.deadlineLocal = local
            device.deadlineOffset = offset
            device.deadlineDate = offset.flatMap { TimeZone(secondsFromGMT: $0) }
                .flatMap { JamfPlatform.SoftwareUpdateBlock.deadline(local, in: $0) }
            return device
        }
        let zones = DeadlineZones.zones(devices: [
            mac("1", target: "26.7.2", local: "2026-11-09T22:59:12", offset: 0),
            mac("2", target: "26.7.2", local: "2026-11-09T22:59:12", offset: 0),
            mac("3", target: "26.7.2", local: "2026-11-09T23:59:00", offset: nil),
            mac("4", target: "27.2", local: "2026-11-09T23:59:00", offset: nil),
        ])
        #expect(zones.count == 3)
        #expect(zones[0].label == "UTC+00:00 (from the device’s report)" && zones[0].deviceCount == 2)
        #expect(zones[0].deadline == Sample.date("2026-11-09T22:59:12"))
        let noZone = zones.filter { $0.zone == nil && $0.offset == nil }
        #expect(Set(noZone.compactMap(\.target)) == ["26.7.2", "27.2"])
        #expect(Set(zones.map(\.id)).count == 3)
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
        #expect(finding.detail == "None of Test Mac Updates’s 1 update declarations applies to macOS 26.7.1 (1 is for other versions or models)")
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
