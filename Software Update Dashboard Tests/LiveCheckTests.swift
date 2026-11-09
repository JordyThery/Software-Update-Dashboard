import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Testing
@testable import Software_Update_Dashboard

// Live checks, run only by Scripts/release-check.sh, which switches them on
// (JTKIT_LIVE=1) and passes the credentials it read from the login Keychain.
// ⌘U skips them. One role only: jamfpro-production, the allow-list's
// read-only production Jamf Pro over the Platform API. Reads only: the
// policy refuses anything else, and so do the app's own clients. Reports
// hold counts and findings, never a name, serial or host.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

private let role = "jamfpro-production"

/// The production role's Platform API client, read only, on the run's guarded network.
@MainActor
private func liveClient(_ run: LiveCheckRun) throws -> JamfPlatform.Client {
    let entry = try run.entry(role: role, service: .jamfPlatform)
    let connection = Connection(name: "Live check \(role)", service: .jamfPlatform,
                                region: try #require(JamfRegion(rawValue: entry.region ?? "")),
                                environmentID: try #require(entry.environmentID),
                                clientID: try run.credential(role, "client-id"))
    let secret = try run.credential(role, "client-secret")
    return try JamfPlatform.Client(connection: connection, secret: { secret },
                                   recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"),
                                   permits: ConnectionsModel.permits)
}

/// Records a step; a failed one also fails the test, so the run can’t pass with it.
@MainActor
private func record(_ run: LiveCheckRun, _ step: String, passed: Bool, note: String? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    run.record(step: step, passed: passed, note: note)
    if !passed { Issue.record("\(step): \(note ?? "failed")", sourceLocation: sourceLocation) }
}

private func failure(_ error: any Error) -> String {
    if let error = error as? JamfPlatform.APIError, error.status == 401 || error.status == 403 {
        return "MISSING PERMISSION (HTTP \(error.status ?? 0)): \(error.standardHints.joined(separator: " "))"
    }
    if let error = error as? JamfPlatform.APIError, let status = error.status { return "HTTP \(status)" }
    return "\(type(of: error))"
}

@MainActor
private func checkUnderTest(_ run: LiveCheckRun, when: String) {
    let saved = TestRun.AttemptLog.savedConnections.attempts()
    run.record(step: "no request to a saved connection under tests (\(when))", passed: saved.isEmpty,
               note: saved.isEmpty ? nil : "\(saved.count) refused")
    #expect(saved.isEmpty)
}

@Suite("Live: sign in", .enabled(if: live), .serialized)
@MainActor
struct LiveSignInTests {
    @Test func signIn() async throws {
        let run = try LiveCheckRun.current()
        checkUnderTest(run, when: "start")
        guard run.roles.contains(role) else { return }
        do {
            try await liveClient(run).signIn()
            run.record(step: "sign in: \(role)", passed: true)
        } catch {
            run.record(step: "sign in: \(role)", passed: false, note: failure(error))
            throw error
        }
        #expect(run.network.refusals.isEmpty)
    }
}

@Suite("Live: a mobile group end to end", .enabled(if: live), .serialized)
@MainActor
struct LiveReadTests {
    /// Reads, in the order the app does: the permissions, the groups, one
    /// mobile group's members and their status reports, a Blueprint with a
    /// software update, the app's own refresh, and one device's declaration
    /// report. Also the Classic route for a static computer group.
    /// Every ID and name of these devices, for `neverReport`.
    static func identifiers(_ members: [JamfPro.GroupMember]) -> [String] {
        members.flatMap { [$0.id, $0.serialNumber, $0.managementID, $0.udid, $0.name].compactMap { $0 } }
    }

    @Test func mobileGroupEndToEnd() async throws {
        let run = try LiveCheckRun.current()
        defer { checkUnderTest(run, when: "after the reads") }
        guard run.roles.contains(role) else { return }
        let client = try liveClient(run)
        func step(_ name: String) -> String { "\(role): \(name)" }

        // 1. the Platform permissions the app asks for
        for (check, result) in await client.checkPermissions([.blueprintsRead, .deviceGroupsRead, .devicesRead]) {
            record(run, step("permission \(check.permission)"), passed: result == .allowed, note: "\(result)")
        }

        // 2. the groups, and the first mobile group with members
        let groups: [JamfPro.DeviceGroup]
        do {
            groups = try await client.jamfProGroups()
            // never in the report, whatever a step or note says
            run.neverReport(groups.flatMap { [$0.groupID, $0.name] })
            record(run, step("Jamf Pro groups (device-groups:read)"), passed: true,
                       note: "\(groups.filter { $0.kind == .mobileDevice }.count) mobile, \(groups.filter { $0.kind == .computer }.count) computer")
        } catch {
            record(run, step("Jamf Pro groups (device-groups:read)"), passed: false, note: failure(error))
            throw error
        }
        var chosen: (group: JamfPro.DeviceGroup, members: [JamfPro.GroupMember])?
        var membershipError: (any Error)?
        for group in groups.filter({ $0.kind == .mobileDevice }).prefix(15) {
            do {
                let members = try await client.members(of: group)
                if !members.isEmpty { chosen = (group, members); break }
            } catch {
                membershipError = error
                break
            }
        }
        if let membershipError {
            record(run, step("mobile group members (device-groups:read, devices:read)"), passed: false, note: failure(membershipError))
            throw membershipError
        }
        if let chosen { run.neverReport(Self.identifiers(chosen.members)) }
        guard let chosen else {
            record(run, step("mobile group members"), passed: true, note: "no mobile group with members among the first 15: nothing to read")
            return
        }
        // diagnostic, kinds only: what the membership answer holds (over the Platform API, IDs and names)
        if let raw = try? await client.json("pro/v2/mobile-device-groups/\(chosen.group.isSmart ? "smart" : "static")-group-membership/\(chosen.group.groupID)",
                                            query: [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")]),
           let first = raw["results"]?.arrayValue?.first?.objectValue {
            func kind(_ key: String) -> String {
                switch first[key] {
                case nil: "absent"
                case .null?: "null"
                case .string(let text)?: text.isEmpty ? "empty text" : "text of \(text.count)"
                case .number?: "number"
                case .bool?: "bool"
                default: "other"
                }
            }
            let kinds = ["mobileDeviceId", "managementId", "timeZone", "lastContactDate", "osVersion", "serialNumber",
                         "modelIdentifier", "displayName"].map { ($0, kind($0)) }
            // the member's ID at least must be there, or the diagnostic read the wrong thing
            run.record(step: step("diagnostic: membership value kinds"), passed: kinds[0].1 != "absent",
                       note: kinds.map { "\($0.0): \($0.1)" }.joined(separator: ", "))
        } else {
            run.record(step: step("diagnostic: membership value kinds"), passed: false,
                       note: "the group's first membership page couldn't be read")
        }
        let withManagementID = chosen.members.filter { $0.managementID != nil }.count
        let withZone = chosen.members.filter { $0.timeZone != nil }.count
        let withoutContact = chosen.members.filter { $0.lastContact == nil }.count
        let unseen = chosen.members.filter { $0.lastSeen == nil }.count
        let inventoryOnly = chosen.members.filter { $0.lastContact == nil }.compactMap(\.lastInventoryUpdate)
        let recent = inventoryOnly.filter { Date().timeIntervalSince($0) <= 30 * 86_400 }.count
        run.record(step: step("diagnostic: last contact"), passed: true,
                   note: "\(withoutContact) without a last contact (\(recent) of them with an inventory update in the last 30 days), \(unseen) without either")
        record(run, step("mobile group members (device-groups:read, devices:read)"), passed: withManagementID > 0,
                   note: "\(chosen.group.isSmart ? "smart" : "static") group, \(chosen.members.count) members, \(withManagementID) with a management ID, \(withZone) with a time zone")

        // 3. status reports of up to ten members
        var reports = 0, none = 0
        var statusError: (any Error)?
        for member in chosen.members.prefix(10) {
            guard let managementID = member.managementID else { continue }
            do {
                if try await client.softwareUpdateStatus(managementID: managementID, kind: .mobileDevice) != nil { reports += 1 } else { none += 1 }
            } catch {
                statusError = error
                break
            }
        }
        record(run, step("DDM status items (devices:read)"), passed: statusError == nil,
                   note: statusError.map(failure) ?? "\(reports) with a report, \(none) without")

        // 4. a Blueprint with a software update
        var tracked: TrackedBlueprint?
        do {
            let blueprints = try await JamfPlatform.Blueprints(client: client).list()
            run.neverReport(blueprints.flatMap { [$0.id, $0.name] })
            for overview in blueprints.prefix(25) {
                let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: overview.id)
                if !update.blocks.isEmpty {
                    tracked = TrackedBlueprint(connectionID: UUID(), blueprintID: overview.id, blueprintName: overview.name)
                    // the sheet's scope section: the Blueprint's Platform groups as Jamf Pro groups (kind and number)
                    do {
                        let platformGroups = try await client.platformGroups()
                        run.neverReport(platformGroups.flatMap { [$0.id, $0.name] })
                        let scope = GroupChoice.scope(platformGroupIDs: update.blueprint.scopeDeviceGroups, platformGroups: platformGroups)
                        let known = Set(groups.map(\.id))
                        record(run, step("the Blueprint's scope as Jamf Pro groups (device-groups:read)"),
                               passed: scope.count == update.blueprint.scopeDeviceGroups.count && scope.isSubset(of: known),
                               note: "\(update.blueprint.scopeDeviceGroups.count) scope groups, \(scope.count) matched: "
                                   + "\(scope.filter { $0.kind == .mobileDevice }.count) mobile, \(scope.filter { $0.kind == .computer }.count) computer")
                    } catch {
                        record(run, step("the Blueprint's scope as Jamf Pro groups (device-groups:read)"), passed: false, note: failure(error))
                    }
                    record(run, step("a Blueprint with a software update (blueprints:read)"), passed: true,
                               note: "\(update.blocks.count) \(update.blocks.count == 1 ? "block" : "blocks"): "
                                   + update.blocks.map { String(describing: $0.enforcement).components(separatedBy: "(").first ?? "" }.joined(separator: ", "))
                    break
                }
            }
            if tracked == nil {
                record(run, step("a Blueprint with a software update (blueprints:read)"), passed: true,
                           note: "none among \(min(blueprints.count, 25)) Blueprints; the refresh runs without a target")
                tracked = blueprints.first.map { TrackedBlueprint(connectionID: UUID(), blueprintID: $0.id, blueprintName: $0.name) }
            }
        } catch {
            record(run, step("a Blueprint with a software update (blueprints:read)"), passed: false, note: failure(error))
            throw error
        }

        // 5. the app's own refresh. Apple's release data isn't read here: an
        // empty catalog, so targets that depend on it are “Target unknown”
        // and a specific version is measured.
        if let tracked {
            do {
                let result = try await RefreshWorkflow(client: client, catalog: AppleReleases.Catalog(), serverTimeZone: .gmt).run(tracked)
                run.neverReport(Self.identifiers(result.members) + result.scope.flatMap { [$0.group.groupID, $0.name] })
                let counts = StatusCategory.allCases.filter { result.counts[$0] > 0 }.map { "\($0.rawValue) \(result.counts[$0])" }
                let unreadable = result.devices.filter { $0.statusProblem != nil }.count
                let targets = Set(result.devices.compactMap(\.targetVersion)).count
                record(run, step("the app's refresh of the Blueprint's scope"), passed: unreadable == 0,
                           note: "\(result.scope.count) scope groups, \(result.devices.count) devices once each, \(targets) targets; "
                               + counts.joined(separator: ", ") + (unreadable > 0 ? "; \(unreadable) status reports unreadable" : ""))
            } catch {
                record(run, step("the app's refresh of the Blueprint's scope"), passed: false, note: failure(error))
                throw error
            }
        }

        // 6. one device's declaration report, and whether its Platform ID is its management ID
        if let member = chosen.members.first(where: { $0.serialNumber != nil }), let serial = member.serialNumber {
            do {
                if let device = try await client.device(serial: serial) {
                    run.neverReport([device.id])
                    let same = device.id.lowercased() == member.managementID?.lowercased()
                    record(run, step("Platform device ID (devices:read)"), passed: true,
                               note: same ? "equals the Jamf Pro management ID" : "differs from the Jamf Pro management ID")
                    let reports = try await client.declarationReports(deviceID: device.id)
                    record(run, step("declaration report (declarations:read)"), passed: true,
                               note: reports.map { "\($0.count) declarations, \($0.filter { $0.blueprintID != nil }.count) from Blueprints" } ?? "no report (404)")
                } else {
                    record(run, step("Platform device ID (devices:read)"), passed: true, note: "the serial isn't in the Platform device list")
                }
            } catch {
                record(run, step("declaration report (declarations:read)"), passed: false, note: failure(error))
                throw error
            }
        }

        // 7. the Classic route for a static computer group
        if let group = groups.first(where: { $0.kind == .computer && !$0.isSmart }) {
            do {
                let members = try await client.members(of: group)
                record(run, step("static computer group over the Classic API (device-groups:read)"), passed: true,
                           note: "\(members.count) members read")
            } catch {
                record(run, step("static computer group over the Classic API (device-groups:read)"), passed: false, note: failure(error))
                throw error
            }
        } else {
            record(run, step("static computer group over the Classic API"), passed: true, note: "no static computer group to read")
        }

        // 8. nothing but reads and the sign-in
        let refusals = run.network.refusals
        record(run, step("nothing sent but reads and the sign-in"), passed: refusals.isEmpty,
                   note: refusals.isEmpty ? nil : "\(refusals.count) refused")
        #expect(refusals.isEmpty)
    }
}

@Suite("Live: cleanup", .enabled(if: live), .serialized)
@MainActor
struct LiveCleanupTests {
    /// The app creates nothing anywhere; the ledger must be empty.
    @Test func nothingToRemove() async throws {
        let run = try LiveCheckRun.current()
        defer { checkUnderTest(run, when: "end of the run") }
        let left = run.ledger.outstanding
        run.record(step: "cleanup", passed: left.isEmpty, note: left.isEmpty ? "nothing was created" : "\(left.count) left in the ledger")
        #expect(left.isEmpty)
    }
}
