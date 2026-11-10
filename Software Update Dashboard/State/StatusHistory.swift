import Foundation
import JTKit

/// The five groups of the progress chart, each a few categories.
nonisolated enum ProgressGroup: String, CaseIterable, Sendable, Identifiable {
    case onTarget = "On target"
    case updating = "Updating"
    case needsAttention = "Needs attention"
    case noActivity = "No activity"
    case excluded = "Not updatable"

    var id: String { rawValue }

    var categories: [StatusCategory] {
        switch self {
        case .onTarget: [.onTarget]
        case .updating: [.inProgress, .otherUpdate]
        case .needsAttention: [.failed, .notStarted]
        case .noActivity: [.noActivity]
        case .excluded: [.unsupported, .offline, .noReport]
        }
    }

    var explanation: String {
        switch self {
        case .onTarget: "On the target version or newer."
        case .updating: "Waiting, downloading, prepared or installing; also via an intermediate version."
        case .needsAttention: "The update failed, or nothing is pending although the device reported since the update started."
        case .noActivity: "No report since the update started (switched off or not synced yet)."
        case .excluded: "Hardware that can’t run the target, offline devices and devices without update status. Not counted as updatable."
        }
    }

    func count(in counts: CategoryCounts) -> Int { categories.map { counts[$0] }.reduce(0, +) }
}

/// One refresh of a tracked group, as kept in its history.
nonisolated struct HistorySnapshot: Sendable, Hashable, Codable, Identifiable {
    var date: Date
    /// What the devices were measured against: the Blueprint’s rule (e.g.
    /// “Minor updates, 14 days after their release”) or the version it asks
    /// for; nil when unknown. Refreshes are compared only for the same one.
    var target: String?
    /// The same rule by its values (`RefreshWorkflow.ruleKey`); nil in
    /// entries saved before it was kept. Compared instead of the text,
    /// which changes with this Mac’s region and clock format.
    var ruleKey: String?
    var counts: CategoryCounts
    /// The measured devices: those whose target was unknown aren’t kept.
    var devices: [DeviceStatus]
    /// The Blueprint’s scope at the time, as Jamf Pro groups (nil in entries
    /// saved before the scope was kept).
    var scope: [GroupReference]?
    /// How this app measured: `currentRules` from targets per device with
    /// “Target unknown” left out; nil in entries saved before. The chart
    /// marks where it changes, as counts on either side don’t compare.
    var rules: Int?

    /// The target rules of this version.
    /// 3 (0.1.1): this Blueprint’s earlier step, and the newer of the reported and inventory versions.
    static let currentRules = 3

    var id: Date { date }

    init(date: Date, target: String?, ruleKey: String? = nil, devices: [DeviceStatus], scope: [GroupReference]? = nil,
         rules: Int? = currentRules) {
        self.date = date
        self.target = target
        self.ruleKey = ruleKey
        self.rules = rules
        self.devices = devices.filter { $0.category != .targetUnknown }
        self.scope = scope
        counts = CategoryCounts(self.devices)
    }

    /// Whether this refresh measured against the given rule: by its values
    /// when both have them, else by its text.
    func measures(target other: String?, ruleKey otherKey: String?) -> Bool {
        if let ruleKey, let otherKey { return ruleKey == otherKey }
        return target == other
    }
}

/// One refresh as the chart needs it: its counts, rule, scope and the
/// targets it measured against, without the devices. Kept for every refresh
/// in a small index per Blueprint, so the chart never decodes full refreshes.
nonisolated struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    /// A target a device was measured against by the rule (not one Jamf sent).
    struct Target: Sendable, Hashable, Codable {
        var os: String
        var version: String
    }

    var date: Date
    var target: String?
    var ruleKey: String?
    var counts: CategoryCounts
    var scope: [GroupReference]?
    var rules: Int?
    /// Each target once.
    var targets: [Target]

    var id: Date { date }

    func measures(target other: String?, ruleKey otherKey: String?) -> Bool {
        if let ruleKey, let otherKey { return ruleKey == otherKey }
        return target == other
    }
}

extension HistorySnapshot {
    /// This refresh as the index keeps it.
    var entry: HistoryEntry {
        var seen = Set<HistoryEntry.Target>()
        let targets = devices.filter { $0.targetFromDevice != true }
            .compactMap { device in device.targetVersion.map { HistoryEntry.Target(os: device.osName, version: $0) } }
            .filter { seen.insert($0).inserted }
        return HistoryEntry(date: date, target: target, ruleKey: ruleKey, counts: counts, scope: scope, rules: rules, targets: targets)
    }
}

/// A refresh in the history where counts on either side don’t compare:
/// the Blueprint’s software update or its scope changed, or an app update
/// changed how targets are worked out. One mark per refresh, whatever
/// changed in it.
nonisolated struct HistoryMark: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable {
        case rule = "Software update", counting = "App update", scope = "Scope", release = "Apple release"
    }
    var date: Date
    var kinds: [Kind]
    /// What changed, in one sentence without a colon.
    var text: String

    var id: Date { date }

    static func marks(_ snapshots: [HistorySnapshot]) -> [HistoryMark] {
        marks(snapshots.map(\.entry))
    }

    static func marks(_ snapshots: [HistoryEntry]) -> [HistoryMark] {
        zip(snapshots, snapshots.dropFirst()).compactMap { previous, next -> HistoryMark? in
            var kinds: [Kind] = []
            var parts: [String] = []
            if !previous.measures(target: next.target, ruleKey: next.ruleKey) {
                kinds.append(.rule)
                // the same text with other values: only its time of day or build changed
                parts.append(previous.target == next.target
                             ? "the Blueprint’s software update “\(next.target ?? "unknown")” changed its time of day or build"
                             : "the Blueprint’s software update changed to “\(next.target ?? "unknown")”")
            } else if previous.rules != next.rules {
                kinds.append(.counting)
                parts.append("targets are worked out differently after an app update")
            }
            if let change = ScopeChange(from: previous.scope, to: next.scope) {
                kinds.append(.scope)
                parts.append("the Blueprint’s scope changed, \(change.description)")
            }
            // Apple released a version that became the target: the counts
            // compare, but devices on the old target are no longer on it
            var released: String?
            if kinds.isEmpty, let versions = Self.newTargets(from: previous, to: next) {
                kinds.append(.release)
                released = "Apple released \(versions), so devices on the earlier version are no longer on target"
            }
            guard !kinds.isEmpty else { return nil }
            let text = parts.isEmpty ? released ?? "" : parts.joined(separator: "; ") + ", so earlier counts don’t compare"
            return HistoryMark(date: next.date, kinds: kinds, text: text.prefix(1).uppercased() + text.dropFirst())
        }
    }

    /// The versions that became a target from Apple’s release data between
    /// two refreshes: a lower target of the same platform and major came
    /// before, and none as high (a device new to a major isn’t a release):
    /// “macOS 27.2.1 and 26.7.3”. Nil when there are none.
    static func newTargets(from previous: HistorySnapshot, to next: HistorySnapshot) -> String? {
        newTargets(from: previous.entry, to: next.entry)
    }

    static func newTargets(from previous: HistoryEntry, to next: HistoryEntry) -> String? {
        func targets(_ entry: HistoryEntry) -> [(os: String, version: OSVersion)] {
            entry.targets.compactMap { target in OSVersion(target.version).map { (target.os, $0) } }
        }
        let before = targets(previous)
        guard !before.isEmpty else { return nil }
        var seen = Set<String>()
        var new: [(os: String, version: OSVersion)] = []
        for item in targets(next) {
            let sameMajor = before.filter { $0.os == item.os && $0.version.major == item.version.major }
            let released = sameMajor.contains { $0.version < item.version } && !sameMajor.contains { !($0.version < item.version) }
            if released && seen.insert("\(item.os) \(item.version)").inserted { new.append(item) }
        }
        guard !new.isEmpty else { return nil }
        var parts: [String] = []
        for (os, items) in Dictionary(grouping: new, by: { $0.os }).sorted(by: { $0.key < $1.key }) {
            let versions: [String] = items.map(\.version).sorted(by: >).map(\.description)
            parts.append("\(os) " + versions.formatted(.list(type: .and)))
        }
        return parts.formatted(.list(type: .and))
    }
}

/// How the Blueprint’s scope changed between two refreshes.
nonisolated struct ScopeChange: Sendable, Hashable {
    var added: [GroupReference]
    var removed: [GroupReference]

    /// Nil when either refresh has no scope kept, or nothing changed.
    init?(from previous: [GroupReference]?, to current: [GroupReference]?) {
        guard let previous, let current else { return nil }
        let before = Set(previous.map(\.key)), after = Set(current.map(\.key))
        added = current.filter { !before.contains($0.key) }
        removed = previous.filter { !after.contains($0.key) }
        if added.isEmpty && removed.isEmpty { return nil }
    }

    /// “Scope: 1 group added (Name), 1 removed (Name)”.
    var text: String { "Scope: " + description }

    /// “1 group added (Name), 1 removed (Name)”.
    var description: String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append("\(added.count) \(added.count == 1 ? "group" : "groups") added (\(added.map(\.name).joined(separator: ", ")))")
        }
        if !removed.isEmpty {
            // “1 group removed” on its own, “…, 1 removed” after what was added
            let what = added.isEmpty ? Plural.count(removed.count, "group") : "\(removed.count)"
            parts.append("\(what) removed (\(removed.map(\.name).joined(separator: ", ")))")
        }
        return parts.joined(separator: ", ")
    }
}

/// The refreshes of every tracked group: one JSON file per refresh in a
/// folder per group, and an index of every refresh’s counts (`counts.index`)
/// for the chart. Counts are kept for 180 days; full refreshes for 7 days,
/// after that the newest of each day (UTC), up to the 180 days. Files that
/// can’t be read are left alone and skipped. Reading is never meant for the
/// main thread: the dashboard model reads off it and keeps what it needs.
nonisolated struct StatusHistory: Sendable {
    static let retentionDays = 180
    /// Full refreshes younger than this are all kept; older ones, the newest per day.
    static let fullDays = 7
    static let indexName = "counts.index"

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// `History` in the app’s Application Support folder (in its container).
    static func standardFolder() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "History", directoryHint: .isDirectory)
    }

    private func groupFolder(_ groupID: UUID) -> URL {
        folder.appending(path: groupID.uuidString, directoryHint: .isDirectory)
    }

    /// Saves a refresh and removes those older than 180 days, in every
    /// folder (also of Blueprints no longer tracked here, e.g. under another
    /// connection: their folders stay, their old refreshes go).
    func save(_ snapshot: HistorySnapshot, for groupID: UUID) throws {
        let groupFolder = groupFolder(groupID)
        try FileManager.default.createDirectory(at: groupFolder, withIntermediateDirectories: true)
        // the index first, from what is on disk now (built once from older history)
        var index = entries(for: groupID).filter { abs($0.date.timeIntervalSince(snapshot.date)) >= 0.001 }
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: groupFolder.appending(path: Self.fileName(for: snapshot.date)), options: .atomic)
        index.append(snapshot.entry)
        index.sort { $0.date < $1.date }
        try writeIndex(index, folder: groupFolder)
        pruneAll(now: snapshot.date)
    }

    /// Every refresh’s counts, oldest first, from the index; built once from
    /// the saved refreshes when there is none yet (history from before it)
    /// or when a saved refresh is newer than the index’s newest.
    func entries(for groupID: UUID) -> [HistoryEntry] {
        let groupFolder = groupFolder(groupID)
        let newestFile = files(groupFolder).last.flatMap { Self.date(fromFileName: $0.lastPathComponent) }   // one name parsed
        if let data = try? Data(contentsOf: groupFolder.appending(path: Self.indexName)),
           let index = try? Self.decoder.decode([HistoryEntry].self, from: data),
           newestFile.map({ newest in index.last.map { $0.date >= newest.addingTimeInterval(-0.001) } ?? false }) ?? true {
            return index
        }
        guard newestFile != nil else { return [] }
        let built = snapshots(for: groupID).map(\.entry)
        try? writeIndex(built, folder: groupFolder)
        return built
    }

    private func writeIndex(_ index: [HistoryEntry], folder groupFolder: URL) throws {
        try Self.encoder.encode(index).write(to: groupFolder.appending(path: Self.indexName), options: .atomic)
    }

    /// The saved refreshes’ files, oldest first (by name, which sorts by time).
    /// Recognized by the shape of the name alone (`yyyyMMdd-HHmmss-SSS.json`): no date is parsed.
    private func files(_ groupFolder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: groupFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.isRefreshFile($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isRefreshFile(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 24, name.hasSuffix(".json") else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            switch index {
            case 8, 15: byte == UInt8(ascii: "-")
            case 19...: true
            default: (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            }
        }
    }

    /// Every refresh of a group, oldest first; since a date if given.
    func snapshots(for groupID: UUID, since: Date? = nil) -> [HistorySnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: groupFolder(groupID), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(HistorySnapshot.self, from: $0) } }
            .filter { snapshot in since.map { snapshot.date >= $0 } ?? true }
    }

    /// The newest refresh, or the one before `date` (saved dates keep
    /// milliseconds, so the refresh at `date` itself never counts).
    /// Found by file name: only that one file is decoded (an unreadable one
    /// is skipped for the one before it).
    func latest(for groupID: UUID, before date: Date? = nil) -> HistorySnapshot? {
        // names sort by time: compared as text, nothing parsed
        let limit = date.map { Self.fileName(for: $0.addingTimeInterval(-0.001)) }
        let candidates = files(groupFolder(groupID)).filter { file in limit.map { file.lastPathComponent < $0 } ?? true }
        for file in candidates.reversed() {
            if let data = try? Data(contentsOf: file), let snapshot = try? Self.decoder.decode(HistorySnapshot.self, from: data),
               date.map({ snapshot.date < $0.addingTimeInterval(-0.001) }) ?? true {
                return snapshot
            }
        }
        return nil
    }

    /// Removes a group’s whole history, when the group is no longer tracked.
    func remove(_ groupID: UUID) {
        try? FileManager.default.removeItem(at: groupFolder(groupID))
    }

    /// Every folder’s refreshes older than 180 days.
    func pruneAll(now: Date) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for groupFolder in folders where UUID(uuidString: groupFolder.lastPathComponent) != nil {
            prune(folder: groupFolder, now: now)
        }
    }

    func prune(_ groupID: UUID, now: Date) {
        prune(folder: groupFolder(groupID), now: now)
    }

    /// Removes refreshes older than 180 days (also from the index) and, older
    /// than 7 days, every full refresh but the newest of its day (UTC).
    private func prune(folder groupFolder: URL, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let thinFrom = now.addingTimeInterval(-Double(Self.fullDays) * 86_400)
        var newestOfDay: [String: URL] = [:]
        // names sort by time: compared as text, nothing parsed
        let cutoffName = Self.fileName(for: cutoff), thinName = Self.fileName(for: thinFrom)
        for file in files(groupFolder) {
            let name = file.lastPathComponent
            if name < cutoffName {
                try? FileManager.default.removeItem(at: file)
            } else if name < thinName {
                // oldest first: a later file of the same day replaces the one kept
                let day = String(file.lastPathComponent.prefix(8))
                if let earlier = newestOfDay[day] { try? FileManager.default.removeItem(at: earlier) }
                newestOfDay[day] = file
            }
        }
        let indexFile = groupFolder.appending(path: Self.indexName)
        if let data = try? Data(contentsOf: indexFile), let index = try? Self.decoder.decode([HistoryEntry].self, from: data),
           index.contains(where: { $0.date < cutoff }) {
            try? writeIndex(index.filter { $0.date >= cutoff }, folder: groupFolder)
        }
    }

    // MARK: Files

    /// A refresh as its file holds it (for tests that lay out an older history).
    static func encoded(_ snapshot: HistorySnapshot) throws -> Data { try encoder.encode(snapshot) }

    /// `20261109-143205-120.json` (to the millisecond), in UTC, so names sort by time.
    static func fileName(for date: Date) -> String { stampFormatter.string(from: date) + ".json" }

    static func date(fromFileName name: String) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        return stampFormatter.date(from: String(name.dropLast(5)))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // to the millisecond, so a refresh is never mistaken for the one before it
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "“\(text)” isn’t a date."))
        }
        return decoder
    }()
}
