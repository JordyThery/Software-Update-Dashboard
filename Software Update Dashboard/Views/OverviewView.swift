import JTKit
import SwiftUI

/// Every tracked group at a glance: how far along it is, and when it was
/// last read.
struct OverviewView: View {
    let model: DashboardModel
    @Binding var isAdding: Bool

    var body: some View {
        Group {
            if model.groups.isEmpty {
                ContentUnavailableView {
                    Label("No Tracked Groups", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Track a Jamf Pro group with the Blueprint that enforces its software update.")
                } actions: {
                    Button("Track a Group…") { isAdding = true }
                        .disabled(model.connections.demoChoice.isActive)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(model.groups) { group in
                            GroupCard(model: model, group: group)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.groups.isEmpty || !model.refreshing.isEmpty)
                .help("Read every tracked group from Jamf again")
            }
        }
        .task(id: model.connections.inUseKey) {
            // the first look at a connection reads its groups once
            for group in model.groups where model.results[group.id] == nil { await model.refresh(group.id) }
        }
    }
}

/// One tracked group in the overview.
struct GroupCard: View {
    let model: DashboardModel
    let group: TrackedGroup

    var body: some View {
        let latest = model.latestCounts(group.id)
        Button {
            model.selection = .group(group.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(group.groupName, systemImage: group.isComputerGroup ? "laptopcomputer" : "ipad")
                        .font(.headline)
                    Spacer()
                    if model.refreshing.contains(group.id) { ProgressView().controlSize(.small) }
                }
                Text(group.blueprintName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let latest {
                    HStack(alignment: .center, spacing: 14) {
                        Gauge(value: (latest.counts.percentOnTarget ?? 0) / 100) {
                            EmptyView()
                        } currentValueLabel: {
                            Text(latest.counts.percentText)
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(latest.counts[.onTarget]) of \(latest.counts.updatable) updatable on target")
                            if let target = latest.target {
                                Text("Target \(target)").foregroundStyle(.secondary)
                            }
                            Text(latest.date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    ProgressBar(counts: latest.counts)
                } else if let error = model.errors[group.id] {
                    WarningLabel(error).font(.callout).lineLimit(3)
                } else {
                    Text("Not read yet").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the group’s dashboard")
    }
}

/// The five progress groups as one bar.
struct ProgressBar: View {
    let counts: CategoryCounts

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(ProgressGroup.allCases) { group in
                    let count = group.count(in: counts)
                    if count > 0 {
                        Rectangle()
                            .fill(group.color)
                            .frame(width: max(2, geometry.size.width * CGFloat(count) / CGFloat(max(1, counts.total))))
                            .help("\(group.rawValue): \(count)")
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel(ProgressGroup.allCases.map { "\($0.rawValue) \($0.count(in: counts))" }.joined(separator: ", "))
    }
}
