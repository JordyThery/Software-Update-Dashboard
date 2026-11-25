import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// 0.3, round 1: the three items from the 0.2 hand checks. Made-up devices
/// and IDs, shaped like what the live tenant showed on 2026-11-10.
@Suite("0.3: the target pending with the earlier step’s deadline")
struct CarriedDeadlineTests {
    // Apple released 27.2 on 26 Oct: its list keeps this Mac's build posted that
    // day and other builds posted 5 Nov; 27.2.1 was posted publicly on 9 Nov
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26B131","PostingDate":"2026-11-09","SupportedDevices":["J457AP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26B131","PostingDate":"2026-11-09","SupportedDevices":["J457AP"]},
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-10-26","SupportedDevices":["J457AP"]},
       {"ProductVersion":"27.2","Build":"26B8125","PostingDate":"2026-11-05","SupportedDevices":["J999AP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"26B131","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"26B131","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"26B123","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"27.1","Build":"26B50","ReleaseDate":"2026-09-30T00:00:00Z"}]}],
     "Models":{"iMac21,2":{"OSVersions":[27]}},"Devices":{"J457AP":{"DeviceID":"iMac21,2"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    /// The newest release, 7 days, at 23:59.
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(os: String = "27.2", pending: String = "27.2.1", deadline: String = "2026-11-02 22:59:06 +0000",
                       state: String = "prepared") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", os), ("softwareupdate.device-id", "J457AP"),
                       ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:06:50")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, os: String = "27.2", known: PostingBasis = PostingBasis()) -> DeviceTarget {
        let rule = TargetRules.target(os: os, model: "iMac21,2", boardID: "J457AP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: Sample.date("2026-04-28T12:25:44"),
            updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: os, osName: "macOS", catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
            model: "iMac21,2", boardID: "J457AP", blueprintChanged: Sample.date("2026-04-28T12:25:44"),
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                            model: "iMac21,2", boardID: "J457AP") },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                        model: "iMac21,2", boardID: "J457AP", now: now) },
            known: known, now: now)
    }

}

@Suite("0.3: errors from before a device installed its target, and failures with nothing in progress")
struct FailuresAndOnTargetTests {
    static let blueprintID = "6a2f0000-1111-4000-8000-00000000c0de"

    static func inspect(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus, row: DeviceStatus,
                        osVersionChanged: Date?) -> InspectResult {
        var input = InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: [])
        input.osVersionChanged = osVersionChanged
        return InspectFindings.evaluate(input, context: InspectContext(blueprintID: blueprintID, target: OSVersion("27.0.1"),
                                                                       since: Sample.updateStarted, now: Sample.now,
                                                                       serverTimeZone: Sample.utc))
    }

}

@Suite("0.3: Open in Jamf Pro (A) and readiness (G)")
@MainActor
struct OpenAndReadinessTests {
    @Test("Pages from the connection’s Jamf Pro web address: devices read-only by kind, the Blueprint; none without an address")
    func pages() throws {
        let iPad = Sample.classify(Sample.iPad("12"), nil)
        let mac = Sample.classify(Sample.mac("12"), nil)
        let base = "https://example.jamfcloud.com"
        #expect(JamfProPages.device(iPad, base: base)?.absoluteString == "https://example.jamfcloud.com/mobileDevices.html?id=12&o=r")
        #expect(JamfProPages.device(mac, base: base)?.absoluteString == "https://example.jamfcloud.com/computers.html?id=12&o=r")
        #expect(JamfProPages.blueprint(id: "6a2f0000-1111-4000-8000-00000000c0de", base: base)?.absoluteString
                == "https://example.jamfcloud.com/view/mfe/blueprints/6a2f0000-1111-4000-8000-00000000c0de")
        #expect(JamfProPages.device(iPad, base: nil) == nil && JamfProPages.device(iPad, base: "") == nil)
        #expect(JamfProPages.blueprint(id: "x", base: nil) == nil)
    }

    @Test("A saved connection’s address: one page opens, more than 10 ask first, nothing without an address")
    func openSaved() throws {
        let connections = ConnectionsModel.preview()
        var connection = Connection(name: "Role A", service: .jamfPlatform, region: .eu,
                                    environmentID: UUID().uuidString, clientID: UUID().uuidString)
        try connections.saved.save(AppConnection(connection: connection))
        connections.activeID = connection.id
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("open")))
        var opened: [URL] = []
        model.openPage = { opened.append($0) }
        let devices = (1...11).map { Sample.classify(Sample.iPad("\($0)"), nil) }
        // no address yet: no pages, nothing opens
        #expect(connections.jamfProWebAddress == nil && model.pages(of: devices).isEmpty)

        connection.jamfProWebURL = "  https://example.jamfcloud.com  "
        try connections.saved.save(AppConnection(connection: connection))
        #expect(connections.jamfProWebAddress == "https://example.jamfcloud.com")
        model.open(model.pages(of: Array(devices.prefix(1))))
        #expect(opened.map(\.absoluteString) == ["https://example.jamfcloud.com/mobileDevices.html?id=1&o=r"])
        // 10 open at once; 11 ask first, and open once confirmed
        opened = []
        model.open(model.pages(of: Array(devices.prefix(10))))
        #expect(opened.count == 10 && model.pagesToConfirm == nil)
        opened = []
        model.open(model.pages(of: devices))
        #expect(opened.isEmpty && model.pagesToConfirm?.count == 11)
        model.open(model.pagesToConfirm ?? [], confirmed: true)
        #expect(opened.count == 11 && model.pagesToConfirm == nil)
        // nothing goes to Jamf for it
        #expect(TestRun.AttemptLog.savedConnections.attempts().isEmpty)
    }

    @Test("Demo Mode opens nothing: it shows the pages, on an address that names no real server")
    func openDemo() async throws {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("open-demo")))
        var opened: [URL] = []
        model.openPage = { opened.append($0) }
        let tracked = try #require(model.trackedBlueprints.first)
        let page = try #require(model.page(of: tracked.id))
        #expect(page.host()?.hasSuffix(".demo.invalid") == true)
        model.open([page])
        #expect(opened.isEmpty && model.demoPages == [page])
        #expect(ContentView.demoPagesText([page]).contains(page.absoluteString))
    }

    @Test("Demo Mode’s sample devices give every readiness count something to open")
    func readinessInDemo() async throws {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("ready-demo")))
        var devices: [DeviceStatus] = []
        for tracked in model.trackedBlueprints {
            await model.refresh(tracked.id)
            devices += model.results[tracked.id]?.devices ?? []
        }
        #expect(devices.filter(ReadinessCheck.userEnrollment.applies).map(\.name) == ["Field iPad 14"])
        #expect(devices.filter(ReadinessCheck.macNotSupervised.applies).map(\.name) == ["Studio Mac 11"])
        #expect(ReadinessCheck.count(.neverReported, in: devices) > 0)
    }
}
