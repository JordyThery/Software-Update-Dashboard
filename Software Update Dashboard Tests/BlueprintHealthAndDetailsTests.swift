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

    /// `reported`: deadlines the Blueprint’s own devices reported for 27.2 (UTC moments): a Mac’s step needs one, to the minute.
    static func target(_ status: JamfPro.SoftwareUpdateStatus, window: Bool = true, awaitingSync: Bool = false,
                       catalog: AppleReleases.Catalog = catalog, timeZone: String? = nil, now: Date = now,
                       reported: [String] = []) -> DeviceTarget {
        let known = PostingBasis(reportedMinutes: [PostingBasis.key(.macOS, OSVersion("27.2")!):
                                                    Set(reported.map { PostingBasis.minute(Sample.date($0)) })])
        let rule = TargetRules.target(os: "27.1", model: "Mac15,12", boardID: "J613AP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.1", osName: "macOS", catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
            model: "Mac15,12", boardID: "J613AP",
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                            model: "Mac15,12", boardID: "J613AP") },
            earlierStepWindow: window ? { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                                 model: "Mac15,12", boardID: "J613AP", now: now) } : nil,
            awaitingSync: awaitingSync, known: known, timeZone: timeZone, now: now)
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
        #expect(Array(DeviceStatus.csvColumns.suffix(7)) == ["rapid_security_response", "beta_enrollment", "install_reason",
                                                             "failure_count", "filevault", "battery_health", "next_install_attempt"])
        #expect(device.csvLine.hasSuffix(#",(a),macOS 28 Developer Beta,"declaration, system-settings",2,ENCRYPTED,service-recommended,"#))
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
        let connections = ConnectionsModel.preview(defaults: TestFiles.defaults("preview"))
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
        // requests: the Platform device list once (whatever the number of devices), none per device; the two update
        // declaration pairs some Mac holds active in full (four), the macOS 26 pair no Mac holds active once (JTKit 1.10.0)
        let paths = model.connections.activityLog.entries.compactMap { $0.request != nil ? $0.detail : nil }
        #expect(paths.filter { $0.contains("devices/v1/devices") && !$0.contains("ddm/report") }.count == 1)
        #expect(paths.filter { $0.contains("ddm/report/v1/declarations/") }.count == 5)
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
        let items = try await model.statusItems(managementID: mac.managementID, isComputer: mac.isComputer)
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
        await #expect(throws: RefreshError.self) { try await model.statusItems(managementID: noID.managementID, isComputer: noID.isComputer) }
    }

    @Test("A refresh stopped while the declarations are read ends as “Stopped.” and saves nothing")
    func stopped() async throws {
        let connections = ConnectionsModel.preview(defaults: TestFiles.defaults("preview"))
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
                                             scope: .environment("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"), tokens: StaticToken(),
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

}
