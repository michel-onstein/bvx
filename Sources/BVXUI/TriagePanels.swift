import BVXAppCore
import BVXCore
import SwiftUI

/// "What should I work on next", with the engine's reasoning shown rather than
/// just its ranking — the score is only trustworthy if you can see why.
struct RecommendationsPanel: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Panel(
            title: "Work on next",
            subtitle: "Composite impact: PageRank, betweenness, blockers, staleness, priority"
        ) {
            let recommendations = store.triage.recommendations
            if recommendations.isEmpty {
                unavailable
            } else {
                VStack(spacing: 8) {
                    ForEach(recommendations.prefix(5)) { rec in
                        RecommendationRow(recommendation: rec)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        if store.phase2InFlight {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scoring…").font(.caption).foregroundStyle(.secondary)
            }
        } else if !store.metrics.hasPhase2Values {
            // Recommendations are derived from Phase-2 scores, so an
            // un-computed graph yields no ranking rather than a wrong one.
            VStack(alignment: .leading, spacing: 6) {
                Text("Recommendations need the full graph metrics.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Compute metrics") { Task { await store.computePhase2() } }
                    .buttonStyle(.link).font(.caption)
            }
        } else {
            Text("Nothing is actionable right now.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RecommendationRow: View {
    @EnvironmentObject var store: ProjectStore
    let recommendation: Recommendation
    @State private var showReasons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                store.select(id: recommendation.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: recommendation.status.symbolName)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(recommendation.id).font(.caption.monospaced())
                    Text(recommendation.title).font(.callout).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f", recommendation.score))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.orange)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !recommendation.action.isEmpty {
                Text(recommendation.action)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if !recommendation.unblocksIDs.isEmpty {
                    Label("unblocks \(recommendation.unblocksIDs.count)", systemImage: "lock.open")
                        .font(.caption2).foregroundStyle(.blue)
                }
                if !recommendation.blockedBy.isEmpty {
                    Label("blocked by \(recommendation.blockedBy.count)", systemImage: "lock")
                        .font(.caption2).foregroundStyle(.red)
                }
                if !recommendation.reasons.isEmpty {
                    Button(showReasons ? "hide why" : "why?") { showReasons.toggle() }
                        .buttonStyle(.link).font(.caption2)
                }
                Spacer()
            }

            if showReasons {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recommendation.reasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Cheap tasks with disproportionate downstream effect.
struct QuickWinsPanel: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Panel(title: "Quick wins", subtitle: "Small effort, large unblocking effect") {
            let wins = store.triage.quickWins
            if wins.isEmpty {
                Text("No quick wins identified.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(wins.prefix(6)) { win in
                        Button {
                            store.select(id: win.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(win.id).font(.caption.monospaced())
                                Text(win.title).font(.caption).lineLimit(1)
                                Spacer()
                                if !win.unblocksIDs.isEmpty {
                                    Text("↓\(win.unblocksIDs.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.blue)
                                        .help("Unblocks \(win.unblocksIDs.joined(separator: ", "))")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(win.reason)
                    }
                }
            }
        }
    }
}

/// The things holding the most work up.
struct BlockersPanel: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Panel(title: "Blockers to clear", subtitle: "Ranked by downstream work released") {
            let blockers = store.triage.blockersToClear
            if blockers.isEmpty {
                Text("Nothing is blocking downstream work.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(blockers.prefix(6)) { blocker in
                        Button {
                            store.select(id: blocker.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(
                                    systemName: blocker.actionable
                                        ? "bolt.fill" : "lock.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(blocker.actionable ? .yellow : .red)
                                .help(
                                    blocker.actionable
                                        ? "Can be worked on now"
                                        : "Itself blocked by \(blocker.blockedBy.joined(separator: ", "))")

                                Text(blocker.id).font(.caption.monospaced())
                                Text(blocker.title).font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(blocker.unblocksCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
