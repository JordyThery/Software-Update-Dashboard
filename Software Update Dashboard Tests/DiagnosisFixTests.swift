import Foundation
import JTKit
import Testing
@testable import Software_Update_Dashboard

/// 0.3.2: installing without contact since, readiness counted once, the
/// current declaration from its newest report, two plain error diagnoses,
/// and the server time zone check. Made-up devices and IDs, shaped like
/// what the live tenant showed on 11, 24 and 25 Nov.
@Suite("0.3.2: diagnoses")
struct DiagnosisFixTests {
    static let noContact = ", no contact since (switched off or stuck)"

    static func installing(_ pending: String, since: String) -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.install-state", "installing"),
                       ("softwareupdate.pending-version.os-version", pending)], time: since)
    }

    static func classify(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus?, target: String = "26.7.3",
                         now: String, zone: TimeZone = Sample.utc) -> DeviceStatus {
        Classifier.classify(DeviceInput(member: member, status: status),
                            context: ClassificationContext(target: OSVersion(target), serverTimeZone: zone, now: Sample.date(now)))
    }

    // MARK: Installing, no contact since

    // MARK: Readiness

    // MARK: Jamf's current declaration

    static let oldRange = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$" AND status.softwareupdate.device-id IN {"J314sAP"}"#
    static let newRange = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-2]([.][0-9]+)*)?)$" AND status.softwareupdate.device-id IN {"J314sAP"}"#

    /// One device’s report of the same declaration (`act12`/`cfg12`), as Jamf last sent it to that device.
    static func pair(_ device: String, predicate: String, updated: String, reported: String) -> [JamfPlatform.DeclarationReport] {
        let id = "Blueprint_\(BlueprintHealthTests.blueprint)_s1_c1_sys_"
        var activation = JamfPlatform.DeclarationReport(declarationIdentifier: id + "act12", deviceID: device, type: "ACTIVATION",
                                                         status: .unsuccessful, active: false,
                                                         reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])])
        var configuration = JamfPlatform.DeclarationReport(declarationIdentifier: id + "cfg12", deviceID: device, type: "CONFIGURATION",
                                                            status: .unsuccessful, active: false)
        for index in [0, 1] {
            var report = index == 0 ? activation : configuration
            report.dateUpdated = Sample.date(updated)
            report.lastReportTime = Sample.date(reported)
            if index == 0 { activation = report } else { configuration = report }
        }
        return [activation, configuration]
    }

    // MARK: Plain error diagnoses

    static func failed(_ reason: String) -> DeviceStatus {
        Sample.classify(Sample.mac(os: "26.7.2", model: "MacBookPro18,3"), Sample.status([
            ("device.operating-system.version", "26.7.2"), ("softwareupdate.install-state", "failed"),
            ("softwareupdate.pending-version.os-version", "26.7.3"),
            ("softwareupdate.failure-reason.reason", reason), ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]),
            context: Sample.context(target: "26.7.3", since: Sample.updateStarted))
    }

    @Test("“Failure to get Bootstrap Token”: a plain diagnosis linked to the bootstrap token; an asset Apple no longer has: plain, no link")
    func plainErrors() {
        let token = "Update failed due to failure to get Bootstrap Token."
        let tokenDevice = Self.failed(token)
        #expect(tokenDevice.diagnosis == "Update failed: the Mac couldn’t get its bootstrap token (check that it’s escrowed in Jamf Pro)")
        #expect(tokenDevice.needsAttention)
        #expect(HelpContent.problem(forCause: "Update error", detail: token)?.id == "bootstrap-token")
        #expect(HelpContent.problem("bootstrap-token")?.source.host == "support.apple.com")

        let asset = "[kSUCoreErrorAssetReloadNotFound] The requested asset could not be found."
        let assetDevice = Self.failed(asset)
        #expect(assetDevice.diagnosis == "Update files no longer available from Apple; check again after the device’s next check-in")
        #expect(assetDevice.needsAttention)
        // no public Apple page describes it: no known problem to link
        #expect(HelpContent.problem(forCause: "Update error", detail: asset) == nil)
        // other errors keep their diagnosis
        #expect(Self.failed("Something else went wrong").diagnosis == "Other error: Something else went wrong")
    }
}
