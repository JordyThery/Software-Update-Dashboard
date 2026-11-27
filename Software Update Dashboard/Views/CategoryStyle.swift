import JTKit
import SwiftUI

/// How a category looks, everywhere it appears.
extension StatusCategory {
    var badgeStyle: StatusBadge.Style {
        switch self {
        case .onTarget: .success
        case .inProgress, .otherUpdate: .info
        case .failed: .failure
        case .notStarted, .noActivity: .attention
        case .unsupported, .offline, .noReport, .targetUnknown: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .onTarget: "checkmark.circle.fill"
        case .inProgress: "arrow.down.circle"
        case .otherUpdate: "arrow.triangle.branch"
        case .failed: "xmark.octagon"
        case .notStarted: "pause.circle"
        case .unsupported: "nosign"
        case .noActivity: "moon.zzz"
        case .offline: "wifi.slash"
        case .noReport: "questionmark.circle"
        case .targetUnknown: "scope"
        }
    }
}

extension ProgressGroup {
    var color: Color {
        switch self {
        case .onTarget: .green
        case .updating: .blue
        case .needsAttention: .orange
        case .noActivity: .purple
        case .excluded: .gray
        }
    }
}

extension CategoryCounts {
    /// “72%”, “99.6%” or “–” (`shareText`).
    var percentText: String {
        percentOnTarget.map { Self.shareText($0) } ?? "–"
    }

    /// A share on target as the window, the menu bar item, notifications and
    /// the summary all write it: up to one decimal (“99.6%”), and never
    /// “100%” unless every device is on target.
    nonisolated static func shareText(_ percent: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let rounded = (percent * 10).rounded() / 10
        let shown = percent < 100 && rounded >= 100 ? 99.9 : rounded
        return "\(shown.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))%"
    }
}
