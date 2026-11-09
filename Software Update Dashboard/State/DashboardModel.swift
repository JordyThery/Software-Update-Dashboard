import Foundation
import JTKit
import Observation

/// What Demo Mode shows besides its sample data, picked in the Blueprint
/// menu: situations the sample data alone never gets into. In memory only.
enum DemoSituation: String, CaseIterable, Identifiable {
    case sampleData = "Sample Data"
    case appleDataUnreachable = "Apple’s Release Data Unreachable"
    case unreadableList = "Saved List Unreadable"

    var id: String { rawValue }
}

/// The tracked Blueprints of the connection in use, their latest refresh and
/// history, and Inspect.
@MainActor
@Observable
final class DashboardModel {
    enum Selection: Hashable {
        case overview
        case blueprint(UUID)
    }

    /// A device of one tracked Blueprint: device numbers repeat across kinds
    /// (a Mac and an iPad can both be 7), so never the number alone.
    struct DeviceKey: Hashable {
        var tracked: UUID
        var device: String
    }

    let connections: ConnectionsModel
    var selection: Selection? = .overview
    private(set) var results: [UUID: RefreshResult] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// “12 of 40 devices”, while a Blueprint refreshes.
    private(set) var progress: [UUID: (done: Int, total: Int)] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var inspections: [DeviceKey: InspectResult] = [:]
    private(set) var inspecting: Set<DeviceKey> = []
    private(set) var inspectError: String?
    /// The saved tracked Blueprints couldn’t be read: where they were copied.
    /// Nothing is saved over them until the app is restarted with a readable list.
    private(set) var unreadableTrackedCopy: String?
    /// Demo Mode’s situation; always sample data outside Demo Mode.
    private(set) var demoSituation: DemoSituation = .sampleData

    @ObservationIgnored private var saved: [TrackedBlueprint]
    /// Demo mode’s two, changed in memory only.
    @ObservationIgnored private var demoTracked: [TrackedBlueprint]?
    @ObservationIgnored private var catalog: (key: String, value: AppleReleases.Catalog, date: Date)?
    @ObservationIgnored private let historyOverride: StatusHistory?
    /// Where Apple’s release data comes from; tests replace it.
    @ObservationIgnored private let releasesOverride: (@Sendable () async throws -> AppleReleases.Catalog)?
    /// Changes when the list changes, so views read it again.
    private var generation = 0

    init(connections: ConnectionsModel, history: StatusHistory? = nil,
         releases: (@Sendable () async throws -> AppleReleases.Catalog)? = nil) {
        self.connections = connections
        historyOverride = history
        releasesOverride = releases
        (saved, unreadableTrackedCopy) = TrackedBlueprintList.read(from: connections.defaults)
    }

    // MARK: Tracked Blueprints

    /// The connection in use’s ID (the demo connection’s in demo mode).
    var connectionID: UUID? { connections.connectionInUse?.id }

    private var isDemo: Bool { connections.demoChoice.isActive }

    /// The tracked Blueprints of the connection in use.
    var trackedBlueprints: [TrackedBlueprint] {
        _ = generation
        guard let connectionID else { return [] }
        if isDemo { return demoTracked ?? TrackedBlueprintList.demo(connectionID: connectionID) }
        return saved.filter { $0.connectionID == connectionID }
    }

    func tracked(_ id: UUID) -> TrackedBlueprint? { trackedBlueprints.first { $0.id == id } }

    func isTracked(blueprintID: String) -> Bool {
        trackedBlueprints.contains { $0.blueprintID == blueprintID }
    }

    func add(_ tracked: TrackedBlueprint) {
        guard !isDemo, canChangeTracked, !isTracked(blueprintID: tracked.blueprintID) else { return }
        saved.append(tracked)
        save()
        selection = .blueprint(tracked.id)
        Task { await refresh(tracked.id) }
    }

    /// Stops tracking a Blueprint and deletes its history. In Demo Mode only
    /// the demo’s list in memory and its history in the demo’s own folder.
    func remove(_ id: UUID) {
        guard canChangeTracked else { return }
        if isDemo {
            demoTracked = trackedBlueprints.filter { $0.id != id }
            generation += 1
        } else {
            saved.removeAll { $0.id == id }
            save()
        }
        history?.remove(id)
        results[id] = nil
        inspections = inspections.filter { $0.key.tracked != id }
        if selection == .blueprint(id) { selection = .overview }
    }

    /// Sets or removes the “Update started” date, then reads again.
    func setUpdateStarted(_ date: Date?, for id: UUID) {
        change(id) { $0.updateStarted = date }
    }

    /// Sets or removes the group to check coverage against, then reads again.
    func setCompareGroup(_ group: GroupReference?, for id: UUID) {
        change(id) { $0.compareGroup = group }
    }

    private func change(_ id: UUID, _ edit: (inout TrackedBlueprint) -> Void) {
        guard canChangeTracked else { return }
        if isDemo {
            var list = trackedBlueprints
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            edit(&list[index])
            demoTracked = list
            generation += 1
        } else {
            guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
            edit(&saved[index])
            save()
        }
        Task { await refresh(id) }
    }

    private func save() {
        if unreadableTrackedCopy == nil { TrackedBlueprintList.save(saved, to: connections.defaults) }
        generation += 1
    }

    /// The unreadable list’s copy as a file (a property list holding the
    /// setting under its dated name), so it can be shown in Finder; written
    /// once, never overwritten.
    func exportUnreadableCopy(to folder: URL? = nil) throws -> URL {
        let key: String, value: Any
        if isDemo {
            // a made-up copy in the demo’s own folder; the real settings stay untouched
            guard demoSituation == .unreadableList else { throw RefreshError("There is no copy of an unreadable list.") }
            (key, value) = (Self.demoUnreadableCopy, "A sample of a list that couldn’t be read")
        } else {
            guard let copy = unreadableTrackedCopy, let saved = connections.defaults.object(forKey: copy) else {
                throw RefreshError("There is no copy of an unreadable list.")
            }
            (key, value) = (copy, saved)
        }
        let folder = try folder ?? (isDemo ? connections.demo.scratchDirectory
            : FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .appending(path: "Unreadable Copies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(key).plist")
        if !FileManager.default.fileExists(atPath: file.path) {
            let data = try PropertyListSerialization.data(fromPropertyList: [key: value], format: .xml, options: 0)
            try data.write(to: file, options: .withoutOverwriting)
        }
        return file
    }

    /// Starts again with an empty list: the unreadable value is removed from
    /// `trackedBlueprints`, its dated copy stays, and changes are saved again.
    func startNewTrackedList() {
        if isDemo {
            guard demoSituation == .unreadableList else { return }
            demoSituation = .sampleData
            demoTracked = []
            generation += 1
            return
        }
        // only while the dated copy is still there: it’s all that’s left of the old list
        guard let copy = unreadableTrackedCopy, connections.defaults.object(forKey: copy) != nil else { return }
        unreadableTrackedCopy = nil
        saved = []
        // an empty list, saved: with no list at all the next launch would
        // move the first version’s tracked groups over again
        save()
    }

    /// Changes to the tracked Blueprints can’t be saved: the saved list couldn’t be read.
    var canChangeTracked: Bool { shownUnreadableCopy == nil }

    /// The unreadable list’s copy the banner names: the real one, or Demo
    /// Mode’s made-up one in its “Saved List Unreadable” situation.
    var shownUnreadableCopy: String? {
        if isDemo { return demoSituation == .unreadableList ? Self.demoUnreadableCopy : nil }
        return unreadableTrackedCopy
    }

    nonisolated static let demoUnreadableCopy = "\(TrackedBlueprintList.key).unreadable-demo"

    // MARK: Demo situations

    /// Switches Demo Mode’s situation and reads every Blueprint again, so
    /// the window shows it straight away.
    func setDemoSituation(_ situation: DemoSituation) async {
        guard isDemo, situation != demoSituation else { return }
        demoSituation = situation
        forgetReleaseData()
        generation += 1
        await refreshAll()
    }

    // MARK: History

    /// Demo mode keeps its history in its own temporary folder; the live
    /// check in its run folder; otherwise the app’s container.
    var history: StatusHistory? {
        if let historyOverride { return historyOverride }
        if isDemo {
            return StatusHistory(folder: connections.demo.scratchDirectory.appending(path: "History", directoryHint: .isDirectory))
        }
        if let folder = LiveLaunch.appFilesFolder("History") { return StatusHistory(folder: folder) }
        if TestRun.isActive { return nil }
        return (try? StatusHistory.standardFolder()).map(StatusHistory.init(folder:))
    }

    func snapshots(_ id: UUID) -> [HistorySnapshot] {
        _ = results[id]?.date
        return history?.snapshots(for: id) ?? []
    }

    /// The latest counts: the refresh in this session, else the newest history.
    func latestCounts(_ id: UUID) -> (counts: CategoryCounts, date: Date, rule: String?)? {
        if let result = results[id] { return (result.counts, result.date, result.rule) }
        return snapshots(id).last.map { ($0.counts, $0.date, $0.target) }
    }

    // MARK: Refresh

    func refreshAll() async {
        for tracked in trackedBlueprints { await refresh(tracked.id) }
    }

    func refresh(_ id: UUID) async {
        guard let tracked = tracked(id), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        errors[id] = nil
        defer {
            refreshing.remove(id)
            progress[id] = nil
        }
        // what this refresh belongs to, taken before the first wait: a switch
        // of Demo Mode or the connection meanwhile drops its result, so
        // nothing lands in the other side’s history
        let key = connections.inUseKey
        let history = history
        let isDemo = isDemo
        do {
            guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
            let catalog = await appleReleases()
            let previous = history?.latest(for: id)
            let workflow = RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: connections.serverTimeZone)
            var result = try await workflow.run(tracked, previousScope: previous?.scope) { done, total in
                Task { @MainActor in self.progress[id] = (done, total) }
            }
            guard connections.inUseKey == key else { return }
            // nothing measured (the banner says so): a snapshot of zero devices would only drop the chart
            if result.counts.isWorthSaving, let history {
                if isDemo && previous == nil { seedDemoHistory(result, in: history) }
                try? history.save(HistorySnapshot(date: result.date, target: result.rule, devices: result.devices, scope: result.scope),
                                  for: id)
            }
            results[id] = result
        } catch is CancellationError {
            if connections.inUseKey == key { errors[id] = "Stopped." }
        } catch {
            if connections.inUseKey == key { errors[id] = error.localizedDescription }
        }
    }

    /// Apple’s release data, read at most once an hour per connection; nil
    /// when it can’t be read (a refresh then stops and keeps the previous one).
    private func appleReleases() async -> AppleReleases.Catalog? {
        let key = connections.inUseKey
        if let catalog, catalog.key == key, Date().timeIntervalSince(catalog.date) < 3_600 { return catalog.value }
        // Demo Mode’s “Apple’s Release Data Unreachable”: as if no source answered
        if isDemo && demoSituation == .appleDataUnreachable { return nil }
        let read: AppleReleases.Catalog?
        if let releasesOverride { read = try? await releasesOverride() } else { read = try? await connections.appleReleases().catalog() }
        guard let fetched = read else { return nil }
        catalog = (key, fetched, Date())
        return fetched
    }

    /// Five made-up earlier days for demo mode, so its chart has a history:
    /// each day back, fewer devices on target. Three days back the software
    /// update was another one and a made-up pilot group joined the scope;
    /// it left a day back: the chart marks both refreshes.
    private func seedDemoHistory(_ result: RefreshResult, in history: StatusHistory) {
        let earlierRule = result.rule.hasPrefix("Version") ? "Minor updates, without delay" : "The newest release, without delay"
        let pilot = GroupReference(key: .init(kind: result.scope.first?.key.kind ?? .mobileDevice, groupID: "699"),
                                   name: "Pilot Devices", isSmart: false)
        for daysAgo in (1...5).reversed() {
            var devices = result.devices
            var onTarget = devices.indices.filter { devices[$0].category == .onTarget }
            var updating = devices.indices.filter { devices[$0].category == .inProgress }
            for _ in 0..<min(daysAgo, onTarget.count) { devices[onTarget.removeLast()].category = .inProgress }
            for _ in 0..<min(daysAgo / 2, updating.count) { devices[updating.removeLast()].category = .notStarted }
            let date = result.date.addingTimeInterval(-Double(daysAgo) * 86_400)
            try? history.save(HistorySnapshot(date: date, target: daysAgo > 3 ? earlierRule : result.rule, devices: devices,
                                              scope: (2...3).contains(daysAgo) ? result.scope + [pilot] : result.scope),
                              for: result.tracked.id)
        }
    }

    // MARK: Inspect

    func inspect(_ devices: [DeviceStatus], in id: UUID) async {
        guard let result = results[id] else { return }
        let ids = Set(devices.map(\.id))
        let keys = Set(ids.map { DeviceKey(tracked: id, device: $0) })
        inspecting.formUnion(keys)
        inspectError = nil
        defer { inspecting.subtract(keys) }
        do {
            guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
            let catalog = await appleReleases()
            let context = InspectContext(blueprintID: result.tracked.blueprintID, blueprintName: result.blueprintName,
                                         target: nil, since: result.blueprintChanged, blueprintChanged: result.blueprintChanged,
                                         now: Date(), serverTimeZone: connections.serverTimeZone, catalog: catalog)
            let members = result.members.filter { ids.contains(RefreshWorkflow.key($0)) }
            for inspection in try await InspectWorkflow(client: client).run(members, rows: result.devices, context: context) {
                inspections[DeviceKey(tracked: id, device: inspection.id)] = inspection
            }
        } catch {
            inspectError = error.localizedDescription
        }
    }

    func inspection(of device: DeviceStatus, in id: UUID) -> InspectResult? {
        inspections[DeviceKey(tracked: id, device: device.id)]
    }

    func isInspecting(_ device: DeviceStatus, in id: UUID) -> Bool {
        inspecting.contains(DeviceKey(tracked: id, device: device.id))
    }

    func isInspecting(in id: UUID) -> Bool {
        inspecting.contains { $0.tracked == id }
    }

    // MARK: Exports

    func csv(_ id: UUID) -> String? {
        guard let result = results[id] else { return nil }
        return CSV.document(header: DeviceStatus.csvColumns, lines: result.devices.map(\.csvLine))
    }

    func summary(_ id: UUID) -> String? {
        guard let result = results[id] else { return nil }
        let previous = StatusSummary.previous(history?.latest(for: id, before: result.date), target: result.rule)
        var notes: [String] = []
        if let change = result.scopeChange { notes.append(change.text) }
        if let coverage = result.coverage {
            notes.append("Compared with \(coverage.group.name): \(coverage.notReached.count) of \(Plural.count(coverage.members, "device")) not reached by the Blueprint")
        }
        if let started = result.tracked.updateStarted {
            notes.append("Update started set by hand: \(started.formatted(date: .abbreviated, time: .shortened))")
        }
        return StatusSummary.text(group: result.blueprintName, devices: result.devices, measuredAgainst: result.rule,
                                  previous: previous, staleDays: 30, date: result.date, notes: notes)
    }

    /// Reads Apple’s release data again at the next refresh.
    func forgetReleaseData() {
        catalog = nil
    }

    /// When the connection in use changes, nothing of the previous one stays.
    func connectionChanged() {
        results = [:]
        errors = [:]
        inspections = [:]
        forgetReleaseData()
        demoTracked = nil
        demoSituation = .sampleData
        selection = .overview
    }
}

struct RefreshError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
