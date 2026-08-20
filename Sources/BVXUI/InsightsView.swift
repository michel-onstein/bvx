import BVXAppCore
import BVXCore
import Charts
import SwiftUI

/// Metric dashboard. Every panel that depends on Phase 2 shows its metric
/// status instead of pretending an uncomputed value is zero.
struct InsightsView: View {
    @EnvironmentObject var store: ProjectStore

    /// Panels vary a lot in height, so they are laid out as balanced columns
    /// rather than in a `LazyVGrid`. A grid aligns rows, which makes every row
    /// as tall as its tallest card and leaves large dead gaps beside the long
    /// recommendations panel.
    private var panels: [(id: String, view: AnyView)] {
        [
            ("recommendations", AnyView(RecommendationsPanel())),
            ("health", AnyView(HealthPanel())),
            ("quick-wins", AnyView(QuickWinsPanel())),
            ("blockers", AnyView(BlockersPanel())),
            ("status", AnyView(StatusBreakdownPanel())),
            (
                "pagerank",
                AnyView(
                    MetricPanel(
                        title: "Foundational blockers",
                        subtitle: "PageRank — recursive dependency authority",
                        values: store.metrics.pageRank,
                        status: store.metrics.status?.pageRank,
                        format: { String(format: "%.4f", $0) }
                    ))
            ),
            (
                "betweenness",
                AnyView(
                    MetricPanel(
                        title: "Bottlenecks",
                        subtitle: "Betweenness — traffic across shortest paths",
                        values: store.metrics.betweenness,
                        status: store.metrics.status?.betweenness,
                        format: { String(format: "%.3f", $0) }
                    ))
            ),
            (
                "critical",
                AnyView(
                    MetricPanel(
                        title: "Critical path",
                        subtitle: "Longest downstream dependency chain",
                        values: store.metrics.criticalPath,
                        status: store.metrics.status?.critical,
                        format: { String(format: "%.2f", $0) }
                    ))
            ),
            ("structure", AnyView(StructurePanel())),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let columnCount = max(1, min(3, Int(geo.size.width / 340)))
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        VStack(spacing: 14) {
                            ForEach(panelsIn(column: column, of: columnCount), id: \.id) { panel in
                                panel.view
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(14)
            }
        }
        .background(.background.secondary)
    }

    /// Round-robin assignment keeps the columns close to equal length without
    /// needing to measure rendered heights.
    private func panelsIn(column: Int, of total: Int) -> [(id: String, view: AnyView)] {
        panels.enumerated()
            .filter { $0.offset % total == column }
            .map(\.element)
    }
}

/// Shared card chrome.
struct Panel<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

struct HealthPanel: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Panel(title: "Project health", subtitle: "Counts and graph shape") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    stat("Beads", "\(store.issues.count)")
                    stat("Ready", "\(store.actionable.count)")
                }
                GridRow {
                    stat("Nodes", "\(store.metrics.nodeCount)")
                    stat("Edges", "\(store.metrics.edgeCount)")
                }
                GridRow {
                    stat("Density", String(format: "%.4f", store.metrics.density))
                    stat("Tracks", "\(store.plan.tracks.count)")
                }
            }
            if let cycles = store.metrics.cycles, !cycles.isEmpty {
                Label("\(cycles.count) dependency cycle(s) detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct StatusBreakdownPanel: View {
    @EnvironmentObject var store: ProjectStore

    private var counts: [(status: IssueStatus, count: Int)] {
        var dict: [IssueStatus: Int] = [:]
        for issue in store.issues { dict[issue.status, default: 0] += 1 }
        return dict.map { (status: $0.key, count: $0.value) }
            .sorted { $0.status.sortOrder < $1.status.sortOrder }
    }

    var body: some View {
        Panel(title: "Status breakdown", subtitle: "Every bead by lifecycle state") {
            Chart(counts, id: \.status.rawValue) { entry in
                BarMark(
                    x: .value("Count", entry.count),
                    y: .value("Status", entry.status.displayName)
                )
                .annotation(position: .trailing) {
                    Text("\(entry.count)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: max(CGFloat(counts.count) * 26, 80))
            .accessibilityLabel("Bead count by status")
        }
    }
}

/// Top-N by a Phase-2 metric, or an honest explanation of why there is no list.
struct MetricPanel: View {
    @EnvironmentObject var store: ProjectStore
    let title: String
    let subtitle: String
    let values: [String: Double]?
    let status: MetricStatusEntry?
    let format: (Double) -> String

    private var top: [(id: String, value: Double)] {
        guard let values else { return [] }
        return values.sorted { $0.value > $1.value }
            .prefix(6)
            .map { (id: $0.key, value: $0.value) }
    }

    var body: some View {
        Panel(title: title, subtitle: subtitle) {
            if let entry = status, !entry.state.isUsable {
                unavailable(entry)
            } else if top.isEmpty {
                if store.phase2InFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Computing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Compute metrics") { Task { await store.computePhase2() } }
                        .buttonStyle(.link).font(.caption)
                }
            } else {
                if let entry = status, entry.state == .approx, let note = entry.annotation {
                    Label(note, systemImage: "tildecircle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                VStack(spacing: 3) {
                    ForEach(top, id: \.id) { row in
                        Button {
                            store.select(id: row.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(row.id).font(.caption.monospaced())
                                Text(store.issuesByID[row.id]?.title ?? "")
                                    .font(.caption).lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(format(row.value))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private func unavailable(_ entry: MetricStatusEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.annotation ?? entry.state.displayName, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("No value is shown rather than a misleading zero.")
                .font(.caption2).foregroundStyle(.tertiary)
            if entry.state == .timeout || entry.state == .skipped {
                Button("Compute anyway") { Task { await store.computePhase2() } }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct StructurePanel: View {
    @EnvironmentObject var store: ProjectStore

    private var mostBlocking: [(id: String, count: Int)] {
        store.metrics.inDegree
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { (id: $0.key, count: $0.value) }
    }

    var body: some View {
        Panel(
            title: "Most blocking",
            subtitle: "Direct dependents — available immediately (Phase 1)"
        ) {
            if mostBlocking.isEmpty {
                Text("No blocking dependencies in this set.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(mostBlocking, id: \.id) { row in
                    BarMark(
                        x: .value("Blocks", row.count),
                        y: .value("Bead", row.id)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartXAxis(.hidden)
                .frame(height: max(CGFloat(mostBlocking.count) * 24, 70))
                .accessibilityLabel("Beads ranked by how many others they block")
            }
        }
    }
}
