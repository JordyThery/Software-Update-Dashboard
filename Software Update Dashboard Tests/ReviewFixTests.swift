import Foundation
import JTKit
import Testing
@testable import Software_Update_Dashboard

/// 0.3.2: the low findings of the 0.3 review. Notifications turned off in
/// System Settings are said as soon as the Notifications sheet opens, and
/// Find a Device says why a device that left the scope isn’t shown.
/// Made-up devices.
@Suite("0.3.2: notifications and Find a Device")
@MainActor
struct ReviewFixTests {
    @Test("Turned off in System Settings: said when the sheet opens, without asking; allowed clears it; not asked yet and Demo Mode say nothing")
    func permissionOnOpen() async {
        let notifier = Notifier(defaults: TestFiles.defaults("notify-open"), activityLog: ActivityLog())
        var asked = 0
        notifier.authorize = { asked += 1; return true }
        var status: Bool? = false
        notifier.permissionStatus = { status }
        await notifier.checkPermission(demo: true)
        #expect(notifier.permissionProblem == nil)
        await notifier.checkPermission(demo: false)
        #expect(notifier.permissionProblem == Notifier.turnedOff && asked == 0)
        status = nil
        await notifier.checkPermission(demo: false)
        #expect(notifier.permissionProblem == Notifier.turnedOff)
        status = true
        await notifier.checkPermission(demo: false)
        #expect(notifier.permissionProblem == nil)
        // the button opens this app's page in System Settings › Notifications
        #expect(Notifier.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="))
        #expect(Notifier.settingsURL.absoluteString.hasSuffix(Bundle.main.bundleIdentifier ?? "be.jordythery.softwareupdatedashboard"))
    }

    @Test("Saved while notifications are off: the sheet says it’s saved and when notifications start; not in Demo Mode")
    func savedWhileOff() async {
        let notifier = Notifier(defaults: TestFiles.defaults("notify-saved"), activityLog: ActivityLog())
        notifier.authorize = { false }
        notifier.permissionStatus = { false }
        let rule = NotificationRule(failedOrStuck: true)
        await notifier.setRule(rule, for: UUID(), demo: false)
        #expect(notifier.permissionProblem == Notifier.turnedOff)
        #expect(notifier.savedNote(for: rule, demo: false) == "Saved. Notifications start once they’re turned on in System Settings.")
        #expect(notifier.savedNote(for: rule, demo: true) == nil && notifier.savedNote(for: nil, demo: false) == nil)
        #expect(notifier.savedNote(for: NotificationRule(), demo: false) == nil)
        // turned on in System Settings, back in the app: both go
        notifier.permissionStatus = { true }
        await notifier.checkPermission(demo: false)
        #expect(notifier.permissionProblem == nil && notifier.savedNote(for: rule, demo: false) == nil)
    }

    @Test("The server time zone warning stays until UTC is saved, on the dashboard as in Settings › Connections")
    func timeZoneWarningUntilSaved() throws {
        let connections = ConnectionsModel.preview()
        let connection = Connection(name: "Role A", service: .jamfPlatform, region: .eu,
                                    environmentID: UUID().uuidString, clientID: UUID().uuidString)
        try connections.saved.save(AppConnection(connection: connection, serverTimeZone: "Europe/Amsterdam"))
        connections.activeID = connection.id
        #expect(connections.serverTimeZoneWarning(forID: connection.id) == nil && !connections.serverTimeZoneLooksWrong)
        connections.noteServerTimeZone(looksWrong: true)
        #expect(connections.serverTimeZoneWarning(forID: connection.id) == ServerTimeZoneCheck.warning(zone: "Europe/Amsterdam"))
        #expect(connections.serverTimeZoneLooksWrong)
        #expect(ConnectionsModel.serverTimeZoneLine == "The Jamf Pro server time zone in Settings › Connections looks wrong.")
        // Use UTC changes only the editor's draft: nothing saved yet, so it still says so
        var draft = try #require(connections.saved.record(id: connection.id))
        draft.serverTimeZone = "UTC"
        #expect(connections.serverTimeZoneWarning(forID: connection.id) != nil)
        // saved: gone, also from the dashboard
        try connections.saved.save(draft)
        #expect(connections.serverTimeZoneWarning(forID: connection.id) == nil && !connections.serverTimeZoneLooksWrong)
        // a refresh that finds it fine forgets it
        connections.noteServerTimeZone(looksWrong: true)
        connections.noteServerTimeZone(looksWrong: false)
        #expect(connections.serverTimeZoneWarning(forID: connection.id) == nil)
    }

    @Test("A device Find a Device opened that isn’t in the new refresh: the list says it left the Blueprint’s scope")
    func leftScope() {
        let found = Sample.date("2026-11-24T06:33:00")
        let present = Sample.classify(Sample.iPad("1"), nil)
        let text = DeviceSearch.notShown(name: "Test iPad 2", device: "mobileDevice/2", foundIn: found, devices: [present])
        #expect(text == "Test iPad 2 isn’t in this refresh: it has left the Blueprint’s scope since the refresh of \(InspectFindings.moment(found)).")
        #expect(DeviceSearch.notShown(name: "Test iPad 1", device: present.id, foundIn: found, devices: [present]) == nil)
        #expect(DeviceSearch.notShown(name: "Test iPad 2", device: "mobileDevice/2", foundIn: nil, devices: [])
                == "Test iPad 2 isn’t in this refresh: it has left the Blueprint’s scope.")
    }
}
