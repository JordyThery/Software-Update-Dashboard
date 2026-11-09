import Foundation

/// The nine categories every device is sorted into. Raw values are the CSV
/// strings and the history’s keys: never rename them.
nonisolated enum StatusCategory: String, CaseIterable, Sendable, Codable, Identifiable {
    case onTarget = "on-target"
    case inProgress = "in-progress"
    case otherUpdate = "other-update"
    case failed = "failed"
    case notStarted = "not-started"
    case unsupported = "unsupported"
    case noActivity = "no-activity"
    case offline = "offline"
    case noReport = "no-report"

    var id: String { rawValue }

    /// The category as people read it.
    var title: String {
        switch self {
        case .onTarget: "On target"
        case .inProgress: "In progress"
        case .otherUpdate: "Other update"
        case .failed: "Failed"
        case .notStarted: "Not started"
        case .unsupported: "Unsupported"
        case .noActivity: "No activity"
        case .offline: "Offline"
        case .noReport: "No report"
        }
    }

    /// Left out of “updatable” in the progress figure: these devices can’t
    /// update now, whatever the Blueprint says.
    var isExcludedFromUpdatable: Bool { [.unsupported, .offline, .noReport].contains(self) }

    /// What the count means, after it in the summary.
    func note(staleDays: Int) -> String? {
        switch self {
        case .otherUpdate: "(e.g. via an intermediate version)"
        case .unsupported: "(hardware can’t run the target)"
        case .noActivity: "(no report since the update started)"
        case .offline: "(no contact for more than \(staleDays) days)"
        default: nil
        }
    }
}
