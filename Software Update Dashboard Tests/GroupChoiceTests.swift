import Foundation
import Testing
import JTKit
@testable import Software_Update_Dashboard

/// Mobile device groups and computer groups are numbered separately in Jamf
/// Pro: a group is its kind and number together. Made-up groups only.
@Suite("Groups by kind and number")
@MainActor
struct GroupChoiceTests {
    let mobile12 = JamfPro.DeviceGroup(groupID: "12", name: "Test iPads", isSmart: true, kind: .mobileDevice)
    let computer12 = JamfPro.DeviceGroup(groupID: "12", name: "Test Macs", isSmart: false, kind: .computer)
    let computer30 = JamfPro.DeviceGroup(groupID: "30", name: "Other Macs", isSmart: true, kind: .computer)

    @Test("Choosing the computer group gives the computer group, not the mobile one with its number")
    func choice() {
        let choice = GroupChoice(groups: [mobile12, computer12, computer30])
        #expect(mobile12.id != computer12.id)
        #expect(choice.group(computer12.id)?.name == "Test Macs")
        #expect(choice.group(mobile12.id)?.name == "Test iPads")
        let reference = GroupReference(computer12)
        #expect(reference.key == computer12.id && reference.group == computer12)
    }

    @Test("A comparison group keeps its kind when saved")
    func storage() throws {
        let defaults = TestFiles.defaults("groups")
        let tracked = TrackedBlueprint(connectionID: UUID(), blueprintID: "b1", blueprintName: "B", compareGroup: GroupReference(computer12))
        TrackedBlueprintList.save([tracked], to: defaults)
        #expect(TrackedBlueprintList.load(from: defaults).first?.compareGroup?.key == computer12.id)
    }

    @Test("The Blueprint’s groups come first; the rest by kind; the search filters every section")
    func sections() {
        var choice = GroupChoice(groups: [mobile12, computer12, computer30], scope: [computer12.id])
        #expect(choice.inScope == [computer12])
        #expect(choice.mobileDeviceGroups == [mobile12])
        #expect(choice.computerGroups == [computer30])
        choice.search = "other"
        #expect(choice.inScope.isEmpty && choice.mobileDeviceGroups.isEmpty && choice.computerGroups == [computer30])
        choice.search = ""
        choice.scope = nil
        #expect(choice.inScope.isEmpty)
        #expect(choice.computerGroups == [computer30, computer12].sorted { $0.name < $1.name })
    }

    @Test("A group outside the Blueprint’s scope gets a warning; none while the scope isn’t known")
    func warning() {
        let choice = GroupChoice(groups: [mobile12, computer12], scope: [computer12.id])
        #expect(choice.scopeWarning(for: computer12.id) == nil)
        #expect(choice.scopeWarning(for: mobile12.id)?.contains("isn’t in the Blueprint’s scope") == true)
        #expect(GroupChoice(groups: [mobile12]).scopeWarning(for: mobile12.id) == nil)
        #expect(GroupChoice(groups: [mobile12], scope: []).scopeWarning(for: mobile12.id)?.contains("isn’t scoped to any group") == true)
        #expect(choice.scopeWarning(for: nil) == nil)
    }

    @Test("The scope’s Platform groups become Jamf Pro groups of the right kind")
    func scopeMapping() {
        let platform = [
            JamfPlatform.PlatformGroup(id: "AAAA-1", name: "x", jamfProID: "12", deviceType: .computer),
            JamfPlatform.PlatformGroup(id: "aaaa-2", name: "y", jamfProID: "12", deviceType: .mobile),
            JamfPlatform.PlatformGroup(id: "aaaa-3", name: "z", jamfProID: "40", deviceType: .mobile),
        ]
        #expect(GroupChoice.scope(platformGroupIDs: ["aaaa-1"], platformGroups: platform) == [computer12.id])
        #expect(GroupChoice.scope(platformGroupIDs: ["AAAA-2", "aaaa-9"], platformGroups: platform) == [mobile12.id])
    }

    @Test("In demo mode a mobile group and a computer group share a number, and each refreshes as its own kind")
    func demoSharedNumber() async throws {
        let connections = ConnectionsModel.preview()
        connections.demo.isOn = true
        let client = try #require(try connections.client())
        let groups = try await client.jamfProGroups()
        let choice = GroupChoice(groups: groups)
        let computer = try #require(choice.group(.init(kind: .computer, groupID: DemoSoftwareUpdate.macGroupID)))
        let mobile = try #require(choice.group(.init(kind: .mobileDevice, groupID: DemoSoftwareUpdate.macGroupID)))
        #expect(computer.name == "Studio Macs" && mobile.name == "Spare iPads")
        let members = try await client.members(of: computer)
        #expect(members.count == 6 && members.allSatisfy { $0.kind == .computer })
        #expect(try await client.members(of: mobile).isEmpty)

        // the Blueprint's scope, mapped through the Platform API's groups
        let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        let scope = GroupChoice.scope(platformGroupIDs: update.blueprint.scopeDeviceGroups, platformGroups: try await client.platformGroups())
        #expect(scope == [computer.id])
    }
}
