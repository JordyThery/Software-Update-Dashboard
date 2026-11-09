import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import Software_Update_Dashboard

/// What the app keeps and writes: CSV cells, the tracked list, the history
/// and demo mode’s copies. Made-up data only.
@Suite("Exports")
struct ExportTests {
    @Test("A cell that starts like a formula is shown as text", arguments: ["=1+1", "+31 6", "-2", "@SUM(A1)", "\tx", "\rx"])
    func formula(_ cell: String) {
        let line = CSV.line([cell, "plain"])
        #expect(line.hasPrefix("\"'"))
        #expect(line.hasSuffix(",plain"))
    }

    @Test("Ordinary cells stay as they were; a formula with a quote is quoted once")
    func ordinary() {
        #expect(CSV.line(["Test iPad 1", "27.0.1", "Jo’s Mac", "a-b"]) == "Test iPad 1,27.0.1,Jo’s Mac,a-b")
        #expect(CSV.line([#"=HYPERLINK("x")"#]) == #""'=HYPERLINK(""x"")""#)
    }

    @Test("A device named like a formula is neutralized in the device list’s CSV")
    func deviceName() {
        var device = Sample.classify(Sample.iPad(), nil)
        device.name = "=cmd|' /C calc'!A0"
        #expect(device.csvLine.contains(#","'=cmd|' /C calc'!A0","#))
    }

    @Test("A reported deadline is written as a moment with its time zone, and every deadline with its source")
    func deadlineColumns() {
        var device = Sample.classify(Sample.mac(), nil)
        device.deadlineDate = Sample.date("2026-11-19T22:59:06")
        device.deadlineLocal = "2026-11-19T22:59:06"
        device.deadlineSource = "Reported by the device"
        #expect(device.csvLine.contains(",2026-11-19T22:59:06Z,Reported by the device,"))
        let header = DeviceStatus.csvColumns
        #expect(header.firstIndex(of: "deadline_source") == header.firstIndex(of: "deadline").map { $0 + 1 })
        device.deadlineDate = nil
        device.deadlineLocal = "2026-11-19T23:59:00"
        device.deadlineSource = "From Apple’s posting date"
        #expect(device.csvLine.contains(",2026-11-19T23:59:00,From Apple’s posting date,"))
    }

    @Test("A release date is a day, without a time, the same everywhere")
    func releaseDay() {
        let day = DeviceDetailView.releaseDay(Sample.date("2026-10-26T00:00:00"))
        #expect(day.contains("2026") && day.contains("26") && !day.contains(":"))
    }
}

@Suite("Stored data")
struct StoredDataTests {
    private func defaults() -> UserDefaults {
        TestFiles.defaults("stored")
    }

    @Test("A tracked list that can’t be read is kept as a dated copy, once, and never saved over")
    @MainActor
    func unreadableList() throws {
        let defaults = defaults()
        defaults.set(Data("not a list".utf8), forKey: TrackedBlueprintList.key)
        let now = Sample.date("2026-11-09T12:00:00")
        let first = TrackedBlueprintList.read(from: defaults, now: now)
        let copy = try #require(first.unreadableCopy)
        #expect(first.list.isEmpty)
        #expect(copy.hasPrefix("trackedBlueprints.unreadable-"))
        #expect(defaults.data(forKey: copy) == Data("not a list".utf8))
        // read again later: the same copy, no second one
        let again = TrackedBlueprintList.read(from: defaults, now: now.addingTimeInterval(3_600))
        #expect(again.unreadableCopy == copy)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("trackedBlueprints.unreadable") }.count == 1)

        // the model refuses every change, so the list is never saved over
        let connections = ConnectionsModel.preview(defaults: defaults)
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("stored")))
        #expect(model.unreadableTrackedCopy == copy && !model.canChangeTracked)
        model.add(TrackedBlueprint(connectionID: UUID(), blueprintID: "bp-1", blueprintName: "Test Blueprint"))
        #expect(defaults.data(forKey: TrackedBlueprintList.key) == Data("not a list".utf8))
    }

    @Test("An unreadable list: its copy can be shown in Finder, and a new list started without losing the copy")
    @MainActor
    func wayOut() throws {
        let defaults = defaults()
        defaults.set(Data("not a list".utf8), forKey: TrackedBlueprintList.key)
        let model = DashboardModel(connections: ConnectionsModel.preview(defaults: defaults),
                                   history: StatusHistory(folder: TestFiles.folder("way")))
        let copy = try #require(model.unreadableTrackedCopy)
        let folder = TestFiles.folder("copies")
        let file = try model.exportUnreadableCopy(to: folder)
        #expect(file.lastPathComponent == "\(copy).plist")
        let written = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(written[copy] as? Data == Data("not a list".utf8))
        // asked again: the same file, not overwritten
        #expect(try model.exportUnreadableCopy(to: folder) == file)

        model.startNewTrackedList()
        #expect(model.unreadableTrackedCopy == nil && model.canChangeTracked)
        // an empty list is saved, not no list at all
        #expect(TrackedBlueprintList.read(from: defaults).list.isEmpty && TrackedBlueprintList.read(from: defaults).unreadableCopy == nil)
        #expect(defaults.data(forKey: copy) == Data("not a list".utf8))
        let connection = try #require(model.connections.connectionInUse?.id ?? Optional(UUID()))
        model.add(TrackedBlueprint(connectionID: connection, blueprintID: "bp-1", blueprintName: "Test Blueprint"))
        #expect(defaults.data(forKey: TrackedBlueprintList.key) != nil)
    }

    @Test("A refresh in which no device has a target isn’t worth a snapshot; one with nobody in scope is")
    func notSaved() {
        let unknown = Sample.classify(Sample.mac("1", os: "28.0"), nil,
                                      target: DeviceTarget(reason: "The device runs a beta", unknown: .betaOfNewerMajor))
        #expect(!CategoryCounts([unknown]).isWorthSaving)
        #expect(CategoryCounts([unknown, Sample.classify(Sample.mac("2"), nil)]).isWorthSaving)
        #expect(CategoryCounts([]).isWorthSaving)
    }

    @Test("Start a New List saves an empty list: the next launch doesn’t move the first version’s groups over again")
    @MainActor
    func newListStaysEmpty() throws {
        let defaults = defaults()
        let legacy = [SavedTrackedGroup(id: UUID(), connectionID: UUID(), groupID: "1", groupName: "Group", isSmart: false,
                                        isComputerGroup: false, blueprintID: "bp-1", blueprintName: "Blueprint")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: TrackedBlueprintList.legacyKey)
        defaults.set(Data("not a list".utf8), forKey: TrackedBlueprintList.key)
        let model = DashboardModel(connections: ConnectionsModel.preview(defaults: defaults), history: StatusHistory(folder: TestFiles.folder("new-list")))
        #expect(model.unreadableTrackedCopy != nil)
        model.startNewTrackedList()
        // the app quits before anything is tracked; the next launch:
        let next = TrackedBlueprintList.read(from: defaults)
        #expect(next.list.isEmpty && next.unreadableCopy == nil)
        #expect(defaults.data(forKey: TrackedBlueprintList.legacyKey) != nil)
    }

    @Test("A value that isn’t data is unreadable too, not “nothing saved”")
    func notData() {
        let defaults = defaults()
        defaults.set("text", forKey: TrackedBlueprintList.key)
        let read = TrackedBlueprintList.read(from: defaults)
        #expect(read.unreadableCopy != nil)
        #expect(defaults.string(forKey: TrackedBlueprintList.key) == "text")
    }

    @Test("History folders of Blueprints no longer tracked stay, but lose their old refreshes")
    func pruneEveryFolder() throws {
        let history = StatusHistory(folder: TestFiles.folder("prune"))
        let gone = UUID(), tracked = UUID()
        let now = Sample.date("2026-11-09T12:00:00")
        try history.save(HistorySnapshot(date: now.addingTimeInterval(-200 * 86_400), target: nil, devices: []), for: gone)
        try history.save(HistorySnapshot(date: now.addingTimeInterval(-10 * 86_400), target: nil, devices: []), for: gone)
        try history.save(HistorySnapshot(date: now, target: nil, devices: []), for: tracked)
        #expect(history.snapshots(for: gone).count == 1)
        #expect(FileManager.default.fileExists(atPath: history.folder.appending(path: gone.uuidString).path))
    }

    @Test("The chart marks where the software update, the app’s counting or the scope changed, once per refresh")
    func historyMarks() {
        let day = 86_400.0
        let snapshots = [
            HistorySnapshot(date: Sample.now, target: "Minor updates", devices: [], rules: nil),
            HistorySnapshot(date: Sample.now + day, target: "Minor updates", devices: []),
            HistorySnapshot(date: Sample.now + 2 * day, target: "Version 27.1", devices: []),
            HistorySnapshot(date: Sample.now + 3 * day, target: "Version 27.1", devices: []),
        ]
        let marks = HistoryMark.marks(snapshots)
        #expect(marks.map(\.kinds) == [[.counting], [.rule]])
        #expect(marks.map(\.date) == [Sample.now + day, Sample.now + 2 * day])
        #expect(marks[1].text == "The Blueprint’s software update changed to “Version 27.1”, so earlier counts don’t compare")
        #expect(marks.allSatisfy { !$0.text.contains(":") })

        // the software update and the scope changing in one refresh: one mark
        let a = GroupReference(key: .init(kind: .mobileDevice, groupID: "1"), name: "A", isSmart: false)
        let b = GroupReference(key: .init(kind: .mobileDevice, groupID: "2"), name: "B", isSmart: false)
        let both = HistoryMark.marks([HistorySnapshot(date: Sample.now, target: "Minor updates", devices: [], scope: [a]),
                                      HistorySnapshot(date: Sample.now + day, target: "Version 27.1", devices: [], scope: [a, b])])
        #expect(both.count == 1 && both[0].kinds == [.rule, .scope])
        #expect(both[0].text.contains("scope changed, 1 group added (B)"))
    }
}

@Suite("Refreshing and demo mode")
@MainActor
struct RefreshAndDemoTests {
    /// Apple’s release data that can be switched off.
    final class Source: @unchecked Sendable {
        var catalog: AppleReleases.Catalog?
    }

    private func demoModel(releases: Source? = nil, history: StatusHistory? = nil) -> DashboardModel {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let read: (@Sendable () async throws -> AppleReleases.Catalog)? = releases.map { source in
            { guard let catalog = source.catalog else { throw URLError(.notConnectedToInternet) }; return catalog }
        }
        return DashboardModel(connections: connections, history: history, releases: read)
    }

    @Test("Without Apple’s data the refresh stops, says why, and keeps the previous result and history")
    func keepsPrevious() async throws {
        let source = Source()
        let folder = TestFiles.folder("stop")
        let model = demoModel(releases: source, history: StatusHistory(folder: folder))
        source.catalog = try await model.connections.appleReleases().catalog()
        let tracked = try #require(model.trackedBlueprints.first)
        await model.refresh(tracked.id)
        let before = try #require(model.results[tracked.id])
        let saved = model.snapshots(tracked.id).count

        source.catalog = nil
        model.forgetReleaseData()
        await model.refresh(tracked.id)
        #expect(model.errors[tracked.id]?.contains("Apple’s release data couldn’t be read") == true)
        #expect(model.results[tracked.id]?.date == before.date)
        #expect(model.snapshots(tracked.id).count == saved)
    }

    @Test("Demo mode keeps its history in its own scratch folder")
    func demoHistoryFolder() throws {
        let model = demoModel()
        let folder = try #require(model.history?.folder)
        #expect(folder.path.hasPrefix(model.connections.demo.scratchDirectory.path))
    }

    @Test("Stop Tracking in demo mode removes it from the demo’s list and history only; nothing saved changes")
    func demoRemove() async throws {
        let model = demoModel()
        let tracked = try #require(model.trackedBlueprints.first)
        await model.refresh(tracked.id)
        #expect(model.snapshots(tracked.id).count > 0)
        model.remove(tracked.id)
        #expect(model.tracked(tracked.id) == nil && model.trackedBlueprints.count == 1)
        #expect(model.snapshots(tracked.id).isEmpty)
        #expect(model.connections.defaults.object(forKey: TrackedBlueprintList.key) == nil)
        // a new demo session starts with both again
        model.connectionChanged()
        #expect(model.trackedBlueprints.count == 2)
    }

    @Test("Demo situation: Apple’s release data unreachable stops the refresh and keeps the one before")
    func demoAppleDataUnreachable() async throws {
        let model = demoModel()
        let tracked = try #require(model.trackedBlueprints.first)
        await model.refresh(tracked.id)
        let before = try #require(model.results[tracked.id])
        await model.setDemoSituation(.appleDataUnreachable)
        #expect(model.errors[tracked.id] == AppleDataUnavailable().localizedDescription)
        #expect(model.results[tracked.id]?.date == before.date)
        await model.setDemoSituation(.sampleData)
        #expect(model.errors[tracked.id] == nil)
    }

    @Test("Demo situation: an unreadable saved list shows its banner with a made-up copy, never the real settings")
    func demoUnreadableList() async throws {
        let model = demoModel()
        #expect(model.shownUnreadableCopy == nil && model.canChangeTracked)
        await model.setDemoSituation(.unreadableList)
        let copy = try #require(model.shownUnreadableCopy)
        #expect(!model.canChangeTracked && model.unreadableTrackedCopy == nil)
        let file = try model.exportUnreadableCopy()
        #expect(file.path.hasPrefix(model.connections.demo.scratchDirectory.path) && file.lastPathComponent == "\(copy).plist")
        model.startNewTrackedList()
        #expect(model.shownUnreadableCopy == nil && model.trackedBlueprints.isEmpty && model.canChangeTracked)
        #expect(model.connections.defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(TrackedBlueprintList.key) })
    }

    @Test("A refresh that ends after Demo Mode was switched off is dropped: nothing in either history")
    func switchDuringRefresh() async throws {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let catalog = try await connections.appleReleases().catalog()
        let history = StatusHistory(folder: TestFiles.folder("switch"))
        // Apple's data arrives just after Demo Mode was switched off
        let model = DashboardModel(connections: connections, history: history, releases: {
            await MainActor.run { connections.demo.isOn = false }
            return catalog
        })
        let tracked = try #require(model.trackedBlueprints.first)
        await model.refresh(tracked.id)
        #expect(model.results[tracked.id] == nil && model.errors[tracked.id] == nil)
        #expect(history.snapshots(for: tracked.id).isEmpty)
    }

    @Test("A status report that can’t be read is noted on that device; the others are read")
    func oneUnreadableStatus() async throws {
        let server = MockServer { request in
            request.path.contains("MGMT-2") ? .json(403, "{}") : .json(200, #"{"statusItems":[]}"#)
        }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: StaticToken(),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        let workflow = RefreshWorkflow(client: client, catalog: AppleReleases.Catalog(), serverTimeZone: .gmt)
        let members = ["1", "2", "3"].map { Sample.iPad($0) }
        let inputs = try await workflow.statuses(members) { _, _ in }
        #expect(inputs.map(\.member.id) == ["1", "2", "3"])
        #expect(inputs[1].statusProblem != nil && inputs[1].status == nil)
        #expect(inputs[0].statusProblem == nil && inputs[2].statusProblem == nil)
    }
}
