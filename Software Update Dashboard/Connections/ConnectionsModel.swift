import Foundation
import JTKit
import Observation
import SwiftUI

/// The saved Jamf Platform API connections, the one in use, demo mode, and
/// the read-only clients the app reads through.
///
/// Read only by construction: every client allows GET (and HEAD) only; the
/// sign-in is the token provider’s own request. Nothing is ever written to
/// Jamf.
@MainActor
@Observable
final class ConnectionsModel {
    nonisolated static let keychainService = "be.jordythery.softwareupdatedashboard.jamf"
    nonisolated static let connectionsKey = "connections"
    nonisolated static let activeKey = "activeConnectionID"
    nonisolated static let demoModeKey = "demoMode"
    /// The Platform API permissions the app asks for, all read only.
    nonisolated static let permissions = [
        JamfPlatform.Permission.blueprintsRead, JamfPlatform.Permission.devicesRead,
        JamfPlatform.Permission.deviceGroupsRead, JamfPlatform.Permission.declarationsRead,
    ]

    let saved: ConnectionStore<AppConnection>
    let activityLog: ActivityLog
    let demo: DemoMode
    let demoChoice: DemoConnectionChoice
    let waits = RequestWaits()

    /// The connection chosen in the picker; remembered across launches.
    var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession

    init(saved: ConnectionStore<AppConnection>, defaults: UserDefaults, activityLog: ActivityLog, demo: DemoMode,
         holdsSavedConnections: Bool) {
        self.saved = saved
        self.defaults = defaults
        self.activityLog = activityLog
        self.demo = demo
        demoChoice = DemoConnectionChoice(mode: demo, connections: [.demoJamfPlatform])
        // Under tests the saved connections are never reached: every request
        // for them, sign-in and Test Connection included, is refused and
        // written down for the release check (demo connections are unaffected).
        session = TestRun.isActive && holdsSavedConnections
            ? TestRun.refusingSession(log: .savedConnections, message: UnderTest.refusal) : Self.jamfSession
        let remembered = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        activeID = remembered.flatMap { saved.record(id: $0) != nil ? $0 : nil } ?? saved.records.first?.id
        // the sample devices mid-update, on the demo Platform API only
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer)
    }

    /// The model for this launch: the saved connections and Keychain; as the
    /// unit-test host or in a sandbox run (UI tests), an empty list in
    /// throwaway settings and secrets in memory; under the live-check switch,
    /// the release check’s connections (JTKit).
    static func forLaunch(activityLog: ActivityLog) -> ConnectionsModel {
        let isTestHost = TestRun.isUnitTestHost
        let isSandbox = DemoMode.isSandboxLaunch
        let defaults: UserDefaults = isTestHost ? UnderTest.emptiedDefaults(domain: UnderTest.unitTestHostDomain)
            : isSandbox ? DemoMode.sandboxDefaults() : .standard
        let secrets: any SecretStore = isTestHost || isSandbox
            ? SandboxSecretStore()
            : KeychainSecretStore(service: keychainService, label: "Software Update Dashboard")
        let list = ConnectionStore<AppConnection>(
            storage: UserDefaultsConnectionStorage(key: connectionsKey, defaults: defaults),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { activityLog.recordAction($0, isWarning: true) },
            // under the live-check switch: the run's connections, in memory
            liveRecord: { AppConnection(connection: $0) })
        return ConnectionsModel(saved: list, defaults: defaults, activityLog: activityLog,
                                demo: DemoMode(key: demoModeKey, defaults: defaults),
                                holdsSavedConnections: !(isTestHost || isSandbox || LiveLaunch.isSwitched))
    }

    /// A model for previews and tests: nothing saved, no Keychain. A test
    /// that reads its own settings passes its own throwaway `defaults`.
    static func preview(activityLog: ActivityLog? = nil, defaults given: UserDefaults? = nil) -> ConnectionsModel {
        let activityLog = activityLog ?? ActivityLog()
        let defaults = given ?? UnderTest.emptiedDefaults(domain: "be.jordythery.softwareupdatedashboard.preview")
        let list = ConnectionStore<AppConnection>(storage: InMemoryConnectionStorage(),
                                                   secrets: [.main: SecretLocation(store: SandboxSecretStore())])
        return ConnectionsModel(saved: list, defaults: defaults, activityLog: activityLog,
                                demo: DemoMode(key: demoModeKey, defaults: defaults), holdsSavedConnections: false)
    }

    nonisolated static let jamfSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: The connection in use

    func role() -> ConnectionRole {
        .active(selection: Binding(get: { self.activeID }, set: { self.activeID = $0 }), demo: demoChoice)
    }

    /// The demo connection when demo mode is on, else the chosen saved one.
    var connectionInUse: Connection? {
        if demoChoice.isActive { return demoChoice.selected }
        return activeRecord?.connection
    }

    var activeRecord: AppConnection? {
        activeID.flatMap { saved.record(id: $0) }
    }

    /// The time zone Jamf Pro writes status item times in.
    var serverTimeZone: TimeZone {
        demoChoice.isActive ? TimeZone(identifier: "UTC") ?? .gmt : activeRecord?.timeZone ?? .gmt
    }

    /// Changes whenever the connection in use does, so views read again.
    var inUseKey: String {
        guard let connection = connectionInUse else { return "none" }
        return "\(connection.id) \(connection.name) \(demoChoice.isActive)"
    }

    // MARK: Clients

    /// A read-only client for the connection in use; nil without one.
    func client() throws -> JamfPlatform.Client? {
        if demoChoice.isActive, let connection = demoChoice.selected, let source = demo.source(for: connection) {
            let recorder = RequestRecorder(session: source.session, log: activityLog, service: connection.service.displayName,
                                           connection: connection.name, waits: waits)
            return try JamfPlatform.Client(connection: source.connection, secret: source.secret, recorder: recorder,
                                           permits: Self.permits)
        }
        guard let record = activeRecord else { return nil }
        return try client(for: record, typedSecret: nil)
    }

    /// Apple’s release data, on the demo network in demo mode.
    func appleReleases() -> AppleReleases.Client {
        let userAgent = "Software Update Dashboard/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        if demoChoice.isActive, let connection = demoChoice.selected, let source = demo.source(for: connection) {
            return AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: activityLog, service: "Apple release data"),
                                        userAgent: userAgent, sofaURL: DemoAppleReleaseServer.sofaURL,
                                        gdmfURL: DemoAppleReleaseServer.gdmfURL)
        }
        let session = TestRun.isActive && !LiveLaunch.isSwitched
            ? TestRun.refusingSession(log: .savedConnections, message: UnderTest.refusal) : Self.jamfSession
        return AppleReleases.Client(recorder: RequestRecorder(session: session, log: activityLog, service: "Apple release data"),
                                    userAgent: userAgent)
    }

    /// GET and HEAD only: the app never changes anything in Jamf.
    nonisolated static let permits: @Sendable (HTTPRequest) -> Bool = { $0.isRead }

    private func client(for record: AppConnection, typedSecret: String?) throws -> JamfPlatform.Client {
        let secret = try typedSecret ?? saved.requiredSecret(for: record.connection)
        let recorder = RequestRecorder(session: session, log: activityLog, service: record.connection.service.displayName,
                                       connection: record.connection.name, waits: waits)
        return try JamfPlatform.Client(connection: record.connection, secret: { secret }, recorder: recorder,
                                       permits: Self.permits)
    }

    // MARK: Settings

    static func newRecord(_ service: ConnectionService) -> AppConnection {
        AppConnection(connection: Connection(name: "", service: .jamfPlatform, region: .eu))
    }

    /// Signs in and checks each read permission the app uses that has a list
    /// to try (declarations:read has none: it is checked on the first Inspect).
    func testConnection(_ record: AppConnection, typed: [ConnectionSecretKind: String]) async throws -> String {
        let typedSecret = typed[.main].flatMap { $0.isEmpty ? nil : $0 }
        let client = try client(for: record, typedSecret: typedSecret)
        return try await client.testConnection(checks: [.blueprintsRead, .deviceGroupsRead, .devicesRead]) {
            let groups = try await client.mobileDeviceGroups().count + client.computerGroups().count
            return "\(groups) Jamf Pro \(groups == 1 ? "group" : "groups")"
        }
    }

    func connectionWasDeleted(_ record: AppConnection) {
        if activeID == record.id { activeID = saved.records.first?.id }
    }
}
