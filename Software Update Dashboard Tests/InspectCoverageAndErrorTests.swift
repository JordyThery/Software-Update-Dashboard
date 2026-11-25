import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// Inspect: ranges Jamf hasn’t extended, the device’s own OS family,
/// awaiting sync, and errors from before the update started. Made-up devices.
@Suite("Inspect: coverage, awaiting sync and earlier errors")
struct InspectCoverageAndErrorTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func pair(_ number: Int, family: String = "macOS", versions: String, lists: [String],
              status: JamfPlatform.DeclarationReport.Status = .unsuccessful) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.family == "\#(family)" AND status.device.operating-system.version MATCHES "\#(versions)" AND status.softwareupdate.device-id IN {\#(lists.map { "\"\($0)\"" }.joined(separator: ", "))}"#
        return [
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)", type: "ACTIVATION",
                                           status: status, active: false, validity: .valid,
                                           reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])],
                                           lastReportTime: Sample.date("2026-11-05T09:00:00")),
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_cfg\(number)", type: "CONFIGURATION",
                                           status: .unsuccessful, active: false, reasons: [.init(code: "Error.ActivationFailed")],
                                           lastReportTime: Sample.date("2026-11-05T09:00:00")),
        ]
    }

    func evaluate(_ member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus,
                  reports: [JamfPlatform.DeclarationReport]) -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: Sample.classify(member, status),
                                              platformDeviceID: "P-1", reports: reports),
                                 context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates", target: OSVersion("26.7.3"),
                                                         since: Sample.updateStarted, now: Sample.now, serverTimeZone: Sample.utc))
    }

    static let mac = Sample.mac(os: "26.7.2", model: "MacBookPro18,3")
    static let status = Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.device-id", "J314sAP")])
    // the form Jamf sends: 26.0 to 26.7.1
    static let below = "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$"

}

@Suite("History: rules by value and Apple’s releases")
struct HistoryMarkValueTests {
    static func device(target: String, fromDevice: Bool = false) -> DeviceStatus {
        var device = Sample.classify(Sample.mac(os: "27.0.1"), Sample.status([("device.operating-system.version", "27.0.1")]))
        device.targetVersion = target
        device.targetFromDevice = fromDevice ? true : nil
        return device
    }

    @Test("The same rule written another way (region, clock format) adds no mark; another rule does")
    func ruleByValue() {
        let block = TargetRulesTests.block(.specific(targetOSVersion: "27.2", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil))
        let key = RefreshWorkflow.ruleKey([block])
        #expect(key == "specific|27.2||2026-11-20T17:00:00")
        #expect(RefreshWorkflow.ruleKey([TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))])
                == "minor|14|23:59")
        let first = HistorySnapshot(date: Sample.date("2026-11-04T10:00:00"), target: "Version 27.2 by 20 Nov 2026 at 17:00",
                                    ruleKey: key, devices: [])
        let second = HistorySnapshot(date: Sample.date("2026-11-05T10:00:00"), target: "Version 27.2 by 20 Nov 2026 at 5:00 PM",
                                     ruleKey: key, devices: [])
        #expect(HistoryMark.marks([first, second]).isEmpty)
        #expect(StatusSummary.previous(first, target: second.target, ruleKey: key) != nil)
        let other = HistorySnapshot(date: Sample.date("2026-11-05T10:00:00"), target: "Version 27.2.1", ruleKey: "specific|27.2.1||",
                                    devices: [])
        #expect(HistoryMark.marks([first, other]).map(\.kinds) == [[.rule]])
        // entries from before the key was kept compare by text
        let older = HistorySnapshot(date: Sample.date("2026-11-03T10:00:00"), target: first.target, devices: [])
        #expect(HistoryMark.marks([older, first]).isEmpty)
    }

    @Test("Apple releasing a version that becomes the target is marked")
    func appleRelease() throws {
        let before = HistorySnapshot(date: Sample.date("2026-11-08T10:00:00"), target: "Minor updates", ruleKey: "minor|14|23:59",
                                     devices: [Self.device(target: "27.2"), Self.device(target: "26.7.2")])
        let after = HistorySnapshot(date: Sample.date("2026-11-09T10:00:00"), target: "Minor updates", ruleKey: "minor|14|23:59",
                                    devices: [Self.device(target: "27.2.1"), Self.device(target: "26.7.3"),
                                              Self.device(target: "27.1", fromDevice: true)])
        let mark = try #require(HistoryMark.marks([before, after]).first)
        #expect(mark.kinds == [.release])
        #expect(mark.text == "Apple released macOS 27.2.1 and 26.7.3, so devices on the earlier version are no longer on target")
        // nothing new: no mark
        #expect(HistoryMark.marks([after, after]).isEmpty)
    }
}
