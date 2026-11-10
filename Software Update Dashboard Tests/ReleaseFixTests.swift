import Foundation
import JTKit
import PDFKit
import Testing
@testable import Software_Update_Dashboard

/// 0.3 fixes before the release: the review’s findings and the round 3 hand
/// check. Made-up devices and Demo Mode only.
@MainActor
private func demo(_ name: String, history: StatusHistory? = nil) -> DashboardModel {
    let connections = ConnectionsModel.preview(defaults: TestFiles.defaults(name))
    connections.demo.isOn = true
    return DashboardModel(connections: connections, history: history ?? StatusHistory(folder: TestFiles.folder(name)))
}

private func inspect(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus) -> InspectResult {
    InspectFindings.evaluate(InspectInput(member: member, status: status, device: Sample.classify(member, status),
                                          platformDeviceID: "P-1", reports: []),
                             context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil,
                                                     since: nil, now: Sample.now, serverTimeZone: Sample.utc))
}

@Suite("0.3 fixes: battery, Help links, hardware")
struct ReleaseFixLogicTests {
    @Test("Low battery only with a battery error or under 20%; under 30% an automatic install may wait")
    func battery() {
        func causes(_ level: Int, error: String? = nil) -> [String] {
            var member = Sample.iPad()
            member.batteryLevel = level
            var pairs = [("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared")]
            if let error { pairs += [("softwareupdate.failure-reason.reason", error), ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")] }
            return inspect(member, Sample.status(pairs)).findings.map(\.cause)
        }
        #expect(causes(15).contains("Low battery"))
        #expect(causes(25).contains("Battery under the automatic minimum") && !causes(25).contains("Low battery"))
        #expect(!causes(35).contains("Low battery") && !causes(35).contains("Battery under the automatic minimum"))
        #expect(causes(60, error: "Install failed: battery level too low").contains("Low battery"))
        // Help shows Apple's figures as they are, and none for an enforced update
        let help = HelpContent.problem("battery")?.text ?? ""
        for figure in ["20% for an update someone starts, 30% for an automatic one", "Apple silicon: 20% and 50%", "Intel processor: 50% for both",
                       "no figure for an enforced update"] {
            #expect(help.contains(figure), "\(figure)")
        }
    }

    @Test("Apple’s servers not reachable: only a clear connection failure, only as the likely cause")
    func connectionLinks() {
        for clear in ["Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\"",
                      "The request timed out.", "NetworkRequired", "The network connection was lost.",
                      "not being able to connect to the host"] {
            #expect(HelpContent.problem(forCause: "Update error", detail: clear)?.id == "network-hosts", "\(clear)")
        }
        for unclear in ["SUMacControllerErrorDownloadNoDescriptorProvided", "No update found", "Download failed",
                        "MobileAssetError: Unable to copy asset information", "The catalog couldn’t be read", "DownloadFailed"] {
            #expect(HelpContent.problem(forCause: "Update error", detail: unclear)?.id != "network-hosts", "\(unclear)")
        }
        // an earlier error, or one that isn't the likely cause, never points at the servers
        #expect(HelpContent.problem(forCause: "Earlier update error", detail: "The request timed out.") == nil)
        #expect(HelpContent.problem(forCause: "Update error", detail: "The request timed out.", likely: false) == nil)
    }

    @Test("Minor updates: a release Apple ships to other models only doesn’t make a device hardware to replace")
    func otherModelsOnly() {
        // 27.2.1 is for iPad15,8 only; iPad14,8 gets 27.2, the newest Apple ships for it
        let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 7, deploymentTime: "23:59"))
        let target = TargetRules.target(os: "27.0.1", model: "iPad14,8", boardID: "iPad14,8", osName: "iPadOS", context: .init(
            block: block, catalog: MovedOnStepTests.catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil,
            now: MovedOnStepTests.now))
        #expect(target.version == "27.2" && !target.limitedByHardware)
        #expect(target.source == "From Apple’s data and the Blueprint’s rule")
        let device = Sample.classify(Sample.iPad(os: "27.0.1", model: "iPad14,8"), nil, target: target)
        #expect(Replacement.list([device]) { _ in "27.2" }.isEmpty)
    }
}

@Suite("0.3 fixes: diagnoses from the snapshot")
struct SnapshotDiagnosisTests {
    @Test("An OS too old for update declarations: in Readiness, and the diagnosis when Apple has a newer version for the model")
    func tooOld() {
        let status = Sample.status([("device.operating-system.version", "16.7.10")])
        let iPad = Sample.iPad(os: "16.7.10", model: "iPad13,18")
        let device = Sample.classify(iPad, status, target: DeviceTarget(version: "16.7.12", reason: "Made up"))
        #expect(device.diagnosis == "iPadOS 16.7.10 is too old for update declarations (Apple’s start at iOS and iPadOS 17): update it another way first")
        #expect(device.needsAttention && ReadinessCheck.osTooOld.applies(to: device))
        // a Mac on 13; one on 14 or an iPad on 17 is fine
        let mac = Sample.classify(Sample.mac(os: "13.7.8"), Sample.status([("device.operating-system.version", "13.7.8")]),
                                  target: DeviceTarget(version: "13.7.9", reason: "Made up"))
        #expect(mac.diagnosis.hasPrefix("macOS 13.7.8 is too old for update declarations (Apple’s start at macOS 14)"))
        #expect(!ReadinessCheck.osTooOld.applies(to: Sample.classify(Sample.mac(os: "14.0"), nil)))
        #expect(!ReadinessCheck.osTooOld.applies(to: Sample.classify(Sample.iPad(os: "17.0"), nil)))
        // without a newer version from Apple's data: counted in Readiness, diagnosis as before
        let held = Sample.classify(iPad, status, target: DeviceTarget(version: "16.7.10", reason: "Made up"))
        #expect(!held.diagnosis.contains("too old") && ReadinessCheck.osTooOld.applies(to: held))
    }

    @Test("A download declined over a cellular connection has its own diagnosis")
    func cellular() {
        let device = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.reason", "Error Domain=SUErrorDomain Code=11 \"Cellular download declined\""),
            ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(device.diagnosis == "Download declined over a cellular connection: the device needs Wi-Fi")
        #expect(device.needsAttention)
    }

    @Test("InstallationKeybagRequired or PasscodeLocked since the update started: the passcode has to be entered, also while downloading")
    func passcode() {
        for (state, reason) in [("downloading", "Error Domain=SUErrorDomain Code=8406 \"InstallationKeybagRequired\""),
                                ("downloading", "PasscodeLocked")] {
            let device = Sample.classify(Sample.iPad(), Sample.status([
                ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", state),
                ("softwareupdate.pending-version.os-version", "27.0.1"),
                ("softwareupdate.failure-reason.reason", reason), ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]),
                context: Sample.context(since: Sample.updateStarted))
            #expect(device.diagnosis == "Downloading; the passcode has to be entered to install", "\(reason)")
            #expect(device.needsAttention)
        }
    }
}

@Suite("0.3 fixes: refresh, report and Find a Device", .serialized)
@MainActor
struct ReleaseFixModelTests {
    @Test("A refresh says every step, not only the status reports")
    func progressSteps() async throws {
        let model = demo("progress")
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        let client = try #require(try model.connections.client())
        let catalog = try await model.connections.appleReleases().catalog()
        let steps = StepLog()
        _ = try await RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: .gmt).run(tracked) { steps.add($0) }
        let names = Set(steps.all.map(\.step))
        for step in ["Reading the Blueprint", "Reading the Blueprint’s scope", "Reading group members", "Reading status reports",
                     "Reading the device list", "Reading Blueprint health"] {
            #expect(names.contains(step), "\(step)")
        }
        let health = try #require(steps.all.last { $0.step == "Reading Blueprint health" })
        #expect(health.done == health.total && health.text.hasSuffix("declarations"))
        #expect(RefreshProgress(step: "Reading Blueprint health", done: 3, total: 18, unit: "declarations").text
                == "Reading Blueprint health, 3 of 18 declarations")
    }

    @Test("All Blueprints: one not refreshed this session uses its newest saved refresh, with its date; none at all gets one line")
    func reportFromHistory() async throws {
        let folder = TestFiles.folder("pdf-history")
        let first = demo("pdf-history-1", history: StatusHistory(folder: folder))
        let mac = try #require(first.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        await first.refresh(mac.id)
        let saved = try #require(first.results[mac.id]?.date)
        // a new session on the same history: nothing refreshed yet
        let later = demo("pdf-history-2", history: StatusHistory(folder: folder))
        await later.loadHistory()
        // saved to the millisecond
        #expect(abs((later.newestSaved(mac.id)?.date ?? .distantPast).timeIntervalSince(saved)) < 0.001)
        let text = try #require(PDFDocument(data: later.reportPDF())?.string)
        #expect(text.contains("Refresh of \(saved.formatted(date: .long, time: .shortened)), the newest saved one"))
        #expect(text.contains("Devices to Check") && text.contains("Studio Mac 10"))
        // the iPad Blueprint has no refresh at all
        #expect(text.contains("Never refreshed: refresh it to include it in the report."))
    }

    @Test("In its own section Blueprint health names declarations by their versions only")
    func reportDeclarationNames() async throws {
        let model = demo("pdf-names")
        let mac = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        await model.refresh(mac.id)
        let text = try #require(PDFDocument(data: model.reportPDF([mac.id]))?.string)
        #expect(text.contains("macOS 27.0 to 27.0.1"))
        #expect(!text.contains("\(mac.blueprintName), macOS"))
    }

    @Test("Find a Device and the menu bar read the history from memory, loaded off the main thread")
    func historyInMemory() async throws {
        let folder = TestFiles.folder("memory")
        let first = demo("memory-1", history: StatusHistory(folder: folder))
        for tracked in first.trackedBlueprints { await first.refresh(tracked.id) }
        let later = demo("memory-2", history: StatusHistory(folder: folder))
        await later.loadHistory()
        #expect(later.searchSources().allSatisfy { !$0.devices.isEmpty && $0.date != nil })
        #expect(later.trackedBlueprints.allSatisfy { later.latestCounts($0.id) != nil && !later.snapshots($0.id).isEmpty })
    }
}

/// Progress steps a refresh reported, from any thread.
private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [RefreshProgress] = []
    func add(_ step: RefreshProgress) { lock.withLock { steps.append(step) } }
    var all: [RefreshProgress] { lock.withLock { steps } }
}
