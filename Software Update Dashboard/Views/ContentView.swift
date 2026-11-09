import JTKit
import SwiftUI

/// The main window: the overview and the tracked groups in the sidebar, the
/// selected one in the detail, and the connection in use in the toolbar.
struct ContentView: View {
    let connections: ConnectionsModel
    @State private var model: DashboardModel
    @State private var isAdding = false
    @State private var page: GroupView.Page = .dashboard
    /// Set by the menu or the toolbar: true for the CSV, false for the summary.
    @State private var exportRequest: Bool?

    init(connections: ConnectionsModel) {
        self.connections = connections
        _model = State(initialValue: DashboardModel(connections: connections))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, isAdding: $isAdding)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if connections.connectionInUse == nil {
                NoConnectionView(demo: connections.demo)
            } else {
                switch model.selection {
                case .group(let id)?:
                    if let group = model.group(id) {
                        GroupView(model: model, group: group, page: $page, exportRequest: $exportRequest)
                    } else {
                        OverviewView(model: model, isAdding: $isAdding)
                    }
                default:
                    OverviewView(model: model, isAdding: $isAdding)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionPicker(store: connections.saved, role: connections.role())
            }
        }
        .sheet(isPresented: $isAdding) {
            AddGroupSheet(model: model)
        }
        .onChange(of: connections.inUseKey) {
            model.connectionChanged()
        }
        .focusedSceneValue(\.groupFocus, GroupFocus(
            model: model,
            page: isGroupSelected ? $page : nil,
            isAdding: $isAdding,
            export: isGroupSelected ? { exportRequest = $0 } : nil))
    }

    private var isGroupSelected: Bool {
        if case .group? = model.selection { return true }
        return false
    }
}

/// The overview and the tracked groups.
struct SidebarView: View {
    @Bindable var model: DashboardModel
    @Binding var isAdding: Bool

    var body: some View {
        List(selection: $model.selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(DashboardModel.Selection.overview)
            Section("Tracked Groups") {
                ForEach(model.groups) { group in
                    Label(group.groupName, systemImage: group.isComputerGroup ? "laptopcomputer" : "ipad")
                        .badge(model.latestCounts(group.id).map { Text($0.counts.percentText) })
                        .tag(DashboardModel.Selection.group(group.id))
                        .contextMenu {
                            Button("Refresh") { Task { await model.refresh(group.id) } }
                            if !model.connections.demoChoice.isActive {
                                Divider()
                                Button("Stop Tracking", role: .destructive) { model.remove(group.id) }
                            }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isAdding = true
                } label: {
                    Label("Track a Group…", systemImage: "plus")
                }
                .disabled(model.connectionID == nil || model.connections.demoChoice.isActive)
                .help(model.connections.demoChoice.isActive ? "Demo Mode has its own sample groups." : "Track a Jamf Pro group and its update Blueprint")
            }
        }
    }
}

/// What the window shows before there is a connection to read.
struct NoConnectionView: View {
    let demo: DemoMode

    var body: some View {
        ContentUnavailableView {
            Label("No Connection", systemImage: "network.slash")
        } description: {
            Text("Add a Jamf Platform API connection in Settings, or try the app with sample devices in Demo Mode.")
        } actions: {
            SettingsLink { Text("Open Settings…") }
            DemoModeToggle(demo: demo)
        }
    }
}

#Preview {
    ContentView(connections: .preview())
}
