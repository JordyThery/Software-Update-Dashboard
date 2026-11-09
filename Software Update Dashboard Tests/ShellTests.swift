import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import Software_Update_Dashboard

@Suite("The app never changes anything in Jamf")
struct ReadOnlyTests {
    @Test("Only GET and HEAD are permitted")
    func permits() {
        for method in ["GET", "HEAD", "get"] {
            #expect(ConnectionsModel.permits(HTTPRequest(method: method, path: "pro/v1/computer-groups")))
        }
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            #expect(!ConnectionsModel.permits(HTTPRequest(method: method, path: "pro/v1/computer-groups")))
        }
    }

    @Test("It asks for read permissions only")
    func readPermissions() {
        #expect(ConnectionsModel.permissions.allSatisfy { $0.hasSuffix(":read") })
        #expect(Set(ConnectionsModel.permissions) == ["blueprints:read", "devices:read", "device-groups:read", "declarations:read"])
    }

    @Test("A write never leaves the app, also when a client is asked for one")
    @MainActor
    func refusedWrite() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"),
                                             tokens: StaticToken(), recorder: RequestRecorder(session: server.session, log: nil),
                                             permits: ConnectionsModel.permits, sleep: { _ in })
        await #expect(throws: (any Error).self) {
            _ = try await client.send(HTTPRequest(method: "POST", path: "pro/v1/buildings"))
        }
        #expect(server.requests.isEmpty)
    }
}

@Suite("Connections")
@MainActor
struct ConnectionTests {
    @Test("A saved connection without a server time zone reads as UTC")
    func defaultTimeZone() throws {
        let connection = Connection(name: "Lab", service: .jamfPlatform, region: .eu)
        let saved = try JSONEncoder().encode(["connection": connection])
        let record = try JSONDecoder().decode(AppConnection.self, from: saved)
        #expect(record.serverTimeZone == "UTC")
        #expect(record.timeZone.secondsFromGMT() == 0)
        #expect(AppConnection(connection: connection, serverTimeZone: "Nowhere/Else").timeZone.secondsFromGMT() == 0)
        #expect(AppConnection(connection: connection, serverTimeZone: "Europe/Brussels").timeZone.identifier == "Europe/Brussels")
    }

    @Test("A new connection is a Platform API connection")
    func newRecord() {
        #expect(ConnectionsModel.newRecord(.jamfPro).connection.service == .jamfPlatform)
    }

    @Test("Without a connection there is no client; in demo mode the demo one")
    func clients() throws {
        let model = ConnectionsModel.preview()
        #expect(model.connectionInUse == nil)
        #expect(try model.client() == nil)
        model.demo.isOn = true
        #expect(model.connectionInUse == .demoJamfPlatform)
        #expect(try model.client() != nil)
        #expect(model.serverTimeZone.secondsFromGMT() == 0)
    }

    @Test("The time zone list starts with UTC and holds every zone once")
    func timeZones() {
        #expect(SettingsView.timeZones.first == "UTC")
        #expect(Set(SettingsView.timeZones).count == SettingsView.timeZones.count)
        #expect(SettingsView.timeZones.contains("America/St_Johns"))
    }
}

/// A token source for tests, never a real token.
struct StaticToken: BearerTokenSource {
    func token() async throws -> String { "test-token" }
    func forgetToken() async {}
}
