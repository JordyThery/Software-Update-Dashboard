import Foundation
import JTKit
import Observation

/// The tracked groups of the connection in use, their latest refresh and
/// history, and Inspect.
@MainActor
@Observable
final class DashboardModel {
    enum Selection: Hashable {
        case overview
        case group(UUID)
    }

    let connections: ConnectionsModel
    var selection: Selection? = .overview
    private(set) var results: [UUID: RefreshResult] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// “12 of 40 devices”, while a group refreshes.
    private(set) var progress: [UUID: String] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var inspections: [String: InspectResult] = [:]
    private(set) var inspecting: Set<String> = []
    private(set) var inspectError: String?

    @ObservationIgnored private var savedGroups: [TrackedGroup]
    @ObservationIgnored private var catalog: (key: String, value: AppleReleases.Catalog, date: Date)?
    @ObservationIgnored private let historyOverride: StatusHistory?
    /// Changes when the saved groups change, so views read them again.
    private var groupsGeneration = 0

    init(connections: ConnectionsModel, history: StatusHistory? = nil) {
        self.connections = connections
        historyOverride = history
        savedGroups = TrackedGroupList.load(from: connections.defaults)
    }

    // MARK: Groups

    /// The connection in use’s ID (the demo connection’s in demo mode).
    var connectionID: UUID? { connections.connectionInUse?.id }

    /// The tracked groups of the connection in use.
    var groups: [TrackedGroup] {
        _ = groupsGeneration
        guard let connectionID else { return [] }
        if connections.demoChoice.isActive { return TrackedGroupList.demo(connectionID: connectionID) }
        return savedGroups.filter { $0.connectionID == connectionID }
    }

    func group(_ id: UUID) -> TrackedGroup? { groups.first { $0.id == id } }

    func add(_ group: TrackedGroup) {
        guard !connections.demoChoice.isActive else { return }
        savedGroups.append(group)
        TrackedGroupList.save(savedGroups, to: connections.defaults)
        groupsGeneration += 1
        selection = .group(group.id)
        Task { await refresh(group.id) }
    }

    func remove(_ id: UUID) {
        guard !connections.demoChoice.isActive else { return }
        savedGroups.removeAll { $0.id == id }
        TrackedGroupList.save(savedGroups, to: connections.defaults)
        history?.remove(id)
        results[id] = nil
        groupsGeneration += 1
        if selection == .group(id) { selection = .overview }
    }

    // MARK: History

    /// Demo mode keeps its history in its own temporary folder; the live
    /// check in its run folder; otherwise the app’s container.
    var history: StatusHistory? {
        if let historyOverride { return historyOverride }
        if connections.demoChoice.isActive {
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

    /// The latest counts of a group: its refresh in this session, else its newest history.
    func latestCounts(_ id: UUID) -> (counts: CategoryCounts, date: Date, target: String?)? {
        if let result = results[id] { return (result.counts, result.date, result.target?.description) }
        return snapshots(id).last.map { ($0.counts, $0.date, $0.target) }
    }

    // MARK: Refresh

    func refreshAll() async {
        for group in groups { await refresh(group.id) }
    }

    func refresh(_ id: UUID) async {
        guard let group = group(id), !refreshing.contains(id) else { return }
        refreshing.insert(id)
        errors[id] = nil
        defer {
            refreshing.remove(id)
            progress[id] = nil
        }
        do {
            guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
            let catalog = await appleReleases()
            let workflow = RefreshWorkflow(client: client, catalog: catalog, serverTimeZone: connections.serverTimeZone)
            let result = try await workflow.run(group) { done, total in
                Task { @MainActor in self.progress[id] = "\(done) of \(total) devices" }
            }
            let previous = history?.latest(for: id)
            if let history {
                if connections.demoChoice.isActive && previous == nil { seedDemoHistory(result, in: history) }
                try? history.save(HistorySnapshot(date: result.date, target: result.target?.description, devices: result.devices), for: id)
            }
            results[id] = result
        } catch is CancellationError {
            errors[id] = "Stopped."
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    /// Apple’s release data, read at most once an hour per connection.
    private func appleReleases() async -> AppleReleases.Catalog? {
        let key = connections.inUseKey
        if let catalog, catalog.key == key, Date().timeIntervalSince(catalog.date) < 3_600 { return catalog.value }
        guard let fetched = try? await connections.appleReleases().catalog() else { return nil }
        catalog = (key, fetched, Date())
        return fetched
    }

    /// Five made-up earlier days for demo mode, so its chart has a history:
    /// each day back, fewer devices on target.
    private func seedDemoHistory(_ result: RefreshResult, in history: StatusHistory) {
        for daysAgo in (1...5).reversed() {
            var devices = result.devices
            var onTarget = devices.indices.filter { devices[$0].category == .onTarget }
            var updating = devices.indices.filter { devices[$0].category == .inProgress }
            for _ in 0..<min(daysAgo, onTarget.count) { devices[onTarget.removeLast()].category = .inProgress }
            for _ in 0..<min(daysAgo / 2, updating.count) { devices[updating.removeLast()].category = .notStarted }
            let date = result.date.addingTimeInterval(-Double(daysAgo) * 86_400)
            try? history.save(HistorySnapshot(date: date, target: result.target?.description, devices: devices), for: result.group.id)
        }
    }

    // MARK: Inspect

    func inspect(_ devices: [DeviceStatus], in id: UUID) async {
        guard let result = results[id] else { return }
        let ids = Set(devices.map(\.id))
        inspecting.formUnion(ids)
        inspectError = nil
        defer { inspecting.subtract(ids) }
        do {
            guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
            let catalog = await appleReleases()
            let context = InspectContext(
                blueprintID: result.group.blueprintID, target: result.target, since: result.since, now: Date(),
                serverTimeZone: connections.serverTimeZone, majors: catalog?.majors(result.group.platform) ?? [],
                supports: { model, board, major in catalog?.supports(model: model, boardID: board, major: major, result.group.platform) })
            let members = result.members.filter { ids.contains($0.id) }
            for inspection in try await InspectWorkflow(client: client).run(members, rows: result.devices, context: context) {
                inspections[inspection.id] = inspection
            }
        } catch {
            inspectError = error.localizedDescription
        }
    }

    // MARK: Exports

    func csv(_ id: UUID) -> String? {
        guard let result = results[id] else { return nil }
        return CSV.document(header: DeviceStatus.csvColumns, lines: result.devices.map(\.csvLine))
    }

    func summary(_ id: UUID) -> String? {
        guard let result = results[id] else { return nil }
        let previous = StatusSummary.previous(history?.latest(for: id, before: result.date), target: result.target?.description)
        return StatusSummary.text(group: result.group.groupName, devices: result.devices, target: result.target?.description,
                                  osName: result.osName, previous: previous, staleDays: 30, date: result.date)
    }

    /// When the connection in use changes, nothing of the previous one stays.
    func connectionChanged() {
        results = [:]
        errors = [:]
        inspections = [:]
        catalog = nil
        selection = .overview
    }
}

struct RefreshError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
