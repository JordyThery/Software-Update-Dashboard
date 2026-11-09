import Foundation
import JTKit
import os

/// What the app does differently under tests: the saved connections are
/// never reached (every request for them is refused and written down for the
/// release check), and the unit-test host uses throwaway settings.
nonisolated enum UnderTest {
    static let folder = TestRun.attemptsFolder(named: "SoftwareUpdateDashboard-under-test")

    static let refusal = "Refused under tests: the release check never reaches a saved connection."

    /// The unit-test host’s settings domain, emptied before anything reads it.
    static let unitTestHostDomain = "be.jordythery.softwareupdatedashboard.unit-test-host"

    static func emptiedDefaults(domain: String) -> UserDefaults {
        // Never the real settings instead: the unit-test host would change them.
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("No settings domain \(domain).")
        }
        defaults.removePersistentDomain(forName: domain)
        return defaults
    }
}

extension TestRun.AttemptLog {
    nonisolated private static let logger = Logger(subsystem: "be.jordythery.softwareupdatedashboard", category: "UnderTest")

    nonisolated static let savedConnections = TestRun.AttemptLog(
        fileURL: UnderTest.folder.appending(path: "saved-connection-requests.jsonl"), logger: logger)
}
