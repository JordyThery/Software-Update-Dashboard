import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// This Blueprint’s earlier step, long installs, the grace after a deadline
/// and the newer of the reported and inventory versions. Made-up devices.
@Suite("Earlier steps, long installs and the deadline’s grace")
struct EarlierStepAndInstallTests {
    // Apple posted 26.7.2 on 26 Oct and 26.7.3 on 9 Nov
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"26","Latest":{"ProductVersion":"26.7.3","Build":"25G342","ReleaseDate":"2026-11-09T00:00:00Z"}}],
     "Models":{"MacBookPro18,3":{"OSVersions":[26]}},"Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let member = Sample.mac(os: "26.7.1", model: "MacBookPro18,3")

    static func status(pending: String = "26.7.2", deadline: String = "2026-11-09 22:59:11 +0000", state: String = "installing",
                       reason: String = "declaration", time: String = "2026-11-09T23:00:00") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.device-id", "J314sAP"),
                       ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", reason)], time: time)
    }

    /// `reported`: the deadlines this Blueprint’s devices reported for 26.7.2 while it was the target (UTC
    /// moments), the only way a Mac’s step is recognized; by default 26.7.2’s own.
    static func target(_ status: JamfPro.SoftwareUpdateStatus, now: String = "2026-11-10T00:30:00",
                       reported: [String] = ["2026-11-09T22:59:04"]) -> DeviceTarget {
        let rule = TargetRules.target(os: "26.7.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date(now)))
        return TargetRules.fromDevice(rule, status: status, os: "26.7.1", osName: "macOS", catalog: catalog, platform: .macOS,
                                      serverTimeZone: Sample.utc, model: "MacBookPro18,3", boardID: "J314sAP",
                                      earlierStepDeadline: { version in
                                          TargetRules.ruleDeadline(for: version, block: block, catalog: catalog, platform: .macOS,
                                                                   model: "MacBookPro18,3", boardID: "J314sAP")
                                      },
                                      known: PostingBasis(reportedMinutes: [PostingBasis.key(.macOS, OSVersion("26.7.2")!):
                                                                                Set(reported.map { PostingBasis.minute(Sample.date($0)) })]),
                                      now: Sample.date(now))
    }

}
