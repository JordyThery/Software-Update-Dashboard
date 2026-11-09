import Foundation

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
    var counts: CategoryCounts
    var devices: [DeviceStatus]
    /// The Blueprint’s scope at the time, as Jamf Pro groups (nil in entries
    /// saved before the scope was kept).
    var scope: [GroupReference]?

    var id: Date { date }

    init(date: Date, target: String?, devices: [DeviceStatus], scope: [GroupReference]? = nil) {
        self.date = date
        self.target = target
        self.devices = devices
        self.scope = scope
        counts = CategoryCounts(devices)
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
    var text: String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append("\(added.count) \(added.count == 1 ? "group" : "groups") added (\(added.map(\.name).joined(separator: ", ")))")
        }
        if !removed.isEmpty {
            parts.append("\(removed.count) removed (\(removed.map(\.name).joined(separator: ", ")))")
        }
        return "Scope: " + parts.joined(separator: ", ")
    }
}

/// The refreshes of every tracked group: one JSON file per refresh in a
/// folder per group, kept for 180 days. Files that can’t be read are left
/// alone and skipped.
nonisolated struct StatusHistory: Sendable {
    static let retentionDays = 180

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

    /// Saves a refresh and removes those older than 180 days.
    func save(_ snapshot: HistorySnapshot, for groupID: UUID) throws {
        let groupFolder = groupFolder(groupID)
        try FileManager.default.createDirectory(at: groupFolder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: groupFolder.appending(path: Self.fileName(for: snapshot.date)), options: .atomic)
        prune(groupID, now: snapshot.date)
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
    func latest(for groupID: UUID, before date: Date? = nil) -> HistorySnapshot? {
        snapshots(for: groupID).last { snapshot in date.map { snapshot.date < $0.addingTimeInterval(-0.001) } ?? true }
    }

    /// Removes a group’s whole history, when the group is no longer tracked.
    func remove(_ groupID: UUID) {
        try? FileManager.default.removeItem(at: groupFolder(groupID))
    }

    func prune(_ groupID: UUID, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: groupFolder(groupID), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let date = Self.date(fromFileName: file.lastPathComponent), date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Files

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
