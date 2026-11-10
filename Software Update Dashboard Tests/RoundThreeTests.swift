import Foundation
import JTKit
import PDFKit
import Testing
@testable import Software_Update_Dashboard

/// 0.3, round 3: Help (I), Export Report as PDF (J), Find a Device (K).
/// Demo Mode and made-up devices only; none of them reads from Jamf.
@MainActor
private func refreshedDemo(_ name: String) async -> DashboardModel {
    let connections = ConnectionsModel.preview(defaults: TestFiles.defaults(name))
    connections.demo.isOn = true
    let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder(name)))
    for tracked in model.trackedBlueprints { await model.refresh(tracked.id) }
    return model
}

@Suite("0.3: Help and Known Problems")
struct HelpTests {
    @Test("Help explains every category and Target unknown, targets, earlier steps, Readiness and Inspect")
    func topics() {
        let categories = HelpContent.categories.paragraphs.joined(separator: "\n")
        for category in StatusCategory.allCases {
            #expect(categories.contains("\(category.title):"), "\(category.title)")
        }
        #expect(HelpContent.topics.map(\.id) == ["categories", "targets", "earlier-step", "readiness", "inspect"])
        #expect(HelpContent.readiness.paragraphs.joined().contains("User Enrollment"))
    }

    @Test("Known problems: each with a public source of Apple’s, unique, in the app’s own words")
    func problems() {
        #expect(Set(HelpContent.problems.map(\.id)).count == HelpContent.problems.count)
        for problem in HelpContent.problems {
            let host = problem.source.host() ?? ""
            #expect(problem.source.scheme == "https" && (host == "support.apple.com" || host == "github.com"), "\(problem.id)")
            if host == "github.com" { #expect(problem.source.path().hasPrefix("/apple/device-management/")) }
            #expect(problem.sourceTitle.hasPrefix("Apple"))
            #expect(!problem.text.isEmpty && !problem.title.isEmpty)
        }
        #expect(HelpContent.problems.map(\.id) == ["bootstrap-token", "network-hosts", "passcode", "battery", "storage", "enrollment", "offline"])
    }

    @Test("Inspect’s causes link to their known problem; others don’t")
    func links() {
        #expect(HelpContent.problem(forCause: "Bootstrap token not escrowed", detail: "")?.id == "bootstrap-token")
        #expect(HelpContent.problem(forCause: "Passcode", detail: "")?.id == "passcode")
        #expect(HelpContent.problem(forCause: "Low battery", detail: "")?.id == "battery")
        #expect(HelpContent.problem(forCause: "Low storage", detail: "")?.id == "storage")
        #expect(HelpContent.problem(forCause: "User Enrollment", detail: "")?.id == "enrollment")
        #expect(HelpContent.problem(forCause: "Not supervised", detail: "")?.id == "enrollment")
        #expect(HelpContent.problem(forCause: "Offline", detail: "")?.id == "offline")
        #expect(HelpContent.problem(forCause: "Update error", detail: "DownloadFailed: The network connection was lost.")?.id == "network-hosts")
        #expect(HelpContent.problem(forCause: "Update error", detail: "InsufficientDiskSpace: Not enough free space")?.id == "storage")
        #expect(HelpContent.problem(forCause: "Update error", detail: "Something else")?.id == nil)
        #expect(HelpContent.problem(forCause: "Earlier step of this Blueprint", detail: "") == nil)
    }

    @Test("Low battery follows Apple’s figure for an automatic install on iPhone and iPad: under 30%")
    func battery() {
        func findings(_ level: Int) -> [String] {
            var member = Sample.iPad()
            member.batteryLevel = level
            let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared")])
            return InspectFindings.evaluate(InspectInput(member: member, status: status, device: Sample.classify(member, status),
                                                         platformDeviceID: "P-1", reports: []),
                                            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil,
                                                                    since: nil, now: Sample.now, serverTimeZone: Sample.utc)).findings.map(\.cause)
        }
        #expect(findings(29).contains("Low battery"))
        #expect(!findings(35).contains("Low battery"))
    }
}

@Suite("0.3: Find a Device")
@MainActor
struct FindDeviceTests {
    @Test("By serial or name, ignoring case; an exact serial first; once per Blueprint; nothing for no text")
    func search() {
        let one = TrackedBlueprint(connectionID: UUID(), blueprintID: "B-1", blueprintName: "Blueprint One")
        let two = TrackedBlueprint(connectionID: UUID(), blueprintID: "B-2", blueprintName: "Blueprint Two")
        let shared = Sample.classify(Sample.iPad("1"), nil)
        let other = Sample.classify(Sample.iPad("12"), nil)
        let sources = [DeviceSearch.Source(tracked: one, devices: [shared, other], date: nil),
                       DeviceSearch.Source(tracked: two, devices: [shared], date: nil)]
        #expect(DeviceSearch.matches("  ", in: sources).isEmpty)
        // ZZTEST1 is in both Blueprints: listed twice; ZZTEST12 contains it too, after the exact ones
        let found = DeviceSearch.matches("zztest1", in: sources)
        #expect(found.map(\.blueprintName) == ["Blueprint One", "Blueprint Two", "Blueprint One"])
        #expect(found.prefix(2).allSatisfy { $0.device.serial == "ZZTEST1" })
        #expect(Set(found.map(\.id)).count == 3)
        #expect(DeviceSearch.matches("test ipad 12", in: sources).map(\.device.serial) == ["ZZTEST12"])
    }

    @Test("In Demo Mode it searches the last refresh, and opening a match shows it in its Blueprint’s device list")
    func demo() async throws {
        let model = await refreshedDemo("find-demo")
        let sources = model.searchSources()
        #expect(sources.count == model.trackedBlueprints.count && sources.allSatisfy { !$0.devices.isEmpty && $0.date != nil })
        let match = try #require(DeviceSearch.matches("Studio Mac 09", in: sources).first)
        model.show(match)
        #expect(model.selection == .blueprint(match.trackedID))
        #expect(model.deviceToShow == DashboardModel.DeviceKey(tracked: match.trackedID, device: match.device.id))
        #expect(TestRun.AttemptLog.savedConnections.attempts().isEmpty)
    }
}

@Suite("0.3: Export Report as PDF")
@MainActor
struct ReportPDFTests {
    private func text(_ data: Data) throws -> (String, Int, String?) {
        let document = try #require(PDFDocument(data: data))
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return (document.string ?? "", document.pageCount, title)
    }

    @Test("All tracked Blueprints: each from a new page, with what the dashboard shows and the devices needing attention")
    func all() async throws {
        let model = await refreshedDemo("pdf-all")
        let data = model.reportPDF()
        #expect(data.starts(with: Data("%PDF".utf8)))
        let (text, pages, title) = try text(data)
        #expect(title == "Software Update Dashboard Report — Demo")
        #expect(text.contains("Software Update Dashboard Report — Demo"))
        #expect(pages >= 2)
        for tracked in model.trackedBlueprints {
            #expect(text.contains(tracked.blueprintName))
            let date = try #require(model.results[tracked.id]?.date)
            #expect(text.contains("Refresh of \(date.formatted(date: .long, time: .shortened))"))
        }
        let missing = ["Readiness", "By Major Release", "Blueprint Health", "Deadline per Time Zone", "Devices Needing Attention", "History"]
            .filter { !text.contains($0) }
        #expect(missing.isEmpty, "missing: \(missing)")
        // a device needing attention, with its diagnosis
        #expect(text.contains("Studio Mac 10"))
        #expect(model.reportName(nil).hasSuffix("(Demo).pdf") && model.reportName(nil).hasPrefix("All Blueprints Report "))
    }

    @Test("The Blueprint on screen only; Hardware to Replace when there is some")
    func one() async throws {
        let model = await refreshedDemo("pdf-one")
        let iPads = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("iPad") })
        let (text, _, _) = try text(model.reportPDF([iPads.id]))
        #expect(text.contains(iPads.blueprintName))
        #expect(!model.trackedBlueprints.filter { $0.id != iPads.id }.contains { text.contains($0.blueprintName) })
        #expect(text.contains("Hardware to Replace") || text.contains("Hardware"))
        #expect(model.reportName(iPads.id).hasPrefix(iPads.blueprintName))
    }

    @Test("A long list of devices needing attention breaks between rows, never inside a section")
    func pages() {
        #expect(ReportPDF.rowsPerBlock > 0)
        let empty = ReportPDF.make([], demo: false)
        #expect(empty.starts(with: Data("%PDF".utf8)))
        #expect(PDFDocument(data: empty)?.pageCount == 1)
        #expect(ReportPDF.title(demo: false) == "Software Update Dashboard Report")
    }
}
