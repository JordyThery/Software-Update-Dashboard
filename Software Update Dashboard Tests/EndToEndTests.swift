import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// A tracked Blueprint from Jamf to the dashboard, in demo mode: JTKit’s real
/// clients on its demo network, nothing leaves the Mac.
@Suite("A tracked Blueprint end to end, in demo mode")
@MainActor
struct EndToEndTests {
    private func demoModel(history: StatusHistory? = nil) -> DashboardModel {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let folder = TestFiles.folder("e2e")
        return DashboardModel(connections: connections, history: history ?? StatusHistory(folder: folder))
    }

    private func refreshed(_ name: String, model given: DashboardModel? = nil) async throws -> (DashboardModel, RefreshResult) {
        let model = given ?? demoModel()
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == name })
        await model.refresh(tracked.id)
        #expect(model.errors[tracked.id] == nil)
        return (model, try #require(model.results[tracked.id]))
    }

    private static let iPads = "Contoso – iPad Update"
    private static let macs = "Contoso – Mac Update"

    @Test("A specific version: every iPad against it, in its category with its diagnosis")
    func iPads() async throws {
        let (_, result) = try await refreshed(Self.iPads)
        #expect(result.rule.hasPrefix("Version 27.1"))
        #expect(result.scope.map(\.name) == ["Field iPads"])
        #expect(result.devices.allSatisfy { $0.targetVersion == "27.1" })
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
        // the deadline is in the future: nobody is late yet
        #expect(result.pastDeadline == 0)
    }

    @Test("Minor updates after a delay: each Mac against the newest release of its own major")
    func macs() async throws {
        let (_, result) = try await refreshed(Self.macs)
        #expect(result.rule == "Minor updates, \(DemoSoftwareUpdate.macDelayDays) days after their release")
        #expect(result.scope.map(\.name) == ["Studio Macs"])
        let byName = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.name, $0) })
        #expect(result.devices.count == 6)
        #expect(byName["Studio Mac 01"]?.category == .onTarget)
        #expect(byName["Studio Mac 02"]?.targetVersion == "27.1")
        #expect(byName["Studio Mac 02"]?.category == .inProgress)
        // the old Mac stays on its own major: on target there, and listed to replace
        let old = try #require(byName["Studio Mac 04"])
        #expect(old.targetVersion == "15.7.4")
        #expect(old.category == .onTarget)
        #expect(old.limitedByHardware == true)
        #expect(result.replacements.first?.modelIdentifier == "MacBookPro15,2")
        #expect(result.replacements.first?.note.localizedCaseInsensitiveContains("measured against 15.7.4") == true)
        // 27.1 came out 12 days ago, 7 days' delay: its deadline has passed for the Macs not on it
        #expect(byName["Studio Mac 02"]?.pastDeadline == true)
        #expect(byName["Studio Mac 01"]?.pastDeadline == false)
        // activity counts from 27.1's release date
        let released = try #require(byName["Studio Mac 02"]?.activityFrom)
        #expect(abs(Date().timeIntervalSince(released) / 86_400 - 12) < 1.1)
        // by major release
        #expect(result.majors.map(\.id) == ["macOS 27", "macOS 15"])
        #expect(result.majors.first?.targets == ["27.1"])
    }

    @Test("Deadlines per time zone point out the unusual ones")
    func zones() async throws {
        let (_, result) = try await refreshed(Self.iPads)
        let zones = Dictionary(uniqueKeysWithValues: result.zones.map { ($0.zone ?? "none", $0) })
        #expect(result.zones.first?.zone == "Europe/Brussels")
        #expect(zones["Europe/Brussels"]?.unusual == nil)
        #expect(zones["America/St_Johns"]?.unusual == "Not a whole hour from UTC")
        #expect(zones["Asia/Tokyo"]?.unusual?.hasSuffix("h from most of the devices") == true)
        #expect(zones["none"]?.unusual == "No time zone reported")
        // 17:00 in Tokyo comes eight hours before 17:00 in Brussels (in November)
        let brussels = try #require(zones["Europe/Brussels"]?.deadline)
        let tokyo = try #require(zones["Asia/Tokyo"]?.deadline)
        #expect(brussels.timeIntervalSince(tokyo) == 8 * 3_600)
        // Macs have no zone in Jamf Pro: a Mac with a pending update reports
        // its deadline as a moment, the others keep their own local time
        let (_, macs) = try await refreshed(Self.macs)
        #expect(macs.zones.allSatisfy { $0.zone == nil && $0.label == "No time zone" })
        let reported = macs.zones.filter { $0.reported != nil }
        #expect(!reported.isEmpty && reported.allSatisfy { $0.deadline == $0.reported })
        let local = macs.zones.filter { $0.reported == nil }
        #expect(!local.isEmpty && local.allSatisfy { $0.unusual?.hasPrefix("Jamf Pro has no time zone for Macs") == true && $0.target != nil })
    }

    @Test("Unsupported hardware is listed with the last version it can run")
    func replacements() async throws {
        let (_, result) = try await refreshed(Self.iPads)
        let item = try #require(result.replacements.first)
        #expect(result.replacements.count == 1)
        #expect(item.modelIdentifier == "iPad7,5" && item.deviceCount == 1 && item.lastSupportedVersion == "17.7.10")
        #expect(item.note.contains("unsupported"))
    }

    @Test("Demo mode starts with five made-up days of history; each refresh adds one, with its scope")
    func history() async throws {
        let (model, result) = try await refreshed(Self.iPads)
        #expect(model.snapshots(result.tracked.id).count == 6)
        // the made-up days hold a change of software update with a pilot group joining, and the group leaving
        let marks = HistoryMark.marks(model.snapshots(result.tracked.id))
        #expect(marks.map(\.kinds) == [[.rule, .scope], [.scope]])
        await model.refresh(result.tracked.id)
        let snapshots = model.snapshots(result.tracked.id)
        #expect(snapshots.count == 7)
        #expect(snapshots.last?.counts[.onTarget] == 2)
        #expect(snapshots.last?.scope?.map(\.name) == ["Field iPads"])
        let summary = try #require(model.summary(result.tracked.id))
        #expect(summary.contains("Devices:    12 (Version 27.1"))
        #expect(summary.contains("Changes since the previous refresh"))
        // compared with the refresh before, never with itself
        let refreshed = try #require(model.results[result.tracked.id])
        #expect(abs((snapshots.last?.date ?? .distantPast).timeIntervalSince(refreshed.date)) < 0.001)
        #expect(model.history?.latest(for: result.tracked.id, before: refreshed.date)?.date != refreshed.date)
        let csv = try #require(model.csv(result.tracked.id))
        #expect(csv.split(separator: "\n").count == 13)
        #expect(csv.hasPrefix(DeviceStatus.csvColumns.joined(separator: ",")))
    }

    @Test("A change in the Blueprint’s scope shows in the refresh and the summary")
    func scopeChange() async throws {
        let folder = TestFiles.folder("e2e")
        let history = StatusHistory(folder: folder)
        let model = demoModel(history: history)
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == Self.iPads })
        let earlier = GroupReference(key: .init(kind: .mobileDevice, groupID: DemoSoftwareUpdate.spareIPadGroupID), name: "Spare iPads", isSmart: false)
        try history.save(HistorySnapshot(date: Date().addingTimeInterval(-86_400), target: "x", devices: [], scope: [earlier]), for: tracked.id)
        let (_, result) = try await refreshed(Self.iPads, model: model)
        #expect(result.scopeChange?.added.map(\.name) == ["Field iPads"])
        #expect(result.scopeChange?.removed.map(\.name) == ["Spare iPads"])
        #expect(model.summary(tracked.id)?.contains("Scope: 1 group added (Field iPads), 1 removed (Spare iPads)") == true)
    }

    @Test("Compare with a group: its devices the Blueprint doesn’t reach")
    func coverage() async throws {
        let model = demoModel()
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == Self.macs })
        let loaners = GroupReference(key: .init(kind: .computer, groupID: DemoSoftwareUpdate.loanerMacGroupID), name: "Loaner Macs", isSmart: false)
        model.setCompareGroup(loaners, for: tracked.id)
        let (_, result) = try await refreshed(Self.macs, model: model)
        #expect(result.coverage?.members == 2)
        #expect(result.coverage?.notReached.count == 2)
        let studio = GroupReference(key: .init(kind: .computer, groupID: DemoSoftwareUpdate.macGroupID), name: "Studio Macs", isSmart: true)
        model.setCompareGroup(studio, for: tracked.id)
        let (_, covered) = try await refreshed(Self.macs, model: model)
        #expect(covered.coverage?.notReached.isEmpty == true)
        // the coverage check doesn't change who is counted
        #expect(covered.devices.count == result.devices.count)
    }

    @Test("“Update started” set by hand counts every device from that date, until removed")
    func updateStarted() async throws {
        let model = demoModel()
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == Self.macs })
        let started = Date().addingTimeInterval(-2 * 86_400)
        model.setUpdateStarted(started, for: tracked.id)
        let (_, result) = try await refreshed(Self.macs, model: model)
        #expect(result.devices.allSatisfy { $0.activityFrom == started })
        #expect(result.tracked.updateStarted == started)
        model.setUpdateStarted(nil, for: tracked.id)
        let (_, removed) = try await refreshed(Self.macs, model: model)
        #expect(removed.devices.allSatisfy { $0.activityFrom != started })
    }

    @Test("Inspect finds the likely cause from the declaration reports")
    func inspect() async throws {
        let (model, result) = try await refreshed(Self.iPads)
        let idle = try #require(result.devices.first { $0.name == "Field iPad 11" })
        await model.inspect([idle], in: result.tracked.id)
        #expect(model.inspectError == nil)
        let inspection = try #require(model.inspection(of: idle, in: result.tracked.id))
        #expect(inspection.cause == "Update declarations not applied yet")
        let onTarget = try #require(result.devices.first { $0.name == "Field iPad 01" })
        await model.inspect([onTarget], in: result.tracked.id)
        #expect(model.inspection(of: onTarget, in: result.tracked.id)?.cause == "On target")
    }

    @Test("Every request of a refresh and Inspect is a GET, besides the sign-in")
    func readOnly() async throws {
        let (model, result) = try await refreshed(Self.iPads)
        await model.inspect(result.devices, in: result.tracked.id)
        let requests = model.connections.activityLog.entries.filter { $0.request != nil }
        #expect(requests.count > 20)
        for entry in requests {
            let isSignIn = entry.operation == "POST" && entry.detail.hasSuffix("auth/token")
            #expect(entry.operation == "GET" || isSignIn, "\(entry.operation) \(entry.detail)")
        }
    }
}
