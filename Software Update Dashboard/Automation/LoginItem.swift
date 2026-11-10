import Foundation
import JTKit
import Observation
import ServiceManagement

/// Open at Login, through the system's login item service: what it shows is
/// what the system says, also after a change in System Settings › General ›
/// Login Items. A test or sandbox run never changes it.
@MainActor
@Observable
final class LoginItem {
    enum State: Equatable {
        case on, off
        /// Turned on here, waiting for approval in System Settings.
        case needsApproval
        /// A test or sandbox run: never changed.
        case unavailable
    }

    private(set) var state: State = .off
    /// Why the last change didn't work.
    private(set) var problem: String?

    /// The system's status; tests replace it and `change`.
    @ObservationIgnored var status: () -> SMAppService.Status = { SMAppService.mainApp.status }
    @ObservationIgnored var change: (Bool) throws -> Void = { on in
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    @ObservationIgnored let canChange: Bool

    init(canChange: Bool = !(TestRun.isActive || DemoMode.isSandboxLaunch)) {
        self.canChange = canChange
        refresh()
    }

    /// Reads the system's status again (on appear, when the app becomes active).
    func refresh() {
        guard canChange else {
            state = .unavailable
            return
        }
        state = switch status() {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    func set(_ on: Bool) {
        guard canChange else { return }
        problem = nil
        do {
            try change(on)
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
