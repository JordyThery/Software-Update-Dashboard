import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// A tracked group from Jamf to the dashboard, in demo mode: JTKit’s real
/// clients on its demo network, nothing leaves the Mac.
@Suite("A tracked group end to end, in demo mode")
@MainActor
struct EndToEndTests {
    private func demoModel() -> DashboardModel {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let folder = FileManager.default.temporaryDirectory.appending(path: "sud-e2e-\(UUID().uuidString)")
        return DashboardModel(connections: connections, history: StatusHistory(folder: folder))
    }

    private func refreshed(_ name: String) async throws -> (DashboardModel, RefreshResult) {
        let model = demoModel()
        let group = try #require(model.groups.first { $0.groupName == name })
        await model.refresh(group.id)
        #expect(model.errors[group.id] == nil)
        return (model, try #require(model.results[group.id]))
    }

    @Test("Every sample iPad lands in its category with its diagnosis")
    func iPads() async throws {
        let (_, result) = try await refreshed("Field iPads")
        #expect(result.target == OSVersion("27.1"))
        #expect(result.build == "24B5074")
        #expect(result.osName == "iPadOS")
        #expect(result.block?.stepName == "iPadOS")
        #expect(result.deadline?.hasSuffix("T17:00:00") == true)
        let byName = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.name, $0) })
        let expected: [(String, StatusCategory, String)] = [
            ("Field iPad 01", .onTarget, "On target"),
            ("Field iPad 02", .onTarget, "On target"),
            ("Field iPad 03", .inProgress, "Downloading"),
            ("Field iPad 04", .inProgress, "Downloaded, install blocked by the passcode"),
            ("Field iPad 05", .otherUpdate, "Downloading (intermediate version 27.0.2)"),
            ("Field iPad 06", .failed, "Download problem (device retries)"),
            ("Field iPad 07", .noReport, "No update status available"),
            ("Field iPad 08", .offline, "Offline: no contact for more than 30 days"),
            ("Field iPad 09", .unsupported, "Hardware can’t run iPadOS 27 (stays on its last supported version)"),
            ("Field iPad 10", .noActivity, "No report since the update started (switched off or not synced yet)"),
            ("Field iPad 11", .notStarted, "Online, update not started (no error)"),
            ("Field iPad 12", .inProgress, "Installing now"),
        ]
        #expect(result.devices.count == expected.count)
        for (name, category, diagnosis) in expected {
            #expect(byName[name]?.category == category, "\(name)")
            #expect(byName[name]?.diagnosis == diagnosis, "\(name)")
        }
        #expect(result.counts.percentOnTarget == 22.2)
    }

    @Test("Deadlines per time zone point out the unusual ones")
    func zones() async throws {
        let (_, result) = try await refreshed("Field iPads")
        let zones = Dictionary(uniqueKeysWithValues: result.zones.map { ($0.zone ?? "none", $0) })
        #expect(result.zones.first?.zone == "Europe/Brussels")
        #expect(zones["Europe/Brussels"]?.unusual == nil)
        #expect(zones["America/St_Johns"]?.unusual == "Not a whole hour from UTC")
        #expect(zones["Asia/Tokyo"]?.unusual?.hasSuffix("h from most of the group") == true)
        #expect(zones["none"]?.unusual == "No time zone reported")
        // 17:00 in Tokyo comes eight hours before 17:00 in Brussels (in November)
        let brussels = try #require(zones["Europe/Brussels"]?.deadline)
        let tokyo = try #require(zones["Asia/Tokyo"]?.deadline)
        #expect(brussels.timeIntervalSince(tokyo) == 8 * 3_600)
    }

    @Test("Unsupported hardware is listed with the last version it can run")
    func replacements() async throws {
        let (_, result) = try await refreshed("Field iPads")
        #expect(result.replacements == [Replacement(modelIdentifier: "iPad7,5", model: "iPad (6th generation)", deviceCount: 1,
                                                    lastSupportedVersion: "17.7.10")])
    }

    @Test("Demo mode starts with five made-up days of history; each refresh adds one")
    func history() async throws {
        let (model, result) = try await refreshed("Field iPads")
        #expect(model.snapshots(result.group.id).count == 6)
        await model.refresh(result.group.id)
        #expect(model.snapshots(result.group.id).count == 7)
        #expect(model.snapshots(result.group.id).last?.counts[.onTarget] == 2)
        let summary = try #require(model.summary(result.group.id))
        #expect(summary.contains("Devices:    12 (target iPadOS 27.1)"))
        #expect(summary.contains("Changes since the previous refresh"))
        // compared with the refresh before, never with itself
        let latest = try #require(model.snapshots(result.group.id).last)
        let refreshed = try #require(model.results[result.group.id])
        #expect(abs(latest.date.timeIntervalSince(refreshed.date)) < 0.001)
        #expect(model.history?.latest(for: result.group.id, before: refreshed.date)?.date != refreshed.date)
        let csv = try #require(model.csv(result.group.id))
        #expect(csv.split(separator: "\n").count == 13)
        #expect(csv.hasPrefix(DeviceStatus.csvColumns.joined(separator: ",")))
    }

    @Test("Inspect finds the likely cause from the declaration reports")
    func inspect() async throws {
        let (model, result) = try await refreshed("Field iPads")
        let idle = try #require(result.devices.first { $0.name == "Field iPad 11" })
        await model.inspect([idle], in: result.group.id)
        #expect(model.inspectError == nil)
        let inspection = try #require(model.inspection(of: idle, in: result.group.id))
        #expect(inspection.cause == "Update declarations not applied yet")
        let onTarget = try #require(result.devices.first { $0.name == "Field iPad 01" })
        await model.inspect([onTarget], in: result.group.id)
        #expect(model.inspection(of: onTarget, in: result.group.id)?.cause == "On target")
    }

    @Test("A computer group: smart members, Macs by board ID, no time zones")
    func macs() async throws {
        let (_, result) = try await refreshed("Studio Macs")
        #expect(result.osName == "macOS")
        #expect(result.devices.count == 6)
        let old = try #require(result.devices.first { $0.modelIdentifier == "MacBookPro15,2" })
        #expect(old.category == .unsupported)
        #expect(result.replacements.first?.lastSupportedVersion == "15.7.4")
        #expect(result.zones.map(\.zone) == [nil])
        #expect(result.zones.first?.unusual?.hasPrefix("Jamf Pro has no time zone for Macs") == true)
    }

    @Test("Every request of a refresh and Inspect is a GET, besides the sign-in")
    func readOnly() async throws {
        let (model, result) = try await refreshed("Field iPads")
        await model.inspect(result.devices, in: result.group.id)
        let requests = model.connections.activityLog.entries.filter { $0.request != nil }
        #expect(requests.count > 20)
        for entry in requests {
            let isSignIn = entry.operation == "POST" && entry.detail.hasSuffix("auth/token")
            #expect(entry.operation == "GET" || isSignIn, "\(entry.operation) \(entry.detail)")
        }
    }
}
