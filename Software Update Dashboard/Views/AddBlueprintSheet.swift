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
    /// The selected Blueprint’s scope as Platform group IDs; worked out as
    /// Jamf Pro groups (`scope`) whenever the groups arrive.
    @State private var scopeIDs: [String] = []
    @State private var platformGroups: [JamfPlatform.PlatformGroup] = []
    @State private var groups: [JamfPro.DeviceGroup] = []
    @State private var isLoading = true
    /// The groups have been read (or couldn’t be: `groupProblem`).
    @State private var groupsRead = false
    @State private var isLoadingBlueprint = false
    /// The Blueprint list couldn’t be read.
    @State private var problem: String?
    /// The groups couldn’t be read, so no scope can be shown.
    @State private var groupProblem: String?
    /// The selected Blueprint couldn’t be read.
    @State private var blueprintProblem: String?

    private var blueprint: JamfPlatform.BlueprintOverview? { blueprints.first { $0.id == blueprintID } }

    private var scope: [GroupReference] {
        let keys = GroupChoice.scope(platformGroupIDs: scopeIDs, platformGroups: platformGroups)
        return keys.compactMap { key in groups.first { $0.id == key }.map(GroupReference.init) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var scopeText: String {
        if !groupsRead { return "Reading the groups…" }
        if groupProblem != nil { return "Unknown: the groups couldn’t be read" }
        return scope.isEmpty ? "No Jamf Pro groups" : scope.map(\.name).joined(separator: ", ")
    }
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
                                Text(scopeText)
                            }
                        }
                    }
                }
                if let blueprintID, model.isTracked(blueprintID: blueprintID) {
                    WarningLabel("This Blueprint is already tracked.").font(.callout)
                }
                ForEach([problem, groupProblem, blueprintProblem].compactMap { $0 }, id: \.self) { line in
                    WarningLabel(line).font(.callout)
                }
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

    /// The Blueprint list first, then the groups; a Blueprint picked before
    /// the groups are in gets its scope when they arrive.
    private func load() async {
        defer { isLoading = false }
        let client: JamfPlatform.Client
        do {
            guard let made = try model.connections.client() else { return }
            client = made
            blueprints = try await JamfPlatform.Blueprints(client: client).list()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
            return
        }
        do {
            platformGroups = try await client.platformGroups()
            groups = try await client.jamfProGroups()
        } catch {
            if !Task.isCancelled { groupProblem = "The groups couldn’t be read, so the scope can’t be shown: \(error.localizedDescription)" }
        }
        groupsRead = true
    }

    /// The selected Blueprint’s software update and scope. Picking another
    /// one stops this read: that is no problem, and it says nothing.
    private func loadBlueprint() async {
        blocks = nil
        scopeIDs = []
        blueprintProblem = nil
        guard let blueprintID, let client = try? model.connections.client() else {
            isLoadingBlueprint = false
            return
        }
        isLoadingBlueprint = true
        do {
            let update = try await JamfPlatform.Blueprints(client: client).softwareUpdate(blueprintID: blueprintID)
            guard !Task.isCancelled else { return }
            blocks = update.blocks
            scopeIDs = update.blueprint.scopeDeviceGroups
        } catch {
            // stopped by the next selection, which shows its own busy state
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            blueprintProblem = error.localizedDescription
        }
        isLoadingBlueprint = false
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
