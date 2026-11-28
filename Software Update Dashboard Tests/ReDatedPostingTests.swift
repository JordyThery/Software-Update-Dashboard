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
                                    serverTimeZone: Sample.utc, blueprintChanged: changed, timeZone: zone)?.posted
    }

    static let firstPosting = Sample.date("2026-11-09T00:00:00")
    static let reDating = Sample.date("2026-11-12T00:00:00")
    static let key = PostingBasis.key(.iOS, OSVersion("27.2.1")!, build: "24C201")

    @Test("The first public posting is saved once and never replaced")
    func savedOnce() {
        let defaults = TestFiles.defaults("first-postings")
        #expect(FirstPostings.remember(Self.posted, in: defaults)[Self.key] == Self.firstPosting)
        #expect(FirstPostings.remember(Self.reDated, in: defaults)[Self.key] == Self.firstPosting)
        #expect(FirstPostings.read(from: defaults)[Self.key] == Self.firstPosting)
        #expect(defaults.dictionary(forKey: "firstPublicPostings") != nil)
    }

    @Test("A refresh: devices that haven’t reported get the deadline the others report, with and without a remembered date")
    func refresh() throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"), tokens: StaticToken(),
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

}
