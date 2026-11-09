import JTKit
import SwiftUI

/// Every tracked Blueprint at a glance: how far along it is, and when it
/// was last read.
struct OverviewView: View {
    let model: DashboardModel
    @Binding var sheet: BlueprintSheet?

    var body: some View {
        Group {
            if model.trackedBlueprints.isEmpty {
                ContentUnavailableView {
                    Label("No Tracked Blueprints", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Track a Blueprint with a software update. Its scope says which devices count.")
                } actions: {
                    Button("Track a Blueprint…") { sheet = .track }
                        .disabled(model.connections.demoChoice.isActive)
                        .help(model.connections.demoChoice.isActive ? "Demo Mode has its own sample Blueprints." : "Track a Blueprint with a software update")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(model.trackedBlueprints) { tracked in
                            BlueprintCard(model: model, tracked: tracked)
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
                .disabled(model.trackedBlueprints.isEmpty || !model.refreshing.isEmpty)
                .help("Read every tracked Blueprint from Jamf again")
            }
        }
        .task(id: model.connections.inUseKey) {
            // the first look at a connection reads its Blueprints once
            for tracked in model.trackedBlueprints where model.results[tracked.id] == nil { await model.refresh(tracked.id) }
        }
    }
}

/// One tracked Blueprint in the overview.
struct BlueprintCard: View {
    let model: DashboardModel
    let tracked: TrackedBlueprint

    var body: some View {
        let latest = model.latestCounts(tracked.id)
        Button {
            model.selection = .blueprint(tracked.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(tracked.blueprintName, systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Spacer()
                    if model.refreshing.contains(tracked.id) { ProgressView().controlSize(.small) }
                }
                if let rule = latest?.rule ?? model.results[tracked.id]?.rule {
                    Text(rule).font(.subheadline).foregroundStyle(.secondary)
                }
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
                            if let result = model.results[tracked.id], result.pastDeadline > 0 {
                                Text("\(result.pastDeadline) past the deadline").foregroundStyle(.secondary)
                            }
                            // “Read now”, “Read 2 hours ago”: when Jamf was last read
                            Text("Read \(latest.date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    ProgressBar(counts: latest.counts)
                    if model.errors[tracked.id] != nil {
                        WarningLabel("The last refresh stopped; showing an earlier one").font(.callout)
                    }
                } else if let error = model.errors[tracked.id] {
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
        .accessibilityHint("Shows the Blueprint’s dashboard")
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
