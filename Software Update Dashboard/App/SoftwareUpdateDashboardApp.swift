import JTKit
import os
import SwiftUI

@main
struct SoftwareUpdateDashboardApp: App {
    @State private var connections = ConnectionsModel.forLaunch(activityLog: .app)
    @State private var updates: UpdateChecker = {
        let logger = Logger(subsystem: "be.jordythery.softwareupdatedashboard", category: "Updates")
        return UpdateChecker(
            configuration: .softwareUpdateDashboard,
            // A failed check can hold GitHub's answer: private in the system log.
            activity: { logger.info("\($0, privacy: .private)") }
        )
    }()

    var body: some Scene {
        Window("Software Update Dashboard", id: "main") {
            ContentView(connections: connections)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 560)
                .confirmsDemoModeSwitch(connections.demo)
                .task {
                    // No update check under tests: neither in a sandbox run nor
                    // as the unit-test host.
                    guard !TestRun.isActive else { return }
                    await updates.checkAutomatically()
                }
        }
        .commands {
            AppInfoCommands(appName: "Software Update Dashboard") { updates.checkManually() }
            // The toolbar picker's items, as JTKit's Connection menu.
            ConnectionCommands(store: connections.saved, roles: [connections.role()]) {
                DemoModeToggle(demo: connections.demo)
            }
            GroupCommands()
        }

        // JTKit's Settings window: Connections and Updates (no General tab:
        // the app has no general settings; it follows the Mac's appearance).
        SettingsWindow(updates: updates, opensTabsByName: true) {
            SettingsView(connections: connections)
                // Settings › Connections notes that these are the real connections.
                .environment(connections.demo)
        }

        AboutWindow(configuration: .softwareUpdateDashboard)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: connections.activityLog,
            emptyDescription: "Sign-ins, reads from Jamf, Apple’s release data, connection tests and retries appear here as they happen."
        )
    }
}

extension ActivityLog {
    /// The app's one activity log (Window › Activity Log).
    static let app = ActivityLog()
}
