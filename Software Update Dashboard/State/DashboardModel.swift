import AppKit
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
    /// Notifications per tracked Blueprint, after each refresh.
    let notifier: Notifier
    var selection: Selection? = .overview
    private(set) var results: [UUID: RefreshResult] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// “12 of 40 devices”, while a Blueprint refreshes.
    private(set) var progress: [UUID: RefreshProgress] = [:]
    /// The refresh of each tracked Blueprint that is running, so Stop can end it.
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var inspections: [DeviceKey: InspectResult] = [:]
    private(set) var inspecting: Set<DeviceKey> = []
    private(set) var inspectError: String?
    /// The saved tracked Blueprints couldn’t be read: where they were copied.
    /// Nothing is saved over them until the app is restarted with a readable list.
    private(set) var unreadableTrackedCopy: String?
    /// Demo Mode’s situation; always sample data outside Demo Mode.
    private(set) var demoSituation: DemoSituation = .sampleData
    /// The history in memory (`snapshots`, `newestSaved`), and per Blueprint
    /// the refresh saved before this session’s latest, for the summary.
    private(set) var historyEntries: [UUID: [HistoryEntry]] = [:]
    private var newestSnapshots: [UUID: HistorySnapshot] = [:]
    private var previousSnapshots: [UUID: HistorySnapshot] = [:]
    /// Jamf Pro pages waiting for a yes: more than `JamfProPages.askAbove` at once.
    var pagesToConfirm: [URL]?
    /// Demo Mode: the pages that would have opened, shown instead.
    var demoPages: [URL]?
    /// Opens a page in the browser; tests replace it.
    @ObservationIgnored var openPage: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @ObservationIgnored private var saved: [TrackedBlueprint]
    /// Demo mode’s two, changed in memory only.
    @ObservationIgnored private var demoTracked: [TrackedBlueprint]?
    @ObservationIgnored private var catalog: (key: String, value: AppleReleases.Catalog, date: Date)?
    /// Demo Mode’s first public posting dates (`FirstPostings`), in memory only.
    @ObservationIgnored private var demoFirstPostings: [String: Date] = [:]
    @ObservationIgnored private let historyOverride: StatusHistory?
    /// Where Apple’s release data comes from; tests replace it.
    @ObservationIgnored private let releasesOverride: (@Sendable () async throws -> AppleReleases.Catalog)?
    /// Changes when the list changes, so views read it again.
    private var generation = 0

    init(connections: ConnectionsModel, history: StatusHistory? = nil,
         releases: (@Sendable () async throws -> AppleReleases.Catalog)? = nil) {
        self.connections = connections
        notifier = Notifier(defaults: connections.defaults, activityLog: connections.activityLog)
        historyOverride = history
        releasesOverride = releases
        (saved, unreadableTrackedCopy) = TrackedBlueprintList.read(from: connections.defaults)
        // the history into memory now and after every change of connection, also without a window open
        Task { [weak self] in await self?.followConnection() }
    }

    /// Loads the history, then waits for the connection in use to change:
    /// then starts over for the new one (`connectionChanged`).
    private func followConnection() async {
        var key = connections.inUseKey
        await loadHistory()
        while !Task.isCancelled {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = connections.inUseKey } onChange: { done.resume() }
            }
            // the change is told before it is made: read it on the next turn
            await Task.yield()
            guard connections.inUseKey != key else { continue }
            key = connections.inUseKey
            connectionChanged()
            await loadHistory()
        }
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
        if let history { Task.detached(priority: .utility) { history.remove(id) } }
        historyEntries[id] = nil
        newestSnapshots[id] = nil
        previousSnapshots[id] = nil
        if !isDemo { notifier.remove(id) }
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
        // the demo's own release feeds fail, as Apple's would
        connections.demo.appleReleaseServer.isUnreachable = situation == .appleDataUnreachable
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

    /// Every saved refresh’s counts, oldest first, for the chart: from
    /// memory, loaded off the main thread (`loadHistory`) and kept up to date
    /// on every save. Never decodes full refreshes.
    func snapshots(_ id: UUID) -> [HistoryEntry] {
        historyEntries[id] ?? []
    }

    /// The newest saved refresh of a tracked Blueprint, with its devices:
    /// from memory, until the next save.
    func newestSaved(_ id: UUID) -> HistorySnapshot? {
        newestSnapshots[id]
    }

    /// Reads the counts and the newest refresh of every tracked Blueprint
    /// off the main thread; what a refresh of this session saved since stays.
    func loadHistory() async {
        guard let history else {
            historyEntries = [:]
            newestSnapshots = [:]
            return
        }
        let key = connections.inUseKey
        let ids = trackedBlueprints.map(\.id)
        let loaded = await Task.detached(priority: .utility) {
            ids.map { id in (id, history.entries(for: id), history.latest(for: id)) }
        }.value
        guard connections.inUseKey == key else { return }
        for (id, entries, newest) in loaded where results[id] == nil {
            historyEntries[id] = entries
            newestSnapshots[id] = newest
        }
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

    /// Refreshes a tracked Blueprint; `stopRefresh` can end it.
    func refresh(_ id: UUID) async {
        guard tracked(id) != nil, !refreshing.contains(id) else { return }
        let task = Task { await read(id) }
        running[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running[id] = nil
    }

    /// Stops the refresh of a tracked Blueprint; the previous one stays.
    func stopRefresh(_ id: UUID) {
        running[id]?.cancel()
    }

    private func read(_ id: UUID) async {
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
            // stopped while Apple's data was read: a stop, not unreachable data
            try Task.checkCancellation()
            // the refresh before, off the main thread (one file, by its name), unless it is in memory
            let previous: HistorySnapshot?
            if let newest = newestSnapshots[id] { previous = newest }
            else if let history { previous = await Task.detached(priority: .utility) { history.latest(for: id) }.value }
            else { previous = nil }
            var workflow = RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: connections.serverTimeZone)
            if let catalog { workflow.firstPosted = firstPostings(catalog, demo: isDemo) }
            var result = try await workflow.run(tracked, previousScope: previous?.scope) { step in
                Task { @MainActor in if self.refreshing.contains(id) { self.progress[id] = step } }
            }
            guard connections.inUseKey == key else { return }
            // nothing measured (the banner says so): a snapshot of zero devices would only drop the chart
            if result.counts.isWorthSaving, let history {
                let seeds = isDemo && previous == nil ? demoHistory(result) : []
                let snapshot = HistorySnapshot(date: result.date, target: result.rule, ruleKey: result.ruleKey, devices: result.devices,
                                               scope: result.scope)
                // saved and read back off the main thread
                let entries = await Task.detached(priority: .utility) {
                    for seed in seeds { try? history.save(seed, for: id) }
                    try? history.save(snapshot, for: id)
                    return history.entries(for: id)
                }.value
                guard connections.inUseKey == key else { return }
                historyEntries[id] = entries
                newestSnapshots[id] = snapshot
            }
            previousSnapshots[id] = previous
            // what changed since the refresh before (this session's, else the history's): never on the first
            let before = results[id]?.devices ?? previous?.devices
            notifier.post(RefreshNotices.between(previous: before, current: result.devices, rule: notifier.rule(for: id, demo: isDemo),
                                                 name: tracked.blueprintName),
                          demo: isDemo)
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
        let read: AppleReleases.Catalog?
        if let releasesOverride { read = try? await releasesOverride() } else { read = try? await connections.appleReleases().catalog() }
        guard let fetched = read else { return nil }
        catalog = (key, fetched, Date())
        return fetched
    }

    /// The first public posting date seen of each build, with the catalog’s
    /// new ones added: saved, or in memory only in Demo Mode.
    private func firstPostings(_ catalog: AppleReleases.Catalog, demo: Bool) -> [String: Date] {
        guard demo else { return FirstPostings.remember(catalog, in: connections.defaults) }
        demoFirstPostings = FirstPostings.merged(demoFirstPostings, with: catalog)
        return demoFirstPostings
    }

    /// Five earlier days for demo mode, from JTKit’s samples
    /// (`DemoSoftwareUpdate.pastRefreshes`), so its chart has a history:
    /// each day back, fewer devices on target; four and five days back the
    /// software update was another one, and two and three days back a pilot
    /// group was in the scope too. The chart marks those refreshes.
    private func demoHistory(_ result: RefreshResult) -> [HistorySnapshot] {
        var seeds: [HistorySnapshot] = []
        for past in DemoSoftwareUpdate.pastRefreshes(now: result.date)
        where past.blueprintID.lowercased() == result.tracked.blueprintID.lowercased() {
            let block = JamfPlatform.SoftwareUpdateBlock(stepIndex: 0, componentIndex: 0, enforcement: past.enforcement)
            var devices = result.devices
            for index in devices.indices where devices[index].category == .onTarget && !past.onTarget.contains(Int(devices[index].jamfID) ?? -1) {
                devices[index].category = .inProgress
            }
            let date = result.date.addingTimeInterval(-Double(past.daysAgo) * 86_400)
            seeds.append(HistorySnapshot(date: date, target: RefreshWorkflow.rule([block]), ruleKey: RefreshWorkflow.ruleKey([block]),
                                         devices: devices, scope: result.scope + (past.extraScopeGroup.map { [GroupReference($0)] } ?? [])))
        }
        return seeds
    }

    // MARK: Status items

    /// Every status item of one device, read now (not kept: neither here
    /// nor in the history). Empty when Jamf Pro has no report for it.
    func statusItems(of device: DeviceStatus, in id: UUID) async throws -> [JamfPro.StatusItem] {
        guard let managementID = device.managementID, !managementID.isEmpty else {
            throw RefreshError("The device has no management ID in Jamf Pro, so its status report can’t be read.")
        }
        guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
        let items = try await client.statusItems(managementID: managementID, kind: device.isComputer ? .computer : .mobileDevice) ?? []
        return items.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    // MARK: Report as PDF

    /// The PDF report of these tracked Blueprints (all when nil), from their
    /// last refresh in this session and their history; nothing is read from Jamf.
    func reportPDF(_ ids: [UUID]? = nil, created: Date = Date()) -> Data {
        let chosen = ids.map { wanted in trackedBlueprints.filter { wanted.contains($0.id) } } ?? trackedBlueprints
        let parts = chosen.map { ReportPDF.Part(tracked: $0, result: results[$0.id], saved: newestSaved($0.id), snapshots: snapshots($0.id)) }
        return ReportPDF.make(parts, demo: isDemo, created: created)
    }

    /// The report’s file name: the Blueprint’s or “All Blueprints”, the day, and Demo in Demo Mode.
    func reportName(_ id: UUID?, day: Date = Date()) -> String {
        let name = id.flatMap { tracked($0)?.blueprintName } ?? "All Blueprints"
        return "\(name) Report \(day.formatted(.iso8601.year().month().day()))\(isDemo ? " (Demo)" : "").pdf"
    }

    // MARK: Find a device

    /// What Find a Device searches: each tracked Blueprint’s refresh of this
    /// session, else the newest in its history. Nothing is read from Jamf.
    func searchSources() -> [DeviceSearch.Source] {
        trackedBlueprints.map { tracked in
            if let result = results[tracked.id] { return DeviceSearch.Source(tracked: tracked, devices: result.devices, date: result.date) }
            let last = newestSaved(tracked.id)
            return DeviceSearch.Source(tracked: tracked, devices: last?.devices ?? [], date: last?.date)
        }
    }

    /// A device the device list is asked to show and select (Find a Device).
    var deviceToShow: DeviceKey?

    /// Opens a device in its Blueprint’s device list.
    func show(_ match: DeviceSearch.Match) {
        selection = .blueprint(match.trackedID)
        deviceToShow = DeviceKey(tracked: match.trackedID, device: match.device.id)
    }

    // MARK: Open in Jamf Pro

    /// The devices’ pages in Jamf Pro; empty without a web address.
    func pages(of devices: [DeviceStatus]) -> [URL] {
        devices.compactMap { JamfProPages.device($0, base: connections.jamfProWebAddress) }
    }

    /// The tracked Blueprint’s page in Jamf Pro; nil without a web address.
    func page(of id: UUID) -> URL? {
        tracked(id).flatMap { JamfProPages.blueprint(id: $0.blueprintID, base: connections.jamfProWebAddress) }
    }

    /// Opens the pages in the browser: asks first above `JamfProPages.askAbove`
    /// unless `confirmed`; in Demo Mode shows them instead. Nothing is sent to Jamf.
    func open(_ urls: [URL], confirmed: Bool = false) {
        guard !urls.isEmpty else { return }
        if !confirmed && urls.count > JamfProPages.askAbove {
            pagesToConfirm = urls
            return
        }
        pagesToConfirm = nil
        if isDemo {
            demoPages = urls
            return
        }
        urls.forEach(openPage)
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
                                         now: Date(), serverTimeZone: connections.serverTimeZone, catalog: catalog,
                                         current: result.health?.current)
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
        // the refresh saved before this one, kept in memory by the refresh (no reading here)
        let previous = StatusSummary.previous(previousSnapshots[id], target: result.rule, ruleKey: result.ruleKey)
        var notes: [String] = []
        if let change = result.scopeChange { notes.append(change.text) }
        if let line = BlueprintHealth.dashboardLine(result.notCoveredCount) { notes.append(line) }
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
        historyEntries = [:]
        newestSnapshots = [:]
        previousSnapshots = [:]
        errors = [:]
        inspections = [:]
        forgetReleaseData()
        demoTracked = nil
        demoSituation = .sampleData
        connections.demo.appleReleaseServer.isUnreachable = false
        selection = .overview
    }
}

struct RefreshError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
