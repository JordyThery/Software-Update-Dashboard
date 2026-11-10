import JTKit
import SwiftUI

/// The main window: the overview and the tracked Blueprints in the sidebar,
/// the selected one in the detail, and the connection in use in the toolbar.
struct ContentView: View {
    let connections: ConnectionsModel
    let model: DashboardModel
    let automation: AutoRefresh
    @State private var sheet: BlueprintSheet?
    @State private var page: BlueprintView.Page = .dashboard
    /// Set by the menu or the toolbar: true for the CSV, false for the summary.
    @State private var exportRequest: Bool?
    /// The tracked Blueprint whose Stop Tracking waits for confirmation.
    @State private var stopTracking: UUID?

    init(connections: ConnectionsModel, model: DashboardModel, automation: AutoRefresh) {
        self.connections = connections
        self.model = model
        self.automation = automation
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, sheet: $sheet, stopTracking: $stopTracking)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                if connections.connectionInUse == nil {
                    NoConnectionView(demo: connections.demo)
                } else if case .blueprint(let id)? = model.selection, let tracked = model.tracked(id) {
                    BlueprintView(model: model, tracked: tracked, page: $page, exportRequest: $exportRequest, sheet: $sheet)
                } else {
                    OverviewView(model: model, automation: automation, sheet: $sheet)
                }
            }
            .safeAreaInset(edge: .top) {
                if let copy = model.shownUnreadableCopy {
                    UnreadableListBanner(model: model, copy: copy)
                }
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
            case .notifications(let id): NotificationSheet(model: model, trackedID: id)
            }
        }
        .confirmationDialog(stopTrackingTitle, isPresented: Binding(get: { stopTracking != nil }, set: { if !$0 { stopTracking = nil } }),
                            titleVisibility: .visible) {
            Button("Stop Tracking and Delete History", role: .destructive) {
                if let id = stopTracking { model.remove(id) }
                stopTracking = nil
            }
            Button("Cancel", role: .cancel) { stopTracking = nil }
        } message: {
            Text(stopTrackingMessage)
        }
        .confirmationDialog("Open \(Plural.count(model.pagesToConfirm?.count ?? 0, "Device")) in Jamf Pro?",
                            isPresented: Binding(get: { model.pagesToConfirm != nil }, set: { if !$0 { model.pagesToConfirm = nil } }),
                            titleVisibility: .visible) {
            Button("Open \(model.pagesToConfirm?.count ?? 0) Pages") { model.open(model.pagesToConfirm ?? [], confirmed: true) }
            Button("Cancel", role: .cancel) { model.pagesToConfirm = nil }
        } message: {
            Text("Each device opens in its own browser tab.")
        }
        .alert("Demo Mode Opens Nothing", isPresented: Binding(get: { model.demoPages != nil }, set: { if !$0 { model.demoPages = nil } })) {
            Button("OK") { model.demoPages = nil }
        } message: {
            Text(Self.demoPagesText(model.demoPages ?? []))
        }
        .onChange(of: connections.inUseKey) {
            model.connectionChanged()
        }
        .focusedSceneValue(\.blueprintFocus, BlueprintFocus(
            model: model, page: selectedID != nil ? $page : nil, sheet: $sheet,
            export: selectedID != nil ? { exportRequest = $0 } : nil, stopTracking: $stopTracking))
    }

    /// What Demo Mode says instead of opening pages: the first few, and how many more.
    static func demoPagesText(_ urls: [URL]) -> String {
        let shown = urls.prefix(3).map(\.absoluteString)
        let more = urls.count > shown.count ? "\nand \(urls.count - shown.count) more" : ""
        return "With a real connection, this opens in your browser:\n" + shown.joined(separator: "\n") + more
    }

    private var stopTrackingTitle: String {
        "Stop tracking “\(stopTracking.flatMap { model.tracked($0)?.blueprintName } ?? "this Blueprint")”?"
    }

    private var stopTrackingMessage: String {
        let refreshes = stopTracking.map { model.snapshots($0).count } ?? 0
        let history = refreshes == 0 ? "Its history on this Mac will be deleted."
            : "Its history on this Mac (\(refreshes) \(refreshes == 1 ? "refresh" : "refreshes")) will be deleted and can’t be restored."
        return history + " Nothing changes in Jamf."
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
    case notifications(UUID)

    var id: String {
        switch self {
        case .track: "track"
        case .compare(let id): "compare \(id)"
        case .updateStarted(let id): "started \(id)"
        case .notifications(let id): "notifications \(id)"
        }
    }
}

/// The overview and the tracked Blueprints.
struct SidebarView: View {
    @Bindable var model: DashboardModel
    @Binding var sheet: BlueprintSheet?
    @Binding var stopTracking: UUID?

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
                            Button("Notifications…") { sheet = .notifications(tracked.id) }
                            Divider()
                            Button("Open in Jamf Pro") { model.page(of: tracked.id).map { model.open([$0]) } }
                                .disabled(model.page(of: tracked.id) == nil)
                            Divider()
                            Button("Stop Tracking…", role: .destructive) { stopTracking = tracked.id }
                                .disabled(!model.canChangeTracked)
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
                .disabled(model.connectionID == nil || model.connections.demoChoice.isActive || !model.canChangeTracked)
                .help(model.connections.demoChoice.isActive ? "Demo Mode has its own sample Blueprints." : "Track a Blueprint with a software update")
            }
        }
    }
}

/// The saved tracked Blueprints couldn’t be read: they were copied, and
/// nothing is saved over them.
struct UnreadableListBanner: View {
    let model: DashboardModel
    let copy: String
    @State private var confirmsNewList = false
    @State private var exportError: String?

    var body: some View {
        WarningBanner(text: "The saved list of tracked Blueprints couldn’t be read. A copy was kept, and changes to the list aren’t saved until you start a new list.",
                      detail: exportError, help: "The copy is the setting “\(copy)”.") {
            Button("Show Copy in Finder") {
                do {
                    NSWorkspace.shared.activateFileViewerSelecting([try model.exportUnreadableCopy()])
                } catch {
                    exportError = error.localizedDescription
                }
            }
            Button("Start a New List…") { confirmsNewList = true }
        }
        .confirmationDialog("Start a new list of tracked Blueprints?", isPresented: $confirmsNewList, titleVisibility: .visible) {
            Button("Start a New List") { model.startNewTrackedList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copy of the list that couldn’t be read is kept; nothing is deleted. Histories on this Mac are kept.")
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
    let connections = ConnectionsModel.preview()
    let model = DashboardModel(connections: connections)
    ContentView(connections: connections, model: model, automation: AutoRefresh(model: model, defaults: connections.defaults))
}
