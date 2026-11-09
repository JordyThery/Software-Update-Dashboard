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
    /// “72%” or “–”.
    var percentText: String {
        percentOnTarget.map { "\(($0 / 100).formatted(.percent.precision(.fractionLength(0))))" } ?? "–"
    }
}
