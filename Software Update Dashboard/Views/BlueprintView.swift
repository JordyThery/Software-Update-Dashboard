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

    var body: some View {
        Group {
            if let result = model.results[tracked.id] {
                switch page {
                case .dashboard: DashboardView(model: model, result: result, sheet: $sheet)
                case .devices: DeviceListView(model: model, result: result)
                }
            } else if model.refreshing.contains(tracked.id) {
                ReadingProgress(model: model, id: tracked.id)
            } else if let error = model.errors[tracked.id] {
                ContentUnavailableView {
                    Label("Couldn’t Read the Blueprint", systemImage: "exclamationmark.triangle")
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
            if let result = model.results[tracked.id], let error = model.errors[tracked.id], !model.refreshing.contains(tracked.id) {
                RefreshStoppedBanner(error: error, shown: result.date) { Task { await model.refresh(tracked.id) } }
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

/// The last refresh stopped: why, and which refresh is shown instead.
struct RefreshStoppedBanner: View {
    let error: String
    let shown: Date
    let tryAgain: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text("The refresh stopped: \(error) Showing the refresh of \(shown.formatted(date: .abbreviated, time: .shortened)).")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button("Try Again", action: tryAgain)
        }
        .padding(10)
        .background(.bar)
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
                    Text("\(progress.done) of \(progress.total) devices")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RuleSection(model: model, result: result, sheet: $sheet)
                ForEach(result.problems, id: \.self) { WarningLabel($0).font(.callout) }
                ProgressSection(counts: result.counts, pastDeadline: result.pastDeadline)
                CategoryGrid(counts: result.counts)
                MajorsSection(result: result)
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
                    Text("\(result.devices.count) devices, each counted once").font(.caption).foregroundStyle(.secondary)
                    if let change = result.scopeChange { Text(change.text).font(.caption).foregroundStyle(.orange) }
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
            .compactMap { name, days in days.map { "\(name) \($0) days" } }
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
                Text("\(counts[.onTarget]) of \(counts.updatable) updatable devices on their target")
                    .foregroundStyle(.secondary)
            }
            ProgressBar(counts: counts)
            ProgressLegend(counts: counts)
            Text("Updatable leaves out unsupported hardware, offline devices and devices without a report. \(counts.total) devices in all"
                 + (pastDeadline > 0 ? "; \(pastDeadline) past their deadline." : "."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CategoryGrid: View {
    let counts: CategoryCounts

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(StatusCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(counts[category])")
                        .font(.title2.monospacedDigit().weight(.semibold))
                    if let note = category.note(staleDays: 30) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
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
                        Text(row.deadlines.isEmpty ? "–"
                             : row.deadlines.map(TargetRules.readable).joined(separator: ", ")
                               + (row.pastDeadline > 0 ? " (\(row.pastDeadline) past)" : ""))
                    }
                }
            }
            if !result.majors.isEmpty {
                Text("Deadlines are each device’s local time.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The five progress groups per refresh, with the refreshes where the scope changed marked.
struct HistoryChart: View {
    let snapshots: [HistorySnapshot]

    private var marks: [HistoryMark] { HistoryMark.marks(snapshots) }

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
                                .lineStyle(StrokeStyle(lineWidth: 1))
                                .accessibilityLabel("\(group.rawValue), \(snapshot.date.formatted(date: .abbreviated, time: .shortened))")
                                .accessibilityValue("\(count) \(count == 1 ? "device" : "devices")")
                        }
                    }
                    ForEach(marks) { mark in
                        RuleMark(x: .value("Change", mark.date))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) { Text(mark.kind.rawValue).font(.caption2) }
                            .accessibilityLabel(mark.text)
                    }
                }
                .chartForegroundStyleScale(domain: ProgressGroup.allCases.map(\.rawValue),
                                           range: ProgressGroup.allCases.map(\.color))
                .frame(height: 180)
                ForEach(marks) { mark in
                    Text("\(mark.date.formatted(date: .abbreviated, time: .omitted)): \(mark.text)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
                            Text(zone.zone ?? "No time zone")
                            Text("\(zone.deviceCount)").monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            if let deadline = zone.deadline {
                                Text(deadline, format: .dateTime.day().month().hour().minute())
                            } else {
                                Text("\(TargetRules.readable(zone.localDeadline)), device local time").foregroundStyle(.secondary)
                            }
                            if let unusual = zone.unusual {
                                WarningLabel(unusual).font(.callout)
                            } else {
                                Text("")
                            }
                        }
                    }
                }
                Text("Times with a zone are shown in this Mac’s time zone.").font(.caption).foregroundStyle(.secondary)
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
                    Label("The Blueprint reaches all \(coverage.members) devices of \(coverage.group.name).", systemImage: "checkmark.circle")
                } else {
                    WarningLabel("\(coverage.notReached.count) of \(coverage.members) devices in \(coverage.group.name) aren’t in the Blueprint’s scope.")
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
