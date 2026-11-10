import Foundation
import Testing
import JTKit
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
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(deadline: String, pending: String = "27.2") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.1"), ("softwareupdate.device-id", "J613AP"),
                       ("softwareupdate.install-state", "downloading"),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:00:00")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, window: Bool = true, awaitingSync: Bool = false) -> DeviceTarget {
        let rule = TargetRules.target(os: "27.1", model: "Mac15,12", boardID: "J613AP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.1", osName: "macOS", catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
            model: "Mac15,12", boardID: "J613AP",
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                            model: "Mac15,12", boardID: "J613AP") },
            earlierStepWindow: window ? { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                                 model: "Mac15,12", boardID: "J613AP", now: now) } : nil,
            awaitingSync: awaitingSync, now: now)
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

    @Test("Only at the Blueprint’s time of day; awaiting sync supports a version the rule targeted in that window")
    func timeOfDayAndAwaitingSync() {
        let odd = Self.status(deadline: "2026-11-19 10:17:00 +0000")
        #expect(Self.target(odd).version == "27.2" && Self.target(odd).fromDevice)
        #expect(Self.target(odd, awaitingSync: true).earlierStepVersion == "27.2")
        // a version the rule never targeted: awaiting sync alone isn't enough
        let unknown = Self.status(deadline: "2026-11-19 22:59:00 +0000", pending: "27.1.5")
        #expect(Self.target(unknown, awaitingSync: true).earlierStepVersion == nil)
    }

    @Test("The window: from the release (its posting is gone) to the next posting, one deadline a day, at the Blueprint’s time")
    func window() throws {
        let window = TargetRules.ruleWindow(for: try #require(OSVersion("27.2")), block: Self.block, catalog: Self.catalog,
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

    @Test("The identifiers come from the devices’ status reports: this Blueprint’s only, each once")
    func identifiers() {
        let mine = "Blueprint_\(Self.blueprint)_s1_c1_sys_cfg1"
        let text = "{activations=[{identifier=\(mine.replacingOccurrences(of: "cfg", with: "act")), active=true}], "
            + "configurations=[{identifier=\(mine), active=true}, {identifier=Blueprint_7b000000-1111-4000-8000-000000000001_s1_c1_sys_cfg1}, "
            + "{identifier=com.example.wifi}]}"
        let status = Sample.status([("management.declarations", text)])
        let found = BlueprintHealth.identifiers(blueprintID: Self.blueprint.uppercased(), statuses: [status, status, nil])
        #expect(found == [mine.replacingOccurrences(of: "cfg", with: "act"), mine])
    }

    @Test("Per declaration by name: applied, pending, awaiting sync, failed, invalid and not for the device, with the common reason")
    func counts() throws {
        let tied = BlueprintHealth.byDevice(Self.all, deviceIDs: Self.ids)
        #expect(tied.unmatched == 1, "P-9 isn’t in the list: left out and counted")
        let health = BlueprintHealth.make(byDevice: tied.reports, devices: [], blueprintName: "Test Mac Updates",
                                          blueprintID: Self.blueprint, unmatchedDevices: tied.unmatched)
        let row = try #require(health.declarations.first)
        #expect(health.declarations.count == 1)
        #expect(row.name == "Test Mac Updates, macOS 26.0 to 26.7.1")
        let counts: [Int] = [row.applied, row.pending, row.awaitingSync, row.failed, row.invalid, row.notForDevice]
        #expect(counts == [1, 1, 1, 1, 1, 1])
        let reason = try #require(row.commonReason)
        #expect(row.commonReasonCount == 2)
        #expect(reason.contains("needs a supervised device") && reason.contains("Test Mac Updates"))
        // never an ID, a server token or a hash
        #expect(!reason.contains(Self.blueprint) && !reason.contains("abcdef0123456789"))
        #expect(BlueprintHealth.isAwaitingSync(tied.reports["computer/2"] ?? []))
        #expect(!BlueprintHealth.isAwaitingSync(tied.reports["computer/1"] ?? []))
    }

    @Test("A device on a version no declaration covers, with a newer target; not one on target or applying one")
    func notCovered() {
        let tied = BlueprintHealth.byDevice(Self.all, deviceIDs: Self.ids)
        let status = Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.device-id", "J314sAP")])
        var device = Sample.classify(JamfPro.GroupMember(id: "6", kind: .computer, name: "Mac 6", serialNumber: "ZZTESTM6",
                                                         managementID: "M-6", osVersion: "26.7.2", modelIdentifier: "MacBookPro18,3",
                                                         lastContact: Sample.now),
                                     status, context: Sample.context(target: "26.7.3"))
        device.targetVersion = "26.7.3"
        device.category = .notStarted
        let health = BlueprintHealth.make(byDevice: tied.reports, devices: [device], blueprintName: "Test Mac Updates",
                                          blueprintID: Self.blueprint)
        #expect(health.notCovered[device.id] == "macOS 26.0 to 26.7.1")
        #expect(BlueprintHealth.notCoveredDiagnosis(device) == "Jamf’s update doesn’t cover macOS 26.7.2 yet")
        // on target, or the target isn't newer: nothing to say
        var onTarget = device
        onTarget.category = .onTarget
        var sameTarget = device
        sameTarget.targetVersion = "26.7.2"
        #expect(BlueprintHealth.notCoveredRanges(onTarget, shapes: [], reports: nil) == nil)
        let again = BlueprintHealth.make(byDevice: tied.reports, devices: [onTarget, sameTarget], blueprintName: "T", blueprintID: Self.blueprint)
        #expect(again.notCovered.isEmpty)
        // a device that applies one of them is covered
        let applying = BlueprintHealth.notCoveredRanges(device, shapes: DeclarationPair.pairs(Self.reports("P-6", notForDevice: true)),
                                                        reports: Self.reports("P-6"))
        #expect(applying == nil)
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

    @Test("The Mac Blueprint: its declarations by name, read once each, never per device; the uncovered Mac says why")
    func macHealth() async throws {
        let (model, result) = try await refreshed("Contoso – Mac Update")
        let health = try #require(result.health)
        #expect(health.declarations.map(\.name) == ["Contoso – Mac Update, macOS 27.0 to 27.0.1", "Contoso – Mac Update, macOS 26.0 to 26.5.x",
                                                    "Contoso – Mac Update, macOS 15.0 to 15.7.3"])
        #expect(health.declarations.first?.awaitingSync == 1)
        #expect(health.unmatchedDevices == 0 && health.devicesWithoutPlatformID == 0)
        let byName = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.name, $0) })
        let uncovered = try #require(byName["Studio Mac 07"])
        #expect(uncovered.diagnosis == "Jamf’s update doesn’t cover macOS 27.0.2 yet" && uncovered.needsAttention)
        #expect(uncovered.notCoveredBy == "macOS 27.0 to 27.0.1")
        #expect(result.notCoveredCount == 1)
        #expect(model.summary(result.tracked.id)?.contains("1 device is on a version the Blueprint’s update doesn’t cover yet") == true)
        // a beta of a major Apple hasn't released: no target
        #expect(byName["Studio Mac 08"]?.category == .targetUnknown)
        // details
        #expect(byName["Studio Mac 01"]?.rapidSecurityResponse == "(a)")
        #expect(byName["Studio Mac 03"]?.batteryHealth == "service-recommended")
        #expect(byName["Studio Mac 05"]?.fileVault == "UNENCRYPTED")
        #expect(byName["Studio Mac 02"]?.installReason == "declaration")
        #expect(byName["Studio Mac 02"]?.bootstrapToken == "NOT_ESCROWED")
        // one read per declaration (configuration and activation), none per device
        let paths = model.connections.activityLog.entries.compactMap { $0.request != nil ? $0.detail : nil }
        #expect(paths.filter { $0.contains("ddm/report/v1/declarations/") }.count == 6)
        #expect(!paths.contains { $0.contains("ddm/report/v1/devices/") })
    }

    @Test("The iPad Blueprint: an invalid and a failed declaration, pending and awaiting sync; Inspect lists them for one device")
    func iPadHealth() async throws {
        let (model, result) = try await refreshed("Contoso – iPad Update")
        let health = try #require(result.health)
        #expect(health.declarations.map(\.name) == ["Contoso – iPad Update, step 1", "Contoso – iPad Update, iOS"])
        let iPadOS = try #require(health.declarations.first)
        let counts: [Int] = [iPadOS.invalid, iPadOS.failed, iPadOS.pending, iPadOS.awaitingSync]
        #expect(counts == [1, 1, 1, 1])
        #expect(health.declarations.last?.notForDevice == 12, "every iPad with a status report")
        let old = try #require(result.devices.first { $0.name == "Field iPad 09" })
        await model.inspect([old], in: result.tracked.id)
        let lines = try #require(model.inspection(of: old, in: result.tracked.id)?.declarations)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.state.hasPrefix("Invalid: ") && $0.state.contains("iPadOS 17") })
        #expect(lines.contains { $0.name == "Contoso – iPad Update, iOS" && $0.state == "Not for this device" })
        #expect(!lines.contains { $0.name.contains(DemoSoftwareUpdate.iPadBlueprintID) || $0.state.contains(DemoSoftwareUpdate.iPadBlueprintID) })
    }

    @Test("All status items, read on request, every value type, sorted; nothing kept")
    func statusItems() async throws {
        let (model, result) = try await refreshed("Contoso – Mac Update")
        let mac = try #require(result.devices.first { $0.name == "Studio Mac 01" })
        let items = try await model.statusItems(of: mac, in: result.tracked.id)
        #expect(items.contains { $0.key == "device.operating-system.supplemental.extra-version" && $0.value == "(a)" })
        #expect(items.contains { $0.key == "management.declarations" })
        #expect(items.map(\.key) == items.map(\.key).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let noID = DeviceStatus(jamfID: "0", isComputer: true, name: "", serial: "", model: "", modelIdentifier: "",
                                    error: "", category: .noReport, diagnosis: "")
        await #expect(throws: RefreshError.self) { try await model.statusItems(of: noID, in: result.tracked.id) }
    }
}
