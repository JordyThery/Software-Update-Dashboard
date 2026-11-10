import JTKit
import SwiftUI

/// Show the menu bar item (saved under `showMenuBarItem`, on by default).
@MainActor
@Observable
final class MenuBarSetting {
    nonisolated static let key = "showMenuBarItem"
    @ObservationIgnored private let defaults: UserDefaults

    var isShown: Bool {
        didSet { defaults.set(isShown, forKey: Self.key) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isShown = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}

/// Settings › General: Open at Login and the menu bar item.
struct GeneralSettingsSections: View {
    let loginItem: LoginItem
    @Bindable var menuBar: MenuBarSetting

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginItem.state == .on || loginItem.state == .needsApproval },
                                                  set: { loginItem.set($0) }))
                .disabled(loginItem.state == .unavailable)
            switch loginItem.state {
            case .needsApproval:
                HStack {
                    Text("Waiting for your approval in System Settings › General › Login Items.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open System Settings") { loginItem.openSystemSettings() }
                }
            case .unavailable:
                Text("Can’t be changed in a test or sandbox run.").font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            if let problem = loginItem.problem { WarningLabel(problem) }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
        Section {
            Toggle("Show in menu bar", isOn: $menuBar.isShown)
            Text("The share on target of each tracked Blueprint, Refresh All and Open Window.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Automation: automatic refresh, and keeping this Mac awake for it.
struct AutomationSettingsSections: View {
    @Bindable var automation: AutoRefresh

    var body: some View {
        Section {
            Picker("Refresh automatically", selection: $automation.hours) {
                ForEach(AutoRefresh.intervals, id: \.self) { hours in
                    Text(hours == 0 ? "Off" : hours == 1 ? "Every hour" : "Every \(hours) hours").tag(hours)
                }
            }
            Text("Reads every tracked Blueprint of the connection in use, one after another, and keeps each refresh in its history. "
                 + "A refresh that fails keeps the previous one and is tried again at the next interval.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Keep this Mac awake while automatic refresh is on", isOn: $automation.keepsAwake)
                .disabled(!automation.isOn)
            if !automation.isOn {
                Text("Turn on automatic refresh to use this.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Only while the Mac is on power; on battery it may sleep. After a sleep, automatic refresh catches up once.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The Overview’s line about automatic refresh: the last and next refresh,
/// any error, and Stop while one runs.
struct AutomationLine: View {
    let automation: AutoRefresh

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.text(automation))
                    if let error = automation.lastError {
                        WarningLabel("Last refresh: \(error)")
                    }
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
            }
            .font(.callout)
            Spacer()
            if automation.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop Refresh") { automation.stop() }
                    .help("Stop this automatic refresh; the next one runs as planned")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    static func text(_ automation: AutoRefresh) -> String {
        let every = automation.hours == 1 ? "every hour" : "every \(automation.hours) hours"
        var parts = ["Automatic refresh \(every)"]
        if automation.isRunning { parts.append("refreshing now") }
        if let last = automation.lastRun { parts.append("last \(last.formatted(date: .omitted, time: .shortened))") }
        if let next = automation.nextRun, !automation.isRunning {
            parts.append("next \(next.formatted(Calendar.current.isDateInToday(next) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute()))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The menu bar item’s window: each tracked Blueprint’s share on target
/// with a colored dot (and its number, so never by color alone), Refresh
/// All and Open Window.
struct MenuBarContent: View {
    let model: DashboardModel
    let automation: AutoRefresh
    @Environment(\.openWindow) private var openWindow
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.trackedBlueprints.isEmpty {
                Text(model.connectionID == nil ? "No connection" : "No tracked Blueprints").foregroundStyle(.secondary)
            }
            ForEach(model.trackedBlueprints) { tracked in
                let percent = model.latestCounts(tracked.id)?.counts.percentOnTarget
                Button {
                    model.selection = .blueprint(tracked.id)
                    open()
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(ShareLevel.color(percent)).frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(tracked.blueprintName).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(percent.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? "–")
                            .monospacedDigit().foregroundStyle(.secondary)
                        if model.refreshing.contains(tracked.id) { ProgressView().controlSize(.mini) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(hovered == tracked.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tracked.id : (hovered == tracked.id ? nil : hovered) }
                .accessibilityLabel("\(tracked.blueprintName), \(percent.map { "\($0.formatted()) percent on target" } ?? "not read yet")"
                                    + (model.refreshing.contains(tracked.id) ? ", refreshing" : ""))
            }
            if automation.isOn {
                Text(AutomationLine.text(automation)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Refresh All") { Task { await model.refreshAll() } }
                    .disabled(model.trackedBlueprints.isEmpty || !model.refreshing.isEmpty)
                Spacer()
                Button("Open Window") { open() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// The dot’s color for a share on target: green from 90%, orange from 60%, red below; gray before a refresh.
nonisolated enum ShareLevel {
    static func color(_ percent: Double?) -> Color {
        guard let percent else { return .gray }
        return percent >= 90 ? .green : percent >= 60 ? .orange : .red
    }
}

/// One tracked Blueprint’s notifications.
struct NotificationSheet: View {
    let model: DashboardModel
    let trackedID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var shareOn = false
    @State private var level = NotificationRule.defaultLevel
    @State private var failedOrStuck = false

    private var isDemo: Bool { model.connections.demoChoice.isActive }

    var body: some View {
        Form {
            Section {
                Toggle("When the share on target crosses a level", isOn: $shareOn)
                Stepper("Level: \(level)%", value: $level, in: 5...100, step: 5)
                    .disabled(!shareOn)
                Toggle("When devices are newly failed or stuck", isOn: $failedOrStuck)
            } header: {
                Text("Notify Me for “\(model.tracked(trackedID)?.blueprintName ?? "This Blueprint")”")
            } footer: {
                Text(isDemo ? "Demo Mode sends no notifications: the activity log shows what it would have sent."
                     : "Only a change between two refreshes notifies, never the first refresh.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let problem = model.notifier.permissionProblem, !isDemo { WarningLabel(problem) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            let rule = model.notifier.rule(for: trackedID, demo: isDemo)
            shareOn = rule.shareLevel != nil
            level = rule.shareLevel ?? NotificationRule.defaultLevel
            failedOrStuck = rule.failedOrStuck
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let rule = NotificationRule(shareLevel: shareOn ? level : nil, failedOrStuck: failedOrStuck)
                    Task {
                        await model.notifier.setRule(rule, for: trackedID, demo: isDemo)
                        // a refused permission stays on screen
                        if model.notifier.permissionProblem == nil || isDemo || !rule.isOn { dismiss() }
                    }
                }
            }
        }
    }
}
