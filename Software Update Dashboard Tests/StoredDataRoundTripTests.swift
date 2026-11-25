import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// What 0.3.2 saved reads with the shared types of 0.3.3 (JTKit 1.9.0), and
/// is written back the same: the history file and its index byte for byte,
/// the remembered deadlines with every value kept.
@Suite("0.3.3: history and remembered deadlines saved by 0.3.2")
struct StoredDataRoundTripTests {
    private func folder(with files: [(String, Data)]) throws -> URL {
        let folder = TestFiles.folder("saved-by-032")
        let group = folder.appending(path: SavedBy032.trackedID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: group.appending(path: name)) }
        return folder
    }

    @Test("A refresh saved by 0.3.2 reads, and saved again gives the same file and the same index")
    func history() throws {
        let saved = StatusHistory(folder: try folder(with: [(SavedBy032.historyFileName, SavedBy032.history),
                                                            (StatusHistory.indexName, SavedBy032.countsIndex)]))
        let snapshot = try #require(saved.latest(for: SavedBy032.trackedID))
        // the Mac Blueprint's 16 Studio Macs but Studio Mac 08, whose target is unknown: the history leaves it out
        #expect(snapshot.devices.count == 15 && !snapshot.devices.contains { $0.name == "Studio Mac 08" })
        #expect(snapshot.devices.contains { $0.name == "Studio Mac 12" && $0.nextInstallAttempt != nil })
        #expect(saved.entries(for: SavedBy032.trackedID).count == 1)

        let again = StatusHistory(folder: try folder(with: []))
        try again.save(snapshot, for: SavedBy032.trackedID)
        let group = again.folder.appending(path: SavedBy032.trackedID.uuidString, directoryHint: .isDirectory)
        #expect(try Data(contentsOf: group.appending(path: SavedBy032.historyFileName)) == SavedBy032.history)
        #expect(try Data(contentsOf: group.appending(path: StatusHistory.indexName)) == SavedBy032.countsIndex)
    }

    @Test("Remembered deadlines saved by 0.3.2 read with every value, and read the same after saving again")
    func reportedDeadlines() throws {
        let saved = StatusHistory(folder: try folder(with: [(StatusHistory.reportedDeadlinesName, SavedBy032.reportedDeadlines)]))
        let read = saved.reportedDeadlines(for: SavedBy032.trackedID)
        let expected = try JSONDecoder().decode(ReportedDeadlines.self, from: SavedBy032.reportedDeadlinesValues)
        #expect(!read.isEmpty)
        #expect(read == expected)

        let again = StatusHistory(folder: try folder(with: []))
        try again.saveReportedDeadlines(read, for: SavedBy032.trackedID)
        #expect(again.reportedDeadlines(for: SavedBy032.trackedID) == expected)
    }
}
