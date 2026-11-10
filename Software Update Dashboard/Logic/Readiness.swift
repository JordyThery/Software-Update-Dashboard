import Foundation

/// Devices the Blueprint’s software update can’t reach as they are: each
/// count on the dashboard opens those devices in the list.
nonisolated enum ReadinessCheck: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// An iPhone or iPad enrolled with User Enrollment: Apple’s enforced
    /// software update allows supervised and device enrollments only.
    case userEnrollment
    /// A Mac that isn’t supervised: on macOS Apple allows the enforced
    /// software update on supervised Macs only.
    case macNotSupervised
    /// Declarative device management is off: the Blueprint can’t reach it.
    case noDeclarativeManagement
    /// Jamf Pro has no status report of the device at all.
    case neverReported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userEnrollment: "User Enrollment"
        case .macNotSupervised: "Macs not supervised"
        case .noDeclarativeManagement: "No declarative device management"
        case .neverReported: "Never reported"
        }
    }

    /// What it means, under the count.
    var note: String {
        switch self {
        case .userEnrollment: "iPhones and iPads enrolled this way don’t get an enforced update"
        case .macNotSupervised: "A Mac gets an enforced update only when it’s supervised"
        case .noDeclarativeManagement: "The Blueprint can’t reach these devices"
        case .neverReported: "No status report in Jamf Pro yet"
        }
    }

    var systemImage: String {
        switch self {
        case .userEnrollment: "person.crop.circle"
        case .macNotSupervised: "lock.open"
        case .noDeclarativeManagement: "point.3.connected.trianglepath.dotted"
        case .neverReported: "questionmark.circle"
        }
    }

    func applies(to device: DeviceStatus) -> Bool {
        switch self {
        // Apple’s enforced update (com.apple.configuration.softwareupdate.enforcement.specific)
        // allows supervised and device enrollments on iOS and iPadOS, supervised Macs only on macOS
        case .userEnrollment: !device.isComputer && device.userEnrollment == true
        case .macNotSupervised: device.isComputer && device.supervised == false
        case .noDeclarativeManagement: device.ddmEnabled == false
        case .neverReported: device.neverReported == true
        }
    }

    static func count(_ check: ReadinessCheck, in devices: [DeviceStatus]) -> Int {
        devices.filter(check.applies).count
    }
}
