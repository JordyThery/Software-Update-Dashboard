import Foundation
import JTKit
import Observation

/// The content caches of the connection in use: the latest sweep and the
/// trend of every cache, read with JTKit’s `ContentCacheRules.Sweep` (GET
/// only) and kept in `ContentCaches/<connection ID>/` (`CacheArchive`). Demo
/// Mode keeps its sweeps in memory, seeded with ten days of sample history.
@MainActor
@Observable
final class CachesModel {
    let connections: ConnectionsModel
    private(set) var latest: CacheSweepRecord?
    /// Every cache of every sweep, oldest first.
    private(set) var trend: [ContentCacheRules.CacheSnapshot] = [] {
        didSet { deltas = ContentCacheRules.Series.deltas(trend) }
    }
    /// What each cache did between two sweeps.
    private(set) var deltas: [ContentCacheRules.Delta] = []
    private(set) var isSweeping = false
    /// “Reading the computer inventory, 3 of 25 pages”, while a sweep runs.
    private(set) var progress: RefreshProgress?
    /// Why the last sweep stopped; nil when it didn’t.
    private(set) var error: String?
    /// Which caches the table shows (the toolbar and View menu).
    var filter: CacheFilter = .all
    /// The site the table shows, from a Blueprint’s “by site” line; nil: every site.
    var siteFilter: SiteFilter?

    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private let archiveOverride: CacheArchive?
    /// Demo Mode’s Blueprints without a caching declaration, in memory.
    @ObservationIgnored private var demoKnown: [String: String] = [:]

    init(connections: ConnectionsModel, archive: CacheArchive? = nil) {
        self.connections = connections
        archiveOverride = archive
    }

    private var isDemo: Bool { connections.demoChoice.isActive }

    /// Where the connection in use keeps its sweeps: the live check’s run
    /// folder under the live-check switch; none in Demo Mode or under tests
    /// (in memory); otherwise the app’s container.
    var archive: CacheArchive? {
        if let archiveOverride { return archiveOverride }
        guard !isDemo, let id = connections.connectionInUse?.id else { return nil }
        if let folder = LiveLaunch.appFilesFolder(CacheArchive.folderName) {
            return CacheArchive(folder: folder.appending(path: id.uuidString, directoryHint: .isDirectory))
        }
        if TestRun.isActive { return nil }
        return (try? CacheArchive.standardFolder(connectionID: id)).map(CacheArchive.init(folder:))
    }

    /// The last sweep found at least one cache.
    var hasCaches: Bool { !(latest?.caches.isEmpty ?? true) }

    // MARK: Loading

    /// Reads the newest sweep and the trend off the main thread.
    func load() async {
        guard let archive else { return }
        let key = connections.inUseKey
        let (record, trend) = await Task.detached(priority: .utility) { (archive.latest(), archive.trend()) }.value
        guard connections.inUseKey == key, !isSweeping else { return }
        latest = record
        self.trend = trend
    }

    /// When the connection in use changes, nothing of the previous one stays.
    func connectionChanged() {
        running?.cancel()
        latest = nil
        trend = []
        error = nil
        progress = nil
        siteFilter = nil
        filter = .all
        demoKnown = [:]
    }

    // MARK: Sweeping

    /// One sweep of the connection in use; `stop` ends it, and so does
    /// cancelling the caller (Stop in the automatic refresh).
    func sweep() async {
        guard !isSweeping, connections.connectionInUse != nil else { return }
        let task = Task { await read() }
        running = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running = nil
    }

    func stop() {
        running?.cancel()
    }

    private func read() async {
        isSweeping = true
        error = nil
        defer {
            isSweeping = false
            progress = nil
        }
        // a switch of Demo Mode or the connection meanwhile drops the result
        let key = connections.inUseKey
        let isDemo = isDemo
        let archive = archive
        let serverTimeZone = connections.serverTimeZone
        do {
            guard let client = try connections.client() else { throw RefreshError("No connection in use.") }
            var sweep = ContentCacheRules.Sweep(client: client)
            sweep.serverTimeZone = serverTimeZone
            let known: [String: String]
            if isDemo { known = demoKnown }
            else if let archive { known = await Task.detached(priority: .utility) { archive.knownBlueprints() }.value }
            else { known = [:] }
            let result = try await sweep.read(skipping: known) { step in
                Task { @MainActor in if self.isSweeping { self.progress = step } }
            }
            guard connections.inUseKey == key else { return }
            let record = CacheSweepRecord(result, serverTimeZone: serverTimeZone)
            let snapshots = result.snapshots
            if isDemo {
                // the sample history, measured from when the demo servers started, so it follows on without a reset
                if trend.isEmpty { trend = DemoContentCaching.pastSweeps(now: connections.demoStarted) }
                trend += snapshots
                demoKnown = result.notCaching
            } else if let archive {
                let notCaching = result.notCaching
                let saved = await Task.detached(priority: .utility) { () -> [ContentCacheRules.CacheSnapshot]? in
                    do {
                        try archive.save(record, snapshots: snapshots)
                        try archive.saveKnownBlueprints(notCaching)
                        return archive.trend()
                    } catch {
                        return nil
                    }
                }.value
                guard connections.inUseKey == key else { return }
                trend = saved ?? trend + snapshots
            } else {
                trend += snapshots
            }
            latest = record
        } catch is CancellationError {
            if connections.inUseKey == key { error = "Stopped." }
        } catch {
            if connections.inUseKey == key { self.error = error.localizedDescription }
        }
    }

    // MARK: What the views show

    /// A cache’s savings over the last `days` days, from the trend; nil
    /// when the trend doesn’t reach that far back yet.
    func savings(of cacheID: String, days: Int, now: Date = Date()) -> Int64? {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        guard let first = trend.first(where: { $0.cacheID == cacheID }), first.date <= since.addingTimeInterval(86_400) else { return nil }
        return ContentCacheRules.Series.total(deltas, since: since, cacheID: cacheID).saved
    }

    /// One cache’s deltas, oldest first.
    func deltas(of cacheID: String) -> [ContentCacheRules.Delta] {
        deltas.filter { $0.cacheID == cacheID }
    }

    /// For a Blueprint’s devices: each site they are in, with the worst
    /// health of that site’s caches and how many there are (0: no cache).
    /// Devices without a site count as “No site”. Empty when the last sweep
    /// found no cache (the line isn’t shown then).
    func sites(of devices: [DeviceStatus]) -> [SiteCaches] {
        guard let latest, !latest.caches.isEmpty else { return [] }
        let sites = Set(devices.map(\.siteName))
        return sites.map { site in
            let caches = latest.caches.filter { $0.site == site }
            return SiteCaches(site: site, devices: devices.filter { $0.siteName == site }.count, caches: caches.count,
                              worst: ContentCacheRules.CacheHealth.worst(of: caches.map(\.health)))
        }
        .sorted { ($0.site ?? "\u{10FFFF}").localizedStandardCompare($1.site ?? "\u{10FFFF}") == .orderedAscending }
    }
}

/// Which caches the Content Caches table shows.
enum CacheFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case attention = "Needs Attention"
    /// Activated, and no caching Blueprint reaches it (`isUnplanned`): also a
    /// cache set up with a configuration profile or by hand.
    case unplanned = "No Caching Blueprint"
    var id: String { rawValue }

    /// The View menu’s name.
    var menuTitle: String {
        switch self {
        case .all: "All Caches"
        case .attention: "Caches Needing Attention"
        case .unplanned: "Caches Without a Caching Blueprint"
        }
    }
}

/// A site chosen for the Caches table (`site` nil: caches without a site).
nonisolated struct SiteFilter: Hashable, Sendable {
    var site: String?
    var name: String { site ?? "No site" }
}

/// One site of a Blueprint’s devices and its content caches.
nonisolated struct SiteCaches: Hashable, Sendable, Identifiable {
    var site: String?
    var devices: Int
    var caches: Int
    var worst: ContentCacheRules.CacheHealth.Level?

    var id: String { site ?? "" }
    var name: String { site ?? "No site" }
}
