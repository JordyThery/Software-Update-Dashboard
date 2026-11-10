import JTKit
import SwiftUI

/// Find a Device: a serial number or name in every tracked Blueprint, from
/// each one’s last refresh; opening a match shows it in its Blueprint.
struct FindDeviceSheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selected: DeviceSearch.Match.ID?
    @FocusState private var fieldFocused: Bool

    private var matches: [DeviceSearch.Match] { DeviceSearch.matches(text, in: model.searchSources()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a Device").font(.headline)
            TextField("Serial number or name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { if let match = chosen { open(match) } }
                // Return and Show Device open the same, highlighted match
                .onChange(of: text) { selected = matches.first?.id }
                .onKeyPress(.downArrow) {
                    fieldFocused = false
                    return .handled
                }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Searches the last refresh of every tracked Blueprint; nothing is read from Jamf.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List(matches, selection: $selected) { match in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.device.name.isEmpty ? match.device.serial : match.device.name)
                            Text("\(match.device.serial) · \(match.blueprintName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(match.device.category.title, style: match.device.category.badgeStyle)
                    }
                    .tag(match.id)
                    .accessibilityElement(children: .combine)
                }
                .contextMenu(forSelectionType: DeviceSearch.Match.ID.self) { _ in } primaryAction: { ids in
                    if let match = matches.first(where: { ids.contains($0.id) }) { open(match) }
                }
                if let date = matches.compactMap(\.date).min() {
                    Text("From refreshes of \(date.formatted(date: .abbreviated, time: .shortened)) and later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onAppear { fieldFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Show Device") {
                    if let match = chosen { open(match) }
                }
                .disabled(chosen == nil)
            }
        }
    }

    /// The selected match, else the first.
    private var chosen: DeviceSearch.Match? { matches.first { $0.id == selected } ?? matches.first }

    private func open(_ match: DeviceSearch.Match) {
        model.show(match)
        dismiss()
    }
}
