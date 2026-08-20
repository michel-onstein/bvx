import BVXAppCore
import BVXCore
import SwiftUI

/// Parallel execution tracks. Each track is a connected component of the
/// actionable subgraph, so two people working in different tracks cannot
/// collide.
struct PlanView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            PlanSummaryBar()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(store.plan.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackColumn(index: index, track: track)
                    }
                }
                .padding(12)
            }
        }
        .background(.background.secondary)
        .overlay {
            if store.plan.tracks.isEmpty {
                EmptyStateView(
                    symbol: "flowchart",
                    title: "No parallel tracks",
                    message: "Nothing is actionable right now — every open bead is blocked."
                )
            }
        }
    }
}

struct PlanSummaryBar: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        let plan = store.plan
        HStack(spacing: 16) {
            Label("\(plan.totalActionable) actionable", systemImage: "bolt.circle")
            Label("\(plan.totalBlocked) blocked", systemImage: "lock")
            Label("\(plan.tracks.count) tracks", systemImage: "arrow.triangle.branch")

            if !plan.highestImpact.isEmpty {
                Divider().frame(height: 14)
                Button {
                    store.select(id: plan.highestImpact)
                } label: {
                    Label(
                        "Highest impact: \(plan.highestImpact)"
                            + (plan.unblocksCount > 0 ? " (unblocks \(plan.unblocksCount))" : ""),
                        systemImage: "star.fill"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help(plan.impactReason)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TrackColumn: View {
    @EnvironmentObject var store: ProjectStore
    let index: Int
    let track: ExecutionTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Track \(index + 1)", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Text("\(track.items.count)")
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            if !track.reason.isEmpty {
                Text(track.reason)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if totalMinutes > 0 {
                Text("~\(totalMinutes / 60)h estimated")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(track.items) { item in
                        PlanCard(item: item)
                            .onTapGesture { store.select(id: item.id) }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var totalMinutes: Int {
        let byID = store.issuesByID
        return track.items.compactMap { byID[$0.id]?.estimatedMinutes }.reduce(0, +)
    }
}

struct PlanCard: View {
    @EnvironmentObject var store: ProjectStore
    let item: PlanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: item.status.symbolName)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("P\(item.priority)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.priority <= 1 ? .orange : .secondary)
            }

            Text(item.title).font(.callout).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // The engine already reports what this unblocks, so the card needs
            // no follow-up query.
            if !item.unblocks.isEmpty {
                Label(
                    "unblocks \(item.unblocks.count): \(item.unblocks.prefix(3).joined(separator: ", "))",
                    systemImage: "lock.open"
                )
                .font(.caption2)
                .foregroundStyle(.blue)
                .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    store.isSelected(item.id) ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}
