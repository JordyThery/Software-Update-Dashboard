import Foundation
import JTKit
import Observation
import UserNotifications

/// What one tracked Blueprint notifies about.
nonisolated struct NotificationRule: Codable, Hashable, Sendable {
    /// Notify when the share on target reaches this level or drops below it; nil: off.
    var shareLevel: Int?
    /// Notify when devices are newly failed or stuck.
    var failedOrStuck = false

    var isOn: Bool { shareLevel != nil || failedOrStuck }
    static let defaultLevel = 90
}

/// One notification, in plain words.
nonisolated struct RefreshNotice: Hashable, Sendable {
    var title: String
    var body: String
}

/// What changed between two refreshes of a tracked Blueprint. Only a change
/// notifies: never the first refresh, never the same state again.
nonisolated enum RefreshNotices {
    /// A downloaded update that didn’t install after its deadline.
    static func isStuck(_ device: DeviceStatus) -> Bool {
        device.diagnosis.range(of: "not installed after", options: .caseInsensitive) != nil
    }

    static func between(previous: [DeviceStatus]?, current: [DeviceStatus], rule: NotificationRule,
                        name: String) -> [RefreshNotice] {
        guard let previous, rule.isOn else { return [] }
        var notices: [RefreshNotice] = []
        if let level = rule.shareLevel, let before = CategoryCounts(previous).percentOnTarget,
           let now = CategoryCounts(current).percentOnTarget {
            let shown = now.formatted(.number.precision(.fractionLength(0...1)))
            if before < Double(level) && now >= Double(level) {
                notices.append(RefreshNotice(title: name, body: "\(shown)% of the devices are on target: the share reached \(level)%."))
            } else if before >= Double(level) && now < Double(level) {
                notices.append(RefreshNotice(title: name, body: "\(shown)% of the devices are on target: the share dropped below \(level)%."))
            }
        }
        if rule.failedOrStuck {
            let failedBefore = Set(previous.filter { $0.category == .failed }.map(\.id))
            let stuckBefore = Set(previous.filter(isStuck).map(\.id))
            let failed = current.filter { $0.category == .failed && !failedBefore.contains($0.id) }
            let stuck = current.filter { isStuck($0) && !stuckBefore.contains($0.id) && $0.category != .failed }
            var parts: [String] = []
            if !failed.isEmpty { parts.append("\(Plural.count(failed.count, "device")) newly failed") }
            if !stuck.isEmpty { parts.append("\(Plural.count(stuck.count, "device")) newly stuck after the deadline") }
            if !parts.isEmpty {
                let names = (failed + stuck).prefix(3).map(\.name).filter { !$0.isEmpty }
                notices.append(RefreshNotice(title: name, body: parts.joined(separator: ", ").capitalizedFirst
                                             + (names.isEmpty ? "." : ": " + names.joined(separator: ", ")
                                                + ((failed.count + stuck.count) > names.count ? " and more." : "."))))
            }
        }
        return notices
    }
}

/// The notification rules of the tracked Blueprints (saved under
/// `notificationRules`), asking for permission when one is turned on, and
/// sending. Demo Mode never sends: it writes what it would have sent in
/// the activity log.
@MainActor
@Observable
final class Notifier {
    nonisolated static let rulesKey = "notificationRules"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let activityLog: ActivityLog
    private(set) var rules: [UUID: NotificationRule]
    /// Demo Mode’s rules: in memory only, never saved.
    private(set) var demoRules: [UUID: NotificationRule] = [:]
    /// Permission was refused: notifications are off in System Settings.
    private(set) var permissionProblem: String?
    /// Everything posted, sent or not (Demo Mode): the newest last.
    private(set) var posted: [RefreshNotice] = []

    /// Asks the system for permission; tests replace it and `deliver`
    /// (under tests the defaults ask nothing and send nothing).
    @ObservationIgnored var authorize: () async -> Bool = {
        guard !TestRun.isActive else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    @ObservationIgnored var deliver: (RefreshNotice) -> Void = { notice in
        guard !TestRun.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    init(defaults: UserDefaults, activityLog: ActivityLog) {
        self.defaults = defaults
        self.activityLog = activityLog
        let data = defaults.data(forKey: Self.rulesKey)
        let saved = data.flatMap { try? JSONDecoder().decode([String: NotificationRule].self, from: $0) } ?? [:]
        rules = Dictionary(uniqueKeysWithValues: saved.compactMap { key, rule in UUID(uuidString: key).map { ($0, rule) } })
    }

    func rule(for id: UUID, demo: Bool) -> NotificationRule { (demo ? demoRules[id] : rules[id]) ?? NotificationRule() }

    /// Saves a rule. Turning a notification on asks for permission, but not
    /// in Demo Mode, which never sends.
    func setRule(_ rule: NotificationRule, for id: UUID, demo: Bool) async {
        let wasOn = self.rule(for: id, demo: demo).isOn
        if demo {
            demoRules[id] = rule
            return
        }
        rules[id] = rule
        save()
        guard rule.isOn, !wasOn || permissionProblem != nil else { return }
        permissionProblem = await authorize() ? nil
            : "Notifications are off for Software Update Dashboard in System Settings › Notifications."
    }

    /// Forgets a Blueprint that is no longer tracked.
    func remove(_ id: UUID) {
        rules[id] = nil
        save()
    }

    /// Posts what changed between two refreshes of a tracked Blueprint.
    func post(_ notices: [RefreshNotice], demo: Bool) {
        for notice in notices {
            posted.append(notice)
            if demo {
                activityLog.recordAction("Demo Mode, notification not sent: \(notice.title)", note: notice.body)
            } else {
                deliver(notice)
            }
        }
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.uuidString, $0.value) })
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.rulesKey)
    }
}
