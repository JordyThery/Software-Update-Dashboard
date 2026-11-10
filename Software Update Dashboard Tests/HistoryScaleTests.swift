import Foundation
import Testing
@testable import Software_Update_Dashboard

/// 0.3 release fix: a history of thousands of refreshes (hourly automatic
/// refresh for months) is read by file name and an index of counts, never
/// by decoding every refresh. Made-up devices only.
@Suite("0.3: a large history", .serialized)
struct HistoryScaleTests {
    static let count = 3_000

    /// Lays out `count` refreshes as earlier versions saved them (no index),
    /// every 86 minutes back from `now`, each with 40 devices.
    static func layOut(now: Date) throws -> (StatusHistory, UUID) {
        let history = StatusHistory(folder: TestFiles.folder("scale"))
        let id = UUID()
        let folder = history.folder.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let devices = (1...40).map { Sample.classify(Sample.iPad("\($0)"), nil) }
        for step in 0..<count {
            let date = now.addingTimeInterval(-Double(step) * 86 * 60)
            let data = try StatusHistory.encoded(HistorySnapshot(date: date, target: "27.1", devices: devices))
            try data.write(to: folder.appending(path: StatusHistory.fileName(for: date)))
        }
        return (history, id)
    }

    static func seconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    @Test("The newest of 3,000 refreshes is read quickly, by its file name; the chart reads an index of counts")
    func newestQuickly() throws {
        let now = Sample.date("2026-11-10T12:00:00")
        let (history, id) = try Self.layOut(now: now)

        var newest: HistorySnapshot?
        let latest = Self.seconds { newest = history.latest(for: id) }
        #expect(newest?.date == now)
        #expect(latest < 0.5, "reading the newest took \(latest) s")
        var before: HistorySnapshot?
        _ = Self.seconds { before = history.latest(for: id, before: now) }
        #expect(before?.date == now.addingTimeInterval(-86 * 60))

        // existing history keeps working: the index is built once from the files
        let first = history.entries(for: id)
        #expect(first.count == Self.count && first.last?.date == now && first.last?.counts.total == 40)
        var again: [HistoryEntry] = []
        let index = Self.seconds { again = history.entries(for: id) }
        #expect(again == first)
        // decoding every refresh, as before, takes far longer than the index
        // (here with 40 devices a refresh; with hundreds the gap grows, the index stays the same)
        let full = Self.seconds { _ = history.snapshots(for: id) }
        #expect(index < 1 && index * 3 < full, "index \(index) s, every refresh \(full) s")
    }

    @Test("Saving keeps every count for 180 days, all full refreshes for 7 days and then the newest of each day")
    func thinning() throws {
        let now = Sample.date("2026-11-10T12:00:00")
        let (history, id) = try Self.layOut(now: now)
        let next = now.addingTimeInterval(3_600)
        try history.save(HistorySnapshot(date: next, target: "27.1", devices: []), for: id)

        let entries = history.entries(for: id)
        let cutoff = next.addingTimeInterval(-180 * 86_400)
        #expect(entries.last?.date == next && entries.allSatisfy { $0.date >= cutoff })
        #expect(entries.count == Self.count + 1 - (0..<Self.count).filter { now.addingTimeInterval(-Double($0) * 86 * 60) < cutoff }.count)
        let folder = history.folder.appending(path: id.uuidString)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        let dates = names.compactMap(StatusHistory.date(fromFileName:))
        let thinFrom = next.addingTimeInterval(-7 * 86_400)
        let olderDays = dates.filter { $0 < thinFrom }.map { String(StatusHistory.fileName(for: $0).prefix(8)) }
        #expect(Set(olderDays).count == olderDays.count, "more than one full refresh kept for a day older than 7 days")
        #expect(dates.filter { $0 >= thinFrom }.count > 100)
        #expect(names.count < 400)
        // the newest stays, with its devices
        #expect(history.latest(for: id)?.date == next)
    }
}
