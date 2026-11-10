import JTKit
import os
import SwiftUI

@main
struct SoftwareUpdateDashboardApp: App {
    @State private var connections: ConnectionsModel
    /// The dashboard, the automatic refresh and the login item live as long
    /// as the app, so the menu bar item and the schedule work without the window.
    @State private var model: DashboardModel
    @State private var automation: AutoRefresh
    @State private var loginItem = LoginItem()
    @State private var menuBar: MenuBarSetting
    @State private var updates: UpdateChecker = {
        let logger = Logger(subsystem: "be.jordythery.softwareupdatedashboard", category: "Updates")
        return UpdateChecker(
            configuration: .softwareUpdateDashboard,
            // A failed check can hold GitHub's answer: private in the system log.
            activity: { logger.info("\($0, privacy: .private)") }
        )
    }()

    init() {
        let connections = ConnectionsModel.forLaunch(activityLog: .app)
        let model = DashboardModel(connections: connections)
        let automation = AutoRefresh(model: model, defaults: connections.defaults)
        _connections = State(initialValue: connections)
        _model = State(initialValue: model)
        _automation = State(initialValue: automation)
        _menuBar = State(initialValue: MenuBarSetting(defaults: connections.defaults))
        // not as the unit-test host: tests start their own
        if !TestRun.isUnitTestHost { automation.schedule() }
    }

    var body: some Scene {
        Window("Software Update Dashboard", id: "main") {
            ContentView(connections: connections, model: model, automation: automation)
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
            BlueprintCommands()
            DeviceCommands()
            HelpCommands()
        }

        // JTKit's Settings window: General (Open at Login, the menu bar item), Connections,
        // Automation and Updates.
        SettingsWindow(updates: updates, opensTabsByName: true) {
            GeneralSettingsSections(loginItem: loginItem, menuBar: menuBar)
        } tabs: {
            SettingsView(connections: connections)
                // Settings › Connections notes that these are the real connections.
                .environment(connections.demo)
            SettingsTab("Automation", systemImage: "clock.arrow.circlepath") {
                AutomationSettingsSections(automation: automation)
            }
        }

        // the share on target of each tracked Blueprint, Refresh All, Open Window
        MenuBarExtra(isInserted: Binding(get: { menuBar.isShown }, set: { menuBar.isShown = $0 })) {
            MenuBarContent(model: model, automation: automation)
        } label: {
            Label("Software Update Dashboard", systemImage: "square.stack.3d.up")
        }
        .menuBarExtraStyle(.window)

        AboutWindow(configuration: .softwareUpdateDashboard)

        // Help › Software Update Dashboard Help: the same in Demo Mode
        Window("Software Update Dashboard Help", id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 720, height: 760)

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
