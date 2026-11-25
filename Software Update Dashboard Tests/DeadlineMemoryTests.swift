import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Software_Update_Dashboard

/// 0.3.2: Jamf’s deadline remembered per tracked Blueprint, reports counted
/// whatever their install reason, a Mac’s next install attempt after the
/// deadline, a 12-hour time, and a Mac’s earlier step by a deadline the
/// Blueprint’s devices reported. Made-up builds, devices and IDs, shaped like
/// what the live tenant showed on 24 and 25 Nov.
@Suite("0.3.2: Jamf’s deadline, remembered and read")
struct DeadlineMemoryTests {
    // Apple posted 26.7.3 on 9 Nov and re-dated its public posting to 16 Nov;
    // Jamf counted from 9 Nov: minor updates, 14 days, 23:59, so 23 Nov 22:59 UTC
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-16","SupportedDevices":["J314sAP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(EarlierStepAndInstallTests.sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let key = PostingBasis.key(.macOS, OSVersion("26.7.3")!)
    static let firstPosting = Sample.date("2026-11-09T00:00:00")
    static let jamfDeadline = "2026-11-23 22:59:11 +0000"

    static func status(pending: String? = "26.7.3", deadline: String? = jamfDeadline, reason: String = "declaration",
                       state: String = "prepared", os: String = "26.7.2", updated: String = "2026-11-10T08:00:00",
                       extra: [(String, String)] = []) -> JamfPro.SoftwareUpdateStatus {
        var pairs = [("device.operating-system.version", os), ("softwareupdate.device-id", "J314sAP"),
                     ("softwareupdate.install-state", state), ("softwareupdate.install-reason.reason", reason)]
        if let pending { pairs.append(("softwareupdate.pending-version.os-version", pending)) }
        if let deadline { pairs.append(("softwareupdate.pending-version.target-local-date-time", deadline)) }
        return Sample.status(pairs + extra, time: updated)
    }

    static func rule(known: PostingBasis = PostingBasis(), now: String = "2026-11-24T06:33:00", block: JamfPlatform.SoftwareUpdateBlock = block,
                     os: String = "26.7.2") -> DeviceTarget {
        TargetRules.target(os: os, model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date(now), known: known))
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, known: PostingBasis = PostingBasis(reported: [key: firstPosting]),
                       now: String = "2026-11-24T06:33:00", block: JamfPlatform.SoftwareUpdateBlock = block,
                       os: String = "26.7.2") -> DeviceTarget {
        TargetRules.fromDevice(rule(known: known, now: now, block: block, os: os), status: status, os: os, osName: "macOS",
                               catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
                               model: "MacBookPro18,3", boardID: "J314sAP",
                               earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                                               model: "MacBookPro18,3", boardID: "J314sAP", known: known) },
                               postingDeadlines: { version, build in
                                   TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                platform: .macOS).map(\.deadline)
                               },
                               known: known, now: Sample.date(now))
    }

    static func workflow(remembered: ReportedDeadlines = ReportedDeadlines()) throws -> RefreshWorkflow {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: StaticToken(),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        var workflow = RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: Sample.utc)
        workflow.reportedDeadlines = remembered
        return workflow
    }

    static let blueprint = try! JamfPlatform.BlueprintDetail(data: Data(#"{"id":"6a2f0000-1111-4000-8000-00000000c0de","name":"Test"}"#.utf8))
    static let tracked = TrackedBlueprint(connectionID: UUID(), blueprintID: blueprint.id, blueprintName: "Test")

    // MARK: Remembered per tracked Blueprint

    @Test("Once the reporting Macs have installed, the others keep Jamf’s 23 Nov, not Apple’s re-dated 30 Nov")
    func rememberedAfterInstall() throws {
        let waiting = DeviceInput(member: Sample.mac("2", os: "26.7.2", model: "MacBookPro18,3"), status: nil)
        // 20 Nov: one Mac reports 26.7.3 pending with Jamf's deadline
        let first = [DeviceInput(member: Sample.mac("1", os: "26.7.2", model: "MacBookPro18,3"), status: Self.status()), waiting]
        let earlier = try Self.workflow()
        let firstNow = Sample.date("2026-11-20T08:00:00")
        let (known, remember) = earlier.deadlineBasis(first, blocks: [Self.block], blueprint: Self.blueprint, tracked: Self.tracked, now: firstNow)
        #expect(known.reported[Self.key] == Self.firstPosting)
        #expect(remember.postings[Self.key]?.posted == Self.firstPosting)
        #expect(remember.moments[Self.key]?.map(\.minute) == [PostingBasis.minute(Sample.date("2026-11-23T22:59:00"))])
        // 25 Nov: that Mac has installed, nobody reports 26.7.3 pending any more
        let installed = DeviceInput(member: Sample.mac("1", os: "26.7.3", model: "MacBookPro18,3"),
                                    status: Self.status(pending: nil, deadline: nil, state: "none", os: "26.7.3"))
        let later = [installed, waiting]
        let now = Sample.date("2026-11-25T05:04:00")
        for (workflow, expected, source) in [(try Self.workflow(remembered: remember), "2026-11-23T23:59:00", "As the Blueprint’s devices reported it earlier"),
                                             (try Self.workflow(), "2026-11-30T23:59:00", "From Apple’s posting date")] {
            let basis = workflow.deadlineBasis(later, blocks: [Self.block], blueprint: Self.blueprint, tracked: Self.tracked, now: now)
            let device = workflow.classify(waiting, blocks: [Self.block], blueprint: Self.blueprint, tracked: Self.tracked, now: now,
                                           known: basis.known)
            #expect(device.deadlineLocal == expected && device.deadlineSource == source)
            #expect(device.pastDeadline == (expected == "2026-11-23T23:59:00"))
        }
        // and it stays remembered for the next refresh
        let again = try Self.workflow(remembered: remember).deadlineBasis(later, blocks: [Self.block], blueprint: Self.blueprint,
                                                                          tracked: Self.tracked, now: now)
        #expect(again.remember.postings[Self.key]?.posted == Self.firstPosting)
    }

    @Test("Saved next to the Blueprint’s history, read back, removed with it; the history doesn’t take it for a refresh")
    func stored() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sud-deadlines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = StatusHistory(folder: folder)
        let id = UUID()
        #expect(history.reportedDeadlines(for: id).isEmpty)
        let memory = ReportedDeadlines(postings: [Self.key: .init(posted: Self.firstPosting, seen: Sample.date("2026-11-20T08:00:00"))])
        try history.saveReportedDeadlines(memory, for: id)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(id.uuidString)/reported-deadlines.plist").path))
        #expect(history.reportedDeadlines(for: id) == memory)
        #expect(history.entries(for: id).isEmpty && history.snapshots(for: id).isEmpty && history.latest(for: id) == nil)
        try history.saveReportedDeadlines(ReportedDeadlines(), for: id)
        #expect(history.reportedDeadlines(for: id).isEmpty)
        try history.saveReportedDeadlines(memory, for: id)
        history.remove(id)
        #expect(history.reportedDeadlines(for: id).isEmpty)
    }

    // MARK: Any install reason

    // MARK: Next install attempt

    @Test("After the 23 Nov deadline a Mac reports 24 Nov 06:02: its next install attempt; it stays past the deadline")
    func nextAttempt() {
        let status = Self.status(deadline: "2026-11-24 06:02:31 +0000", updated: "2026-11-24T05:02:00")
        let target = Self.target(status)
        #expect(target.deadlineLocal == "2026-11-23T23:59:00" && target.deadlineDate == nil && target.deadlineSource == .otherDevices)
        #expect(target.nextInstallAttempt == Sample.date("2026-11-24T06:02:31"))
        let device = Sample.classify(Sample.mac(os: "26.7.2", model: "MacBookPro18,3"), status, target: target, now: "2026-11-24T06:33:00")
        #expect(device.pastDeadline == true && device.nextInstallAttempt == Sample.date("2026-11-24T06:02:31"))
        #expect(device.csvLine.hasSuffix(",2026-11-24T06:02:31Z"))
        // the same time reported before the deadline is the device's own
        let before = Self.target(Self.status(deadline: "2026-11-24 06:02:31 +0000", updated: "2026-11-20T08:00:00"), now: "2026-11-21T08:00:00")
        #expect(before.nextInstallAttempt == nil && before.deadlineSource == .reported && before.deadlineDate == Sample.date("2026-11-24T06:02:31"))
        // Jamf's own deadline, reported after it passed, is no next attempt
        let jamf = Self.target(Self.status(updated: "2026-11-24T05:02:00"))
        #expect(jamf.nextInstallAttempt == nil && jamf.deadlineSource == .reported)
    }

    // MARK: A 12-hour time

    // MARK: A Mac's earlier step

    @Test("The refresh gives the step the deadlines this refresh’s devices report and those remembered")
    func minutesFromRefreshAndMemory() throws {
        let stepKey = PostingBasis.key(.macOS, OSVersion("26.7.2")!)
        let remembered = ReportedDeadlines(moments: [stepKey: [.init(minute: PostingBasis.minute(Sample.date("2026-11-09T22:59:00")),
                                                                     seen: Sample.date("2026-11-05T08:00:00"))]])
        let reporting = DeviceInput(member: Sample.mac("1", os: "26.7.2", model: "MacBookPro18,3"), status: Self.status())
        let basis = try Self.workflow(remembered: remembered).deadlineBasis([reporting], blocks: [Self.block], blueprint: Self.blueprint,
                                                                            tracked: Self.tracked, now: Sample.date("2026-11-20T08:00:00"))
        #expect(basis.known.reportedMinutes[stepKey] == [PostingBasis.minute(Sample.date("2026-11-09T22:59:00"))])
        #expect(basis.known.reportedMinutes[Self.key] == [PostingBasis.minute(Sample.date("2026-11-23T22:59:00"))])
        #expect(basis.remember.moments[stepKey]?.count == 1 && basis.remember.moments[Self.key]?.count == 1)
    }
}

/// iPhones and iPads keep the full-time match of their earlier step, without
/// any remembered deadline: their deadline is written in their own zone.
@Suite("0.3.2: an iPad’s earlier step, by its full clock time")
struct EarlierStepConfirmedTests {
    // 27.2 released 26 Oct and posted 5 Nov; Apple's public catalog lists 27.2.1 only
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]}]},
     "AssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]},
       {"ProductVersion":"27.2","Build":"24B119","PostingDate":"2026-11-05","SupportedDevices":["iPad14,8"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"24B119","ReleaseDate":"2026-10-26T00:00:00Z"}]}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func target(deadline: String) -> DeviceTarget {
        let status = Sample.status([("device.operating-system.version", "27.1"), ("softwareupdate.install-state", "downloading"),
                                    ("softwareupdate.pending-version.os-version", "27.2"),
                                    ("softwareupdate.pending-version.target-local-date-time", deadline),
                                    ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:00:00")
        let rule = TargetRules.target(os: "27.1", model: "iPad14,8", boardID: nil, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.1", osName: "iPadOS", catalog: catalog, platform: .iOS, serverTimeZone: Sample.utc,
            model: "iPad14,8",
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .iOS, model: "iPad14,8", boardID: nil) },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .iOS, model: "iPad14,8",
                                                        boardID: nil, now: now) },
            timeZone: "Europe/Brussels", now: now)
    }

}
