import Foundation

/// Devices the Blueprint’s software update can’t reach as they are: each
/// count on the dashboard opens those devices in the list.
nonisolated enum ReadinessCheck: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// An iPhone or iPad that isn’t supervised: update enforcement needs it.
    case notSupervised
    /// Declarative device management is off: the Blueprint can’t reach it.
    case noDeclarativeManagement
    /// Jamf Pro has no status report of the device at all.
    case neverReported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notSupervised: "Not supervised"
        case .noDeclarativeManagement: "No declarative device management"
        case .neverReported: "Never reported"
        }
    }

    /// What it means, under the count.
    var note: String {
        switch self {
        case .notSupervised: "iPhones and iPads need supervision for an enforced update"
        case .noDeclarativeManagement: "The Blueprint can’t reach these devices"
        case .neverReported: "No status report in Jamf Pro yet"
        }
    }

    var systemImage: String {
        switch self {
        case .notSupervised: "lock.open"
        case .noDeclarativeManagement: "point.3.connected.trianglepath.dotted"
        case .neverReported: "questionmark.circle"
        }
    }

    func applies(to device: DeviceStatus) -> Bool {
        switch self {
        // a Mac’s update enforcement doesn’t need supervision
        case .notSupervised: !device.isComputer && device.supervised == false
        case .noDeclarativeManagement: device.ddmEnabled == false
        case .neverReported: device.neverReported == true
        }
    }

    static func count(_ check: ReadinessCheck, in devices: [DeviceStatus]) -> Int {
        devices.filter(check.applies).count
    }
}
