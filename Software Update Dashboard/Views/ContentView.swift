import JTKit
import SwiftUI

/// The main window: the overview and the tracked Blueprints in the sidebar,
/// the selected one in the detail, and the connection in use in the toolbar.
struct ContentView: View {
    let connections: ConnectionsModel
    @State private var model: DashboardModel
    @State private var sheet: BlueprintSheet?
    @State private var page: BlueprintView.Page = .dashboard
    /// Set by the menu or the toolbar: true for the CSV, false for the summary.
    @State private var exportRequest: Bool?

    init(connections: ConnectionsModel) {
        self.connections = connections
        _model = State(initialValue: DashboardModel(connections: connections))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if connections.connectionInUse == nil {
                NoConnectionView(demo: connections.demo)
            } else if case .blueprint(let id)? = model.selection, let tracked = model.tracked(id) {
                BlueprintView(model: model, tracked: tracked, page: $page, exportRequest: $exportRequest, sheet: $sheet)
            } else {
                OverviewView(model: model, sheet: $sheet)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionPicker(store: connections.saved, role: connections.role())
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .track: AddBlueprintSheet(model: model)
            case .compare(let id): CompareGroupSheet(model: model, trackedID: id)
            case .updateStarted(let id): UpdateStartedSheet(model: model, trackedID: id)
            }
        }
        .onChange(of: connections.inUseKey) {
            model.connectionChanged()
        }
        .focusedSceneValue(\.blueprintFocus, BlueprintFocus(
            model: model, page: selectedID != nil ? $page : nil, sheet: $sheet,
            export: selectedID != nil ? { exportRequest = $0 } : nil))
    }

    private var selectedID: UUID? {
        if case .blueprint(let id)? = model.selection { return id }
        return nil
    }
}

/// The sheets of the main window.
enum BlueprintSheet: Identifiable, Hashable {
    case track
    case compare(UUID)
    case updateStarted(UUID)

    var id: String {
        switch self {
        case .track: "track"
        case .compare(let id): "compare \(id)"
        case .updateStarted(let id): "started \(id)"
        }
    }
}

/// The overview and the tracked Blueprints.
struct SidebarView: View {
    @Bindable var model: DashboardModel
    @Binding var sheet: BlueprintSheet?

    var body: some View {
        List(selection: $model.selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(DashboardModel.Selection.overview)
            Section("Tracked Blueprints") {
                ForEach(model.trackedBlueprints) { tracked in
                    Label(tracked.blueprintName, systemImage: "square.stack.3d.up")
                        .badge(model.latestCounts(tracked.id).map { Text($0.counts.percentText) })
                        .tag(DashboardModel.Selection.blueprint(tracked.id))
                        .contextMenu {
                            Button("Refresh") { Task { await model.refresh(tracked.id) } }
                            Button("Compare with a Group…") { sheet = .compare(tracked.id) }
                            Button("Set Update Start…") { sheet = .updateStarted(tracked.id) }
                            if !model.connections.demoChoice.isActive {
                                Divider()
                                Button("Stop Tracking", role: .destructive) { model.remove(tracked.id) }
                            }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    sheet = .track
                } label: {
                    Label("Track a Blueprint…", systemImage: "plus")
                }
                .disabled(model.connectionID == nil || model.connections.demoChoice.isActive)
                .help(model.connections.demoChoice.isActive ? "Demo Mode has its own sample Blueprints." : "Track a Blueprint with a software update")
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
