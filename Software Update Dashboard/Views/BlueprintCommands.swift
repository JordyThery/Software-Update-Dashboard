import JTKit
import SwiftUI

/// What the menu bar’s commands act on: the main window’s model and page.
struct BlueprintFocus {
    let model: DashboardModel
    let page: Binding<BlueprintView.Page>?
    let sheet: Binding<BlueprintSheet?>
    let export: ((Bool) -> Void)?
    /// Export Report as PDF: true for all tracked Blueprints, false for the one on screen.
    let exportPDF: ((Bool) -> Void)?
    /// Set to ask for confirmation before Stop Tracking.
    let stopTracking: Binding<UUID?>
}

/// The devices selected in the device list, for the Device menu.
struct DeviceSelection {
    let model: DashboardModel
    let trackedID: UUID
    let devices: [DeviceStatus]
}

extension FocusedValues {
    @Entry var blueprintFocus: BlueprintFocus?
    @Entry var deviceSelection: DeviceSelection?
}

/// The Blueprint menu and the View menu’s pages: every toolbar and context
/// command, also in the menu bar.
struct BlueprintCommands: Commands {
    @FocusedValue(\.blueprintFocus) private var focus

    private var selectedID: UUID? {
        if case .blueprint(let id)? = focus?.model.selection { return id }
        return nil
    }

    private var result: RefreshResult? { selectedID.flatMap { focus?.model.results[$0] } }
    private var isDemo: Bool { focus?.model.connections.demoChoice.isActive == true }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Dashboard") { focus?.page?.wrappedValue = .dashboard }
                .keyboardShortcut("1")
                .disabled(focus?.page == nil)
            Button("Devices") { focus?.page?.wrappedValue = .devices }
                .keyboardShortcut("2")
                .disabled(focus?.page == nil)
            Divider()
        }
        CommandMenu("Blueprint") {
            Button("Track a Blueprint…") { focus?.sheet.wrappedValue = .track }
                .disabled(focus == nil || focus?.model.connectionID == nil || isDemo || focus?.model.canChangeTracked == false)
            Divider()
            Button("Refresh") {
                if let id = selectedID, let model = focus?.model { Task { await model.refresh(id) } }
            }
            .keyboardShortcut("r")
            .disabled(selectedID == nil || focus?.model.refreshing.contains(selectedID!) == true)
            Button("Refresh All") {
                if let model = focus?.model { Task { await model.refreshAll() } }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(focus?.model.trackedBlueprints.isEmpty ?? true)
            Divider()
            Button("Compare with a Group…") { if let id = selectedID { focus?.sheet.wrappedValue = .compare(id) } }
                .disabled(selectedID == nil)
            Button("Stop Comparing") { if let id = selectedID { focus?.model.setCompareGroup(nil, for: id) } }
                .disabled(selectedID.flatMap { focus?.model.tracked($0)?.compareGroup } == nil)
            Button("Set Update Start…") { if let id = selectedID { focus?.sheet.wrappedValue = .updateStarted(id) } }
                .disabled(selectedID == nil)
            Button("Remove Update Start") { if let id = selectedID { focus?.model.setUpdateStarted(nil, for: id) } }
                .disabled(selectedID.flatMap { focus?.model.tracked($0)?.updateStarted } == nil)
            Button("Notifications…") { if let id = selectedID { focus?.sheet.wrappedValue = .notifications(id) } }
                .disabled(selectedID == nil)
            Divider()
            Button("Inspect Devices Needing Attention") {
                guard let id = selectedID, let model = focus?.model, let result else { return }
                Task { await model.inspect(InspectWorkflow.select(result.devices), in: id) }
            }
            .disabled(result == nil)
            Button("Export Device List as CSV…") { focus?.export?(true) }
                .disabled(focus?.export == nil || result == nil)
            Button("Export Summary…") { focus?.export?(false) }
                .disabled(focus?.export == nil || result == nil)
            Button("Export Report as PDF…") { focus?.exportPDF?(false) }
                .disabled(focus?.exportPDF == nil || result == nil)
            Button("Export Report of All Blueprints as PDF…") { focus?.exportPDF?(true) }
                .disabled(focus?.model.trackedBlueprints.isEmpty ?? true)
            Button("Open Blueprint in Jamf Pro") {
                if let id = selectedID, let model = focus?.model, let page = model.page(of: id) { model.open([page]) }
            }
            .disabled(selectedID.flatMap { focus?.model.page(of: $0) } == nil)
            Divider()
            Button("Stop Tracking…") {
                if let id = selectedID { focus?.stopTracking.wrappedValue = id }
            }
            .disabled(selectedID == nil || focus?.model.canChangeTracked == false)
            if isDemo, let model = focus?.model {
                Divider()
                Picker("Demo Situation", selection: Binding(get: { model.demoSituation }, set: { situation in Task { await model.setDemoSituation(situation) } })) {
                    ForEach(DemoSituation.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
    }
}

/// The Device menu: what the device list’s context menu does, for the
/// selected devices.
struct DeviceCommands: Commands {
    @FocusedValue(\.deviceSelection) private var selection
    @FocusedValue(\.blueprintFocus) private var focus

    private var pages: [URL] { selection.map { $0.model.pages(of: $0.devices) } ?? [] }

    var body: some Commands {
        CommandMenu("Device") {
            Button("Find a Device…") { focus?.sheet.wrappedValue = .findDevice }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(focus == nil || focus?.model.trackedBlueprints.isEmpty == true)
            Divider()
            Button("Open in Jamf Pro") { selection?.model.open(pages) }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(pages.isEmpty)
            Button("Inspect") {
                guard let selection else { return }
                Task { await selection.model.inspect(selection.devices, in: selection.trackedID) }
            }
            .disabled(selection?.devices.isEmpty ?? true)
        }
    }
}
