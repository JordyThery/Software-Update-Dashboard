import JTKit
import SwiftUI

/// Every device of the group with its category and diagnosis, and the
/// selected one’s detail beside it.
struct DeviceListView: View {
    let model: DashboardModel
    let result: RefreshResult
    /// Set from a readiness count on the dashboard: only those devices.
    @Binding var readiness: ReadinessCheck?
    @State private var selection: Set<DeviceStatus.ID> = []
    @State private var category: StatusCategory?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\DeviceStatus.name)]
    @State private var showsDetail = true

    private var devices: [DeviceStatus] {
        result.devices
            .filter { category == nil || $0.category == category }
            .filter { readiness?.applies(to: $0) ?? true }
            .filter { device in
                search.isEmpty || [device.name, device.serial, device.modelIdentifier, device.diagnosis]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(devices, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 120, ideal: 150)
            TableColumn("Serial", value: \.serial)
                // serial numbers are 10 to 12 characters: never cut off
                .width(min: 110, ideal: 120)
            TableColumn("Model", value: \.modelIdentifier)
                .width(min: 80, ideal: 110)
            TableColumn("OS", value: \.currentOS)
                .width(min: 60, ideal: 70)
            TableColumn("Target") { device in
                let limited = device.limitedByHardware == true
                HStack(spacing: 3) {
                    Text(device.targetVersion ?? (device.category == .targetUnknown ? "Unknown" : "–"))
                    // not by color alone: a symbol, a help tag and the spoken label say it too
                    if limited {
                        Image(systemName: "exclamationmark.triangle").imageScale(.small).accessibilityHidden(true)
                    }
                }
                .foregroundStyle(limited ? .orange : .primary)
                .help([limited ? DeviceDetailText.hardwareLimit(device) : nil, device.targetReason].compactMap { $0 }.joined(separator: "\n"))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(device.targetVersion ?? (device.category == .targetUnknown ? "Unknown" : "None"))
                .accessibilityValue(limited ? DeviceDetailText.hardwareLimit(device) : "")
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
            Button("Open in Jamf Pro") { model.open(pages(ids)) }
                .disabled(pages(ids).isEmpty)
            Button("Inspect") { inspect(ids) }
                .disabled(ids.isEmpty)
        }
        .focusedSceneValue(\.deviceSelection, DeviceSelection(model: model, trackedID: result.tracked.id,
                                                              devices: result.devices.filter { selected.contains($0.id) }))
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
                if let readiness {
                    Button {
                        self.readiness = nil
                    } label: {
                        Label("\(readiness.title) (\(ReadinessCheck.count(readiness, in: result.devices)))", systemImage: "xmark.circle.fill")
                    }
                    .help("Show every device again")
                    .accessibilityLabel("Remove filter: \(readiness.title)")
                }
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
                if selected.count == 1, let id = selected.first, let device = result.devices.first(where: { $0.id == id }) {
                    DeviceDetailView(model: model, result: result, device: device)
                        // a fresh form per device, so nothing of the one before stays on screen
                        .id(device.id)
                } else {
                    ContentUnavailableView(selected.isEmpty ? "No Device Selected"
                                           : "\(Plural.count(selected.count, "Device")) Selected",
                                           systemImage: "ipad.and.iphone")
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340)
        }
        .onChange(of: result.tracked.id) {
            // another Blueprint’s devices: nothing of the one before stays selected
            selection = []
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

    /// The selection, without devices that aren’t in this refresh.
    private var selected: Set<DeviceStatus.ID> {
        selection.intersection(result.devices.map(\.id))
    }

    private func pages(_ ids: Set<DeviceStatus.ID>) -> [URL] {
        model.pages(of: result.devices.filter { ids.contains($0.id) })
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
    @State private var showsStatusItems = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Category") { StatusBadge(device.category.title, style: device.category.badgeStyle) }
                Text(device.diagnosis)
                if let ranges = device.notCoveredBy {
                    Text("The Blueprint’s update declarations for this hardware cover \(ranges), not \(device.currentOS). "
                         + "Jamf sets these ranges; until it widens them, the device gets no update from this Blueprint.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Device") {
                LabeledContent("Serial number", value: device.serial)
                if let page = model.pages(of: [device]).first {
                    Button("Open in Jamf Pro") { model.open([page]) }
                        .help("Opens the device’s page in Jamf Pro in your browser, read-only")
                } else {
                    LabeledContent("Jamf Pro") { Text("No web address").foregroundStyle(.secondary) }
                        .help(JamfProPages.noAddress)
                }
                LabeledContent("Model", value: device.model.isEmpty ? device.modelIdentifier : "\(device.model) (\(device.modelIdentifier))")
                LabeledContent("\(device.osName) reported", value: device.reportedOS ?? "–")
                LabeledContent("In inventory", value: device.inventoryOS ?? "–")
                if let response = device.rapidSecurityResponse {
                    LabeledContent("Rapid Security Response",
                                   value: response + (device.supplementalBuild.map { ", build \($0)" } ?? ""))
                }
                LabeledContent("Time zone", value: device.timeZone ?? (device.isComputer ? "Not in Jamf Pro for Macs" : "Not reported"))
                if device.isComputer {
                    LabeledContent("FileVault", value: DeviceDetailText.fileVault(device.fileVault))
                    LabeledContent("Bootstrap token", value: DeviceDetailText.bootstrap(device.bootstrapToken))
                    // only a Mac with Apple silicon needs the token to install an enforced update
                    if device.bootstrapToken?.uppercased() == "NOT_ESCROWED",
                       let why = DeviceDetailText.notEscrowedWarning(
                           appleSilicon: DeviceDetailText.isAppleSilicon(model: device.modelIdentifier, boardID: device.boardID)) {
                        WarningLabel(why)
                    }
                }
                LabeledContent("Battery health", value: DeviceDetailText.batteryHealth(device.batteryHealth))
                if DeviceDetailText.batteryNeedsService(device.batteryHealth) {
                    WarningLabel("The battery needs service")
                }
                LabeledContent("Last contact") {
                    if let date = device.lastContact { Text(date, format: .relative(presentation: .named)) } else { Text("Never") }
                }
            }
            Section("Target") {
                LabeledContent("Target", value: device.targetVersion
                               ?? (device.category == .targetUnknown ? "Unknown" : "None"))
                // one line: where the target comes from, or why there is none
                if let line = device.targetSource ?? device.targetReason { Text(line).foregroundStyle(.secondary) }
                if device.limitedByHardware == true { WarningLabel(DeviceDetailText.hardwareLimit(device)) }
                // this Blueprint's earlier step, still pending: shown, not counted
                if let step = device.earlierStepVersion {
                    let late = device.earlierStepLapsed == true
                    LabeledContent("Installs first", value: step)
                    Text("An earlier step of this Blueprint, sent before Apple posted \(device.targetVersion ?? "the target")")
                        .foregroundStyle(.secondary)
                    if let text = DeadlineZones.text(local: device.earlierStepLocal, reported: device.earlierStepDeadline) {
                        LabeledContent("Its deadline", value: text)
                        if late {
                            WarningLabel("Not installed by its deadline: the device counts as past its deadline")
                        } else {
                            Text("Not counted: the Blueprint’s current deadline counts").foregroundStyle(.secondary)
                        }
                    }
                }
                // the target pending with this Blueprint's earlier step's deadline: shown, not counted
                if let step = device.carriedStepVersion,
                   let text = DeadlineZones.text(local: device.carriedDeadlineLocal, reported: device.carriedDeadline) {
                    LabeledContent("Device reports", value: text)
                    Text("The deadline of \(step), an earlier step of this Blueprint, kept when Jamf moved it to \(device.targetVersion ?? "the target"). "
                         + "Not counted: the Blueprint’s current deadline counts")
                        .foregroundStyle(.secondary)
                }
                if device.targetFromDevice == true, device.targetDiffersFromRule == true {
                    LabeledContent("Blueprint’s rule gives", value: device.ruleTarget ?? "No version")
                    if let rule = device.ruleReason { Text(rule).foregroundStyle(.secondary) }
                    WarningLabel("Another declaration may be enforcing this: the device’s pending version differs from the Blueprint’s rule")
                }
                if let released = device.targetReleased {
                    LabeledContent("Released by Apple", value: Self.releaseDay(released))
                }
                if let deadline = DeadlineZones.text(local: device.deadlineLocal, reported: device.deadlineDate) {
                    LabeledContent("Deadline", value: deadline)
                    if let source = device.deadlineSource { Text(source).foregroundStyle(.secondary) }
                    if device.pastDeadline == true { WarningLabel("Past the deadline") }
                }
                // a deadline the device reported earlier, not used: shown also when the rule has none
                if let reason = device.staleReason,
                   let text = DeadlineZones.text(local: device.staleReportedLocal, reported: device.staleReportedDeadline) {
                    LabeledContent("Device reports", value: text)
                    Text(reason.text.prefix(1).uppercased() + reason.text.dropFirst() + ", so it isn’t used").foregroundStyle(.secondary)
                }
                if let from = device.activityFrom {
                    // a day: the update start set by hand in this Mac’s time, else a release day (UTC)
                    LabeledContent("Reports count from", value: result.tracked.updateStarted != nil
                                   ? from.formatted(date: .abbreviated, time: .omitted) : Self.releaseDay(from))
                }
            }
            Section("Software Update") {
                LabeledContent("Install state", value: DeviceDetailText.installState(device.installState))
                LabeledContent("Pending version", value: device.pendingVersion ?? "–")
                if device.installReason != nil {
                    LabeledContent("Started by", value: DeviceDetailText.installReason(device.installReason))
                }
                if let beta = device.betaEnrollment {
                    LabeledContent("Beta program", value: beta)
                }
                if !device.error.isEmpty {
                    LabeledContent("Last error", value: device.error)
                    if let failures = failureText { LabeledContent("Failures", value: failures) }
                    LabeledContent("Since the update started", value: device.errorSinceUpdate == true ? "Yes" : "No")
                }
                LabeledContent("Passcode", value: device.passcodePresent.map { $0 ? "Present" : "None" } ?? "–")
                LabeledContent("Status reported") {
                    if let date = device.statusUpdated { Text(date, format: .relative(presentation: .named)) } else { Text("–") }
                }
                if let problem = device.statusProblem { WarningLabel(problem) }
                Button("Show All Status Items…") { showsStatusItems = true }
                    .help("Reads every item of the device’s status report from Jamf Pro now; the items aren’t saved")
            }
            Section("Inspect") {
                if model.isInspecting(device, in: result.tracked.id) {
                    ProgressView("Inspecting…").controlSize(.small)
                } else if let inspection = model.inspection(of: device, in: result.tracked.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Likely cause").font(.subheadline).foregroundStyle(.secondary)
                        Text(inspection.cause).font(.headline)
                        Text(inspection.detail).foregroundStyle(.secondary)
                    }
                    let others = inspection.alsoFound
                    if !others.isEmpty {
                        Text(others.count == 1 ? "Also Found" : "Also Found (\(others.count))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(Array(others.enumerated()), id: \.offset) { _, finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.cause)
                                Text(finding.detail).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !inspection.declarations.isEmpty || inspection.otherDeclarations > 0 {
                        Text("The Blueprint’s Declarations for \(device.osName)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        // names are unique (BlueprintHealth.uniqueNames): never the row numbers the list above uses
                        ForEach(inspection.declarations, id: \.name) { line in
                            LabeledContent(line.name) { Text(line.state).multilineTextAlignment(.trailing) }
                        }
                        if let others = BlueprintHealth.othersLine(inspection.otherDeclarations, inScope: false) {
                            Text(others).foregroundStyle(.secondary)
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
        .sheet(isPresented: $showsStatusItems) {
            StatusItemsView(model: model, trackedID: result.tracked.id, device: device)
        }
    }

    private var failureText: String? {
        DeviceDetailText.failures(count: device.failureCount, time: device.errorTime, serverTimeZone: model.connections.serverTimeZone)
    }

    /// Apple dates a release by its day: “26 Oct 2026”, without a time,
    /// read in UTC so it is the same day everywhere.
    static func releaseDay(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
