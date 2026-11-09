import JTKit
import SwiftUI

/// Track a group: first the Blueprint that enforces the software update,
/// then a Jamf Pro group, with the Blueprint’s own groups at the top. Only reads.
struct AddGroupSheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var blueprints: [JamfPlatform.BlueprintOverview] = []
    @State private var platformGroups: [JamfPlatform.PlatformGroup] = []
    @State private var choice = GroupChoice(groups: [])
    @State private var blueprintID: String?
    /// Kind and number together: a mobile device group and a computer group
    /// can share a number.
    @State private var groupID: JamfPro.DeviceGroup.ID?
    @State private var blocks: [JamfPlatform.SoftwareUpdateBlock]?
    @State private var isLoading = true
    @State private var isLoadingBlueprint = false
    @State private var problem: String?

    private var group: JamfPro.DeviceGroup? { choice.group(groupID) }
    private var blueprint: JamfPlatform.BlueprintOverview? { blueprints.first { $0.id == blueprintID } }
    private var alreadyTracked: Bool {
        guard let groupID, let blueprintID else { return false }
        return model.isTracked(groupID, blueprintID: blueprintID)
    }

    var body: some View {
        SheetFrame(title: "Track a Group", systemImage: "plus.square.on.square", isBusy: isLoading || isLoadingBlueprint) {
            VStack(alignment: .leading, spacing: 12) {
                Form {
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
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)

                TextField("Search groups", text: $choice.search)
                    .textFieldStyle(.roundedBorder)
                    .disabled(blueprintID == nil)
                List(selection: $groupID) {
                    if !choice.inScope.isEmpty {
                        Section("In the Blueprint’s Scope") { rows(choice.inScope) }
                    }
                    Section("Mobile Device Groups") { rows(choice.mobileDeviceGroups) }
                    Section("Computer Groups") { rows(choice.computerGroups) }
                }
                .frame(height: 300)
                .disabled(blueprintID == nil)
                .overlay {
                    if blueprintID == nil {
                        Text("Choose a Blueprint first.").foregroundStyle(.secondary)
                    }
                }

                if let warning = choice.scopeWarning(for: groupID) { WarningLabel(warning).font(.callout) }
                if alreadyTracked { WarningLabel("This group is already tracked with this Blueprint.").font(.callout) }
                if let problem { WarningLabel(problem).font(.callout) }
            }
            .padding(.horizontal, 20)
        } footer: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Track") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(group == nil || blueprint == nil || (blocks ?? []).isEmpty || alreadyTracked)
        }
        .frame(width: 560)
        .task { await load() }
        .task(id: blueprintID) { await loadBlueprint() }
    }

    private func rows(_ groups: [JamfPro.DeviceGroup]) -> some View {
        ForEach(groups) { group in
            HStack {
                Label(group.name, systemImage: group.kind == .computer ? "laptopcomputer" : "ipad")
                Spacer()
                Text(group.isSmart ? "Smart" : "Static").foregroundStyle(.secondary)
            }
            .tag(group.id)
            .accessibilityElement(children: .combine)
        }
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
            let (loadedGroups, loadedBlueprints) = try await (groups, blueprints)
            choice.groups = loadedGroups
            self.blueprints = loadedBlueprints.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // which Jamf Pro group each Platform group is; without it, no scope section
            platformGroups = (try? await client.platformGroups()) ?? []
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadBlueprint() async {
        blocks = nil
        choice.scope = nil
        guard let blueprintID, let client = try? model.connections.client() else { return }
        isLoadingBlueprint = true
        defer { isLoadingBlueprint = false }
        do {
            let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: blueprintID)
            blocks = update.blocks
            if !platformGroups.isEmpty {
                choice.scope = GroupChoice.scope(platformGroupIDs: update.blueprint.scopeDeviceGroups, platformGroups: platformGroups)
            }
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
