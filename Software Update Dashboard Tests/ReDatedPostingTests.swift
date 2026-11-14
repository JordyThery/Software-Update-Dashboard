import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Software_Update_Dashboard

/// Apple posts a build publicly on 9 Nov and re-dates its public posting to
/// 12 Nov three days later; its first posting (`AssetSets`) stays 9 Nov.
/// Jamf keeps the deadline it sent: 9 Nov plus 7 days, 16 Nov 23:59 in
/// Brussels (22:59 UTC). Made-up builds and devices.
@Suite("A release Apple re-dates after posting it")
struct ReDatedPostingTests {
    static func gdmf(publicDate: String) -> String {
        """
        {"PublicAssetSets":{"iOS":[
           {"ProductVersion":"27.2.1","Build":"24C201","PostingDate":"\(publicDate)","SupportedDevices":["iPad14,8"]},
           {"ProductVersion":"27.2","Build":"24C100","PostingDate":"2026-10-27","SupportedDevices":["iPad14,8"]}]},
         "AssetSets":{"iOS":[
           {"ProductVersion":"27.2.1","Build":"24C201","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]},
           {"ProductVersion":"27.2","Build":"24C100","PostingDate":"2026-10-27","SupportedDevices":["iPad14,8"]}]}}
        """
    }
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C201","ReleaseDate":"2026-11-09T00:00:00Z"}}]}
    """#
    static func catalog(publicDate: String) -> AppleReleases.Catalog {
        try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf(publicDate: publicDate).utf8))
    }
    /// As Apple first posted it, and as its feed reads after the re-dating.
    static let posted = catalog(publicDate: "2026-11-09")
    static let reDated = catalog(publicDate: "2026-11-12")
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let zone = "Europe/Brussels"
    static let jamfDeadline = "2026-11-16 22:59:00 +0000"
    static let now = "2026-11-14T10:00:00"

    static func rule(_ catalog: AppleReleases.Catalog = reDated, known: PostingBasis = PostingBasis()) -> DeviceTarget {
        TargetRules.target(os: "27.2", model: "iPad14,8", boardID: nil, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date(now), known: known))
    }

    static func pending(updated: String, deadline: String = jamfDeadline, version: String = "27.2.1",
                        reason: String = "declaration") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.2"), ("softwareupdate.install-state", "downloading"),
                       ("softwareupdate.pending-version.os-version", version),
                       ("softwareupdate.pending-version.build-version", "24C201"),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", reason)], time: updated)
    }

    static func sent(_ status: JamfPro.SoftwareUpdateStatus, rule: DeviceTarget = rule(), known: PostingBasis = PostingBasis(),
                     catalog: AppleReleases.Catalog = reDated) -> DeviceTarget {
        TargetRules.fromDevice(rule, status: status, os: "27.2", osName: "iPadOS", catalog: catalog, platform: .iOS,
                               serverTimeZone: Sample.utc, model: "iPad14,8",
                               postingDeadlines: { version, build in
                                   TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                platform: .iOS).map(\.deadline)
                               },
                               known: known, timeZone: zone, now: Sample.date(now))
    }

    static func reportedPosting(_ status: JamfPro.SoftwareUpdateStatus, changed: Date? = nil) -> Date? {
        TargetRules.reportedPosting(rule(), status: status, block: block, catalog: reDated, platform: .iOS,
                                    serverTimeZone: Sample.utc, blueprintChanged: changed, timeZone: zone)
    }

    static let firstPosting = Sample.date("2026-11-09T00:00:00")
    static let reDating = Sample.date("2026-11-12T00:00:00")
    static let key = PostingBasis.key(.iOS, OSVersion("27.2.1")!, build: "24C201")

    @Test("Nothing reported and nothing remembered: today’s public posting, 19 Nov")
    func todaysPosting() {
        let target = Self.rule()
        #expect(target.version == "27.2.1")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
    }

    @Test("A remembered first public posting: the deadline stays 16 Nov after the re-dating")
    func rememberedPosting() {
        let remembered = FirstPostings.merged(FirstPostings.merged([:], with: Self.posted), with: Self.reDated)
        #expect(remembered[Self.key] == Self.firstPosting)
        let target = Self.rule(known: PostingBasis(remembered: remembered))
        #expect(target.deadlineLocal == "2026-11-16T23:59:00" && target.deadlineSource == .postingDate)
        // first seen after the re-dating: only today's posting is known
        #expect(FirstPostings.merged([:], with: Self.reDated)[Self.key] == Self.reDating)
    }

    @Test("The first public posting is saved once and never replaced")
    func savedOnce() {
        let defaults = TestFiles.defaults("first-postings")
        #expect(FirstPostings.remember(Self.posted, in: defaults)[Self.key] == Self.firstPosting)
        #expect(FirstPostings.remember(Self.reDated, in: defaults)[Self.key] == Self.firstPosting)
        #expect(FirstPostings.read(from: defaults)[Self.key] == Self.firstPosting)
        #expect(defaults.dictionary(forKey: "firstPublicPostings") != nil)
    }

    @Test("A device’s report says which posting date Jamf counted from, before and after the re-dating")
    func reportedPostingDate() {
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-10T08:00:00")) == Self.firstPosting)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00")) == Self.firstPosting)
        // a deadline counted from the re-dated posting says so too
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", deadline: "2026-11-19 22:59:00 +0000")) == Self.reDating)
        // a deadline from neither posting, another version, no declaration, a report from before the Blueprint's change: nothing
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", deadline: "2026-11-14 22:59:00 +0000")) == nil)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", version: "27.2")) == nil)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", reason: "notification")) == nil)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-10T08:00:00"), changed: Sample.date("2026-11-11T09:00:00")) == nil)
    }

    @Test("The posting date most devices report counts; the earlier one when as many report each")
    func mostReported() {
        let version = OSVersion("27.2.1")!
        let key = PostingBasis.key(.iOS, version)
        let reports = [(AppleReleases.Platform.iOS, version, Self.firstPosting), (.iOS, version, Self.firstPosting), (.iOS, version, Self.reDating)]
        #expect(TargetRules.reportedPostings(reports.map { ($0.0, $0.1, $0.2) })[key] == Self.firstPosting)
        #expect(TargetRules.reportedPostings([(.iOS, version, Self.reDating), (.iOS, version, Self.firstPosting)])[key] == Self.firstPosting)
    }

    @Test("What the Blueprint’s devices report wins over a remembered date")
    func reportsWin() {
        var known = PostingBasis(remembered: [Self.key: Self.reDating])
        #expect(Self.rule(known: known).deadlineLocal == "2026-11-19T23:59:00")
        known.reported = [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting]
        #expect(Self.rule(known: known).deadlineLocal == "2026-11-16T23:59:00")
    }

    @Test("The deadline’s source: the other devices’ reports have their own; a remembered or today’s posting is Apple’s")
    func deadlineSources() {
        let fromDevices = Self.rule(known: PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting]))
        #expect(fromDevices.deadlineLocal == "2026-11-16T23:59:00" && fromDevices.deadlineSource == .otherDevices)
        #expect(fromDevices.deadlineSource?.text == "As the Blueprint’s other devices report it")
        let remembered = Self.rule(known: PostingBasis(remembered: [Self.key: Self.firstPosting]))
        #expect(remembered.deadlineLocal == "2026-11-16T23:59:00" && remembered.deadlineSource == .postingDate)
        #expect(remembered.deadlineSource?.text == "From Apple’s posting date")
        let today = Self.rule()
        #expect(today.deadlineLocal == "2026-11-19T23:59:00" && today.deadlineSource == .postingDate)
        // a device whose report predates the update gets the Blueprint's deadline, and says where it comes from
        let known = PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting])
        let stale = Self.sent(Self.pending(updated: "2026-11-08T08:00:00", deadline: "2026-11-14 22:59:00 +0000"),
                              rule: Self.rule(known: known), known: known)
        #expect(stale.deadlineLocal == "2026-11-16T23:59:00" && stale.deadlineSource == .otherDevices)
    }

    @Test("A deadline reported before the re-dating, from the first posting, stays reported by the device")
    func reportBeforeReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-10T08:00:00"))
        #expect(target.fromDevice && target.version == "27.2.1")
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-16T22:59:00"))
        #expect(target.staleReason == nil && target.staleReportedDeadline == nil && target.carriedStepVersion == nil)
        // the same with the remembered date or the devices' reports
        let known = PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting])
        let withKnown = Self.sent(Self.pending(updated: "2026-11-10T08:00:00"), rule: Self.rule(known: known), known: known)
        #expect(withKnown.deadlineSource == .reported && withKnown.staleReason == nil)
    }

    @Test("A deadline reported after the re-dating stays reported by the device")
    func reportAfterReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-13T08:00:00"))
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-16T22:59:00"))
        #expect(target.staleReason == nil)
    }

    @Test("A report before the re-dating whose deadline fits no posting is still out of date")
    func unmatchedReportBeforeReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-10T08:00:00", deadline: "2026-11-14 22:59:00 +0000"))
        #expect(target.staleReason == .posted && target.staleSince == Self.reDating)
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
        // remembered: the first posting is what it predates, and the report is newer
        let known = PostingBasis(remembered: [Self.key: Self.firstPosting])
        let remembered = Self.sent(Self.pending(updated: "2026-11-10T08:00:00", deadline: "2026-11-14 22:59:00 +0000"),
                                   rule: Self.rule(known: known), known: known)
        #expect(remembered.staleReason == nil && remembered.deadlineSource == .reported)
    }

    @Test("A refresh: devices that haven’t reported get the deadline the others report, with and without a remembered date")
    func refresh() throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: StaticToken(),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        let blueprint = try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"6a2f0000-1111-4000-8000-00000000c0de","name":"Test"}"#.utf8))
        let tracked = TrackedBlueprint(connectionID: UUID(), blueprintID: blueprint.id, blueprintName: "Test")
        let inputs = [
            DeviceInput(member: Sample.iPad("1", os: "27.2", model: "iPad14,8"), status: Self.pending(updated: "2026-11-10T08:00:00")),
            DeviceInput(member: Sample.iPad("2", os: "27.2", model: "iPad14,8"), status: Self.pending(updated: "2026-11-13T08:00:00")),
            DeviceInput(member: Sample.iPad("3", os: "27.2", model: "iPad14,8"), status: nil),
        ]
        func run(firstPosted: [String: Date]) -> [DeviceStatus] {
            var workflow = RefreshWorkflow(client: client, catalog: Self.reDated, serverTimeZone: Sample.utc)
            workflow.firstPosted = firstPosted
            let now = Sample.date(Self.now)
            let known = workflow.postingBasis(inputs, blocks: [Self.block], blueprint: blueprint, tracked: tracked, now: now)
            return inputs.map { workflow.classify($0, blocks: [Self.block], blueprint: blueprint, tracked: tracked, now: now, known: known) }
        }
        for firstPosted in [[:], [Self.key: Self.reDating], [Self.key: Self.firstPosting]] {
            let devices = run(firstPosted: firstPosted)
            #expect(devices[0].deadlineSource == "Reported by the device" && devices[1].deadlineSource == "Reported by the device")
            #expect(devices[2].deadlineLocal == "2026-11-16T23:59:00"
                    && devices[2].deadlineSource == "As the Blueprint’s other devices report it")
        }
        // nobody reports it: the remembered first posting, else today's
        let silent = [inputs[2]]
        var workflow = RefreshWorkflow(client: client, catalog: Self.reDated, serverTimeZone: Sample.utc)
        let now = Sample.date(Self.now)
        #expect(workflow.postingBasis(silent, blocks: [Self.block], blueprint: blueprint, tracked: tracked, now: now).reported.isEmpty)
        #expect(workflow.classify(silent[0], blocks: [Self.block], blueprint: blueprint, tracked: tracked, now: now).deadlineLocal
                == "2026-11-19T23:59:00")
        workflow.firstPosted = [Self.key: Self.firstPosting]
        #expect(workflow.classify(silent[0], blocks: [Self.block], blueprint: blueprint, tracked: tracked, now: now).deadlineLocal
                == "2026-11-16T23:59:00")
    }

    @Test("Still counted from a public posting later than the release-day posting (26 Oct, 5 Nov)")
    func laterPublicPostingStillCounts() {
        let catalog = PostingDeadlineTests.catalog
        let remembered = FirstPostings.merged([:], with: catalog)
        let target = TargetRules.target(os: "27.0.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(PostingDeadlineTests.minor), catalog: catalog, platform: .macOS, blueprintChanged: nil,
            updateStarted: nil, now: Sample.date("2026-11-09T12:00:00"), known: PostingBasis(remembered: remembered)))
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
        // a Mac reporting Jamf's 19 Nov says Jamf counted from the public posting of 5 Nov, not 26 Oct
        let status = PostingDeadlineTests.pending(updated: "2026-11-07T08:00:00", deadline: "2026-11-19 22:59:06 +0000")
        let posted = TargetRules.reportedPosting(target, status: status, block: TargetRulesTests.block(PostingDeadlineTests.minor),
                                                 catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc)
        #expect(posted == Sample.date("2026-11-05T00:00:00"))
    }
}
