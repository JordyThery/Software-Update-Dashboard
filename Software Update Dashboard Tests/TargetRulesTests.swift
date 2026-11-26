import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// Each software update setting of Jamf’s reference, with and without a
/// delay, against a made-up release history and a fixed “now”.
@Suite("Targets per device")
struct TargetRulesTests {
    static let sofaMacOS = #"""
    {"OSVersions":[
      {"OSVersion":"Golden Gate 27","Latest":{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP"]},
       "SecurityReleases":[{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"27.1","Build":"26B100","ReleaseDate":"2026-09-30T00:00:00Z"}]},
      {"OSVersion":"Tahoe 26","Latest":{"ProductVersion":"26.7.2","Build":"25H200","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP"]},
       "SecurityReleases":[{"ProductVersion":"26.7.2","Build":"25H200","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"26.7.1","Build":"25H100","ReleaseDate":"2026-09-30T00:00:00Z"}]},
      {"OSVersion":"Sequoia 15","Latest":{"ProductVersion":"15.8.2","Build":"24J200","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP","J132AP"]},
       "SecurityReleases":[{"ProductVersion":"15.8.2","Build":"24J200","ReleaseDate":"2026-10-26T00:00:00Z"}]}],
     "Models":{"Mac14,2":{"MarketingName":"MacBook Air (M2)","OSVersions":[27,26,15]},
               "MacBookPro15,2":{"MarketingName":"MacBook Pro (2018)","OSVersions":[15,14]},
               "MacOld1,1":{"MarketingName":"An old Mac","OSVersions":[11]}},
     "Devices":{"J413AP":{"DeviceID":"Mac14,2"},"J132AP":{"DeviceID":"MacBookPro15,2"}}}
    """#

    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofaMacOS.utf8))
    static let blueprintChanged = Sample.date("2026-10-01T09:00:00")

    static func block(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, build: String? = nil,
                      source: JamfPlatform.SoftwareUpdateBlock.Source = .component) -> JamfPlatform.SoftwareUpdateBlock {
        JamfPlatform.SoftwareUpdateBlock(stepIndex: 0, componentIndex: 0, enforcement: enforcement, targetBuildVersion: build, source: source)
    }

    static func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, os: String, model: String = "Mac14,2",
                       now: String = "2026-11-09T12:00:00", build: String? = nil, catalog: AppleReleases.Catalog? = catalog,
                       updateStarted: Date? = nil, source: JamfPlatform.SoftwareUpdateBlock.Source = .component) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: nil, osName: "macOS", context: .init(
            block: block(enforcement, build: build, source: source), catalog: catalog, platform: .macOS,
            blueprintChanged: blueprintChanged, updateStarted: updateStarted, now: Sample.date(now)))
    }

    // MARK: Specific version

    // MARK: Latest

    // MARK: Minor updates

    // MARK: Start and deadline

}
