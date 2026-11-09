import JTKit
import SwiftUI

/// Track a Blueprint: choose one with a software update; its scope groups
/// are the devices. Only reads.
struct AddBlueprintSheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var blueprints: [JamfPlatform.BlueprintOverview] = []
    @State private var search = ""
    @State private var blueprintID: String?
    @State private var blocks: [JamfPlatform.SoftwareUpdateBlock]?
    @State private var scope: [GroupReference] = []
    @State private var platformGroups: [JamfPlatform.PlatformGroup] = []
    @State private var groups: [JamfPro.DeviceGroup] = []
    @State private var isLoading = true
    @State private var isLoadingBlueprint = false
    @State private var problem: String?

    private var blueprint: JamfPlatform.BlueprintOverview? { blueprints.first { $0.id == blueprintID } }
    private var shown: [JamfPlatform.BlueprintOverview] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? blueprints : blueprints.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        SheetFrame(title: "Track a Blueprint", systemImage: "plus.square.on.square", isBusy: isLoading || isLoadingBlueprint) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search Blueprints", text: $search)
                    .textFieldStyle(.roundedBorder)
                List(shown, selection: $blueprintID) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        if model.isTracked(blueprintID: item.id) { Text("Tracked").foregroundStyle(.secondary) }
                    }
                    .tag(item.id)
                }
                .frame(height: 220)
                if let blocks {
                    if blocks.isEmpty {
                        WarningLabel("This Blueprint has no software update.")
                    } else {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                GridRow {
                                    Text(block.stepName ?? "Step \(block.stepIndex + 1)").foregroundStyle(.secondary)
                                    Text(RefreshWorkflow.rule([block]))
                                }
                            }
                            GridRow {
                                Text("Scope").foregroundStyle(.secondary)
                                Text(scope.isEmpty ? "No Jamf Pro groups" : scope.map(\.name).joined(separator: ", "))
                            }
                        }
                    }
                }
                if let blueprintID, model.isTracked(blueprintID: blueprintID) {
                    WarningLabel("This Blueprint is already tracked.").font(.callout)
                }
                if let problem { WarningLabel(problem).font(.callout) }
            }
            .padding(.horizontal, 20)
        } footer: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Track") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(blueprint == nil || (blocks ?? []).isEmpty || model.isTracked(blueprintID: blueprintID ?? ""))
        }
        .frame(width: 560)
        .task { await load() }
        .task(id: blueprintID) { await loadBlueprint() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            guard let client = try model.connections.client() else { return }
            blueprints = try await JamfPlatform.Blueprints(client: client).list()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            platformGroups = (try? await client.platformGroups()) ?? []
            groups = (try? await client.jamfProGroups()) ?? []
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadBlueprint() async {
        blocks = nil
        scope = []
        guard let blueprintID, let client = try? model.connections.client() else { return }
        isLoadingBlueprint = true
        defer { isLoadingBlueprint = false }
        do {
            let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: blueprintID)
            blocks = update.blocks
            let keys = GroupChoice.scope(platformGroupIDs: update.blueprint.scopeDeviceGroups, platformGroups: platformGroups)
            scope = keys.compactMap { key in groups.first { $0.id == key }.map(GroupReference.init) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func add() {
        guard let blueprint, let connectionID = model.connectionID else { return }
        model.add(TrackedBlueprint(connectionID: connectionID, blueprintID: blueprint.id, blueprintName: blueprint.name))
        dismiss()
    }
}

/// Compare with a group: a coverage check of a group the Blueprint may not
/// reach entirely. The Blueprint’s own groups are listed first.
struct CompareGroupSheet: View {
    let model: DashboardModel
    let trackedID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var choice = GroupChoice(groups: [])
    @State private var groupID: JamfPro.DeviceGroup.ID?
    @State private var isLoading = true
    @State private var problem: String?

    var body: some View {
        SheetFrame(title: "Compare with a Group", systemImage: "square.on.square.dashed", isBusy: isLoading) {
            VStack(alignment: .leading, spacing: 12) {
                Text("See which devices of a group the Blueprint doesn’t reach. They aren’t counted in the categories.")
                    .foregroundStyle(.secondary)
                TextField("Search groups", text: $choice.search)
                    .textFieldStyle(.roundedBorder)
                List(selection: $groupID) {
                    if !choice.inScope.isEmpty { Section("In the Blueprint’s Scope") { rows(choice.inScope) } }
                    Section("Mobile Device Groups") { rows(choice.mobileDeviceGroups) }
                    Section("Computer Groups") { rows(choice.computerGroups) }
                }
                .frame(height: 300)
                if let problem { WarningLabel(problem).font(.callout) }
            }
            .padding(.horizontal, 20)
        } footer: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Compare") {
                if let group = choice.group(groupID) { model.setCompareGroup(GroupReference(group), for: trackedID) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(choice.group(groupID) == nil)
        }
        .frame(width: 520)
        .task { await load() }
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

    private func load() async {
        defer { isLoading = false }
        do {
            guard let client = try model.connections.client() else { return }
            choice.groups = try await client.jamfProGroups()
            if let result = model.results[trackedID] { choice.scope = Set(result.scope.map(\.key)) }
            groupID = model.tracked(trackedID)?.compareGroup?.key
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The “Update started” date: reports and errors before it don’t count. It
/// overrides the start the Blueprint’s rule gives, until it is removed.
struct UpdateStartedSheet: View {
    let model: DashboardModel
    let trackedID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        SheetFrame(title: "Update Started", systemImage: "calendar") {
            Form {
                DatePicker("Update started", selection: $date, in: ...Date())
                Text("Reports and errors from before this date don’t count. It replaces the start the Blueprint’s software update gives until you remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } footer: {
            if model.tracked(trackedID)?.updateStarted != nil {
                Button("Remove Date") {
                    model.setUpdateStarted(nil, for: trackedID)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Set") {
                model.setUpdateStarted(date, for: trackedID)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 440)
        .onAppear {
            date = model.tracked(trackedID)?.updateStarted ?? model.results[trackedID]?.devices.compactMap(\.activityFrom).min() ?? Date()
        }
    }
}
