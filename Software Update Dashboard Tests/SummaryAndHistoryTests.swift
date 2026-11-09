import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

private func row(_ id: String, _ category: StatusCategory, _ diagnosis: String, passcode: Bool? = nil,
                 problem: String? = nil) -> DeviceStatus {
    DeviceStatus(jamfID: id, isComputer: false, name: "Test iPad \(id)", serial: "ZZTEST\(id)", model: "iPad Air",
                 modelIdentifier: "iPad13,18", inventoryOS: "26.7.1", reportedOS: nil, installState: nil, pendingVersion: nil,
                 failureCount: nil, error: "", errorTime: nil, errorSinceUpdate: nil, passcodePresent: passcode,
                 lastContact: nil, statusUpdated: nil, timeZone: nil, managementID: nil, category: category,
                 diagnosis: diagnosis, statusProblem: problem)
}

private let rows = [
    row("1", .onTarget, "On target"), row("2", .onTarget, "On target"),
    row("3", .inProgress, "Downloaded, install blocked by the passcode", passcode: true),
    row("4", .offline, "Offline: no contact for more than 30 days"),
]

@Suite("Summary")
struct StatusSummaryTests {
    @Test("Counts, the change since the previous refresh and the progress line")
    func text() {
        let previous = HistorySnapshot(date: Sample.date("2026-11-04T21:00:00"), target: "27.0.1",
                                       devices: [row("1", .onTarget, "On target"), row("3", .inProgress, "x"), row("4", .offline, "y")])
        let text = StatusSummary.text(group: "Field iPads", devices: rows, measuredAgainst: "Version 27.0.1",
                                      previous: StatusSummary.previous(previous, target: "27.0.1"), staleDays: 30, date: Sample.now,
                                      locale: Locale(identifier: "en_US_POSIX"))
        #expect(text.contains("  Devices:    4 (Version 27.0.1)\n"))
        #expect(text.contains("  Deadline:   0 devices not on target past their deadline\n"))
        #expect(text.contains("    On target          2  (+1)\n"))
        #expect(text.contains("    In progress        1\n"))
        #expect(text.contains("    Offline            1  (no contact for more than 30 days)\n"))
        #expect(text.contains("  Changes since the previous refresh ("))
        #expect(text.contains("  Progress:   2 of 3 updatable devices on target (66.7%); updatable excludes unsupported, offline and no report\n"))
        #expect(text.contains("  Passcode:   1 online device not on target report a passcode\n"))
        #expect(text.contains("  Needs attention: 1 device\n    Test iPad 3  iPad13,18  iPadOS 26.7.1  Downloaded, install blocked by the passcode\n"))
        #expect(!text.contains("!!"))
    }

    @Test("A previous refresh for another target isn’t compared")
    func otherTarget() {
        let previous = HistorySnapshot(date: Sample.now, target: "27.0", devices: [])
        #expect(StatusSummary.previous(previous, target: "27.0.1") == nil)
        #expect(StatusSummary.previous(HistorySnapshot(date: Sample.now, target: nil, devices: []), target: nil) != nil)
        #expect(StatusSummary.previous(nil, target: "27.0.1") == nil)
    }

    @Test("Devices whose status couldn’t be read are pointed out")
    func unreadable() {
        let text = StatusSummary.text(group: "G", devices: [row("1", .noReport, "Update status couldn’t be read", problem: "403")],
                                      measuredAgainst: "Version 27.0.1", previous: nil, staleDays: 30, notes: ["Scope: 1 group added (A)"])
        #expect(text.contains("  Scope: 1 group added (A)\n"))
        #expect(text.contains("!! The update status couldn’t be read for 1 device; they count as no report."))
    }

    @Test("Diagnoses by count, then by name; on-target devices left out")
    func diagnoses() {
        let counted = StatusSummary.diagnosisCounts(rows + [row("5", .notStarted, "B"), row("6", .notStarted, "A"),
                                                            row("7", .notStarted, "A")])
        #expect(counted.map(\.diagnosis) == ["A", "B", "Downloaded, install blocked by the passcode",
                                             "Offline: no contact for more than 30 days"])
        #expect(counted.first?.count == 2)
    }

    @Test("Updatable leaves out unsupported, offline and no report")
    func counts() {
        let counts = CategoryCounts(rows + [row("5", .unsupported, "u"), row("6", .noReport, "n")])
        #expect(counts.total == 6)
        #expect(counts.updatable == 3)
        #expect(counts.percentOnTarget == 66.7)
        #expect(CategoryCounts([]).percentOnTarget == nil)
        #expect(ProgressGroup.excluded.count(in: counts) == 3)
        #expect(ProgressGroup.allCases.map { $0.count(in: counts) }.reduce(0, +) == counts.total)
    }
}

@Suite("History")
struct StatusHistoryTests {
    private func history() -> StatusHistory {
        StatusHistory(folder: TestFiles.folder("history"))
    }

    @Test("A refresh is saved and read back, newest last")
    func saveAndRead() throws {
        let history = history()
        let group = UUID()
        try history.save(HistorySnapshot(date: Sample.date("2026-11-04T10:00:00"), target: "27.0.1", devices: [rows[0]]), for: group)
        try history.save(HistorySnapshot(date: Sample.date("2026-11-05T10:00:00"), target: "27.0.1", devices: rows), for: group)
        let snapshots = history.snapshots(for: group)
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.counts[.onTarget] == 2)
        #expect(snapshots.last?.devices.map(\.serial) == rows.map(\.serial))
        #expect(history.latest(for: group)?.date == Sample.date("2026-11-05T10:00:00"))
        #expect(history.latest(for: group, before: Sample.date("2026-11-05T10:00:00"))?.devices.count == 1)
        #expect(history.snapshots(for: UUID()).isEmpty)
    }

    @Test("Refreshes older than 180 days are removed when one is saved")
    func retention() throws {
        let history = history()
        let group = UUID()
        let old = Sample.now.addingTimeInterval(-181 * 86_400)
        let kept = Sample.now.addingTimeInterval(-179 * 86_400)
        try history.save(HistorySnapshot(date: old, target: nil, devices: []), for: group)
        try history.save(HistorySnapshot(date: kept, target: nil, devices: []), for: group)
        #expect(history.snapshots(for: group).count == 2)
        try history.save(HistorySnapshot(date: Sample.now, target: nil, devices: []), for: group)
        #expect(history.snapshots(for: group).map(\.date) == [kept, Sample.now])
    }

    @Test("A file that can’t be read is skipped and left alone")
    func unreadable() throws {
        let history = history()
        let group = UUID()
        try history.save(HistorySnapshot(date: Sample.now, target: nil, devices: []), for: group)
        let broken = history.folder.appending(path: group.uuidString).appending(path: "20261101-000000-000.json")
        try Data("not json".utf8).write(to: broken)
        #expect(history.snapshots(for: group).count == 1)
        #expect(FileManager.default.fileExists(atPath: broken.path))
    }

    @Test("Counts are saved by the categories’ names")
    func countsByName() throws {
        let data = try JSONEncoder().encode(CategoryCounts(rows))
        let names = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(names["on-target"] == 2 && names["offline"] == 1)
        // a saved count without a category reads as 0
        let decoded = try JSONDecoder().decode(CategoryCounts.self, from: Data(#"{"on-target":3}"#.utf8))
        #expect(decoded[.onTarget] == 3 && decoded[.failed] == 0)
    }

    @Test("File names sort by time and read back as dates")
    func names() {
        #expect(StatusHistory.fileName(for: Sample.date("2026-11-05T13:04:09")) == "20261105-130409-000.json")
        #expect(StatusHistory.date(fromFileName: "20261105-130409-000.json") == Sample.date("2026-11-05T13:04:09"))
        #expect(StatusHistory.date(fromFileName: "notes.txt") == nil)
    }
}
