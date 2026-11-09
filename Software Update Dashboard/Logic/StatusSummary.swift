import Foundation

/// How many devices are in each category.
nonisolated struct CategoryCounts: Sendable, Hashable, Codable {
    var counts: [StatusCategory: Int]

    init(_ devices: [DeviceStatus]) {
        var counts = Dictionary(uniqueKeysWithValues: StatusCategory.allCases.map { ($0, 0) })
        for device in devices { counts[device.category, default: 0] += 1 }
        self.counts = counts
    }

    init(counts: [StatusCategory: Int]) { self.counts = counts }

    subscript(_ category: StatusCategory) -> Int { counts[category] ?? 0 }
    var total: Int { counts.values.reduce(0, +) }
    /// Every device but the unsupported, offline and no-report ones.
    var updatable: Int { total - StatusCategory.allCases.filter(\.isExcludedFromUpdatable).map { self[$0] }.reduce(0, +) }
    /// The share of updatable devices on target, rounded to 0.1; nil without any.
    var percentOnTarget: Double? {
        updatable > 0 ? (Double(self[.onTarget]) * 1000 / Double(updatable)).rounded() / 10 : nil
    }

    // Saved by the categories' raw values, so the history reads on as categories are added.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Int].self)
        counts = Dictionary(uniqueKeysWithValues: StatusCategory.allCases.map { ($0, raw[$0.rawValue] ?? 0) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: StatusCategory.allCases.map { ($0.rawValue, self[$0]) }))
    }
}

/// The text summary of a refresh: counts with the change since the previous
/// one, the progress figure, the diagnoses and who needs attention.
nonisolated enum StatusSummary {
    /// The previous refresh to compare with: only one for the same target.
    static func previous(_ snapshot: HistorySnapshot?, target: String?) -> HistorySnapshot? {
        guard let snapshot, snapshot.target == target else { return nil }
        return snapshot
    }

    static func text(group: String, devices: [DeviceStatus], target: String?, osName: String, previous: HistorySnapshot?,
                     staleDays: Int, date: Date = Date(), locale: Locale = .current) -> String {
        let counts = CategoryCounts(devices)
        var lines: [String] = []
        lines.append("\(group): \(date.formatted(date: .abbreviated, time: .shortened))")
        lines.append("  Devices:    \(devices.count) (target \(osName) \(target ?? "unknown"))")
        for category in StatusCategory.allCases {
            var line = "    " + category.title.padding(toLength: 14, withPad: " ", startingAt: 0)
                + String(String(repeating: " ", count: 6) + String(counts[category])).suffix(6)
            if let before = previous?.counts[category], before != counts[category] {
                let change = counts[category] - before
                line += "  (\(change > 0 ? "+" : "")\(change))"
            }
            if let note = category.note(staleDays: staleDays) { line += "  \(note)" }
            lines.append(line)
        }
        if let previous {
            lines.append("  Changes since the previous refresh (\(previous.date.formatted(date: .abbreviated, time: .shortened))) in brackets.")
        }
        var progress = "  Progress:   \(counts[.onTarget]) of \(counts.updatable) updatable devices on target"
        if let percent = counts.percentOnTarget { progress += " (\(percent.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))%)" }
        progress += "; updatable excludes unsupported, offline and no report"
        lines.append(progress)
        let passcodes = devices.filter { $0.passcodePresent == true && $0.category != .offline && $0.category != .onTarget }.count
        lines.append("  Passcode:   \(passcodes) online \(passcodes == 1 ? "device" : "devices") not on target report a passcode")
        let unreadable = devices.filter { $0.statusProblem != nil }
        if !unreadable.isEmpty {
            lines.append("  !! The update status couldn’t be read for \(unreadable.count) \(unreadable.count == 1 ? "device" : "devices"); they count as no report. Refresh again.")
        }
        let diagnoses = diagnosisCounts(devices)
        if !diagnoses.isEmpty {
            lines.append("  Not on target, by diagnosis:")
            for item in diagnoses.prefix(12) {
                lines.append("    \(String(String(repeating: " ", count: 6) + String(item.count)).suffix(6))  \(item.diagnosis)")
            }
        }
        let attention = devices.filter(\.needsAttention)
        if !attention.isEmpty {
            lines.append("  Needs attention: \(attention.count) \(attention.count == 1 ? "device" : "devices")"
                         + (attention.count > 10 ? " (first 10; all in the CSV)" : ""))
            for device in attention.prefix(10) {
                lines.append("    \(device.name)  \(device.modelIdentifier)  \(device.osName) \(device.currentOS.isEmpty ? "?" : device.currentOS)  \(device.diagnosis)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The diagnoses of the devices not on target, most common first (ties
    /// in alphabetical order).
    static func diagnosisCounts(_ devices: [DeviceStatus]) -> [(diagnosis: String, count: Int)] {
        Dictionary(grouping: devices.filter { $0.category != .onTarget }, by: \.diagnosis)
            .map { (diagnosis: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.diagnosis < $1.diagnosis }
    }
}
