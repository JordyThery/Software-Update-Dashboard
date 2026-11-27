import Foundation
import JTKit

/// One sweep of a connection’s content caches as the app keeps it: what the
/// Caches view shows, from JTKit’s `ContentCacheRules.Sweep.Result`.
nonisolated struct CacheSweepRecord: Codable, Hashable, Sendable {
    var date: Date
    /// Every activated cache, by name.
    var caches: [CacheRow]
    var blueprints: [CachingBlueprintRow]
    /// Macs in the inventory, caches or not, and the inventory pages read.
    var computersRead: Int
    var inventoryPages: Int
    /// What couldn’t be read; the rest of the sweep stands.
    var problems: [String]

    var unplanned: [CacheRow] { caches.filter(\.isUnplanned) }

    /// The worst health of the caches in each site; caches without a site under nil.
    var healthBySite: [String?: ContentCacheRules.CacheHealth.Level] {
        Dictionary(grouping: caches, by: \.site).compactMapValues { ContentCacheRules.CacheHealth.worst(of: $0.map(\.health)) }
    }
}

/// One cache, as the table and its detail show it.
nonisolated struct CacheRow: Codable, Hashable, Sendable, Identifiable {
    nonisolated struct Category: Codable, Hashable, Sendable {
        var name: String
        var bytes: Int64
        var isPersonal: Bool { name.caseInsensitiveCompare("iCloud") == .orderedSame }
    }

    /// A parent or a peer.
    nonisolated struct Neighbor: Codable, Hashable, Sendable {
        var address: String?
        var port: Int?
        var isHealthy: Bool?
        var isFriendly: Bool?
        var version: String?
    }

    nonisolated struct Alert: Codable, Hashable, Sendable {
        var name: String
        var posted: Date?
    }

    /// Jamf Pro’s computer ID: the cache’s identity across sweeps.
    var id: String
    var name: String
    var serial: String?
    var managementID: String?
    var site: String?
    var osVersion: String?
    var model: String?
    var lastContact: Date?
    /// The inventory report the figures are from.
    var reportDate: Date?
    var health: ContentCacheRules.CacheHealth
    var isActive: Bool?
    var cacheStatus: String?
    var startupStatus: String?
    /// “Registered”, “Pending” or “Failed”.
    var registration: String?
    var registrationError: String?
    var used: Int64?
    var free: Int64?
    /// Nil: no limit.
    var limit: Int64?
    var personalUsed: Int64?
    var pressure: Int?
    var categories: [Category]
    var savings: ContentCacheRules.Savings
    var parents: [Neighbor]
    /// From macOS 27’s status items; nil without them.
    var peers: [Neighbor]?
    var alerts: [Alert]
    var declarations: [ContentCacheRules.DeclarationState]
    var isUnplanned: Bool
    /// When the Mac last sent its live figures (`content-cache.info`); nil when it doesn’t.
    var liveFigures: Date?
    /// When it last sent `content-cache.status`; nil before macOS 27.
    var statusUpdated: Date?
    var statusProblem: String?

    /// The largest category that isn’t personal (iCloud).
    var topCategory: Category? { categories.filter { !$0.isPersonal && $0.bytes > 0 }.max { $0.bytes < $1.bytes } }

    /// The shared cache in use against its limit, 0 to 1; nil without a limit.
    var usedShare: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(Double(used) / Double(limit), 1)
    }
}

/// A Blueprint that sends Apple’s content caching declaration.
nonisolated struct CachingBlueprintRow: Codable, Hashable, Sendable, Identifiable {
    /// What it sets (one declaration applies per Mac; the first is shown).
    nonisolated struct Settings: Codable, Hashable, Sendable {
        var cacheLimit: Int64?
        var personalCacheLimit: Int64?
        var parents: [String]?
        var allowPersonalCaching: Bool?
        var allowSharedCaching: Bool?
        var autoActivation: Bool?
        /// Seconds between live figures; nil or 0: none.
        var statusInterval: Int?
    }

    nonisolated struct Configured: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var site: String?
        var isActivated: Bool
        var declaration: ContentCacheRules.DeclarationState.State
    }

    var id: String
    var name: String
    var settings: Settings?
    var configured: [Configured]

    var activated: Int { configured.filter(\.isActivated).count }
    var applied: Int { configured.filter { $0.declaration == .applied }.count }
    /// Configured Macs that aren’t activated.
    var notActivated: [Configured] { configured.filter { !$0.isActivated } }
}

// MARK: - From JTKit’s sweep

extension CacheSweepRecord {
    /// The record of a sweep. Status item times are the Jamf Pro server’s local time.
    init(_ result: ContentCacheRules.Sweep.Result, serverTimeZone: TimeZone) {
        func time(_ text: String?) -> Date? { text.flatMap { JamfPro.serverDate($0, timeZone: serverTimeZone) } }
        date = result.date
        computersRead = result.computersRead
        inventoryPages = result.inventoryPages
        problems = result.problems
        blueprints = result.cachingBlueprints.map { blueprint in
            let first = blueprint.settings.first
            return CachingBlueprintRow(
                id: blueprint.id, name: blueprint.name,
                settings: first.map {
                    CachingBlueprintRow.Settings(cacheLimit: $0.cacheLimit, personalCacheLimit: $0.personalCacheLimit,
                                                 parents: $0.parents, allowPersonalCaching: $0.allowPersonalCaching,
                                                 allowSharedCaching: $0.allowSharedCaching, autoActivation: $0.autoActivation,
                                                 statusInterval: $0.declarativeStatusInterval)
                },
                configured: blueprint.configured.map {
                    CachingBlueprintRow.Configured(id: $0.id, name: $0.name ?? $0.serialNumber ?? "Mac \($0.id)", site: $0.siteName,
                                                   isActivated: $0.isActivated, declaration: $0.declaration)
                })
        }
        caches = result.caches.map { record in
            let caching = record.caching
            let status = record.status
            let live = status?.status
            let info = status?.info
            let liveNewer = time(info?.updated).map { date in record.reportDate.map { date > $0 } ?? true } ?? false
            let registration: String? = switch caching.registration {
            case .succeeded?: "Registered"
            case .pending?: "Pending"
            case .failed?: "Failed"
            case .other(let raw)?: raw
            case nil: nil
            }
            let categories = (liveNewer && !(info?.categories.isEmpty ?? true) ? info?.categories : nil) ?? caching.categories
            return CacheRow(
                id: record.id, name: record.name ?? record.serialNumber ?? "Mac \(record.id)", serial: record.serialNumber,
                managementID: record.managementID, site: record.siteName, osVersion: record.osVersion, model: record.model,
                lastContact: record.lastContact, reportDate: record.reportDate, health: record.health,
                isActive: live?.isActive ?? caching.isActive, cacheStatus: live?.cacheStatus ?? caching.cacheStatus,
                startupStatus: live?.startupStatus ?? caching.startupStatus, registration: registration,
                registrationError: caching.registrationError,
                used: liveNewer ? info?.cacheUsed ?? caching.cacheUsed : caching.cacheUsed,
                free: liveNewer ? info?.cacheFree ?? caching.cacheFree : caching.cacheFree,
                limit: liveNewer ? info?.cacheLimit ?? caching.cacheLimit : caching.cacheLimit,
                personalUsed: liveNewer ? info?.personalUsed ?? caching.personalUsed : caching.personalUsed,
                pressure: liveNewer ? info?.pressurePercent ?? caching.pressurePercent : caching.pressurePercent,
                categories: categories.map { CacheRow.Category(name: $0.name, bytes: $0.bytes) },
                savings: record.savings,
                parents: status?.parents.map { $0.map { CacheRow.Neighbor(address: $0.address, port: $0.port, isHealthy: $0.isHealthy,
                                                                         version: $0.version) } }
                    ?? caching.parents.map { CacheRow.Neighbor(address: $0.address, port: $0.port, isHealthy: $0.isHealthy, version: $0.version) },
                peers: status?.peers.map { $0.map { CacheRow.Neighbor(address: $0.address, port: $0.port, isHealthy: $0.isHealthy,
                                                                     isFriendly: $0.isFriendly, version: $0.version) } },
                alerts: caching.alerts.map { CacheRow.Alert(name: $0.className.map(Self.alertName) ?? "Alert", posted: $0.posted) },
                declarations: record.declarations, isUnplanned: record.isUnplanned, liveFigures: time(info?.updated),
                statusUpdated: time(live?.updated), statusProblem: record.statusProblem)
        }
    }

    /// `com.apple.AssetCache.CacheVolumeAlert` → “Cache Volume”.
    static func alertName(_ className: String) -> String {
        var name = className.split(separator: ".").last.map(String.init) ?? className
        if name.hasSuffix("Alert"), name.count > 5 { name.removeLast(5) }
        return name.replacing(/([a-z])([A-Z])/) { "\($0.output.1) \($0.output.2)" }
    }
}

// MARK: - Storage

/// The sweeps of one connection, in `ContentCaches/<connection ID>/`: one
/// JSON file per sweep (`yyyyMMdd-HHmmss-SSS.json`, as the history), the
/// trend (`trend.index`, every cache’s `CacheSnapshot` of every sweep, so the
/// chart never reads full sweeps) and the Blueprints known to have no caching
/// declaration (`known-blueprints.plist`, so the next sweep reads only the
/// changed ones). Kept as the history is: 180 days, full sweeps for 7 days,
/// then the newest of each day. Never read on the main thread.
nonisolated struct CacheArchive: Sendable {
    static let folderName = "ContentCaches"
    static let trendName = "trend.index"
    static let knownName = "known-blueprints.plist"

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// `ContentCaches/<connection ID>` in the app’s Application Support folder (in its container).
    static func standardFolder(connectionID: UUID) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: connectionID.uuidString, directoryHint: .isDirectory)
    }

    /// Saves a sweep, adds its caches to the trend and removes what is older than the history keeps.
    func save(_ record: CacheSweepRecord, snapshots: [ContentCacheRules.CacheSnapshot]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: folder.appending(path: StatusHistory.fileName(for: record.date)), options: .atomic)
        var trend = self.trend().filter { abs($0.date.timeIntervalSince(record.date)) >= 0.001 } + snapshots
        trend.sort { ($0.date, $0.cacheID) < ($1.date, $1.cacheID) }
        try writeTrend(trend)
        prune(now: record.date)
    }

    /// The newest sweep; an unreadable file is skipped for the one before it.
    func latest() -> CacheSweepRecord? {
        for file in files().reversed() {
            if let data = try? Data(contentsOf: file), let record = try? StatusHistory.decoder.decode(CacheSweepRecord.self, from: data) {
                return record
            }
        }
        return nil
    }

    /// Every cache of every sweep, oldest first; empty when there is none or it can’t be read.
    func trend() -> [ContentCacheRules.CacheSnapshot] {
        guard let data = try? Data(contentsOf: folder.appending(path: Self.trendName)),
              let trend = try? StatusHistory.decoder.decode([ContentCacheRules.CacheSnapshot].self, from: data) else { return [] }
        return trend
    }

    /// The Blueprints without a caching declaration, with their `updated` time.
    func knownBlueprints() -> [String: String] {
        guard let data = try? Data(contentsOf: folder.appending(path: Self.knownName)),
              let known = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
        return known
    }

    func saveKnownBlueprints(_ known: [String: String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(known).write(to: folder.appending(path: Self.knownName), options: .atomic)
    }

    /// Sweep files, oldest first (by name, which sorts by time).
    func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { StatusHistory.isRefreshFile($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func writeTrend(_ trend: [ContentCacheRules.CacheSnapshot]) throws {
        try Self.encoder.encode(trend).write(to: folder.appending(path: Self.trendName), options: .atomic)
    }

    /// Removes sweeps older than 180 days (also from the trend) and, older
    /// than 7 days, every sweep but the newest of its day (UTC).
    func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(StatusHistory.retentionDays) * 86_400)
        let thinFrom = now.addingTimeInterval(-Double(StatusHistory.fullDays) * 86_400)
        let cutoffName = StatusHistory.fileName(for: cutoff), thinName = StatusHistory.fileName(for: thinFrom)
        var newestOfDay: [String: URL] = [:]
        for file in files() {
            let name = file.lastPathComponent
            if name < cutoffName {
                try? FileManager.default.removeItem(at: file)
            } else if name < thinName {
                let day = String(name.prefix(8))
                if let earlier = newestOfDay[day] { try? FileManager.default.removeItem(at: earlier) }
                newestOfDay[day] = file
            }
        }
        let trend = self.trend()
        if trend.contains(where: { $0.date < cutoff }) { try? writeTrend(trend.filter { $0.date >= cutoff }) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
