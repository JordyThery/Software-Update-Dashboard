import AppKit
import JTKit
import SwiftUI

/// Every item of one device’s status report, read from Jamf Pro when the
/// sheet opens, with a filter and Copy. The items aren’t saved: closing the
/// sheet forgets them and the history never holds them (the request’s answer
/// stays in the in-memory activity log, like every other, until the app quits).
struct StatusItemsView: View {
    let model: DashboardModel
    let trackedID: UUID
    let device: DeviceStatus
    @Environment(\.dismiss) private var dismiss
    @State private var items: [StatusItemRow] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var filter = ""
    @State private var selection: Set<Int> = []

    private var shown: [StatusItemRow] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.item.key.localizedCaseInsensitiveContains(filter) || ($0.item.value ?? "").localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // a sheet shows no window title: say whose report this is
            VStack(alignment: .leading, spacing: 2) {
                Text("Status Items of \(device.name.isEmpty ? device.serial : device.name)").font(.headline)
                Text("Read from Jamf Pro now; the items aren’t saved").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            Group {
                if loading {
                    ProgressView("Reading the status report…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let problem {
                    ContentUnavailableView {
                        Label("Couldn’t Read the Status Report", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(problem)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if items.isEmpty {
                    ContentUnavailableView("No Status Report", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Jamf Pro has no status report for this device."))
                } else {
                    Table(shown, selection: $selection) {
                        TableColumn("Key") { row in
                            // the start and the end of a long key both tell it apart
                            Text(row.item.key).truncationMode(.middle).help(row.item.key)
                        }
                        .width(min: 220, ideal: 340)
                        TableColumn("Value") { row in
                            Text(row.item.value ?? "–")
                                .lineLimit(2)
                                .help(row.item.value ?? "")
                        }
                        .width(min: 160, ideal: 280)
                        TableColumn("Last Update") { row in
                            Text(lastUpdate(row.item))
                        }
                        .width(min: 110, ideal: 140)
                    }
                    .contextMenu(forSelectionType: Int.self) { ids in
                        Button("Copy") { copy(ids.isEmpty ? shown : items.filter { ids.contains($0.id) }) }
                    }
                }
            }
            .frame(minWidth: 860, minHeight: 420)
            Divider()
            HStack {
                TextField("Filter by key or value", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if !loading && problem == nil && !items.isEmpty {
                    Text("\(shown.count) of \(Plural.count(items.count, "item"))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(selection.isEmpty ? "Copy All Shown" : "Copy Selected") {
                    copy(selection.isEmpty ? shown : items.filter { selection.contains($0.id) })
                }
                .disabled(shown.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                // nothing to complete or save here: Close, not Done
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            items = try await model.statusItems(of: device, in: trackedID).enumerated().map { StatusItemRow(id: $0.offset, item: $0.element) }
        } catch is CancellationError {
            problem = "Stopped."
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A status item’s time, written by Jamf Pro in its own zone, in this Mac’s.
    private func lastUpdate(_ item: JamfPro.StatusItem) -> String {
        guard let text = item.lastUpdateTime, let date = JamfPro.serverDate(text, timeZone: model.connections.serverTimeZone) else {
            return item.lastUpdateTime ?? "–"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func copy(_ chosen: [StatusItemRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StatusItemsView.text(chosen.map(\.item)), forType: .string)
    }

    /// The items as text, one per line: `key = value`.
    static func text(_ items: [JamfPro.StatusItem]) -> String {
        items.map { "\($0.key) = \($0.value ?? "")" }.joined(separator: "\n")
    }
}

/// One row: the item and its place in the report, so a key Jamf repeats
/// still has a row of its own.
struct StatusItemRow: Identifiable, Hashable {
    let id: Int
    let item: JamfPro.StatusItem
}
