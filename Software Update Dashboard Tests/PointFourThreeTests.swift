import Foundation
import JTKit
import PDFKit
import Testing
@testable import Software_Update_Dashboard

/// 0.4.3: what starts, stops and outlives a refresh, Inspect, saving, and
/// the wording of shares, sizes and settings. Demo Mode and made-up values only.
@MainActor
private func demoModel(_ name: String, history: StatusHistory? = nil) -> DashboardModel {
    let connections = ConnectionsModel.preview(defaults: TestFiles.defaults(name))
    connections.demo.isOn = true
    return DashboardModel(connections: connections, history: history ?? StatusHistory(folder: TestFiles.folder(name)))
}

/// Gives way until `done` holds, at most about ten seconds.
@MainActor
private func wait(until done: () -> Bool) async {
    let end = Date().addingTimeInterval(10)
    while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Gives way without sleeping until `done` holds (a task that only has to reach its first wait).
@MainActor
private func yield(until done: () -> Bool) async {
    for _ in 0..<1_000 where !done() { await Task.yield() }
}

@Suite("0.4.3: what starts and stops a refresh")
@MainActor
struct RefreshLifetimeTests {
    @Test("The first reads aren’t tied to the view that asks: a page that goes away doesn’t stop them")
    func firstReadsOutliveTheView() async throws {
        let model = demoModel("first-reads")
        // as a page whose own task is canceled the moment it goes away
        let page = Task { model.readFirstTime() }
        page.cancel()
        await page.value
        await wait { model.trackedBlueprints.allSatisfy { model.results[$0.id] != nil } }
        for tracked in model.trackedBlueprints {
            #expect(model.results[tracked.id] != nil, "\(tracked.blueprintName)")
            #expect(model.errors[tracked.id] == nil, "\(tracked.blueprintName)")
        }
    }

    @Test("A Blueprint’s page reads it once; leaving the page doesn’t stop the read")
    func pageReadOutlivesThePage() async throws {
        let model = demoModel("page-read")
        let tracked = try #require(model.trackedBlueprints.first)
        let page = Task { model.readIfNeverRead(tracked.id) }
        page.cancel()
        await page.value
        await wait { model.results[tracked.id] != nil }
        #expect(model.results[tracked.id] != nil)
        #expect(model.errors[tracked.id] == nil)
    }

    @Test("A Blueprint whose read was stopped isn’t read again by the first reads")
    func stoppedStaysStopped() async throws {
        let model = demoModel("stopped-stays")
        let stopped = try #require(model.trackedBlueprints.first)
        let reading = Task { await model.refresh(stopped.id) }
        reading.cancel()
        await reading.value
        #expect(model.errors[stopped.id] == DashboardModel.stopped)
        model.readFirstTime()
        let others = model.trackedBlueprints.filter { $0.id != stopped.id }
        await wait { others.allSatisfy { model.results[$0.id] != nil } && model.refreshing.isEmpty }
        #expect(model.results[stopped.id] == nil)
        #expect(model.errors[stopped.id] == DashboardModel.stopped)
    }

    @Test("A second refresh in the same turn does nothing, and Stop still ends the first")
    func secondCallInTheSameTurn() async throws {
        let model = demoModel("same-turn")
        let tracked = try #require(model.trackedBlueprints.first)
        let first = Task { await model.refresh(tracked.id) }
        let second = Task { await model.refresh(tracked.id) }
        await second.value
        #expect(model.refreshing.contains(tracked.id))
        model.stopRefresh(tracked.id)
        await first.value
        #expect(model.errors[tracked.id] == DashboardModel.stopped)
        #expect(!model.refreshing.contains(tracked.id))
    }

    @Test("Stop Tracking during a read stops it, and its history isn’t written again")
    func stopTrackingDuringRead() async throws {
        let folder = TestFiles.folder("stop-tracking")
        let history = StatusHistory(folder: folder)
        let model = demoModel("stop-tracking", history: history)
        let tracked = try #require(model.trackedBlueprints.first)
        let reading = Task { await model.refresh(tracked.id) }
        await yield { model.refreshing.contains(tracked.id) }
        model.remove(tracked.id)
        await reading.value
        // the deletion waits for the read to end; give it a moment
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: tracked.id.uuidString).path))
        #expect(history.snapshots(for: tracked.id).isEmpty)
        #expect(model.results[tracked.id] == nil && model.errors[tracked.id] == nil)
        #expect(!model.refreshing.contains(tracked.id))
    }

    @Test("A change made while a Blueprint is read is read once more, so the dashboard shows it")
    func changeDuringRead() async throws {
        let model = demoModel("change-during-read")
        let tracked = try #require(model.trackedBlueprints.first)
        let reading = Task { await model.refresh(tracked.id) }
        await yield { model.refreshing.contains(tracked.id) }
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        model.setUpdateStarted(started, for: tracked.id)
        await reading.value
        #expect(model.results[tracked.id]?.tracked.updateStarted == started)
        #expect(!model.refreshing.contains(tracked.id))
    }

    @Test("The connection’s key names the tenant it reads, never the connection’s name")
    func keyWithoutName() throws {
        let model = demoModel("key")
        let connection = try #require(model.connections.connectionInUse)
        #expect(!connection.name.isEmpty)
        #expect(!model.connections.inUseKey.contains(connection.name))
        #expect(model.connections.inUseKey.hasPrefix(connection.id.uuidString))
    }

    @Test("A history that can’t be written is said on the dashboard and in the activity log")
    func historySaveFails() async throws {
        // a file where the history's folder should be: nothing can be saved in it
        let blocked = TestFiles.folder("history-blocked")
        try Data().write(to: blocked)
        let model = demoModel("history-blocked", history: StatusHistory(folder: blocked))
        let tracked = try #require(model.trackedBlueprints.first)
        await model.refresh(tracked.id)
        let result = try #require(model.results[tracked.id])
        #expect(result.problems.contains { $0.hasPrefix("This refresh couldn’t be saved in the history on this Mac: ") })
        #expect(model.connections.activityLog.entries.contains { "\($0)".contains("couldn’t be saved") })
    }
}

@Suite("0.4.3: Inspect per tracked Blueprint")
@MainActor
struct InspectRunTests {
    @Test("Inspect can be stopped; the stop is kept for that Blueprint only")
    func stop() async throws {
        let model = demoModel("inspect-stop")
        for tracked in model.trackedBlueprints { await model.refresh(tracked.id) }
        let mac = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        let other = try #require(model.trackedBlueprints.first { $0.id != mac.id })
        let devices = try #require(model.results[mac.id]?.devices)
        let inspecting = Task { await model.inspect(devices, in: mac.id) }
        await yield { model.isInspectRunning(in: mac.id) }
        #expect(model.inspectProgress[mac.id]?.total == devices.count)
        model.stopInspect(mac.id)
        await inspecting.value
        #expect(model.inspectError(in: mac.id) == DashboardModel.stopped)
        #expect(model.inspectError(in: other.id) == nil)
        #expect(!model.isInspectRunning(in: mac.id))
        #expect(devices.allSatisfy { !model.isInspecting($0, in: mac.id) })
    }

    @Test("Inspect counts as it goes and keeps what it found")
    func counts() async throws {
        let model = demoModel("inspect-count")
        let mac = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        await model.refresh(mac.id)
        let devices = Array(try #require(model.results[mac.id]?.devices).prefix(DashboardModel.inspectBatch + 2))
        await model.inspect(devices, in: mac.id)
        #expect(model.inspectError(in: mac.id) == nil)
        #expect(devices.allSatisfy { model.inspection(of: $0, in: mac.id) != nil })
        #expect(model.inspectProgress[mac.id] == nil)
    }
}

@Suite("0.4.3: wording")
struct WordingTests {
    @Test("A share has up to one decimal everywhere, and is never “100%” unless every device is on target")
    func shares() {
        let en = Locale(identifier: "en_US")
        #expect(CategoryCounts.shareText(99.6, locale: en) == "99.6%")
        #expect(CategoryCounts.shareText(99.96, locale: en) == "99.9%")
        #expect(CategoryCounts.shareText(100, locale: en) == "100%")
        #expect(CategoryCounts.shareText(72, locale: en) == "72%")
        #expect(CategoryCounts.shareText(0, locale: en) == "0%")
    }

    @Test("Zero bytes read “0 KB”, never spelled out")
    @MainActor
    func zeroBytes() {
        #expect(bytesText(0) == "0 KB")
        #expect(bytesText(nil) == "–")
        #expect(bytesText(2_048) == "2 KB")
    }

    @Test("Live figures below a minute are given in seconds")
    @MainActor
    func liveFigures() {
        #expect(CachingBlueprintCard.liveFiguresText(30) == "Live figures every 30 s")
        #expect(CachingBlueprintCard.liveFiguresText(900) == "Live figures every 15 min")
    }

    @Test("The beta program setting reads in plain words")
    @MainActor
    func beta() {
        #expect(RuleSection.betaText(.allowed) == "Allowed")
        #expect(RuleSection.betaText(.alwaysOn) == "Always on")
        #expect(RuleSection.betaText(.alwaysOff) == "Always off")
        #expect(RuleSection.betaText(.other("Managed")) == "Managed")
    }

    @Test("Notifications keep only the latest notices in memory")
    @MainActor
    func postedKept() {
        let notifier = Notifier(defaults: TestFiles.defaults("posted"), activityLog: ActivityLog())
        let notices = (0..<(Notifier.postedKept + 5)).map { RefreshNotice(title: "Blueprint", body: "Notice \($0)") }
        notifier.post(notices, demo: true)
        #expect(notifier.posted.count == Notifier.postedKept)
        #expect(notifier.posted.last?.body == "Notice \(Notifier.postedKept + 4)")
    }
}

@Suite("0.4.3: the PDF report")
@MainActor
struct ReportLimitTests {
    @Test("Devices to Check lists at most 180 devices per Blueprint and counts the rest")
    func cap() async throws {
        let model = demoModel("pdf-cap")
        let mac = try #require(model.trackedBlueprints.first { $0.blueprintName.contains("Mac") })
        await model.refresh(mac.id)
        var result = try #require(model.results[mac.id])
        let template = try #require(ReportPDF.attentionDevices(result).first)
        result.devices = (0..<200).map { number in
            var device = template
            device.jamfID = "9\(number)"
            device.name = String(format: "Capped Mac %03d", number)
            return device
        }
        var part = ReportPDF.Part(tracked: mac, result: nil, saved: nil, snapshots: [])
        part.result = result
        let text = try #require(PDFDocument(data: await ReportPDF.make([part], demo: true))?.string)
            .replacingOccurrences(of: "\n", with: " ")
        #expect(text.contains("Capped Mac 179"))
        #expect(!text.contains("Capped Mac 180"))
        #expect(text.contains("And 20 more devices to check"))
    }
}
