import JTKit
import SwiftUI

/// The Settings window’s Connections tab: JTKit’s shared list and editor for
/// the saved Jamf Platform API connections, with the Jamf Pro server’s time
/// zone and what the connection needs below the fields.
struct SettingsView: View {
    let connections: ConnectionsModel

    var body: some View {
        ConnectionsSettingsTab(
            store: connections.saved,
            services: [.jamfPlatform],
            optionalFields: [.jamfProWebURL],
            roles: [connections.role()],
            newRecord: ConnectionsModel.newRecord,
            didDelete: { connections.connectionWasDeleted($0) },
            test: { record, typed in try await connections.testConnection(record, typed: typed) }
        ) { record in
            Section {
                Picker("Jamf Pro server time zone", selection: record.serverTimeZone) {
                    ForEach(Self.timeZones, id: \.self) { Text($0).tag($0) }
                }
                Text("Jamf Pro writes the times of devices’ status reports in its own time zone. Jamf Cloud uses UTC.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(Self.help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// UTC first, then every zone the Mac knows.
    static let timeZones = [AppConnection.defaultServerTimeZone]
        + TimeZone.knownTimeZoneIdentifiers.filter { $0 != AppConnection.defaultServerTimeZone }.sorted()

    static let help = """
        Create an integration in Jamf Account scoped to a platform environment, in the region your Jamf Pro is hosted in. \
        It needs these read permissions only: \(ConnectionsModel.permissions.joined(separator: ", ")). \
        Software Update Dashboard never changes anything in Jamf. Copy the environment ID from the integration’s details. \
        Integrations expire after six months. The Jamf Pro web address is optional and used only for “Open in Jamf Pro” links. \
        The client secret is stored in the Keychain.
        """
}

#Preview {
    SettingsTabs {
        // Never the saved connections: a throwaway list.
        SettingsView(connections: .preview())
    }
}
