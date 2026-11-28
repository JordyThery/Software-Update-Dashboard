import Charts
import JTKit
import SwiftUI

typealias CacheHealthLevel = ContentCacheRules.CacheHealth.Level

extension CacheHealthLevel {
    /// A symbol per level, so health never rests on color alone.
    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .fault: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .fault: .red
        }
    }
}

/// A cache’s health: its symbol in its color, and its name.
struct CacheHealthLabel: View {
    let level: CacheHealthLevel

    var body: some View {
        Label {
            Text(level.title)
        } icon: {
            Image(systemName: level.systemImage).foregroundStyle(level.color)
        }
    }
}

/// Bytes as Finder writes them (“61 GB”, “2 KB”), and zero as a number in
/// its smallest unit (“0 KB”), never spelled out.
func bytesText(_ bytes: Int64?) -> String {
    guard let bytes else { return "–" }
    return (bytes == 0 ? ByteText.zero : ByteText.any).string(fromByteCount: bytes)
}

private enum ByteText {
    static let any: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    static let zero: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useKB
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - The page

/// Content Caches: every Mac whose content cache is activated, read from
/// Jamf by a sweep (Refresh here, Refresh All, automatic refresh), with the
/// Blueprints that send Apple’s content caching declaration. Read only.
struct CachesView: View {
    @Bindable var model: DashboardModel
    @State private var selection: CacheRow.ID?
    @State private var sortOrder = [KeyPathComparator(\CacheRow.healthRank, order: .reverse)]

    private var caches: CachesModel { model.caches }

    private var rows: [CacheRow] {
        let all = caches.latest?.caches ?? []
        let filtered = all.filter { row in
            switch caches.filter {
            case .all: true
            case .attention: row.health.level != .ok
            case .unplanned: row.isUnplanned
            }
        }.filter { row in caches.siteFilter.map { $0.site == row.site } ?? true }
        return filtered.sorted(using: sortOrder)
    }

    private var selected: CacheRow? { selection.flatMap { id in caches.latest?.caches.first { $0.id == id } } }

    var body: some View {
        Group {
            if let latest = caches.latest {
                if latest.caches.isEmpty && latest.blueprints.isEmpty {
                    ContentUnavailableView {
                        Label("No Content Caches Found", systemImage: "server.rack")
                    } description: {
                        Text("No Mac’s inventory in Jamf says content caching is activated. Read \(Plural.count(latest.computersRead, "Mac")) \(latest.date.formatted(.relative(presentation: .named))).")
                    } actions: {
                        Button("Refresh") { Task { await caches.sweep() } }.disabled(caches.isSweeping)
                    }
                } else {
                    content(latest)
                }
            } else if caches.isSweeping {
                ProgressView(caches.progress?.text ?? "Reading from Jamf…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if caches.error == DashboardModel.stopped {
                ContentUnavailableView {
                    Label("Reading Stopped", systemImage: "stop.circle")
                } description: {
                    Text("The content caches haven’t been read yet.")
                } actions: {
                    Button("Read Content Caches") { Task { await caches.sweep() } }
                }
            } else if let error = caches.error {
                ContentUnavailableView {
                    Label("Couldn’t Read the Content Caches", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await caches.sweep() } }
                }
            } else {
                ContentUnavailableView {
                    Label("Content Caches", systemImage: "server.rack")
                } description: {
                    Text("Find the Macs with an activated content cache, what they serve and save, and the Blueprints that set them up. Reads every Mac’s inventory from Jamf; nothing changes in Jamf.")
                } actions: {
                    Button("Read Content Caches") { Task { await caches.sweep() } }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if caches.latest != nil, caches.isSweeping {
                HStack(spacing: 8) {
                    if let step = caches.progress, step.total > 0 {
                        ProgressView(value: Double(step.done), total: Double(step.total)).progressViewStyle(.linear).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(caches.progress?.text ?? "Reading from Jamf…").font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 6)
                .background(.bar)
                .accessibilityElement(children: .combine)
            } else if let latest = caches.latest, let error = caches.error {
                RefreshStoppedBanner(error: error, shown: latest.date) { Task { await caches.sweep() } }
            } else if let problem = caches.saveProblem {
                WarningBanner(text: "The last sweep couldn’t be saved on this Mac, so the trend keeps it only until the app quits.",
                              detail: problem) {
                    EmptyView()
                }
            }
        }
        .navigationTitle("Content Caches")
        .navigationSubtitle(caches.latest.map { "Read \($0.date.formatted(.relative(presentation: .named)))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: Binding(get: { caches.filter }, set: { caches.filter = $0 })) {
                    ForEach(CacheFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!caches.hasCaches)
            }
            ToolbarItem {
                if caches.isSweeping {
                    Button {
                        caches.stop()
                    } label: {
                        Label("Stop Refresh", systemImage: "stop.fill")
                    }
                    .help("Stop reading from Jamf (\(caches.progress?.text ?? "starting"))")
                } else {
                    Button {
                        Task { await caches.sweep() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read every Mac’s content cache from Jamf again")
                }
            }
        }
        // read on first open, as a Blueprint’s dashboard is; not tied to the
        // view, so redrawing it never stops the sweep (Stop does)
        .onAppear {
            if caches.latest == nil && caches.error == nil && !caches.isSweeping { Task { await caches.sweep() } }
        }
        .inspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selection = nil } })) {
            if let selected {
                CacheDetailView(model: model, row: selected)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
    }

    private func content(_ latest: CacheSweepRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CachesSummary(record: latest)
            ForEach(latest.problems, id: \.self) { WarningLabel($0).font(.callout) }
            if !latest.blueprints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Caching Blueprints").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(latest.blueprints) { CachingBlueprintCard(blueprint: $0) }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Caches").font(.headline)
                if let site = caches.siteFilter {
                    // from a Blueprint’s “by site” line: say so, and how to see them all
                    Text("in \(site.name)").foregroundStyle(.secondary)
                    Button("Show All Sites") { caches.siteFilter = nil }.buttonStyle(.link)
                }
                Spacer()
                Text("\(rows.count) of \(Plural.count(latest.caches.count, "cache"))").foregroundStyle(.secondary).monospacedDigit()
            }
            CachesTable(rows: rows, selection: $selection, sortOrder: $sortOrder)
        }
        .padding(20)
    }
}

/// How many caches are in each health, and how many no caching Blueprint reaches.
struct CachesSummary: View {
    let record: CacheSweepRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                ForEach(CacheHealthLevel.allCases, id: \.self) { level in
                    let count = record.caches.filter { $0.health.level == level }.count
                    HStack(spacing: 6) {
                        Image(systemName: level.systemImage).foregroundStyle(level.color)
                        Text(level.title)
                        Text("\(count)").monospacedDigit().fontWeight(.semibold)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(level.title): \(Plural.count(count, "cache"))")
                }
                Spacer()
                Text("\(Plural.count(record.computersRead, "Mac")) read").foregroundStyle(.secondary).monospacedDigit()
            }
            let unplanned = record.unplanned.count
            if unplanned > 0 {
                Label("\(Plural.count(unplanned, "cache")) \(unplanned == 1 ? "has" : "have") no caching Blueprint.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One caching Blueprint: what it sets and how many of its Macs cache.
struct CachingBlueprintCard: View {
    let blueprint: CachingBlueprintRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(blueprint.name, systemImage: "square.stack.3d.up").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Configured").foregroundStyle(.secondary)
                    Text(Plural.count(blueprint.configured.count, "Mac")).monospacedDigit()
                }
                GridRow {
                    Text("Activated").foregroundStyle(.secondary)
                    Text("\(blueprint.activated)").monospacedDigit()
                }
                GridRow {
                    Text("Declaration applied").foregroundStyle(.secondary)
                    Text("\(blueprint.applied)").monospacedDigit()
                }
            }
            .font(.callout)
            if let settings = blueprint.settings {
                Text(Self.settingsLine(settings)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let waiting = blueprint.configured.filter { !$0.isActivated || $0.declaration != .applied }
            if !waiting.isEmpty {
                DisclosureGroup("\(Plural.count(waiting.count, "Mac")) not caching or not applied") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(waiting) { mac in
                            Text("\(mac.name): \(mac.isActivated ? "activated" : "not activated"), \(mac.declaration.title.lowercased())")
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// “Limit 100 GB · 1 parent · No personal content · Live figures every 15 min”.
    static func settingsLine(_ settings: CachingBlueprintRow.Settings) -> String {
        var parts = [settings.cacheLimit.map { "Limit \(bytesText($0))" } ?? "No limit"]
        if let parents = settings.parents, !parents.isEmpty { parts.append(Plural.count(parents.count, "parent")) }
        if settings.allowPersonalCaching == false { parts.append("No personal content") }
        parts.append(liveFiguresText(settings.statusInterval))
        return parts.joined(separator: " · ")
    }

    static func liveFiguresText(_ interval: Int?) -> String {
        guard let interval, interval > 0 else { return "No live figures" }
        // seconds below one minute, never “every 0 min”
        if interval < 60 { return "Live figures every \(interval) s" }
        let minutes = interval / 60
        return minutes < 60 ? "Live figures every \(minutes) min" : "Live figures every \(Plural.count(minutes / 60, "hour"))"
    }
}

/// One row per cache, sortable on every column.
struct CachesTable: View {
    let rows: [CacheRow]
    @Binding var selection: CacheRow.ID?
    @Binding var sortOrder: [KeyPathComparator<CacheRow>]

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Health", value: \.healthRank) { row in
                CacheHealthLabel(level: row.health.level)
                    .help(row.health.reasons.joined(separator: "\n"))
            }
            .width(min: 80, ideal: 90)
            TableColumn("Mac", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    if row.isUnplanned { Text("No caching Blueprint").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Site", value: \.siteText) { Text($0.siteText) }
                .width(min: 80, ideal: 120)
            TableColumn("Last Contact", value: \.contactSort) { row in
                Text(row.lastContact.map { $0.formatted(.relative(presentation: .named)) } ?? "–")
                    .help(row.lastContact?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("Used", value: \.usedSort) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.limit.map { "\(bytesText(row.used)) of \(bytesText($0))" } ?? bytesText(row.used)).monospacedDigit()
                    if let share = row.usedShare {
                        ProgressView(value: share).progressViewStyle(.linear).accessibilityHidden(true)
                    }
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn("Pressure", value: \.pressureSort) { row in
                Text(row.pressure.map { "\($0)%" } ?? "–").monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Served", value: \.servedSort) { Text(bytesText($0.savings.served)).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Saved", value: \.savedSort) { row in
                Text(bytesText(row.savings.saved)).monospacedDigit()
                    .help(row.savings.since.map { "Since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            .width(min: 70, ideal: 90)
            TableColumn("Top Content", value: \.topSort) { Text($0.topCategory?.name ?? "–") }
                .width(min: 90, ideal: 120)
        }
    }
}

extension CacheRow {
    /// Sort keys: Fault before Warning before OK when descending.
    var healthRank: Int { CacheHealthLevel.allCases.firstIndex(of: health.level) ?? 0 }
    var siteText: String { site ?? "No site" }
    var contactSort: Date { lastContact ?? .distantPast }
    var usedSort: Int64 { used ?? -1 }
    var pressureSort: Int { pressure ?? -1 }
    var servedSort: Int64 { savings.served }
    var savedSort: Int64 { savings.saved }
    var topSort: String { topCategory?.name ?? "" }
}

// MARK: - The detail

/// One cache: why its health is what it is, its figures, what its caching
/// Blueprint sets against what the Mac reports, its parents, peers (macOS 27)
/// and alerts, and its trend.
struct CacheDetailView: View {
    let model: DashboardModel
    let row: CacheRow
    @State private var showsStatusItems = false

    private var caches: CachesModel { model.caches }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                figures
                if !row.categories.isEmpty {
                    DetailSection("Content") {
                        ForEach(row.categories.sorted { $0.bytes > $1.bytes }, id: \.name) { category in
                            DetailRow(category.isPersonal ? "\(category.name) (personal)" : category.name, bytesText(category.bytes))
                        }
                    }
                }
                savings
                if !row.declarations.isEmpty || row.isUnplanned { blueprints }
                neighbors("Parents", row.parents, empty: "No parent cache.")
                if let peers = row.peers { neighbors("Peers", peers, empty: "No peer cache.") }
                if !row.alerts.isEmpty { alerts }
                trend
                Button("Status Items…") { showsStatusItems = true }
                    .disabled(row.managementID == nil)
                    .help("Every item of the Mac’s status report, read from Jamf Pro now")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsStatusItems) {
            StatusItemsView(model: model, name: row.name, managementID: row.managementID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.name).font(.title2.weight(.semibold))
            Text([row.model, row.osVersion.map { "macOS \($0)" }, row.site].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            CacheHealthLabel(level: row.health.level).font(.headline).padding(.top, 4)
            ForEach(row.health.reasons, id: \.self) { reason in
                Text(reason).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = row.statusProblem {
                WarningLabel("Its status report couldn’t be read: \(problem)").font(.callout)
            }
        }
    }

    private var figures: some View {
        DetailSection("Cache") {
            DetailRow("Used", row.limit.map { "\(bytesText(row.used)) of \(bytesText($0))" } ?? "\(bytesText(row.used)), no limit")
            DetailRow("Free", bytesText(row.free))
            DetailRow("Pressure", row.pressure.map { "\($0)% in the last hour" } ?? "–")
            if let personal = row.personalUsed, personal > 0 { DetailRow("Personal (iCloud)", bytesText(personal)) }
            DetailRow("Running", row.isActive.map { $0 ? "Yes" : "No" } ?? "–")
            if let registration = row.registration {
                DetailRow("Registration", [registration, row.registrationError].compactMap { $0 }.joined(separator: ": "))
            }
            Text(figuresNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("A content cache fills to its limit by design and removes what is used least; pressure shows when it is too small.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var figuresNote: String {
        let inventory = row.reportDate.map { "Figures from the Mac’s inventory of \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Figures from the Mac’s inventory"
        if let live = row.liveFigures, live > (row.reportDate ?? .distantPast) {
            return "Live figures the Mac sent \(live.formatted(date: .abbreviated, time: .shortened))."
        }
        return inventory + (row.statusUpdated == nil ? "." : "; the Mac sends no live figures (its caching Blueprint doesn’t ask for them).")
    }

    private var savings: some View {
        DetailSection("Savings") {
            DetailRow("Served", bytesText(row.savings.served))
            DetailRow("Fetched from Apple", bytesText(row.savings.fromOrigin))
            DetailRow("Saved", bytesText(row.savings.saved))
            if let week = caches.savings(of: row.id, days: 7) { DetailRow("Saved, last 7 days", bytesText(week)) }
            if let month = caches.savings(of: row.id, days: 30) { DetailRow("Saved, last 30 days", bytesText(month)) }
            Text(savingsNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var savingsNote: String {
        let since = row.savings.since.map { "Since the counters started on \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? ""
        let personal = row.savings.includesPersonal ? " Bytes served may include personal (iCloud) content, which isn’t counted as a saving on its own." : ""
        return since + "Saved is what the cache served minus what it fetched from Apple." + personal
    }

    private var blueprints: some View {
        DetailSection("Caching Blueprint") {
            if row.isUnplanned {
                Text("No caching Blueprint reaches this cache. It may be set up with a Jamf Pro configuration profile or by hand.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(row.declarations, id: \.blueprintID) { declaration in
                let blueprint = caches.latest?.blueprints.first { $0.id == declaration.blueprintID }
                VStack(alignment: .leading, spacing: 4) {
                    Text(declaration.blueprintName).font(.headline)
                    DetailRow("Declaration", declaration.state.title + (declaration.reasons.isEmpty ? "" : " (\(declaration.reasons.joined(separator: ", ")))"))
                    if let settings = blueprint?.settings {
                        DetailRow("Limit", "\(settings.cacheLimit.map(bytesText) ?? "None") set, \(row.limit.map(bytesText) ?? "none") reported")
                        DetailRow("Parents", "\(settings.parents?.count ?? 0) set, \(row.parents.count) reported")
                        if settings.allowPersonalCaching == false {
                            DetailRow("Personal content", (row.personalUsed ?? 0) > 0 ? "Not allowed, \(bytesText(row.personalUsed)) held" : "Not allowed, none held")
                        }
                        DetailRow("Live figures", CachingBlueprintCard.liveFiguresText(settings.statusInterval))
                    }
                }
            }
        }
    }

    private func neighbors(_ title: String, _ list: [CacheRow.Neighbor], empty: String) -> some View {
        DetailSection(title) {
            if list.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, neighbor in
                HStack(alignment: .firstTextBaseline) {
                    if let healthy = neighbor.isHealthy {
                        CacheHealthLabel(level: healthy ? .ok : .fault).labelStyle(.iconOnly)
                            .accessibilityLabel(healthy ? "Healthy" : "Unhealthy")
                    }
                    Text([neighbor.address, neighbor.port.map { "port \($0)" }].compactMap { $0 }.joined(separator: ", "))
                        .textSelection(.enabled)
                    Spacer()
                    Text([neighbor.isFriendly == true ? "friendly" : nil, neighbor.version].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var alerts: some View {
        DetailSection("Alerts") {
            ForEach(Array(row.alerts.enumerated()), id: \.offset) { _, alert in
                DetailRow(alert.name, alert.posted?.formatted(date: .abbreviated, time: .shortened) ?? "–")
            }
        }
    }

    private var trend: some View {
        let deltas = caches.deltas(of: row.id)
        let resets = deltas.filter(\.isReset)
        return DetailSection("Trend") {
            if let week = caches.savings(of: row.id, days: 7), !deltas.isEmpty {
                Text("Saved \(bytesText(week)) in the last 7 days").font(.callout.weight(.semibold))
            }
            if deltas.isEmpty {
                Text("The chart fills in as the caches are read over time.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(deltas.enumerated()), id: \.offset) { _, delta in
                        BarMark(x: .value("Read", delta.to, unit: .day), y: .value("Gigabytes", Double(delta.saved) / 1e9))
                            .foregroundStyle(by: .value("Kind", "Saved"))
                            .accessibilityLabel(delta.to.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("Saved \(bytesText(delta.saved)), served \(bytesText(delta.served))")
                        BarMark(x: .value("Read", delta.to, unit: .day), y: .value("Gigabytes", Double(max(delta.served - delta.saved, 0)) / 1e9))
                            .foregroundStyle(by: .value("Kind", "Fetched from Apple"))
                            .accessibilityHidden(true)
                    }
                    ForEach(resets, id: \.to) { reset in
                        RuleMark(x: .value("Reset", reset.to, unit: .day))
                            .foregroundStyle(Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .accessibilityLabel("Counters restarted on \(reset.to.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .chartForegroundStyleScale(["Saved": Color.green, "Fetched from Apple": Color.secondary.opacity(0.5)])
                .chartYAxisLabel("GB")
                .frame(height: 160)
                Text("Bytes served per sweep, and how many of them were saved.").font(.callout).foregroundStyle(.secondary)
                ForEach(resets, id: \.to) { reset in
                    Text("Dashed line: the counters restarted before the read of \(reset.to.formatted(date: .abbreviated, time: .omitted)); the trend counts on from there.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A titled group of the detail.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

/// A label and its value on one line.
struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - On a Blueprint’s dashboard

/// The content caches in each site of a Blueprint’s devices, next to its
/// rollout: the worst health of that site’s caches, or none. Shown only when
/// the last sweep found a cache.
struct SiteCachesSection: View {
    let sites: [SiteCaches]
    /// Opens Content Caches on a site; nil in a printed report.
    var show: ((SiteCaches) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content Caches by Site").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(sites) { site in
                    GridRow {
                        Text(site.name)
                        if let worst = site.worst {
                            CacheHealthLabel(level: worst)
                        } else {
                            Text("No cache").foregroundStyle(.secondary)
                        }
                        Text(site.caches == 0 ? Plural.count(site.devices, "device")
                             : "\(Plural.count(site.caches, "cache")), \(Plural.count(site.devices, "device"))")
                            .foregroundStyle(.secondary).monospacedDigit()
                        if let show, site.caches > 0 {
                            Button("Show Caches") { show(site) }
                                .buttonStyle(.link)
                                .help("Show \(site.name)’s caches in Content Caches")
                                .accessibilityLabel("Show \(site.name)’s caches")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
