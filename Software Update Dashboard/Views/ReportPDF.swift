import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// Export Report as PDF: what the dashboard shows for one tracked Blueprint
/// or all of them, from their last refresh (nothing is read from Jamf), with
/// the devices that need attention and their diagnosis. Each section is
/// drawn on its own and placed on A4 pages, never cut in half.
@MainActor
enum ReportPDF {
    /// One Blueprint in the report: its last refresh and its history.
    struct Part {
        var tracked: TrackedBlueprint
        /// This session’s refresh, else one made from the newest saved refresh (`fromHistory`).
        var result: RefreshResult?
        var snapshots: [HistoryEntry]
        /// The result comes from the history: Blueprint health isn’t kept there.
        var fromHistory = false

        /// This session’s refresh, else the newest saved one, else none.
        init(tracked: TrackedBlueprint, result: RefreshResult?, saved: HistorySnapshot?, snapshots: [HistoryEntry]) {
            self.tracked = tracked
            self.snapshots = snapshots
            if let result {
                self.result = result
            } else if let saved {
                self.result = Self.result(saved, tracked: tracked)
                fromHistory = true
            }
        }

        /// What the dashboard shows, worked out again from a saved refresh’s devices.
        static func result(_ saved: HistorySnapshot, tracked: TrackedBlueprint) -> RefreshResult {
            RefreshResult(date: saved.date, tracked: tracked, blueprintName: tracked.blueprintName, blueprintChanged: nil,
                          blocks: [], settings: [], rule: saved.target ?? "", ruleKey: saved.ruleKey,
                          scope: saved.scope ?? [], unmatchedScope: 0, scopeChange: nil, members: [], devices: saved.devices,
                          majors: MajorRow.rows(saved.devices), zones: DeadlineZones.zones(devices: saved.devices, now: saved.date),
                          replacements: Replacement.list(saved.devices) { _ in nil }, coverage: nil, problems: [], health: nil)
        }
    }

    static let pageSize = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 36
    static var contentWidth: CGFloat { pageSize.width - 2 * margin }
    /// Devices needing attention per block, so a long list breaks between rows.
    static let rowsPerBlock = 18
    /// Grey text dark enough for paper (about 7.5:1 on white); the report is always light.
    static let secondaryInk = Color(white: 0.35)

    /// “Software Update Dashboard Report” (“ — Demo” in Demo Mode).
    static func title(demo: Bool) -> String {
        "Software Update Dashboard Report" + (demo ? " — Demo" : "")
    }

    /// The PDF: a title, then each Blueprint from a new page.
    static func make(_ parts: [Part], demo: Bool, created: Date = Date()) -> Data {
        var blocks: [(view: AnyView, newPage: Bool)] = []
        blocks.append((AnyView(ReportTitle(title: title(demo: demo), created: created, count: parts.count)), false))
        for (index, part) in parts.enumerated() {
            for (number, view) in sections(part).enumerated() {
                blocks.append((view, number == 0 && index > 0))
            }
        }
        return render(blocks, title: title(demo: demo))
    }

    /// One Blueprint’s blocks, in the dashboard’s order.
    static func sections(_ part: Part) -> [AnyView] {
        var views: [AnyView] = [AnyView(ReportBlueprintHeader(tracked: part.tracked, result: part.result, fromHistory: part.fromHistory))]
        guard let result = part.result else { return views }
        views.append(AnyView(ProgressSection(counts: result.counts, pastDeadline: result.pastDeadline)))
        views.append(AnyView(CategoryGrid(counts: result.counts)))
        views.append(AnyView(ReadinessSection(devices: result.devices, showDevices: { _ in }, interactive: false)))
        views.append(AnyView(MajorsSection(result: result)))
        if !part.fromHistory { views.append(AnyView(BlueprintHealthSection(result: result, versionsOnly: true))) }
        views.append(AnyView(HistoryChart(snapshots: part.snapshots)))
        views.append(AnyView(DeadlineZonesSection(result: result)))
        if !result.replacements.isEmpty { views.append(AnyView(ReplacementSection(result: result))) }
        let attention = attentionDevices(result)
        if attention.isEmpty {
            views.append(AnyView(ReportAttentionRows(title: "Devices to Check", devices: [], total: 0)))
        } else {
            for start in stride(from: 0, to: attention.count, by: rowsPerBlock) {
                let rows = Array(attention[start..<min(start + rowsPerBlock, attention.count)])
                views.append(AnyView(ReportAttentionRows(title: start == 0 ? "Devices to Check" : "Devices to Check (continued)",
                                                         devices: rows, total: attention.count)))
            }
        }
        return views
    }

    /// The devices whose diagnosis needs someone to look, not on target, by name.
    static func attentionDevices(_ result: RefreshResult) -> [DeviceStatus] {
        result.devices.filter { $0.category != .onTarget && $0.needsAttention }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Draws the blocks on pages: a block that doesn’t fit starts a new page;
    /// one taller than a page is scaled down to fit.
    static func render(_ blocks: [(view: AnyView, newPage: Bool)], title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Software Update Dashboard"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }
        let available = pageSize.height - 2 * margin
        var used: CGFloat = 0
        var pageOpen = false
        func newPage() {
            if pageOpen { context.endPDFPage() }
            context.beginPDFPage(nil)
            pageOpen = true
            used = 0
        }
        for block in blocks {
            // its height at the page's width: text that wraps makes it taller
            let renderer = ImageRenderer(content: block.view
                .frame(width: contentWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .light)
                .padding(.bottom, 18))
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
            renderer.render { size, draw in
                let scale = size.height > available ? available / size.height : 1
                let height = size.height * scale
                if !pageOpen || block.newPage || used + height > available { newPage() }
                context.saveGState()
                context.translateBy(x: margin, y: pageSize.height - margin - used - height)
                context.scaleBy(x: scale, y: scale)
                draw(context)
                context.restoreGState()
                used += height
            }
        }
        if !pageOpen { newPage() }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// The report’s first lines.
struct ReportTitle: View {
    let title: String
    let created: Date
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.semibold))
            Text("Made \(created.formatted(date: .long, time: .shortened)) from the last refresh of \(Plural.count(count, "tracked Blueprint")); nothing was read from Jamf for it.")
                .font(.callout).foregroundStyle(ReportPDF.secondaryInk)
        }
    }
}

/// A Blueprint’s name, rule, scope and the refresh the report comes from.
struct ReportBlueprintHeader: View {
    let tracked: TrackedBlueprint
    let result: RefreshResult?
    var fromHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tracked.blueprintName).font(.title2.weight(.semibold))
            if let result {
                Text(result.rule)
                Text("Refresh of \(result.date.formatted(date: .long, time: .shortened))"
                     + (fromHistory ? ", the newest saved one (Blueprint health isn’t kept in the history)" : ""))
                    .foregroundStyle(ReportPDF.secondaryInk)
                Text("Scope: \(result.scope.isEmpty ? "no Jamf Pro groups" : result.scope.map(\.name).joined(separator: ", ")); "
                     + "\(Plural.count(result.devices.count, "device")), each counted once")
                    .font(.callout).foregroundStyle(ReportPDF.secondaryInk)
            } else {
                Text("Never refreshed: refresh it to include it in the report.")
                    .foregroundStyle(ReportPDF.secondaryInk)
            }
        }
    }
}

/// Some of the devices needing attention, with their diagnosis.
struct ReportAttentionRows: View {
    let title: String
    let devices: [DeviceStatus]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if devices.isEmpty {
                Text("No device to check.").foregroundStyle(ReportPDF.secondaryInk)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("Device"); Text("Serial"); Text("OS"); Text("Target"); Text("Diagnosis")
                    }
                    .font(.caption.weight(.semibold))
                    ForEach(devices) { device in
                        GridRow {
                            Text(device.name).lineLimit(2)
                            Text(device.serial).monospaced()
                            Text(device.currentOS)
                            Text(device.targetVersion ?? "–")
                            Text(device.diagnosis).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}

/// The PDF for the Save panel.
struct PDFReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
