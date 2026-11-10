import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import Software_Update_Dashboard

/// 0.2: Blueprint health (F), device details (H), all status items (E),
/// and this Blueprint’s earlier step once Apple’s public catalog has
/// dropped its posting. Made-up devices and IDs, and Demo Mode.
@Suite("0.2: an earlier step whose posting Apple no longer lists")
struct EarlierStepWindowTests {
    // Apple released 27.2 on 26 Oct (posted 5 Nov) and posted 27.2.1 on 9 Nov;
    // the public catalog now lists 27.2.1 only
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26C40","PostingDate":"2026-11-09","SupportedDevices":["J613AP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26C40","PostingDate":"2026-11-09","SupportedDevices":["J613AP"]},
       {"ProductVersion":"27.2","Build":"26C30","PostingDate":"2026-11-05","SupportedDevices":["J613AP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"26C40","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"26C40","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"26C30","ReleaseDate":"2026-10-26T00:00:00Z"}]}],
     "Models":{"Mac15,12":{"OSVersions":[27]}},"Devices":{"J613AP":{"DeviceID":"Mac15,12"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    /// The same without 27.2 in Apple’s list at all: only the window can tell.
    static let gdmfWithoutStep = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26C40","PostingDate":"2026-11-09","SupportedDevices":["J613AP"]}]}}
    """#
    static let windowCatalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmfWithoutStep.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(deadline: String, pending: String = "27.2") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.1"), ("softwareupdate.device-id", "J613AP"),
                       ("softwareupdate.install-state", "downloading"),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:00:00")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, window: Bool = true, awaitingSync: Bool = false,
                       catalog: AppleReleases.Catalog = catalog, timeZone: String? = nil, now: Date = now) -> DeviceTarget {
        let rule = TargetRules.target(os: "27.1", model: "Mac15,12", boardID: "J613AP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.1", osName: "macOS", catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
            model: "Mac15,12", boardID: "J613AP",
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                            model: "Mac15,12", boardID: "J613AP") },
            earlierStepWindow: window ? { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                                 model: "Mac15,12", boardID: "J613AP", now: now) } : nil,
            awaitingSync: awaitingSync, timeZone: timeZone, now: now)
    }

    @Test("27.2 due 19 Nov while the target is 27.2.1: an earlier step; the current target and deadline count")
    func liveCase() {
        let target = Self.target(Self.status(deadline: "2026-11-19 22:59:00 +0000"))
        #expect(target.version == "27.2.1" && target.deadlineLocal == "2026-11-23T23:59:00")
        #expect(target.earlierStepVersion == "27.2" && !target.fromDevice)
        let device = Sample.classify(Sample.mac(os: "27.1", model: "Mac15,12"), Self.status(deadline: "2026-11-19 22:59:00 +0000"),
                                     target: target, now: "2026-11-10T12:00:00")
        #expect(device.category == .otherUpdate)
        #expect(device.diagnosis == "Downloading 27.2 first (an earlier step of this Blueprint)")
        // without the window (0.1.1), the posting Apple dropped hid the step
        #expect(Self.target(Self.status(deadline: "2026-11-19 22:59:00 +0000"), window: false).version == "27.2")
    }

    @Test("Without Apple’s posting date, a Mac’s UTC moment is checked by its minutes only; awaiting sync supports a version in the window")
    func macMinutesAndAwaitingSync() {
        // another quarter-hour minute: not this Blueprint's step
        let odd = Self.status(deadline: "2026-11-19 10:17:00 +0000")
        #expect(Self.target(odd, catalog: Self.windowCatalog).version == "27.2" && Self.target(odd, catalog: Self.windowCatalog).fromDevice)
        // the same minutes at another hour can't be told apart for a Mac writing UTC: taken as the step (a known limit)
        let otherHour = Self.status(deadline: "2026-11-19 09:59:00 +0000")
        #expect(Self.target(otherHour, catalog: Self.windowCatalog).earlierStepVersion == "27.2")
        #expect(Self.target(odd, awaitingSync: true, catalog: Self.windowCatalog).earlierStepVersion == "27.2")
        // a version the rule never targeted: awaiting sync alone isn't enough
        let unknown = Self.status(deadline: "2026-11-19 22:59:00 +0000", pending: "27.1.5")
        #expect(Self.target(unknown, awaitingSync: true, catalog: Self.windowCatalog).earlierStepVersion == nil)
    }

    @Test("Apple’s posting date first: only its deadline counts, not every day of the window")
    func exactPostingFirst() throws {
        let window = TargetRules.ruleWindow(for: try #require(OSVersion("27.2")), block: Self.block, catalog: Self.catalog,
                                            platform: .macOS, model: "Mac15,12", boardID: "J613AP", now: Self.now)
        #expect(window == ["2026-11-19T23:59:00"])
        // 21 Nov at the Blueprint's time is in the window, but not the posting's deadline
        #expect(Self.target(Self.status(deadline: "2026-11-21 22:59:00 +0000")).earlierStepVersion == nil)
        #expect(Self.target(Self.status(deadline: "2026-11-21 22:59:00 +0000"), catalog: Self.windowCatalog).earlierStepVersion == "27.2")
    }

    @Test("A device whose zone is known: the full clock time, so another hour on the same minutes isn’t the step")
    func knownZone() {
        // 23:59 in Brussels is 22:59 UTC; 09:59 UTC is 10:59 there
        let right = Self.status(deadline: "2026-11-19 22:59:00 +0000")
        let wrong = Self.status(deadline: "2026-11-19 09:59:00 +0000")
        #expect(Self.target(right, catalog: Self.windowCatalog, timeZone: "Europe/Brussels").earlierStepVersion == "27.2")
        #expect(Self.target(wrong, catalog: Self.windowCatalog, timeZone: "Europe/Brussels").earlierStepVersion == nil)
        #expect(TargetRules.sameClock(reported: Sample.date("2026-11-19T22:59:00"), reportedLocal: nil, expected: "2026-11-19T23:59:00",
                                      timeZone: "Europe/Brussels"))
        #expect(!TargetRules.sameClock(reported: Sample.date("2026-11-19T09:59:00"), reportedLocal: nil, expected: "2026-11-19T23:59:00",
                                       timeZone: "Europe/Brussels"))
        // a local date-time at another hour isn't the step either
        let local = Self.status(deadline: "2026-11-19T17:00:00")
        #expect(Self.target(local, catalog: Self.windowCatalog).earlierStepVersion == nil)
    }

    @Test("A step taken through the window or awaiting sync whose own deadline passed still counts as past its deadline")
    func lapsedThroughWindow() {
        let later = Sample.date("2026-11-21T12:00:00")
        let status = Self.status(deadline: "2026-11-19 22:59:00 +0000")
        for awaitingSync in [false, true] {
            let target = Self.target(status, awaitingSync: awaitingSync, catalog: Self.windowCatalog, now: later)
            #expect(target.earlierStepVersion == "27.2" && target.earlierStepLapsed)
            let device = Sample.classify(Sample.mac(os: "27.1", model: "Mac15,12"), status, target: target, now: "2026-11-21T12:00:00")
            #expect(device.pastDeadline == true)
        }
    }

    @Test("The window: from the release (its posting is gone) to the next posting, one deadline a day, at the Blueprint’s time")
    func window() throws {
        let window = TargetRules.ruleWindow(for: try #require(OSVersion("27.2")), block: Self.block, catalog: Self.windowCatalog,
                                            platform: .macOS, model: "Mac15,12", boardID: "J613AP", now: Self.now)
        #expect(window.first == "2026-11-09T23:59:00" && window.last == "2026-11-23T23:59:00")
        #expect(window.contains("2026-11-19T23:59:00") && window.count == 15)
        // nothing followed the current target; a specific version has no window
        #expect(TargetRules.ruleWindow(for: try #require(OSVersion("27.2.1")), block: Self.block, catalog: Self.catalog,
                                       platform: .macOS, model: "Mac15,12", boardID: "J613AP", now: Self.now).isEmpty)
        let specific = TargetRulesTests.block(.specific(targetOSVersion: "27.2.1", targetLocalDateTime: nil, detailsURL: nil))
        #expect(TargetRules.ruleWindow(for: try #require(OSVersion("27.2")), block: specific, catalog: Self.catalog,
                                       platform: .macOS, model: "Mac15,12", boardID: "J613AP", now: Self.now).isEmpty)
    }

    @Test("The same time of day: a moment by its minutes, a local time by its clock")
    func sameClock() {
        #expect(TargetRules.sameClock(reported: Sample.date("2026-11-19T22:59:12"), reportedLocal: nil, expected: "2026-11-19T23:59:00"))
        // a zone half an hour off
        #expect(TargetRules.sameClock(reported: Sample.date("2026-11-19T18:29:00"), reportedLocal: nil, expected: "2026-11-19T23:59:00"))
        #expect(!TargetRules.sameClock(reported: Sample.date("2026-11-19T22:17:00"), reportedLocal: nil, expected: "2026-11-19T23:59:00"))
        #expect(TargetRules.sameClock(reported: nil, reportedLocal: "2026-11-19T23:59:00", expected: "2026-11-19T23:59:00"))
        #expect(!TargetRules.sameClock(reported: nil, reportedLocal: "2026-11-19T17:00:00", expected: "2026-11-19T23:59:00"))
    }
}

@Suite("0.2: Blueprint health, read per declaration")
struct BlueprintHealthTests {
    static let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"
    static let below = "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$"
    static let predicate = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "\#(below)" AND status.softwareupdate.device-id IN {"J314sAP"}"#

    static func reports(_ device: String, configuration: JamfPlatform.DeclarationReport.Status = .successful,
                        validity: JamfPlatform.DeclarationReport.Validity = .valid,
                        reasons: [JamfPlatform.DeclarationReport.Reason] = [], notForDevice: Bool = false) -> [JamfPlatform.DeclarationReport] {
        let id = "Blueprint_\(blueprint)_s1_c1_sys_"
        if notForDevice {
            return [
                .init(declarationIdentifier: id + "act12", deviceID: device, type: "ACTIVATION", status: .unsuccessful, active: false,
                      reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])]),
                .init(declarationIdentifier: id + "cfg12", deviceID: device, type: "CONFIGURATION", status: .unsuccessful, active: false,
                      reasons: [.init(code: "Error.ActivationFailed")]),
            ]
        }
        return [
            .init(declarationIdentifier: id + "act12", deviceID: device, type: "ACTIVATION", status: .successful, active: true),
            .init(declarationIdentifier: id + "cfg12", deviceID: device, type: "CONFIGURATION", status: configuration, active: true,
                  validity: validity, reasons: reasons),
        ]
    }

    static let failure = JamfPlatform.DeclarationReport.Reason(
        code: "Error.ConfigurationFailed",
        details: [.init(key: "Error", description: "Blueprint_\(blueprint)_s1_c1_sys_cfg12:abcdef0123456789abcdef needs a supervised device"),
                  .init(key: "ServerToken", description: "abcdef0123456789")])

    static var all: [JamfPlatform.DeclarationReport] {
        reports("P-1") + reports("P-2", configuration: .awaitingSync) + reports("P-3", configuration: .unsuccessful, reasons: [failure])
            + reports("P-4", configuration: .unsuccessful, validity: .invalid, reasons: [failure]) + reports("P-5", configuration: .pending)
            + reports("P-6", notForDevice: true) + reports("P-9")
    }

    static let ids = Dictionary(uniqueKeysWithValues: (1...6).map { ("p-\($0)", "computer/\($0)") })

    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static var current: [BlueprintHealth.Current] {
        BlueprintHealth.catalogue(all, blocks: [block], blueprintName: "Test Mac Updates")
    }

    /// A pair the way a device reports an iPadOS one it isn’t meant for.
    static func iPadPair(_ device: String, number: Int, status: JamfPlatform.DeclarationReport.Status) -> [JamfPlatform.DeclarationReport] {
        let id = "Blueprint_\(blueprint)_s1_c1_sys_"
        let predicate = #"status.device.operating-system.family == "iPadOS" AND status.device.operating-system.version MATCHES "^26[.][0-6]([.][0-9]+)*$""#
        return [
            .init(declarationIdentifier: id + "act\(number)", deviceID: device, type: "ACTIVATION", status: .unsuccessful, active: false,
                  reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])]),
            .init(declarationIdentifier: id + "cfg\(number)", deviceID: device, type: "CONFIGURATION", status: status, active: false),
        ]
    }

    static func mac(_ id: String, os: String) -> DeviceStatus {
        let status = Sample.status([("device.operating-system.version", os), ("softwareupdate.device-id", "J314sAP")])
        var device = Sample.classify(JamfPro.GroupMember(id: id, kind: .computer, name: "Mac \(id)", serialNumber: "ZZTESTM\(id)",
                                                         managementID: "M-\(id)", osVersion: os, modelIdentifier: "MacBookPro18,3",
                                                         lastContact: Sample.now),
                                     status, context: Sample.context(target: "26.7.3"))
        device.targetVersion = "26.7.3"
        device.category = .notStarted
        return device
    }

    @Test("The identifiers come from the devices’ status reports: this Blueprint’s update declarations only, each once")
    func identifiers() {
        let mine = "Blueprint_\(Self.blueprint)_s1_c1_sys_cfg1"
        let text = "{activations=[{identifier=\(mine.replacingOccurrences(of: "cfg", with: "act")), active=true}], "
            + "configurations=[{identifier=\(mine), active=true}, {identifier=Blueprint_7b000000-1111-4000-8000-000000000001_s1_c1_sys_cfg1}, "
            // another component of the same Blueprint (not its software update), and another declaration
            + "{identifier=Blueprint_\(Self.blueprint)_s1_c2_sys_cfg1}, {identifier=com.example.wifi}]}"
        let status = Sample.status([("management.declarations", text)])
        let found = BlueprintHealth.identifiers(blueprintID: Self.blueprint.uppercased(), statuses: [status, status, nil], blocks: [Self.block])
        #expect(found == [mine.replacingOccurrences(of: "cfg", with: "act"), mine])
        #expect(BlueprintHealth.identifiers(blueprintID: Self.blueprint, statuses: [status], blocks: []).isEmpty)
    }

    @Test("Per declaration by name: applied, pending, awaiting sync, failed, invalid and not for the device, with the common reason")
    func counts() throws {
        let tied = BlueprintHealth.byDevice(Self.all, deviceIDs: Self.ids)
        #expect(tied.unmatched == 1, "P-9 isn’t in the list: left out and counted")
        let health = BlueprintHealth.make(byDevice: tied.reports, devices: [], current: Self.current, blueprintName: "Test Mac Updates",
                                          blueprintID: Self.blueprint, unmatchedDevices: tied.unmatched)
        let row = try #require(health.declarations.first)
        #expect(health.declarations.count == 1 && health.inapplicable == 0)
        #expect(row.name == "Test Mac Updates, macOS 26.0 to 26.7.1")
        let counts: [Int] = [row.applied, row.pending, row.awaitingSync, row.failed, row.invalid, row.notForDevice]
        #expect(counts == [1, 1, 1, 1, 1, 1])
        let reason = try #require(row.commonReason)
        #expect(row.commonReasonCount == 2)
        #expect(reason.contains("needs a supervised device") && reason.contains("Test Mac Updates"))
        // never an ID, a server token or a hash
        #expect(!reason.contains(Self.blueprint) && !reason.contains("abcdef0123456789"))
        #expect(BlueprintHealth.isAwaitingSync(tied.reports["computer/2"] ?? [], osName: "macOS", current: Self.current))
        #expect(!BlueprintHealth.isAwaitingSync(tied.reports["computer/1"] ?? [], osName: "macOS", current: Self.current))
    }

    @Test("Awaiting sync counts only for an update declaration of the device’s own OS")
    func awaitingSyncOwnOS() {
        // the Mac's own declaration applied; an iPadOS declaration of the Blueprint awaiting sync
        let reports = Self.reports("P-1") + Self.iPadPair("P-1", number: 3, status: .awaitingSync)
        let current = BlueprintHealth.catalogue(reports, blocks: [Self.block], blueprintName: "T")
        #expect(current.first { $0.key.hasSuffix("3") }?.family == "iPadOS")
        #expect(!BlueprintHealth.isAwaitingSync(reports, osName: "macOS", current: current))
        #expect(BlueprintHealth.isAwaitingSync(reports, osName: "iPadOS", current: current))
    }

    @Test("Rows with the same range merge, counted once per device; rows for no device in scope collapse")
    func mergeAndCollapse() throws {
        // a second pair for the same range (another hardware group), and an iPadOS pair no Mac uses
        let second = Self.reports("P-1").map { report -> JamfPlatform.DeclarationReport in
            var copy = report
            copy.declarationIdentifier = report.declarationIdentifier.replacingOccurrences(of: "12", with: "14")
            return copy
        }.map { report -> JamfPlatform.DeclarationReport in
            var copy = report
            copy.status = .unsuccessful
            copy.active = false
            copy.reasons = [.init(code: report.type == "ACTIVATION" ? "Info.Predicate" : "Error.ActivationFailed",
                                  details: report.type == "ACTIVATION" ? [.init(key: "Predicate", description: Self.predicate)] : [])]
            return copy
        }
        let reports = Self.all + second + Self.iPadPair("P-1", number: 3, status: .unsuccessful)
        let tied = BlueprintHealth.byDevice(reports, deviceIDs: Self.ids)
        let current = BlueprintHealth.catalogue(reports, blocks: [Self.block], blueprintName: "Test Mac Updates")
        #expect(current.count == 3)
        let health = BlueprintHealth.make(byDevice: tied.reports, devices: [], current: current, blueprintName: "Test Mac Updates",
                                          blueprintID: Self.blueprint)
        let row = try #require(health.declarations.first)
        #expect(health.declarations.map(\.name) == ["Test Mac Updates, macOS 26.0 to 26.7.1"])
        // P-1 applies the first pair and not the second: applied once, never also “not for”
        #expect(row.applied == 1 && row.notForDevice == 1)
        #expect(health.inapplicable == 1)
        #expect(BlueprintHealth.othersLine(health.inapplicable, inScope: true) == "1 other declaration doesn’t apply to any device in scope")
        #expect(BlueprintHealth.othersLine(17, inScope: false) == "17 others don’t apply to this device")
    }

    @Test("None of the current declarations covers the version: doesn’t cover; one does but the device hasn’t fetched it: not fetched")
    func coverage() {
        let tied = BlueprintHealth.byDevice(Self.all, deviceIDs: Self.ids)
        let device = Self.mac("6", os: "26.7.2")
        let health = BlueprintHealth.make(byDevice: tied.reports, devices: [device], current: Self.current, blueprintName: "Test Mac Updates",
                                          blueprintID: Self.blueprint)
        #expect(health.coverage[device.id] == .notCovered("macOS 26.0 to 26.7.1"))
        #expect(BlueprintHealth.diagnosis(.notCovered("x"), device: device) == "Jamf’s update doesn’t cover macOS 26.7.2 yet")

        // Jamf widened the range in a new declaration another Mac already fetched; this one reported before it
        let wide = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "^26[.]([0-6]|7)([.][0-9]+)*$" AND status.softwareupdate.device-id IN {"J314sAP"}"#
        let id = "Blueprint_\(Self.blueprint)_s1_c1_sys_"
        let widened: [JamfPlatform.DeclarationReport] = [
            .init(declarationIdentifier: id + "act13", deviceID: "P-1", type: "ACTIVATION", status: .unsuccessful, active: false,
                  reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: wide)])]),
            .init(declarationIdentifier: id + "cfg13", deviceID: "P-1", type: "CONFIGURATION", status: .unsuccessful, active: false),
        ]
        let reports = Self.all + widened
        let current = BlueprintHealth.catalogue(reports, blocks: [Self.block], blueprintName: "Test Mac Updates")
        let again = BlueprintHealth.byDevice(reports, deviceIDs: Self.ids)
        let last = Sample.date("2026-11-03T08:00:00")
        let own = Self.reports("P-6", notForDevice: true).map { report -> JamfPlatform.DeclarationReport in
            var copy = report
            copy.lastReportTime = last
            return copy
        }
        let found = BlueprintHealth.coverage(device, current: current, reports: own)
        #expect(found == .notFetched(lastReport: last))
        #expect(BlueprintHealth.diagnosis(found!, device: device).hasPrefix("Hasn’t fetched Jamf’s current declarations yet (last reported "))
        // having fetched it, it is covered: nothing to say
        #expect(BlueprintHealth.coverage(device, current: current, reports: own + widened.map { report in
            var copy = report
            copy.deviceID = "P-6"
            return copy
        }) == nil)
        _ = again

        // on target, or the target isn't newer: nothing to say
        var onTarget = device
        onTarget.category = .onTarget
        var sameTarget = device
        sameTarget.targetVersion = "26.7.2"
        #expect(BlueprintHealth.coverage(onTarget, current: Self.current, reports: nil) == nil)
        #expect(BlueprintHealth.coverage(sameTarget, current: Self.current, reports: nil) == nil)
        // a device that applies one of them is covered
        #expect(BlueprintHealth.coverage(device, current: Self.current, reports: Self.reports("P-6")) == nil)
    }

    @Test("A failed or invalid update declaration of the device’s own OS is its list diagnosis; another OS’s isn’t")
    func declarationProblem() {
        let names = [Self.blueprint: "Test Mac Updates"]
        let failed = Self.reports("P-3", configuration: .unsuccessful, reasons: [Self.failure])
        #expect(BlueprintHealth.declarationProblem(failed, osName: "macOS", current: Self.current, names: names)?
            .hasPrefix("Update declaration failed: Error.ConfigurationFailed") == true)
        let other = Self.iPadPair("P-1", number: 3, status: .unsuccessful)
        let current = BlueprintHealth.catalogue(other, blocks: [Self.block], blueprintName: "T")
        #expect(BlueprintHealth.declarationProblem(other, osName: "macOS", current: current, names: names) == nil)
    }

    @Test("Lines and names: the dashboard says it once; names stay unique")
    func texts() {
        #expect(BlueprintHealth.dashboardLine(0) == nil)
        #expect(BlueprintHealth.dashboardLine(1) == "1 device is on a version the Blueprint’s update doesn’t cover yet")
        #expect(BlueprintHealth.dashboardLine(3) == "3 devices are on a version the Blueprint’s update doesn’t cover yet")
        let lines = BlueprintHealth.uniqueNames([.init(name: "A, iPadOS", state: ""), .init(name: "A, iPadOS", state: ""), .init(name: "B", state: "")])
        #expect(lines.map(\.name) == ["A, iPadOS", "A, iPadOS (2)", "B"])
    }
}

@Suite("0.2: device details and status items")
struct DeviceDetailsTests {
    @Test("Rapid Security Response, beta, install reason, failures, FileVault and battery health, in the row and the CSV")
    func details() throws {
        var mac = Sample.mac()
        mac.diskEncryption = JamfPro.Computer.DiskEncryption(bootPartitionFileVault2State: "ENCRYPTED")
        let status = Sample.status([("device.operating-system.version", "27.0.1"),
                                    ("device.operating-system.supplemental.build-version", "26A5341a"),
                                    ("device.operating-system.supplemental.extra-version", "(a)"),
                                    ("device.power.battery-health", "service-recommended"),
                                    ("softwareupdate.beta-enrollment", "macOS 28 Developer Beta"),
                                    ("softwareupdate.install-reason.reason", "declaration,system-settings"),
                                    ("softwareupdate.failure-reason.count", "2"),
                                    ("softwareupdate.failure-reason.reason", "Download failed"),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")])
        let device = Sample.classify(mac, status)
        #expect(device.rapidSecurityResponse == "(a)" && device.supplementalBuild == "26A5341a")
        #expect(device.betaEnrollment == "macOS 28 Developer Beta")
        #expect(device.installReason == "declaration, system-settings")
        #expect(device.failureCount == 2)
        #expect(device.fileVault == "ENCRYPTED")
        #expect(device.batteryHealth == "service-recommended")
        #expect(Array(DeviceStatus.csvColumns.suffix(6)) == ["rapid_security_response", "beta_enrollment", "install_reason",
                                                             "failure_count", "filevault", "battery_health"])
        #expect(device.csvLine.hasSuffix(#",(a),macOS 28 Developer Beta,"declaration, system-settings",2,ENCRYPTED,service-recommended"#))
        // an iPad’s from its inventory; no beta when it says none
        var iPad = Sample.iPad()
        iPad.osRapidSecurityResponse = "(b)"
        let none = Sample.classify(iPad, Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.beta-enrollment", "none")]))
        #expect(none.rapidSecurityResponse == "(b)" && none.betaEnrollment == nil && none.batteryHealth == "NORMAL")
    }

    @Test("Detail texts in plain words")
    func texts() {
        #expect(DeviceDetailText.fileVault("ENCRYPTED") == "On" && DeviceDetailText.fileVault("UNENCRYPTED") == "Off")
        #expect(DeviceDetailText.fileVault(nil) == "Not reported" && DeviceDetailText.fileVault("ENCRYPTING") == "Encrypting")
        #expect(DeviceDetailText.batteryHealth("service-recommended") == "Service recommended")
        #expect(DeviceDetailText.batteryHealth("SERVICE_RECOMMENDED") == "Service recommended")
        #expect(DeviceDetailText.batteryNeedsService("SERVICE_RECOMMENDED") && !DeviceDetailText.batteryNeedsService("normal"))
        #expect(DeviceDetailText.installReason("declaration, mdm") == "A declaration; An MDM command")
        #expect(DeviceDetailText.betaProgram("False") == nil && DeviceDetailText.betaProgram("Public Beta") == "Public Beta")
        #expect(StatusItemsView.text([.init(key: "a", value: "1"), .init(key: "b")]) == "a = 1\nb = ")
    }
}

@Suite("0.2: in Demo Mode")
@MainActor
struct DemoFeatureTests {
    private func refreshed(_ name: String) async throws -> (DashboardModel, RefreshResult) {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let model = DashboardModel(connections: connections, history: StatusHistory(folder: TestFiles.folder("v02")))
        let tracked = try #require(model.trackedBlueprints.first { $0.blueprintName == name })
        await model.refresh(tracked.id)
        #expect(model.errors[tracked.id] == nil)
        return (model, try #require(model.results[tracked.id]))
    }

    @Test("The Mac Blueprint: the device list read once, each update declaration once, nothing per device; the causes say why")
    func macHealth() async throws {
        let (model, result) = try await refreshed("Contoso – Mac Update")
        let health = try #require(result.health)
        // the range for macOS 26 applies to no Studio Mac: collapsed into one line (Studio Mac 11 is on 15.7.3)
        #expect(health.declarations.map(\.name) == ["Contoso – Mac Update, macOS 27.0 to 27.0.1", "Contoso – Mac Update, macOS 15.0 to 15.7.3"])
        #expect(health.inapplicable == 1)
        #expect(health.declarations.first?.awaitingSync == 1)
        #expect(health.unmatchedDevices == 0 && health.devicesWithoutPlatformID == 0)
        let byName = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.name, $0) })
        let uncovered = try #require(byName["Studio Mac 07"])
        #expect(uncovered.diagnosis == "Jamf’s update doesn’t cover macOS 27.0.2 yet" && uncovered.needsAttention)
        #expect(uncovered.notCoveredBy == "macOS 27.0 to 27.0.1")
        #expect(result.notCoveredCount == 1)
        // covered by the current declaration, which the Mac hasn't fetched (awaiting sync)
        let behind = try #require(byName["Studio Mac 05"])
        #expect(behind.diagnosis.hasPrefix("Hasn’t fetched Jamf’s current declarations yet (last reported ") && behind.notFetched == true)
        #expect(model.summary(result.tracked.id)?.contains("1 device is on a version the Blueprint’s update doesn’t cover yet") == true)
        // a beta of a major Apple hasn't released: no target
        #expect(byName["Studio Mac 08"]?.category == .targetUnknown)
        // details
        #expect(byName["Studio Mac 01"]?.rapidSecurityResponse == "(a)")
        #expect(byName["Studio Mac 03"]?.batteryHealth == "service-recommended")
        #expect(byName["Studio Mac 05"]?.fileVault == "UNENCRYPTED")
        #expect(byName["Studio Mac 02"]?.installReason == "declaration")
        #expect(byName["Studio Mac 02"]?.bootstrapToken == "NOT_ESCROWED")
        // requests: the Platform device list once (whatever the number of devices), one per update declaration, none per device
        let paths = model.connections.activityLog.entries.compactMap { $0.request != nil ? $0.detail : nil }
        #expect(paths.filter { $0.contains("devices/v1/devices") && !$0.contains("ddm/report") }.count == 1)
        #expect(paths.filter { $0.contains("ddm/report/v1/declarations/") }.count == 6)
        #expect(!paths.contains { $0.contains("ddm/report/v1/devices/") })
    }

    @Test("The iPad Blueprint: an invalid and a failed declaration, pending and awaiting sync; Inspect lists its own platform’s")
    func iPadHealth() async throws {
        let (model, result) = try await refreshed("Contoso – iPad Update")
        let health = try #require(result.health)
        // named by the step's OS family; the iPhone step applies to no iPad in scope
        #expect(health.declarations.map(\.name) == ["Contoso – iPad Update, iPadOS"])
        #expect(health.inapplicable == 1)
        let iPadOS = try #require(health.declarations.first)
        let counts: [Int] = [iPadOS.invalid, iPadOS.failed, iPadOS.pending, iPadOS.awaitingSync]
        #expect(counts == [1, 1, 1, 1])
        // the failed declaration explains the unsupervised iPad in the list
        #expect(result.devices.first { $0.name == "Field iPad 13" }?.diagnosis.hasPrefix("Update declaration failed: ") == true)
        let old = try #require(result.devices.first { $0.name == "Field iPad 09" })
        await model.inspect([old], in: result.tracked.id)
        let inspection = try #require(model.inspection(of: old, in: result.tracked.id))
        #expect(inspection.declarations.map(\.name) == ["Contoso – iPad Update, iPadOS"])
        #expect(inspection.declarations.first?.state.hasPrefix("Invalid: ") == true)
        #expect(inspection.declarations.first?.state.contains("iPadOS 17") == true)
        #expect(inspection.otherDeclarations == 1, "the iOS step, in one line")
        #expect(!inspection.declarations.contains { $0.name.contains(DemoSoftwareUpdate.iPadBlueprintID) || $0.state.contains(DemoSoftwareUpdate.iPadBlueprintID) })
    }

    @Test("All status items, read on request, with their value types, sorted; not saved in the history")
    func statusItems() async throws {
        let (model, result) = try await refreshed("Contoso – Mac Update")
        let mac = try #require(result.devices.first { $0.name == "Studio Mac 01" })
        let items = try await model.statusItems(of: mac, in: result.tracked.id)
        #expect(items.contains { $0.key == "device.operating-system.supplemental.extra-version" && $0.value == "(a)" && $0.valueKind == .string })
        #expect(items.contains { $0.key == "passcode.is-present" && $0.value == "false" && $0.valueKind == .boolean })
        #expect(items.contains { $0.key == "management.declarations" })
        #expect(items.map(\.key) == items.map(\.key).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        // nothing of them reaches the history's files
        let folder = try #require(model.history?.folder)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        #expect(!files.isEmpty)
        for file in files where !file.hasDirectoryPath {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains("supplemental.extra-version") && !text.contains("management.declarations"))
        }
        let noID = DeviceStatus(jamfID: "0", isComputer: true, name: "", serial: "", model: "", modelIdentifier: "",
                                error: "", category: .noReport, diagnosis: "")
        await #expect(throws: RefreshError.self) { try await model.statusItems(of: noID, in: result.tracked.id) }
    }

    @Test("A refresh stopped while the declarations are read ends as “Stopped.” and saves nothing")
    func stopped() async throws {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let history = StatusHistory(folder: TestFiles.folder("stop"))
        let model = DashboardModel(connections: connections, history: history)
        let tracked = try #require(model.trackedBlueprints.first)
        let task = Task { await model.refresh(tracked.id) }
        task.cancel()
        await task.value
        #expect(model.results[tracked.id] == nil)
        #expect(model.errors[tracked.id] == "Stopped.")
        #expect(history.snapshots(for: tracked.id).isEmpty)
    }
}

@Suite("0.2: the declaration reads in a refresh")
struct DeclarationReadTests {
    private func workflow(_ server: MockServer) throws -> RefreshWorkflow {
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                                             scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: StaticToken(),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        return RefreshWorkflow(client: client, catalog: AppleReleases.Catalog(), serverTimeZone: .gmt)
    }

    @Test("A failed device list read is an error, never “serial not found”; no declaration is read")
    func deviceListRefused() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[]}"#) }
        var inputs = [DeviceInput(member: Sample.iPad("1"))]
        let read = try await workflow(server).declarationReports(["Blueprint_x_s1_c1_sys_cfg1"], inputs: &inputs)
        #expect(read.problem?.hasPrefix("The Platform device list couldn’t be read") == true)
        #expect(!(read.problem ?? "").localizedCaseInsensitiveContains("not found"))
        #expect(read.reports.isEmpty && inputs[0].platformDeviceID == nil)
        #expect(server.requests.allSatisfy { !$0.path.contains("ddm/report") })
    }

    @Test("The list is read once and matched by serial number, whatever the case; a device not in it has no Platform ID")
    func matchedBySerial() async throws {
        let server = MockServer { request in
            if request.path == "/devices/v1/devices" {
                return .json(200, #"{"hasNext":false,"results":[{"id":"P-1","serialNumber":"zztest1"}]}"#)
            }
            return .json(200, #"{"totalCount":1,"results":[{"declarationIdentifier":"cfg1","deviceId":"P-1","status":"SUCCESSFUL"}]}"#)
        }
        var inputs = [DeviceInput(member: Sample.iPad("1")), DeviceInput(member: Sample.iPad("2"))]
        let read = try await workflow(server).declarationReports(["cfg1", "act1"], inputs: &inputs)
        #expect(read.problem == nil && read.reports.count == 2)
        #expect(inputs.map(\.platformDeviceID) == ["P-1", nil])
        #expect(server.requests.filter { $0.path == "/devices/v1/devices" }.count == 1)
        // nothing to read: not even the list
        var none = inputs
        let empty = try await workflow(server).declarationReports([], inputs: &none)
        #expect(empty.reports.isEmpty && empty.problem == nil)
    }

    @Test("A stop while reading is thrown, never a problem of the refresh")
    func cancellation() async throws {
        let server = MockServer { _ in .json(200, #"{"hasNext":false,"results":[]}"#) }
        let flow = try workflow(server)
        let task = Task {
            var inputs = [DeviceInput(member: Sample.iPad("1"))]
            return try await flow.declarationReports(["cfg1"], inputs: &inputs)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("A history saved by 0.1.1, without the new fields, still reads")
    func oldHistory() throws {
        let device = Sample.classify(Sample.iPad(), Sample.status([("device.operating-system.version", "26.7.1")]))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any])
        for key in ["rapidSecurityResponse", "supplementalBuild", "betaEnrollment", "installReason", "fileVault", "batteryHealth",
                    "notCoveredBy", "notFetched", "notFetchedSince", "declarationsChecked"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(DeviceStatus.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.serial == device.serial && decoded.batteryHealth == nil && decoded.declarationsChecked == nil)
    }
}

@Suite("0.2: Inspect against the Blueprint’s current declarations")
struct InspectCurrentDeclarationsTests {
    static let blueprint = BlueprintHealthTests.blueprint

    /// A Mac on 26.7.2 the refresh found behind the current declarations.
    static func row(notFetched: Bool = false, notCovered: String? = nil) -> (JamfPro.GroupMember, JamfPro.SoftwareUpdateStatus, DeviceStatus) {
        let member = JamfPro.GroupMember(id: "6", kind: .computer, name: "Mac 6", serialNumber: "ZZTESTM6", managementID: "M-6",
                                         osVersion: "26.7.2", modelIdentifier: "MacBookPro18,3", lastContact: Sample.now,
                                         managed: true, supervised: true)
        let status = Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.device-id", "J314sAP"),
                                    ("softwareupdate.install-state", "none"),
                                    ("softwareupdate.failure-reason.count", "77"),
                                    ("softwareupdate.failure-reason.reason", "Code=101 \"The update couldn’t be prepared\""),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-04T09:00:00")])
        var device = BlueprintHealthTests.mac("6", os: "26.7.2")
        device.declarationsChecked = true
        device.notFetched = notFetched ? true : nil
        device.notFetchedSince = notFetched ? Sample.date("2026-11-02T08:00:00") : nil
        device.notCoveredBy = notCovered
        device.activityFrom = Sample.updateStarted
        return (member, status, device)
    }

    static func evaluate(_ parts: (JamfPro.GroupMember, JamfPro.SoftwareUpdateStatus, DeviceStatus),
                         current: [BlueprintHealth.Current]? = nil) -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: parts.0, status: parts.1, device: parts.2, platformDeviceID: "P-6",
                                              reports: BlueprintHealthTests.reports("P-6", notForDevice: true)),
                                 context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates", target: nil,
                                                         since: Sample.updateStarted, now: Sample.now, serverTimeZone: Sample.utc,
                                                         current: current))
    }

    @Test("Covered by a current declaration the device hasn’t fetched: that cause, not “doesn’t cover”; an update error since the start ranks first")
    func notFetchedBelowError() {
        let result = Self.evaluate(Self.row(notFetched: true))
        #expect(result.likely?.cause == "Update error")
        #expect(result.findings.contains { $0.cause == "Hasn’t fetched Jamf’s current declarations yet" && $0.detail.contains("last reported its declarations on") })
        #expect(!result.findings.contains { $0.cause.hasPrefix("Jamf’s update doesn’t cover") })
        let error = result.findings.firstIndex { $0.cause == "Update error" } ?? .max
        let fetched = result.findings.firstIndex { $0.cause.hasPrefix("Hasn’t fetched") } ?? .min
        #expect(error < fetched)
    }

    @Test("Not covered by the current declarations: said from them, below an update error since the start")
    func notCoveredFromCurrent() {
        let result = Self.evaluate(Self.row(notCovered: "macOS 26.0 to 26.7.1"))
        #expect(result.likely?.cause == "Update error")
        #expect(result.findings.contains { $0.cause == "Jamf’s update doesn’t cover macOS 26.7.2 yet" && $0.detail.contains("current update declarations") })
    }

    @Test("The list: the current declarations of the device’s own platform by their own names; the rest in one line")
    func ownPlatformList() {
        // a macOS range from the Mac's own report, an iPadOS and an iOS range from other devices
        let iPad = BlueprintHealthTests.iPadPair("P-1", number: 3, status: .unsuccessful)
        let iOS = BlueprintHealthTests.iPadPair("P-1", number: 4, status: .unsuccessful).map { report -> JamfPlatform.DeclarationReport in
            var copy = report
            copy.reasons = report.reasons.map { reason in
                var changed = reason
                changed.details = reason.details.map { .init(key: $0.key, description: $0.description?.replacingOccurrences(of: "iPadOS", with: "iOS")) }
                return changed
            }
            return copy
        }
        let current = BlueprintHealth.catalogue(BlueprintHealthTests.all + iPad + iOS, blocks: [BlueprintHealthTests.block],
                                                blueprintName: "Test Mac Updates")
        #expect(current.map(\.name).contains("Test Mac Updates, iPadOS 26.0 to 26.6.x"))
        #expect(current.map(\.name).contains("Test Mac Updates, iOS 26.0 to 26.6.x"))
        let result = Self.evaluate(Self.row(), current: current)
        // the macOS range doesn't take 26.7.2 either: no line of its own
        #expect(result.declarations.isEmpty)
        #expect(result.otherDeclarations == 3)
        #expect(!result.declarations.contains { $0.name.contains("macOS 18") || $0.name.contains("macOS 17") })
    }

    @Test("Failures: “0” without a date; otherwise the count and the last time")
    func failures() {
        #expect(DeviceDetailText.failures(count: 0, time: "2026-10-13T09:00:00", serverTimeZone: Sample.utc) == "0")
        #expect(DeviceDetailText.failures(count: 3, time: "2026-11-05T11:00:00", serverTimeZone: Sample.utc)?.hasPrefix("3, last ") == true)
        #expect(DeviceDetailText.failures(count: nil, time: nil, serverTimeZone: Sample.utc) == nil)
    }
}

@Suite("0.2: hand-check fixes")
struct HandCheckFixTests {
    static func installing(failedAt: String) -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.device-id", "J314sAP"),
                       ("softwareupdate.install-state", "installing"),
                       ("softwareupdate.pending-version.os-version", "26.7.3"),
                       ("softwareupdate.install-reason.reason", "declaration"),
                       ("softwareupdate.failure-reason.count", "2"),
                       ("softwareupdate.failure-reason.reason", "Code=101 \"The update couldn’t be prepared\""),
                       ("softwareupdate.failure-reason.timestamp", failedAt)], time: "2026-11-05T09:00:00")
    }

    static func inspect(_ status: JamfPro.SoftwareUpdateStatus, stateChanged: String?) -> InspectResult {
        let (member, _, device) = InspectCurrentDeclarationsTests.row(notFetched: true)
        var input = InspectInput(member: member, status: status, device: device, platformDeviceID: "P-6",
                                 reports: BlueprintHealthTests.reports("P-6", notForDevice: true))
        input.installStateChanged = stateChanged.map(Sample.date)
        return InspectFindings.evaluate(input, context: InspectContext(blueprintID: BlueprintHealthTests.blueprint, blueprintName: "Test Mac Updates",
                                                                       target: nil, since: Sample.updateStarted, now: Sample.now,
                                                                       serverTimeZone: Sample.utc))
    }

    @Test("Installing: an error from before the install state changed isn’t the likely cause; a newer one is")
    func errorDuringInstall() {
        let older = Self.inspect(Self.installing(failedAt: "2026-11-05T07:00:00"), stateChanged: "2026-11-05T09:00:00")
        #expect(older.likely?.cause != "Update error")
        #expect(older.findings.contains { $0.cause == "Update error" }, "still listed")
        let newer = Self.inspect(Self.installing(failedAt: "2026-11-05T10:00:00"), stateChanged: "2026-11-05T09:00:00")
        #expect(newer.likely?.cause == "Update error")
        // not installing: the error since the update started leads
        #expect(InspectCurrentDeclarationsTests.evaluate(InspectCurrentDeclarationsTests.row(notFetched: true)).likely?.cause == "Update error")
    }

    @Test("Offline comes before “Not evaluated since the update started”")
    func offlineFirst() {
        let member = JamfPro.GroupMember(id: "8", kind: .mobileDevice, name: "iPad 8", serialNumber: "ZZTEST8", managementID: "M-8",
                                         osVersion: "26.7.1", modelIdentifier: "iPad13,18",
                                         lastContact: Sample.date("2026-09-01T10:00:00"), managed: true, supervised: true)
        let reports = BlueprintHealthTests.reports("P-8").map { report -> JamfPlatform.DeclarationReport in
            var copy = report
            copy.lastReportTime = Sample.date("2026-09-01T09:00:00")
            return copy
        }
        let status = Sample.status([("device.operating-system.version", "26.7.1")], time: "2026-09-01T09:00:00")
        let result = InspectFindings.evaluate(InspectInput(member: member, status: status, platformDeviceID: "P-8", reports: reports),
                                              context: InspectContext(blueprintID: BlueprintHealthTests.blueprint, target: OSVersion("27.0.1"),
                                                                      since: Sample.updateStarted, now: Sample.now, serverTimeZone: Sample.utc))
        #expect(result.likely?.cause == "Offline")
        #expect(result.findings.contains { $0.cause == "Not evaluated since the update started" })
    }

    @Test("Deadline per Time Zone: an earlier step is listed at its passed deadline only when the device counts as past it")
    func earlierStepZone() {
        var device = InspectCurrentDeclarationsTests.row().2
        device.targetVersion = "27.2.1"
        device.deadlineLocal = "2026-11-23T23:59:00"
        device.earlierStepVersion = "27.2"
        device.earlierStepDeadline = Sample.date("2026-11-04T22:59:00")
        // still installing the step (not lapsed): at its current target's deadline
        device.earlierStepLapsed = nil
        device.pastDeadline = false
        #expect(DeadlineZones.zones(devices: [device], now: Sample.now).map(\.target) == ["27.2.1"])
        // lapsed and counted as past: at the step and its deadline, for any major
        device.earlierStepLapsed = true
        device.pastDeadline = true
        let zones = DeadlineZones.zones(devices: [device], now: Sample.now)
        #expect(zones.map(\.target) == ["27.2, earlier step"])
        #expect(zones.first?.deadline == device.earlierStepDeadline)
    }

    @Test("Another Blueprint’s declaration is named without its ID")
    func otherBlueprintName() {
        let other = JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_7b000000-1111-4000-8000-000000000001_s1_c1_sys_cfg3")
        #expect(InspectFindings.otherName(other) == "A declaration from another Blueprint")
        #expect(InspectFindings.otherName(.init(declarationIdentifier: "7b000000-1111-4000-8000-000000000002")) == "Another declaration")
        #expect(InspectFindings.otherName(.init(declarationIdentifier: "com.example.wifi")) == "com.example.wifi")
    }
}
