import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import Software_Update_Dashboard

/// A device without a target is never measured against nothing: it is
/// “Target unknown” with its reason, outside every count. Made-up data only.
@Suite("Target unknown")
struct TargetUnknownTests {
    private static func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement?, os: String?, osName: String = "macOS",
                               platform: AppleReleases.Platform = .macOS,
                               catalog: AppleReleases.Catalog? = TargetRulesTests.catalog) -> DeviceTarget {
        TargetRules.target(os: os, model: "Mac14,2", boardID: nil, osName: osName, context: .init(
            block: enforcement.map { TargetRulesTests.block($0) }, catalog: catalog, platform: platform,
            blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
    }

    private static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
    private static let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 0, deploymentTime: nil)

    @Test("Apple’s data unreachable: latest and minor have no target")
    func appleDataUnreachable() {
        for enforcement in [Self.minor, Self.latest] {
            let target = Self.target(enforcement, os: "26.7.1", catalog: nil)
            #expect(target.unknown == .appleDataUnreachable && target.version == nil)
        }
        // a specific version doesn't need Apple's data
        #expect(Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: nil, detailsURL: nil), os: "26.7.1",
                            catalog: nil).unknown == nil)
    }

    @Test("No software update in the Blueprint, or one this app can’t read")
    func noSoftwareUpdate() {
        #expect(Self.target(nil, os: "26.7.1").unknown == .noSoftwareUpdate)
        #expect(Self.target(.unknown(nil), os: "26.7.1").unknown == .unreadableUpdate)
        #expect(Self.target(.specific(targetOSVersion: "latest please", targetLocalDateTime: nil, detailsURL: nil), os: "26.7.1")
            .unknown == .unreadableUpdate)
    }

    @Test("No release for the platform or the device’s major")
    func noReleaseForPlatform() {
        // Apple's data holds Mac releases only
        #expect(Self.target(Self.latest, os: "26.7.1", osName: "iPadOS", platform: .iOS).unknown == .noReleaseForPlatform)
        #expect(Self.target(Self.minor, os: "26.7.1", osName: "iPadOS", platform: .iOS).unknown == .noReleaseForPlatform)
        // an old major Apple's data no longer lists
        #expect(Self.target(Self.minor, os: "14.8.9").unknown == .noReleaseForPlatform)
    }

    @Test("A beta of a major newer than Apple’s newest release")
    func betaOfNewerMajor() {
        let target = Self.target(Self.minor, os: "28.0")
        #expect(target.unknown == .betaOfNewerMajor)
        #expect(target.reason.contains("beta of macOS 28"))
        // with the newest release as the rule, a beta is simply past it
        #expect(Self.target(Self.latest, os: "28.0").version == "27.2")
    }

    @Test("A device that reports no version, under minor updates")
    func noReportedVersion() {
        #expect(Self.target(Self.minor, os: nil).unknown == .noReportedVersion)
    }

    @Test("Shown as Target unknown with its reason; never on target, late or in need of attention")
    func classified() {
        let target = Self.target(Self.minor, os: "28.0")
        let device = Sample.classify(Sample.mac(os: "28.0"), Sample.status([("device.operating-system.version", "28.0")]), target: target)
        #expect(device.category == .targetUnknown)
        #expect(device.diagnosis == "Target unknown: " + target.reason)
        #expect(device.targetReason == target.reason && device.targetVersion == nil)
        #expect(device.pastDeadline == nil && !device.needsAttention)
        #expect(device.csvLine.contains(",target-unknown,"))
    }

    @Test("Left out of the counts, the progress figure, the diagnoses and the history")
    func leftOut() throws {
        let onTarget = Sample.classify(Sample.mac("1", os: "27.2"), Sample.status([("device.operating-system.version", "27.2")]),
                                       target: Self.target(Self.minor, os: "27.2"))
        let unknown = Sample.classify(Sample.mac("2", os: "28.0"), Sample.status([("device.operating-system.version", "28.0")]),
                                      target: Self.target(Self.minor, os: "28.0"))
        let counts = CategoryCounts([onTarget, unknown])
        #expect(counts.total == 1 && counts.updatable == 1 && counts.percentOnTarget == 100)
        #expect(counts[.targetUnknown] == 1)
        #expect(ProgressGroup.allCases.map { $0.count(in: counts) }.reduce(0, +) == counts.total)
        #expect(StatusSummary.diagnosisCounts([onTarget, unknown]).isEmpty)

        let snapshot = HistorySnapshot(date: Sample.now, target: "Minor updates", devices: [onTarget, unknown])
        #expect(snapshot.devices.map(\.id) == [onTarget.id])
        let saved = String(decoding: try JSONEncoder().encode(snapshot.counts), as: UTF8.self)
        #expect(!saved.contains("target-unknown"))

        let summary = StatusSummary.text(group: "Test", devices: [onTarget, unknown], measuredAgainst: "Minor updates",
                                         previous: nil, staleDays: 30, date: Sample.now)
        #expect(summary.contains("Devices:    1 (Minor updates)"))
        #expect(summary.contains("Target unknown: 1 device not measured"))
        #expect(summary.contains("beta of macOS 28"))
        #expect(summary.contains("1 of 1 updatable devices on target"))
    }

    @Test("Without Apple’s data the refresh stops before reading anything")
    func refreshStops() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: StaticToken(),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        let tracked = TrackedBlueprint(connectionID: UUID(), blueprintID: "bp-1", blueprintName: "Test Blueprint")
        await #expect(throws: AppleDataUnavailable.self) {
            _ = try await RefreshWorkflow(client: client, catalog: nil, serverTimeZone: .gmt).run(tracked)
        }
        #expect(server.requests.isEmpty)
    }
}

/// The target rules’ finer points: releases for some devices only, the
/// Blueprint step per OS, deadlines around daylight saving and on Macs.
@Suite("Targets: releases per device, steps, daylight saving")
struct TargetRulesEdgeTests {
    static let sofaIOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z","SupportedDevices":["iPhone18,1"]},
      "SecurityReleases":[{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z"},
                          {"ProductVersion":"27.0.1","Build":"24A200","ReleaseDate":"2026-10-01T00:00:00Z"}]}]}
    """#
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
      {"ProductVersion":"27.0.2","Build":"24A300","PostingDate":"2026-10-20","SupportedDevices":["iPhone18,1"]},
      {"ProductVersion":"27.0.1","Build":"24A200","PostingDate":"2026-10-01","SupportedDevices":["iPhone17,1","iPhone18,1"]}]}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofaIOS.utf8), gdmf: Data(gdmf.utf8))

    private func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, os: String, model: String) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: nil, osName: "iOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: Self.catalog, platform: .iOS,
            blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
    }

    @Test("A release for some devices only is the target of those devices only")
    func perReleaseDevices() {
        let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 0, deploymentTime: nil)
        let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
        #expect(target(latest, os: "27.0.1", model: "iPhone18,1").version == "27.0.2")
        #expect(target(latest, os: "27.0.1", model: "iPhone17,1").version == "27.0.1")
        #expect(target(minor, os: "27.0.1", model: "iPhone17,1").version == "27.0.1")
        #expect(target(minor, os: "27.0.1", model: "iPhone18,1").version == "27.0.2")
        // not limited by hardware: the same major
        #expect(!target(latest, os: "27.0.1", model: "iPhone17,1").limitedByHardware)
        // a model no list knows gets the newest
        #expect(target(latest, os: "27.0.1", model: "iPhone99,9").version == "27.0.2")
    }

    @Test("A step applies to an OS when its predicate asks for it, never when it excludes it")
    func blockPerOS() {
        func block(_ predicate: String?, _ version: String) -> JamfPlatform.SoftwareUpdateBlock {
            JamfPlatform.SoftwareUpdateBlock(stepIndex: 0, componentIndex: 0, activationPredicate: predicate,
                                             enforcement: .specific(targetOSVersion: version, targetLocalDateTime: nil, detailsURL: nil))
        }
        let blocks = [block("@status(device.operating-system.family) != 'iPadOS'", "27.0"),
                      block("@status(device.operating-system.family) == 'iPadOS'", "27.1")]
        #expect(RefreshWorkflow.block(for: "iPadOS", in: blocks) == blocks[1])
        #expect(RefreshWorkflow.block(for: "iPadOS", in: Array(blocks.reversed())) == blocks[1])
        let spaced = [block("@status(device.operating-system.family)=='macOS'", "27.2")]
        #expect(RefreshWorkflow.block(for: "macOS", in: spaced) == spaced[0])
        // none asks for iOS and none is without a predicate: the first
        #expect(RefreshWorkflow.block(for: "iOS", in: blocks) == blocks[0])
    }

    @Test("A deadline on the day the clocks go back is that day’s local time")
    func daylightSaving() throws {
        let deadline = try #require(TargetRules.deadlineDate("2026-10-25T17:00:00", timeZone: "Europe/Brussels"))
        #expect(deadline == Sample.date("2026-10-25T16:00:00"))
        let summer = try #require(TargetRules.deadlineDate("2026-10-24T17:00:00", timeZone: "Europe/Brussels"))
        #expect(summer == Sample.date("2026-10-24T15:00:00"))
        #expect(TargetRules.isPastDeadline("2026-10-25T17:00:00", timeZone: "Europe/Brussels", now: Sample.date("2026-10-25T15:30:00")) == false)
        #expect(TargetRules.isPastDeadline("2026-10-25T17:00:00", timeZone: "Europe/Brussels", now: Sample.date("2026-10-25T16:00:00")) == true)
        // 25 October plus 14 days stays 8 November at the same local time
        #expect(TargetRules.deadline(released: Sample.date("2026-10-25T00:00:00"), days: 14, time: "17:00") == "2026-11-08T17:00:00")
    }

    @Test("A Mac without a time zone: past the deadline in this Mac’s zone")
    func macWithoutZone() {
        #expect(TargetRules.isPastDeadline("2026-01-01T00:00:00", timeZone: nil, now: Sample.date("2026-11-09T12:00:00")) == true)
        #expect(TargetRules.isPastDeadline("2027-01-01T00:00:00", timeZone: nil, now: Sample.date("2026-11-09T12:00:00")) == false)
        let target = TargetRules.target(os: "26.7.1", model: "Mac14,2", boardID: nil, osName: "macOS", context: .init(
            block: TargetRulesTests.block(.specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-01T17:00:00", detailsURL: nil)),
            catalog: TargetRulesTests.catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
        let mac = Sample.classify(Sample.mac(os: "26.7.1"), Sample.status([("device.operating-system.version", "26.7.1")]), target: target)
        #expect(mac.timeZone == nil)
        #expect(mac.pastDeadline == true)
    }
}
