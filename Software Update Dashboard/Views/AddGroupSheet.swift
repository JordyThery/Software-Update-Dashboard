import JTKit
import SwiftUI

/// Track a group: a Jamf Pro group and the Blueprint that enforces its
/// software update. Only reads.
struct AddGroupSheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [JamfPro.DeviceGroup] = []
    @State private var blueprints: [JamfPlatform.BlueprintOverview] = []
    @State private var groupID: String?
    @State private var blueprintID: String?
    @State private var blocks: [JamfPlatform.SoftwareUpdateBlock]?
    @State private var isLoading = true
    @State private var problem: String?

    private var group: JamfPro.DeviceGroup? { groups.first { $0.id == groupID } }
    private var blueprint: JamfPlatform.BlueprintOverview? { blueprints.first { $0.id == blueprintID } }

    var body: some View {
        SheetFrame(title: "Track a Group", systemImage: "plus.square.on.square", isBusy: isLoading) {
            Form {
                Picker("Jamf Pro group", selection: $groupID) {
                    Text("Choose a Group").tag(String?.none)
                    Section("Mobile Device Groups") {
                        ForEach(groups.filter { $0.kind == .mobileDevice }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Section("Computer Groups") {
                        ForEach(groups.filter { $0.kind == .computer }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Picker("Blueprint", selection: $blueprintID) {
                    Text("Choose a Blueprint").tag(String?.none)
                    ForEach(blueprints) { Text($0.name).tag(Optional($0.id)) }
                }
                if let blocks {
                    if blocks.isEmpty {
                        WarningLabel("This Blueprint has no software update.")
                    } else {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            LabeledContent(block.stepName ?? "Step \(block.stepIndex + 1)", value: Self.describe(block))
                        }
                    }
                }
                if let problem { WarningLabel(problem) }
            }
            .formStyle(.grouped)
        } footer: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Track") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(group == nil || blueprint == nil || (blocks ?? []).isEmpty)
        }
        .frame(width: 520)
        .task { await load() }
        .task(id: blueprintID) { await loadBlocks() }
    }

    static func describe(_ block: JamfPlatform.SoftwareUpdateBlock) -> String {
        switch block.enforcement {
        case .specific(let version, let deadline, _):
            "\(version)" + (deadline.map { " by \(TargetSection.localText($0))" } ?? "")
        case .latest(let days, _): "The newest version, \(days ?? 0) days after its release"
        case .semantic(let days, _): "Minor updates, \(days ?? 0) days after their release"
        case .unknown: "An enforcement this version doesn’t read"
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            guard let client = try model.connections.client() else { return }
            async let groups = client.jamfProGroups()
            async let blueprints = JamfPlatform.Blueprints(client: client).list()
            (self.groups, self.blueprints) = try await (groups, blueprints)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadBlocks() async {
        blocks = nil
        guard let blueprintID, let client = try? model.connections.client() else { return }
        do {
            blocks = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: blueprintID).blocks
        } catch {
            problem = error.localizedDescription
        }
    }

    private func add() {
        guard let group, let blueprint, let connectionID = model.connectionID else { return }
        model.add(TrackedGroup(connectionID: connectionID, group: group, blueprintID: blueprint.id, blueprintName: blueprint.name))
        dismiss()
    }
}
