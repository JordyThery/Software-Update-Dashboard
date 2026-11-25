import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// A late earlier step, left-over install states, check-ins, the grace,
/// coverage by major, range shapes and history marks. Made-up devices.
@Suite("Late earlier steps and edge cases")
struct LateStepAndEdgeCaseTests {
    typealias Step = EarlierStepAndInstallTests

    static func prepared(time: String = "2026-11-09T23:00:00", state: String = "prepared") -> JamfPro.SoftwareUpdateStatus {
        Step.status(state: state, time: time)
    }

    // MARK: Earlier steps

    @Test("Downloaded 26.7.2, its deadline long passed, then Apple posts 26.7.3: the target stays 26.7.3, past the step’s deadline")
    func lateEarlierStep() {
        let status = Self.prepared()
        let target = Step.target(status, now: "2026-11-11T09:00:00")
        #expect(target.version == "26.7.3" && target.deadlineLocal == "2026-11-23T23:59:00")
        #expect(!target.fromDevice && target.earlierStepVersion == "26.7.2" && target.earlierStepLapsed)
        let device = Sample.classify(Step.member, status, target: target, now: "2026-11-11T09:00:00")
        #expect(device.targetVersion == "26.7.3")
        #expect(device.pastDeadline == true)
        #expect(device.diagnosis == "26.7.2 downloaded but not installed after its deadline")
        #expect(device.needsAttention)
        // Inspect: stuck, not an earlier step under way
        let inspected = InspectFindings.evaluate(
            InspectInput(member: Step.member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.date("2026-11-11T09:00:00"), serverTimeZone: Sample.utc))
        #expect(inspected.findings.contains { $0.cause == "Update stuck" })
        #expect(inspected.findings.contains { $0.cause == "Earlier step past its deadline" })
        #expect(!inspected.findings.contains { $0.cause == "Earlier step of this Blueprint" })
        // By Major Release shows the current target; Deadline per Time Zone the step it is late for, with that step's deadline
        #expect(MajorRow.rows([device]).first?.targets == ["26.7.3"])
        let zones = DeadlineZones.zones(devices: [device])
        #expect(zones.map(\.target) == ["26.7.2, earlier step"])
        #expect(zones.first?.deadline == device.earlierStepDeadline)
    }

    @Test("An offline Mac with a two-month-old report: no September target or deadline anywhere")
    func oldReportOffline() {
        var member = Sample.mac(os: "26.6.2", model: "MacBookPro18,3")
        member.lastContact = Sample.date("2026-09-20T08:00:00")
        let status = Sample.status([("device.operating-system.version", "26.6.2"), ("softwareupdate.device-id", "J314sAP"),
                                    ("softwareupdate.install-state", "prepared"),
                                    ("softwareupdate.pending-version.os-version", "26.7"),
                                    ("softwareupdate.pending-version.target-local-date-time", "2026-09-28 21:59:00 +0000"),
                                    ("softwareupdate.install-reason.reason", "declaration")], time: "2026-09-20T08:00:00")
        let rule = TargetRules.target(os: "26.6.2", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: Step.block, catalog: Step.catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date("2026-11-10T09:00:00")))
        let target = TargetRules.fromDevice(rule, status: status, os: "26.6.2", osName: "macOS", catalog: Step.catalog,
                                            platform: .macOS, serverTimeZone: Sample.utc, now: Sample.date("2026-11-10T09:00:00"))
        #expect(target.version == "26.7.3" && target.deadlineLocal == "2026-11-23T23:59:00" && target.deadlineDate == nil)
        let device = Sample.classify(member, status, target: target, now: "2026-11-10T09:00:00")
        #expect(device.category == .offline)
        #expect(MajorRow.rows([device]).first?.targets == ["26.7.3"])
        #expect(!DeadlineZones.zones(devices: [device]).contains { $0.localDeadline.hasPrefix("2026-09") })
    }

    // MARK: Install states and check-ins

    // MARK: Inspect

    // MARK: History

    @Test("A device new to a major isn’t an Apple release")
    func newMajorIsNoRelease() {
        let before = HistorySnapshot(date: Sample.date("2026-11-08T10:00:00"), target: "Minor updates", ruleKey: "minor|14|23:59",
                                     devices: [HistoryMarkValueTests.device(target: "27.2")])
        let after = HistorySnapshot(date: Sample.date("2026-11-09T10:00:00"), target: "Minor updates", ruleKey: "minor|14|23:59",
                                    devices: [HistoryMarkValueTests.device(target: "27.2"), HistoryMarkValueTests.device(target: "26.7.3")])
        #expect(HistoryMark.marks([before, after]).isEmpty)
    }

    @Test("A 0.1.0 history entry, then a 0.1.1 one: marked as an app update, not as a changed software update")
    func fromOlderVersion() throws {
        let rule = "Minor updates, 14 days after their release"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let current = HistorySnapshot(date: Sample.date("2026-11-04T10:00:00"), target: rule, ruleKey: "minor|14|23:59", devices: [])
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any])
        json.removeValue(forKey: "ruleKey")
        json["rules"] = 2
        let older = try StatusHistory.decoder.decode(HistorySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.ruleKey == nil && older.rules == 2)
        let next = HistorySnapshot(date: Sample.date("2026-11-05T10:00:00"), target: rule, ruleKey: "minor|14|23:59", devices: [])
        #expect(HistoryMark.marks([older, next]).map(\.kinds) == [[.counting]])
    }
}
