import JTKit
import SwiftUI

/// The main window: the tracked groups in the sidebar, the selected one’s
/// dashboard in the detail, and the connection in use in the toolbar.
struct ContentView: View {
    let connections: ConnectionsModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("Overview", systemImage: "square.grid.2x2")
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if connections.connectionInUse == nil {
                NoConnectionView(demo: connections.demo)
            } else {
                ContentUnavailableView("No Tracked Groups", systemImage: "square.stack.3d.up",
                                       description: Text("Add a Jamf Pro group and the Blueprint that enforces its update."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionPicker(store: connections.saved, role: connections.role())
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
