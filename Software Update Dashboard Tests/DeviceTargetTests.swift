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

    // MARK: Deadline per time zone

    @Test("A reported deadline is a moment, never a time zone; computed ones stay in local time, told apart by target")
    func zones() throws {
        func mac(_ id: String, target: String?, local: String, reported: String?) -> DeviceStatus {
            var device = Sample.classify(Sample.mac(id), nil)
            device.targetVersion = target
            device.deadlineLocal = local
            device.deadlineDate = reported.map(Sample.date)
            device.deadlineOffset = reported == nil ? nil : 0
            return device
        }
        let here = TimeZone(identifier: "Europe/Amsterdam")!
        let zones = DeadlineZones.zones(devices: [
            // written in UTC by the device: 22:59 UTC is 23:59 in Amsterdam
            mac("1", target: "27.2", local: "2026-11-19T22:59:06", reported: "2026-11-19T22:59:06"),
            mac("2", target: "27.2", local: "2026-11-19T22:59:09", reported: "2026-11-19T22:59:09"),
            mac("3", target: "27.2", local: "2026-11-09T22:59:06", reported: "2026-11-09T22:59:06"),
            mac("4", target: "26.7.2", local: "2026-11-09T23:59:00", reported: nil),
            // computed 23:59 in this Mac's zone is the moment Mac 3 reports: one row
            mac("5", target: "27.2", local: "2026-11-09T23:59:00", reported: nil),
            // 23:59 six hours west: the same deadline in another zone
            mac("6", target: "27.2", local: "2026-11-10T05:59:00", reported: "2026-11-10T05:59:00"),
        ], here: here)
        #expect(zones.count == 4)
        #expect(zones.allSatisfy { !$0.label.contains("UTC") && $0.reported != nil && $0.deadline == $0.reported })
        // to the minute: Mac 3 reports 22:59:06
        let same = try #require(zones.first { $0.target == "27.2"
            && abs(($0.reported ?? .distantPast).timeIntervalSince(Sample.date("2026-11-09T22:59:00"))) < 60 })
        #expect(same.deviceCount == 2 && same.unusual == DeadlineZones.macNote)
        let later = try #require(zones.first { $0.target == "27.2" && $0.deviceCount == 2 && $0 != same })
        // ten days off is another deadline, not another zone
        #expect(later.unusual == nil)
        let west = try #require(zones.first { $0.reported == Sample.date("2026-11-10T05:59:00") })
        #expect(west.unusual == "+7 h from most of the devices")
        #expect(zones.first { $0.target == "26.7.2" }?.unusual == DeadlineZones.macNote)

        // shown the same way everywhere
        let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
        let text = DeadlineZones.text(local: "2026-11-19T22:59:06", reported: Sample.date("2026-11-19T22:59:06"), timeZone: amsterdam)
        #expect(text?.hasSuffix(" (this Mac’s time)") == true)
        #expect(text?.contains("23:59") == true)
        #expect(DeadlineZones.text(local: "2026-11-09T23:59:00", reported: nil)?.hasSuffix(" (device’s local time)") == true)

        // the macOS 27 row: each distinct deadline once (to the minute)
        // the Blueprint's deadline once; a reported one that is it in some zone counts as it, the others apart
        let row = MajorRow.deadlineColumn([mac("1", target: "27.2", local: "", reported: "2026-11-19T22:59:06"),
                                           mac("2", target: "27.2", local: "", reported: "2026-11-19T22:59:09"),
                                           mac("3", target: "27.2", local: "", reported: "2026-11-09T22:59:06"),
                                           mac("5", target: "27.2", local: "2026-11-09T23:59:00", reported: nil)])
        #expect(row.shown.count == 1 && row.shown[0].hasSuffix("(device’s local time)"))
        #expect(row.others.count == 1 && row.otherDevices == 2)
        // only reported deadlines: those show
        #expect(MajorRow.deadlineColumn([mac("1", target: "27.2", local: "", reported: "2026-11-19T22:59:06")]).shown.count == 1)
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

    static func pending(updated: String, deadline: String = "2026-11-09 22:59:06 +0000", version: String = "27.2") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", "prepared"),
                       ("softwareupdate.pending-version.os-version", version),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: updated)
    }

    static func sent(_ status: JamfPro.SoftwareUpdateStatus, changed: Date? = nil, rule: DeviceTarget = rule(os: "27.0.1"),
                     serverTimeZone: TimeZone = Sample.utc) -> DeviceTarget {
        TargetRules.fromDevice(rule, status: status, os: "27.0.1", osName: "macOS", catalog: Self.catalog,
                               platform: .macOS, serverTimeZone: serverTimeZone, model: "MacBookPro18,3", boardID: "J314sAP",
                               blueprintChanged: changed)
    }

    static let named = rule(os: "27.0.1", .specific(targetOSVersion: "27.2", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil))
    static let member = Sample.mac(os: "27.0.1", model: "MacBookPro18,3")

    static func inspect(_ status: JamfPro.SoftwareUpdateStatus, _ device: DeviceStatus, now: String) -> InspectResult {
        InspectFindings.evaluate(
            InspectInput(member: member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.date(now), serverTimeZone: Sample.utc))
    }

}
