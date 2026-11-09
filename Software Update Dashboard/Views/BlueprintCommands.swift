import JTKit
import SwiftUI

/// What the menu bar’s commands act on: the main window’s model and page.
struct BlueprintFocus {
    let model: DashboardModel
    let page: Binding<BlueprintView.Page>?
    let sheet: Binding<BlueprintSheet?>
    let export: ((Bool) -> Void)?
}

extension FocusedValues {
    @Entry var blueprintFocus: BlueprintFocus?
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
                .disabled(focus == nil || focus?.model.connectionID == nil || isDemo)
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
            Divider()
            Button("Stop Tracking") {
                if let id = selectedID { focus?.model.remove(id) }
            }
            .disabled(selectedID == nil || isDemo)
        }
    }
}
