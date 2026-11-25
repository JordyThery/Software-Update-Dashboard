import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// 0.3, round 2: the fixes from the round 1 hand check. Made-up devices and
/// IDs, shaped like what the live tenant showed on 2026-11-10.
@Suite("0.3: an older pending version with the newer version’s deadline")
struct MovedOnStepTests {
    // 27.2 released 26 Oct; 27.2.1 posted publicly on 9 Nov, for iPad15,8 only
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad15,8"]}]},
     "AssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad15,8"]},
       {"ProductVersion":"27.2","Build":"24B119","PostingDate":"2026-10-26","SupportedDevices":["iPad15,8","iPad14,8"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"24B119","ReleaseDate":"2026-10-26T00:00:00Z"}]}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    /// The newest release, 7 days, at 23:59: 27.2.1 is due 16 Nov 23:59, device local time.
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(pending: String = "27.2", deadline: String = "2026-11-16 22:59:02 +0000",
                       state: String = "none") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T07:57:08")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, model: String = "iPad15,8",
                       zone: String = "Europe/Brussels") -> DeviceTarget {
        let rule = TargetRules.target(os: "27.0.1", model: model, boardID: model, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.0.1", osName: "iPadOS", catalog: catalog, platform: .iOS, serverTimeZone: Sample.utc,
            model: model, boardID: model,
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .iOS,
                                                            model: model, boardID: model) },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .iOS,
                                                        model: model, boardID: model, now: now) },
            timeZone: zone, now: now)
    }

}

@Suite("0.3: the device detail’s pending version")
struct PendingVersionTextTests {
}

@Suite("0.3: past the earlier step’s deadline, in the count and in Deadline per Time Zone")
struct PastStepAgreementTests {
}
