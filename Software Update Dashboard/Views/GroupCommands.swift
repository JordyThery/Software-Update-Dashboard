import JTKit
import SwiftUI

/// What the menu bar’s commands act on: the main window’s model and page.
struct GroupFocus {
    let model: DashboardModel
    let page: Binding<GroupView.Page>?
    let isAdding: Binding<Bool>
    let export: ((Bool) -> Void)?
}

extension FocusedValues {
    @Entry var groupFocus: GroupFocus?
}

/// The Group menu and the View menu’s pages: every toolbar and context
/// command, also in the menu bar.
struct GroupCommands: Commands {
    @FocusedValue(\.groupFocus) private var focus

    private var selectedID: UUID? {
        if case .group(let id)? = focus?.model.selection { return id }
        return nil
    }

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
        CommandMenu("Group") {
            Button("Track a Group…") { focus?.isAdding.wrappedValue = true }
                .disabled(focus == nil || focus?.model.connectionID == nil || focus?.model.connections.demoChoice.isActive == true)
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
            .disabled(focus?.model.groups.isEmpty ?? true)
            Divider()
            Button("Inspect Devices Needing Attention") {
                guard let id = selectedID, let model = focus?.model, let result = model.results[id] else { return }
                Task { await model.inspect(InspectWorkflow.select(result.devices), in: id) }
            }
            .disabled(selectedID.flatMap { focus?.model.results[$0] } == nil)
            Button("Export Device List as CSV…") { focus?.export?(true) }
                .disabled(focus?.export == nil || selectedID.flatMap { focus?.model.results[$0] } == nil)
            Button("Export Summary…") { focus?.export?(false) }
                .disabled(focus?.export == nil || selectedID.flatMap { focus?.model.results[$0] } == nil)
            Divider()
            Button("Stop Tracking") {
                if let id = selectedID { focus?.model.remove(id) }
            }
            .disabled(selectedID == nil || focus?.model.connections.demoChoice.isActive == true)
        }
    }
}
