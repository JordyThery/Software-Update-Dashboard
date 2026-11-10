import Charts
import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// One tracked Blueprint: its dashboard or its devices, with Refresh and the exports.
struct BlueprintView: View {
    enum Page: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case devices = "Devices"
        var id: String { rawValue }
    }

    let model: DashboardModel
    let tracked: TrackedBlueprint
    @Binding var page: Page
    @Binding var exportRequest: Bool?
    @Binding var sheet: BlueprintSheet?
    @State private var export: TextExportDocument?
    @State private var exportName = ""
    @State private var exportType: UTType = .plainText
    /// A readiness count opened on the dashboard: the device list shows those devices.
    @State private var readiness: ReadinessCheck?

    var body: some View {
        Group {
            if let result = model.results[tracked.id] {
                switch page {
                case .dashboard: DashboardView(model: model, result: result, sheet: $sheet) { check in
                    readiness = check
                    page = .devices
                }
                case .devices: DeviceListView(model: model, result: result, readiness: $readiness)
                }
            } else if model.refreshing.contains(tracked.id) {
                ReadingProgress(model: model, id: tracked.id)
            } else if let error = model.errors[tracked.id] {
                ContentUnavailableView {
                    Label(error == AppleDataUnavailable().localizedDescription ? "Couldn’t Read Apple’s Release Data" : "Couldn’t Read the Blueprint",
                          systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh(tracked.id) } }
                }
            } else {
                ContentUnavailableView {
                    Label(tracked.blueprintName, systemImage: "square.stack.3d.up")
                } description: {
                    Text("Read the Blueprint’s software update and the devices in its scope from Jamf.")
                } actions: {
                    Button("Refresh") { Task { await model.refresh(tracked.id) } }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            // a refresh that stopped keeps the previous one on screen: say so
            if let result = model.results[tracked.id], !model.refreshing.contains(tracked.id) {
                if let error = model.errors[tracked.id] {
                    RefreshStoppedBanner(error: error, shown: result.date) { Task { await model.refresh(tracked.id) } }
                } else if !result.counts.isWorthSaving && page == .dashboard {
                    NoTargetBanner { page = .devices }
                }
            }
        }
        .navigationTitle(tracked.blueprintName)
        .navigationSubtitle(model.results[tracked.id]?.rule ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.results[tracked.id] == nil)
            }
            ToolbarItem {
                Menu {
                    Button("Device List as CSV…") { prepareExport(csv: true) }
                    Button("Summary…") { prepareExport(csv: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.results[tracked.id] == nil)
                .help("Save the device list or the summary")
            }
            ToolbarItem {
                if model.refreshing.contains(tracked.id) {
                    ProgressView().controlSize(.small).help("Reading from Jamf")
                } else {
                    Button {
                        Task { await model.refresh(tracked.id) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the Blueprint and its devices from Jamf again")
                }
            }
        }
        .onChange(of: tracked.id) { readiness = nil }
        .task(id: tracked.id) {
            if model.results[tracked.id] == nil && model.errors[tracked.id] == nil { await model.refresh(tracked.id) }
        }
        .onChange(of: exportRequest) {
            if let csv = exportRequest { prepareExport(csv: csv) }
            exportRequest = nil
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export, contentType: exportType, defaultFilename: exportName) { _ in
            export = nil
        }
    }

    private func prepareExport(csv: Bool) {
        let text = csv ? model.csv(tracked.id) : model.summary(tracked.id)
        guard let text else { return }
        let day = Date().formatted(.iso8601.year().month().day())
        exportName = "\(tracked.blueprintName) \(day)\(csv ? ".csv" : ".txt")"
        exportType = csv ? .commaSeparatedText : .plainText
        export = TextExportDocument(text: text)
    }
}

/// A warning across the top of the content: what happened, and what to do
/// about it. The same sign and color as every other warning in the app.
struct WarningBanner<Actions: View>: View {
    let text: String
    /// A second line, e.g. why the action didn’t work.
    var detail: String?
    /// A tooltip on the text, for details only support needs.
    var help: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    // no fixedSize here: in a top inset it pushes the whole window’s content out of view
                    Text(text)
                        .help(help ?? "")
                    if let detail { Text(detail).foregroundStyle(.secondary) }
                }
            } icon: {
                // the sign every warning in the app uses (JTKit’s WarningLabel)
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
            Spacer()
            actions
        }
        .padding(10)
        .background(.bar)
    }
}

/// The last refresh stopped: why, and which refresh is shown instead.
struct RefreshStoppedBanner: View {
    let error: String
    let shown: Date
    let tryAgain: () -> Void

    var body: some View {
        WarningBanner(text: "The refresh stopped: \(error) Showing the refresh of \(shown.formatted(date: .abbreviated, time: .shortened)).") {
            Button("Try Again", action: tryAgain)
        }
    }
}

/// No device got a target: nothing was measured or saved. The devices
/// say why, each in its own row.
struct NoTargetBanner: View {
    let showDevices: () -> Void

    var body: some View {
        WarningBanner(text: "No device has a target, so nothing is measured and this refresh isn’t saved in the history. "
                      + "Each device in Devices says why its target is unknown.") {
            Button("Show Devices", action: showDevices)
        }
    }
}

/// While a Blueprint is read: how many status reports are in.
struct ReadingProgress: View {
    let model: DashboardModel
    let id: UUID

    var body: some View {
        VStack(spacing: 8) {
            if let progress = model.progress[id], progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("Reading status reports")
                } currentValueLabel: {
                    Text("\(progress.done) of \(Plural.count(progress.total, "device"))")
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView("Reading from Jamf…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The progress bar’s groups by name and count, so the bar never relies on color alone.
struct ProgressLegend: View {
    let counts: CategoryCounts

    var body: some View {
        HStack(spacing: 16) {
            ForEach(ProgressGroup.allCases) { group in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text("\(group.rawValue) \(group.count(in: counts))")
                }
                .help(group.explanation)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The Blueprint’s dashboard: its rule and scope, the progress, the nine
/// categories, each platform and major, the history, the deadlines per time
/// zone, the hardware to replace and the coverage check.
struct DashboardView: View {
    let model: DashboardModel
    let result: RefreshResult
    @Binding var sheet: BlueprintSheet?
    /// Opens the devices of a readiness count in the list.
    var showDevices: (ReadinessCheck) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RuleSection(model: model, result: result, sheet: $sheet)
                ForEach(result.problems, id: \.self) { WarningLabel($0).font(.callout) }
                ProgressSection(counts: result.counts, pastDeadline: result.pastDeadline)
                if let line = BlueprintHealth.dashboardLine(result.notCoveredCount) {
                    WarningLabel(line + ".").font(.callout)
                }
                CategoryGrid(counts: result.counts)
                ReadinessSection(devices: result.devices, showDevices: showDevices)
                MajorsSection(result: result)
                BlueprintHealthSection(result: result)
                HistoryChart(snapshots: model.snapshots(result.tracked.id))
                DeadlineZonesSection(result: result)
                if !result.replacements.isEmpty { ReplacementSection(result: result) }
                CoverageSection(model: model, result: result, sheet: $sheet)
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }
}

struct RuleSection: View {
    let model: DashboardModel
    let result: RefreshResult
    @Binding var sheet: BlueprintSheet?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Software update").foregroundStyle(.secondary)
                Text(result.rule).font(.title3.weight(.semibold))
            }
            GridRow {
                Text("Update started").foregroundStyle(.secondary)
                if let started = result.tracked.updateStarted {
                    HStack {
                        Text("\(started.formatted(date: .abbreviated, time: .shortened)), set by you")
                        Button("Change…") { sheet = .updateStarted(result.tracked.id) }
                        Button("Remove") { model.setUpdateStarted(nil, for: result.tracked.id) }
                    }
                } else {
                    HStack {
                        Text(Self.computedStart(result))
                        Button("Set…") { sheet = .updateStarted(result.tracked.id) }
                            .help("Count reports and errors from a date of your choice instead")
                    }
                }
            }
            GridRow {
                Text("Scope").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.scope.isEmpty ? "No Jamf Pro groups" : result.scope.map(\.name).joined(separator: ", "))
                    Text("\(Plural.count(result.devices.count, "device")), each counted once").font(.caption).foregroundStyle(.secondary)
                    if let change = result.scopeChange { WarningLabel(change.text).font(.caption) }
                }
            }
            if let settings = result.settings.first, let text = Self.settingsText(settings) {
                GridRow {
                    Text("Update settings").foregroundStyle(.secondary)
                    Text(text).font(.callout)
                }
            }
            GridRow {
                Text("Read").foregroundStyle(.secondary)
                Text(result.date, format: .dateTime.day().month().hour().minute())
            }
        }
    }

    /// Where activity is counted from when no date is set by hand.
    static func computedStart(_ result: RefreshResult) -> String {
        let automatic = result.blocks.contains { if case .specific = $0.enforcement { return false }; return true }
        if automatic { return "From Apple’s release date of each device’s target" }
        return result.blueprintChanged.map { "From the Blueprint’s last change, \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Not known"
    }

    static func settingsText(_ settings: JamfPlatform.SoftwareUpdateSettings) -> String? {
        var parts: [String] = []
        let deferrals = [("all updates", settings.combinedDeferralDays), ("majors", settings.majorDeferralDays),
                         ("minors", settings.minorDeferralDays), ("system", settings.systemDeferralDays)]
            .compactMap { name, days in days.map { "\(name) \(Plural.count($0, "day"))" } }
        if !deferrals.isEmpty { parts.append("Deferred: " + deferrals.joined(separator: ", ")) }
        if let cadence = settings.recommendedCadence { parts.append("Cadence: \(cadence)") }
        if let beta = settings.betaProgramEnrollment { parts.append("Beta: \(String(describing: beta))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ProgressSection: View {
    let counts: CategoryCounts
    let pastDeadline: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(counts.percentText).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text("\(counts[.onTarget]) of \(Plural.count(counts.updatable, "updatable device")) on \(counts.updatable == 1 ? "its" : "their") target")
                    .foregroundStyle(.secondary)
            }
            ProgressBar(counts: counts)
            ProgressLegend(counts: counts)
            Text("Updatable leaves out unsupported hardware, offline devices and devices without a report. \(Plural.count(counts.total, "device")) in all"
                 + (pastDeadline > 0 ? "; \(pastDeadline) past their deadline." : "."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CategoryGrid: View {
    let counts: CategoryCounts

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(StatusCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(counts[category])")
                        .font(.title2.monospacedDigit().weight(.semibold))
                    // what the count means, only when there is something to count
                    if counts[category] > 0, let note = category.note(staleDays: 30) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                // every card in a row as tall as the tallest, all aligned to the top
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Devices the update can’t reach as they are; each count opens them in the list.
struct ReadinessSection: View {
    let devices: [DeviceStatus]
    let showDevices: (ReadinessCheck) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness").font(.headline)
            if ReadinessCheck.allCases.allSatisfy({ ReadinessCheck.count($0, in: devices) == 0 }) {
                Text("No device is enrolled with User Enrollment, every Mac is supervised, and every device uses declarative device management and has reported.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(ReadinessCheck.allCases) { check in
                        let count = ReadinessCheck.count(check, in: devices)
                        GridRow {
                            Label(check.title, systemImage: check.systemImage)
                            Button("\(count)") { showDevices(check) }
                                .buttonStyle(.link)
                                .monospacedDigit()
                                .disabled(count == 0)
                                .help(count == 0 ? "" : "Show \(count == 1 ? "this device" : "these \(count) devices") in the device list")
                                .accessibilityLabel("\(check.title): \(Plural.count(count, "device"))")
                                .accessibilityHint(count == 0 ? "" : "Shows them in the device list")
                            Text(check.note).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Each platform and major release: its target, how many are on it, its deadline.
struct MajorsSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Major Release").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Release"); Text("Devices"); Text("Target"); Text("On target"); Text("Deadline")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(result.majors) { row in
                    GridRow {
                        Text("\(row.osName) \(row.major.map(String.init) ?? "unknown")")
                        Text("\(row.devices)").monospacedDigit()
                        Text(row.targets.isEmpty ? "–" : row.targets.joined(separator: ", "))
                        Text("\(row.onTarget) of \(row.updatable)").monospacedDigit()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.deadlines.isEmpty ? "–" : row.deadlines.joined(separator: "; "))
                            if row.otherDeadlineDevices > 0 {
                                Text("\(Plural.count(row.otherDeadlineDevices, "device")) \(row.otherDeadlineDevices == 1 ? "reports" : "report") another deadline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(row.otherDeadlines.joined(separator: "\n"))
                                    .accessibilityHint(row.otherDeadlines.joined(separator: "; "))
                            }
                            // for the whole row, whichever deadline each device has
                            if row.pastDeadline > 0 {
                                Text("\(Plural.count(row.pastDeadline, "device")) past \(row.pastDeadline == 1 ? "its" : "their") deadline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !result.majors.isEmpty {
                Text("Deadlines are each device’s local time.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The five progress groups per refresh, with the refreshes where the
/// counts stop comparing marked by number and listed under the chart.
struct HistoryChart: View {
    let snapshots: [HistorySnapshot]

    private var marks: [HistoryMark] { HistoryMark.marks(snapshots) }

    /// The chart’s labels: one per mark, except marks too close to tell
    /// apart on the axis share one (“2, 3”), so labels never overlap.
    private var labels: [(date: Date, text: String)] {
        guard let first = snapshots.first?.date, let last = snapshots.last?.date else { return [] }
        let closeTogether = max(1, last.timeIntervalSince(first)) * 0.05
        var labels: [(date: Date, numbers: [Int])] = []
        for (index, mark) in marks.enumerated() {
            if let previous = labels.last, mark.date.timeIntervalSince(previous.date) < closeTogether {
                labels[labels.count - 1].numbers.append(index + 1)
            } else {
                labels.append((mark.date, [index + 1]))
            }
        }
        return labels.map { ($0.date, $0.numbers.map(String.init).joined(separator: ", ")) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            if snapshots.count < 2 {
                Text("The chart fills in as the Blueprint is refreshed over time.")
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(snapshots) { snapshot in
                        ForEach(ProgressGroup.allCases) { group in
                            let count = group.count(in: snapshot.counts)
                            AreaMark(x: .value("Refresh", snapshot.date), y: .value("Devices", count))
                                .foregroundStyle(by: .value("Group", group.rawValue))
                                // counts hold until the next refresh: steps, not slopes between refreshes
                                .interpolationMethod(.stepEnd)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                                .accessibilityLabel("\(group.rawValue), \(snapshot.date.formatted(date: .abbreviated, time: .shortened))")
                                .accessibilityValue(Plural.count(count, "device"))
                        }
                    }
                    ForEach(marks) { mark in
                        RuleMark(x: .value("Change", mark.date))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .accessibilityLabel(mark.text)
                    }
                    ForEach(labels, id: \.date) { label in
                        RuleMark(x: .value("Change", label.date))
                            .foregroundStyle(.clear)
                            .annotation(position: .top, alignment: .center, spacing: 2) {
                                Text(label.text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .accessibilityHidden(true)
                    }
                }
                .chartForegroundStyleScale(domain: ProgressGroup.allCases.map(\.rawValue),
                                           range: ProgressGroup.allCases.map(\.color))
                .chartYAxisLabel("Devices")
                .frame(height: 180)
                if !marks.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            GridRow {
                                Text("\(index + 1)").font(.subheadline.weight(.semibold)).monospacedDigit()
                                Text(mark.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                                Text(mark.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Each of the Blueprint’s declarations by name, with how many devices
/// report it applied, pending, awaiting sync, failed or invalid, and the
/// most common reason.
struct BlueprintHealthSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blueprint Health").font(.headline)
            if let health = result.health {
                if health.declarations.isEmpty && health.inapplicable == 0 {
                    Text("No device reports one of the Blueprint’s declarations yet.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Declaration"); Text("Applied"); Text("Pending"); Text("Awaiting sync"); Text("Failed"); Text("Invalid")
                            Text("Most common reason")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(health.declarations) { declaration in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(declaration.name)
                                    if declaration.notForDevice > 0 {
                                        Text("Not for \(Plural.count(declaration.notForDevice, "device")), by its condition")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                count(declaration.applied)
                                count(declaration.pending)
                                count(declaration.awaitingSync)
                                count(declaration.failed, warns: true)
                                count(declaration.invalid, warns: true)
                                Text(declaration.commonReason.map { "\($0) (\(Plural.count(declaration.commonReasonCount, "device")))" } ?? "–")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let others = BlueprintHealth.othersLine(health.inapplicable, inScope: true) {
                    Text(others + " (other platforms, other versions or hardware).").font(.callout).foregroundStyle(.secondary)
                }
                if health.unmatchedDevices > 0 || health.devicesWithoutPlatformID > 0 {
                    Text(Self.unmatchedNote(health)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Each declaration’s device list is read once per refresh; Inspect shows them for one device.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The Blueprint’s declaration reports couldn’t be read in this refresh.").foregroundStyle(.secondary)
            }
        }
    }

    /// A number, with the warning sign when a problem count isn’t zero (never by color alone).
    @ViewBuilder
    private func count(_ value: Int, warns: Bool = false) -> some View {
        if warns && value > 0 {
            Label("\(value)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .monospacedDigit()
        } else {
            Text("\(value)").monospacedDigit().foregroundStyle(value == 0 ? .secondary : .primary)
        }
    }

    /// Reports left out because they couldn’t be tied to a device in the list.
    static func unmatchedNote(_ health: BlueprintHealth) -> String {
        var parts: [String] = []
        if health.devicesWithoutPlatformID > 0 {
            parts.append("\(Plural.count(health.devicesWithoutPlatformID, "device")) of the list \(health.devicesWithoutPlatformID == 1 ? "isn’t" : "aren’t") "
                         + "in the Platform device list by serial number")
        }
        if health.unmatchedDevices > 0 {
            parts.append("reports of \(Plural.count(health.unmatchedDevices, "device")) outside the list")
        }
        return "Left out: " + parts.joined(separator: "; ") + "."
    }
}

struct DeadlineZonesSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deadline per Time Zone").font(.headline)
            if result.zones.isEmpty {
                Text("No device has a deadline.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(result.zones) { zone in
                        GridRow {
                            Text(zone.target.map { "\(zone.label), target \($0)" } ?? zone.label)
                            Text("\(zone.deviceCount)").monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(DeadlineZones.text(local: zone.localDeadline, reported: zone.reported) ?? "–")
                            // the Mac note is said once, under the table
                            if let unusual = zone.unusual, unusual != DeadlineZones.macNote {
                                WarningLabel(unusual).font(.callout)
                            } else {
                                Text("")
                            }
                        }
                    }
                }
                if result.zones.contains(where: { $0.unusual == DeadlineZones.macNote }) {
                    WarningLabel(DeadlineZones.macNote).font(.callout)
                }
                Text("Deadlines reported by the devices are shown in this Mac’s time zone; computed ones in each device’s local time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReplacementSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware to Replace").font(.headline)
            Text("These models can’t run the newest release.").foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Model"); Text("Devices"); Text("Last version it can run"); Text("Counted")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(result.replacements) { item in
                    GridRow {
                        Text(item.model.isEmpty ? item.modelIdentifier : "\(item.model) (\(item.modelIdentifier))")
                        Text("\(item.deviceCount)").monospacedDigit()
                        Text(item.lastSupportedVersion ?? "Unknown")
                        Text(item.note).font(.callout)
                    }
                }
            }
        }
    }
}

/// The comparison group’s devices the Blueprint doesn’t reach.
struct CoverageSection: View {
    let model: DashboardModel
    let result: RefreshResult
    @Binding var sheet: BlueprintSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Coverage").font(.headline)
                Spacer()
                Button(result.coverage == nil ? "Compare with a Group…" : "Change Group…") { sheet = .compare(result.tracked.id) }
                if result.coverage != nil {
                    Button("Stop Comparing") { model.setCompareGroup(nil, for: result.tracked.id) }
                }
            }
            if let coverage = result.coverage {
                if coverage.notReached.isEmpty {
                    Label(coverage.members == 1 ? "The Blueprint reaches the only device of \(coverage.group.name)."
                          : "The Blueprint reaches all \(coverage.members) devices of \(coverage.group.name).", systemImage: "checkmark.circle")
                } else {
                    WarningLabel("\(coverage.notReached.count) of \(Plural.count(coverage.members, "device")) in \(coverage.group.name) \(coverage.notReached.count == 1 ? "isn’t" : "aren’t") in the Blueprint’s scope.")
                    ForEach(coverage.notReached.prefix(50), id: \.id) { member in
                        Text("\(member.name ?? "Unnamed")  \(member.serialNumber ?? "")  \(member.osVersion ?? "")")
                            .font(.callout.monospaced())
                    }
                    if coverage.notReached.count > 50 {
                        Text("and \(coverage.notReached.count - 50) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Compare with a group to see which of its devices the Blueprint doesn’t reach.").foregroundStyle(.secondary)
            }
        }
    }
}
