import JTKit
import SwiftUI

/// Every device of the group with its category and diagnosis, and the
/// selected one’s detail beside it.
struct DeviceListView: View {
    let model: DashboardModel
    let result: RefreshResult
    @State private var selection: Set<DeviceStatus.ID> = []
    @State private var category: StatusCategory?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\DeviceStatus.name)]
    @State private var showsDetail = true

    private var devices: [DeviceStatus] {
        result.devices
            .filter { category == nil || $0.category == category }
            .filter { device in
                search.isEmpty || [device.name, device.serial, device.modelIdentifier, device.diagnosis]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(devices, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("Serial", value: \.serial)
            TableColumn("Model", value: \.modelIdentifier)
            TableColumn("OS", value: \.currentOS)
                .width(min: 60, ideal: 70)
            TableColumn("Target") { device in
                Text(device.targetVersion ?? (device.category == .targetUnknown ? "Unknown" : "–"))
                    .foregroundStyle(device.limitedByHardware == true ? .orange : .primary)
                    .help(device.targetReason ?? "")
            }
            .width(min: 60, ideal: 80)
            TableColumn("Category", value: \.category.title) { device in
                StatusBadge(device.category.title, style: device.category.badgeStyle)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Diagnosis", value: \.diagnosis)
                .width(min: 200, ideal: 320)
        }
        .contextMenu(forSelectionType: DeviceStatus.ID.self) { ids in
            Button("Inspect") { inspect(ids) }
                .disabled(ids.isEmpty)
        }
        .searchable(text: $search, prompt: "Name, serial, model or diagnosis")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Category", selection: $category) {
                    Text("All Categories (\(result.devices.count))").tag(StatusCategory?.none)
                    Divider()
                    ForEach(StatusCategory.allCases) { category in
                        Text("\(category.title) (\(result.counts[category]))").tag(Optional(category))
                    }
                }
                .fixedSize()
                Spacer()
                Button("Inspect Devices Needing Attention") {
                    inspect(Set(InspectWorkflow.select(result.devices).map(\.id)))
                }
                .disabled(InspectWorkflow.select(result.devices).isEmpty || model.isInspecting(in: result.tracked.id))
                .help("Look for the likely cause on every device whose diagnosis needs attention")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .inspector(isPresented: $showsDetail) {
            Group {
                if selection.count == 1, let id = selection.first, let device = result.devices.first(where: { $0.id == id }) {
                    DeviceDetailView(model: model, result: result, device: device)
                        // a fresh form per device, so nothing of the one before stays on screen
                        .id(device.id)
                } else {
                    ContentUnavailableView(selection.isEmpty ? "No Device Selected" : "\(selection.count) Devices Selected",
                                           systemImage: "ipad.and.iphone")
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showsDetail.toggle()
                } label: {
                    Label("Device Detail", systemImage: "sidebar.trailing")
                }
                .help(showsDetail ? "Hide the device detail" : "Show the device detail")
            }
        }
    }

    private func inspect(_ ids: Set<DeviceStatus.ID>) {
        let chosen = result.devices.filter { ids.contains($0.id) }
        Task { await model.inspect(chosen, in: result.tracked.id) }
    }
}

/// One device: what Jamf and the device report, its diagnosis, and Inspect.
struct DeviceDetailView: View {
    let model: DashboardModel
    let result: RefreshResult
    let device: DeviceStatus

    var body: some View {
        Form {
            Section {
                LabeledContent("Category") { StatusBadge(device.category.title, style: device.category.badgeStyle) }
                Text(device.diagnosis)
            }
            Section("Device") {
                LabeledContent("Serial number", value: device.serial)
                LabeledContent("Model", value: device.model.isEmpty ? device.modelIdentifier : "\(device.model) (\(device.modelIdentifier))")
                LabeledContent("\(device.osName) reported", value: device.reportedOS ?? "–")
                LabeledContent("In inventory", value: device.inventoryOS ?? "–")
                LabeledContent("Time zone", value: device.timeZone ?? (device.isComputer ? "Not in Jamf Pro for Macs" : "Not reported"))
                if device.isComputer {
                    LabeledContent("Bootstrap token", value: DeviceDetailText.bootstrap(device.bootstrapToken))
                }
                LabeledContent("Last contact") {
                    if let date = device.lastContact { Text(date, format: .relative(presentation: .named)) } else { Text("Never") }
                }
            }
            Section("Target") {
                LabeledContent("Target", value: device.targetSource ?? device.targetVersion
                               ?? (device.category == .targetUnknown ? "Unknown" : "None"))
                if let reason = device.targetReason { Text(reason).foregroundStyle(.secondary) }
                if device.targetFromDevice == true {
                    LabeledContent("Blueprint’s rule gives", value: device.ruleTarget ?? "No version")
                    if let rule = device.ruleReason { Text(rule).foregroundStyle(.secondary) }
                    if device.targetDiffersFromRule == true {
                        WarningLabel("Another declaration may be enforcing this: the device’s pending version differs from the Blueprint’s rule")
                    }
                }
                if let released = device.targetReleased {
                    LabeledContent("Released by Apple", value: Self.releaseDay(released))
                }
                if let deadline = DeadlineZones.text(local: device.deadlineLocal, reported: device.deadlineDate) {
                    LabeledContent("Deadline", value: deadline)
                    if device.pastDeadline == true { WarningLabel("Past the deadline") }
                }
                if let from = device.activityFrom {
                    // a day: the update start set by hand in this Mac’s time, else a release day (UTC)
                    LabeledContent("Reports count from", value: result.tracked.updateStarted != nil
                                   ? from.formatted(date: .abbreviated, time: .omitted) : Self.releaseDay(from))
                }
            }
            Section("Software Update") {
                LabeledContent("Install state", value: device.installState ?? "–")
                LabeledContent("Pending version", value: device.pendingVersion ?? "–")
                if !device.error.isEmpty {
                    LabeledContent("Last error", value: device.error)
                    LabeledContent("Since the update started", value: device.errorSinceUpdate == true ? "Yes" : "No")
                }
                LabeledContent("Passcode", value: device.passcodePresent.map { $0 ? "Present" : "None" } ?? "–")
                LabeledContent("Status reported") {
                    if let date = device.statusUpdated { Text(date, format: .relative(presentation: .named)) } else { Text("–") }
                }
                if let problem = device.statusProblem { WarningLabel(problem) }
            }
            Section("Inspect") {
                if model.isInspecting(device, in: result.tracked.id) {
                    ProgressView("Inspecting…").controlSize(.small)
                } else if let inspection = model.inspection(of: device, in: result.tracked.id) {
                    LabeledContent("Likely cause", value: inspection.cause)
                    Text(inspection.detail).foregroundStyle(.secondary)
                    ForEach(Array(inspection.findings.dropFirst().enumerated()), id: \.offset) { _, finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.cause)
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.inspectError { WarningLabel(error) }
                Button(model.inspection(of: device, in: result.tracked.id) == nil ? "Inspect" : "Inspect Again") {
                    Task { await model.inspect([device], in: result.tracked.id) }
                }
                .disabled(model.isInspecting(device, in: result.tracked.id))
                .help("Reads the device’s status and declaration reports to find the likely cause")
            }
        }
        .formStyle(.grouped)
    }

    /// Apple dates a release by its day: “26 Oct 2026”, without a time,
    /// read in UTC so it is the same day everywhere.
    static func releaseDay(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
