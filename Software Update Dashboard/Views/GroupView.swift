import Charts
import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// One tracked group: its dashboard or its devices, with Refresh and the exports.
struct GroupView: View {
    enum Page: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case devices = "Devices"
        var id: String { rawValue }
    }

    let model: DashboardModel
    let group: TrackedGroup
    @Binding var page: Page
    @Binding var exportRequest: Bool?
    @State private var export: TextExportDocument?
    @State private var exportName = ""
    @State private var exportType: UTType = .plainText

    var body: some View {
        Group {
            if let result = model.results[group.id] {
                switch page {
                case .dashboard: DashboardView(model: model, result: result)
                case .devices: DeviceListView(model: model, result: result)
                }
            } else if model.refreshing.contains(group.id) {
                ReadingProgress(model: model, id: group.id)
            } else if let error = model.errors[group.id] {
                ContentUnavailableView {
                    Label("Couldn’t Read the Group", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh(group.id) } }
                }
            } else {
                ContentUnavailableView {
                    Label(group.groupName, systemImage: group.isComputerGroup ? "laptopcomputer" : "ipad")
                } description: {
                    Text("Read the group’s devices and the Blueprint’s software update from Jamf.")
                } actions: {
                    Button("Refresh") { Task { await model.refresh(group.id) } }
                }
            }
        }
        .navigationTitle(group.groupName)
        .navigationSubtitle(group.blueprintName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.results[group.id] == nil)
            }
            ToolbarItem {
                Menu {
                    Button("Device List as CSV…") { prepareExport(csv: true) }
                    Button("Summary…") { prepareExport(csv: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.results[group.id] == nil)
                .help("Save the device list or the summary")
            }
            ToolbarItem {
                if model.refreshing.contains(group.id) {
                    ProgressView().controlSize(.small)
                        .help(model.progress[group.id] ?? "Reading from Jamf")
                } else {
                    Button {
                        Task { await model.refresh(group.id) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the group from Jamf again")
                }
            }
        }
        .task(id: group.id) {
            if model.results[group.id] == nil && model.errors[group.id] == nil { await model.refresh(group.id) }
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
        let text = csv ? model.csv(group.id) : model.summary(group.id)
        guard let text else { return }
        let day = Date().formatted(.iso8601.year().month().day())
        exportName = "\(group.groupName) \(day)\(csv ? ".csv" : ".txt")"
        exportType = csv ? .commaSeparatedText : .plainText
        export = TextExportDocument(text: text)
    }
}

/// While a group is read: how many status reports are in.
struct ReadingProgress: View {
    let model: DashboardModel
    let id: UUID

    var body: some View {
        VStack(spacing: 8) {
            if let progress = model.progress[id], let done = Int(progress.split(separator: " ").first ?? ""),
               let total = Int(progress.split(separator: " ").dropFirst(2).first ?? ""), total > 0 {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Reading status reports")
                } currentValueLabel: {
                    Text("\(done) of \(total) devices")
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

/// The group’s dashboard: the target, the progress, the nine categories,
/// the history, the deadline per time zone and the hardware to replace.
struct DashboardView: View {
    let model: DashboardModel
    let result: RefreshResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TargetSection(result: result)
                ForEach(result.problems, id: \.self) { WarningLabel($0).font(.callout) }
                ProgressSection(counts: result.counts)
                CategoryGrid(counts: result.counts)
                HistoryChart(snapshots: model.snapshots(result.group.id))
                DeadlineZonesSection(result: result)
                if !result.replacements.isEmpty { ReplacementSection(result: result) }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }
}

struct TargetSection: View {
    let result: RefreshResult

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Target").foregroundStyle(.secondary)
                if let target = result.target {
                    Text("\(result.osName) \(target.description)" + (result.build.map { " (build \($0))" } ?? ""))
                        .font(.title3.weight(.semibold))
                } else {
                    Text("Unknown").font(.title3.weight(.semibold))
                }
            }
            if let deadline = result.deadline {
                GridRow {
                    Text("Deadline").foregroundStyle(.secondary)
                    Text("\(Self.localText(deadline)), in each device’s local time")
                }
            }
            if let since = result.since {
                GridRow {
                    Text("Update started").foregroundStyle(.secondary)
                    Text(since, format: .dateTime.day().month().year().hour().minute())
                }
            }
            if result.blocks.count > 1, let block = result.block {
                GridRow {
                    Text("Block").foregroundStyle(.secondary)
                    Text("\(block.stepName ?? "Step \(block.stepIndex + 1)") of \(result.blocks.count) in the Blueprint")
                }
            }
            GridRow {
                Text("Read").foregroundStyle(.secondary)
                Text(result.date, format: .dateTime.day().month().hour().minute())
            }
        }
    }

    /// `2026-11-16T17:00:00` as people read it, without moving it to a zone.
    static func localText(_ local: String) -> String {
        guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return local }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

struct ProgressSection: View {
    let counts: CategoryCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(counts.percentText).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text("\(counts[.onTarget]) of \(counts.updatable) updatable devices on target")
                    .foregroundStyle(.secondary)
            }
            ProgressBar(counts: counts)
            ProgressLegend(counts: counts)
            Text("Updatable leaves out unsupported hardware, offline devices and devices without a report. \(counts.total) devices in all.")
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

/// The five progress groups per refresh.
struct HistoryChart: View {
    let snapshots: [HistorySnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            if snapshots.count < 2 {
                Text("The chart fills in as the group is refreshed over time.")
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
                }
                .chartForegroundStyleScale(domain: ProgressGroup.allCases.map(\.rawValue),
                                           range: ProgressGroup.allCases.map(\.color))
                .frame(height: 180)
                .accessibilityLabel("Devices per progress group over \(snapshots.count) refreshes")
            }
        }
    }
}

struct DeadlineZonesSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deadline per Time Zone").font(.headline)
            if result.deadline == nil {
                Text("The Blueprint sets no deadline.").foregroundStyle(.secondary)
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
                                Text("–").foregroundStyle(.secondary)
                            }
                            if let unusual = zone.unusual {
                                WarningLabel(unusual).font(.callout)
                            } else {
                                Text("")
                            }
                        }
                    }
                }
                Text("Times are shown in this Mac’s time zone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReplacementSection: View {
    let result: RefreshResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware to Replace").font(.headline)
            Text("These models can’t run \(result.osName) \(result.target?.major ?? 0).").foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text("Devices").foregroundStyle(.secondary)
                    Text("Last version it can run").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(result.replacements) { item in
                    GridRow {
                        Text(item.model.isEmpty ? item.modelIdentifier : "\(item.model) (\(item.modelIdentifier))")
                        Text("\(item.deviceCount)").monospacedDigit()
                        Text(item.lastSupportedVersion ?? "Unknown")
                    }
                }
            }
        }
    }
}
