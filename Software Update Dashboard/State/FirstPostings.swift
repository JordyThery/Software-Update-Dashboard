import Foundation
import JTKit

/// The first public posting date this app saw of each build (JTKit’s
/// `FirstPostings.merged`), saved under `firstPublicPostings`; Demo Mode’s
/// in memory only.
extension FirstPostings {
    nonisolated static let defaultsKey = "firstPublicPostings"

    nonisolated static func read(from defaults: UserDefaults) -> [String: Date] {
        defaults.dictionary(forKey: defaultsKey)?.compactMapValues { $0 as? Date } ?? [:]
    }

    /// Adds the catalog’s new public postings to those saved, saves them
    /// when something was added, and returns them all.
    nonisolated static func remember(_ catalog: AppleReleases.Catalog, in defaults: UserDefaults) -> [String: Date] {
        let known = read(from: defaults)
        let merged = merged(known, with: catalog)
        if merged != known { defaults.set(merged, forKey: defaultsKey) }
        return merged
    }
}
