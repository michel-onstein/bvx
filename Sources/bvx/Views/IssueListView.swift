import BVXAppCore
import BVXCore
import SwiftUI

/// Native sortable table. Metric columns render a placeholder rather than a
/// zero until Phase 2 lands.
struct IssueListView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Table(store.visibleIssues, selection: $store.selection) {
            TableColumn("ID") { issue in
                Text(issue.id).monospaced().font(.callout)
            }
            .width(min: 70, ideal: 96, max: 160)

            TableColumn("") { issue in
                Image(systemName: issue.type.symbolName)
                    .foregroundStyle(.secondary)
                    .help(issue.type.displayName)
            }
            .width(22)

            TableColumn("Title") { issue in
                HStack(spacing: 6) {
                    Text(issue.title).lineLimit(1)
                    if store.actionable.contains(issue.id) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Actionable now")
                    }
                }
            }
            .width(min: 200, ideal: 360)

            TableColumn("Status") { issue in
                StatusChip(status: issue.status)
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("P") { issue in
                Text(issue.priorityLabel)
                    .monospacedDigit()
                    .foregroundStyle(issue.priority <= 1 ? .primary : .secondary)
            }
            .width(30)

            TableColumn("Blocks") { issue in
                let n = store.metrics.blocks(issue.id)
                Text(n == 0 ? "—" : "\(n)")
                    .monospacedDigit()
                    .foregroundStyle(n > 0 ? .primary : .tertiary)
                    .help("Issues that depend on this one")
            }
            .width(52)

            TableColumn("Blocked by") { issue in
                let n = store.metrics.blockedBy(issue.id)
                Text(n == 0 ? "—" : "\(n)")
                    .monospacedDigit()
                    .foregroundStyle(n > 0 ? .primary : .tertiary)
            }
            .width(74)

            TableColumn("PageRank") { issue in
                MetricCell(
                    value: store.metrics.pageRank?[issue.id],
                    status: store.metrics.status?.pageRank,
                    format: { String(format: "%.4f", $0) }
                )
            }
            .width(min: 76, ideal: 86, max: 120)

            TableColumn("Labels") { issue in
                Text(issue.labels.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Updated") { issue in
                Text(issue.updatedAt.map { Self.relative.localizedString(for: $0, relativeTo: .now) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if store.visibleIssues.isEmpty {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No matching beads",
                    message: store.query.searchText.isEmpty
                        ? "No beads match the \(store.query.filter.displayName.lowercased()) filter."
                        : "No beads match “\(store.query.searchText)”."
                )
            }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Renders a Phase-2 value, or *why* there isn't one. Never shows a bare 0.
struct MetricCell: View {
    let value: Double?
    let status: MetricStatusEntry?
    var format: (Double) -> String

    var body: some View {
        if let value {
            HStack(spacing: 3) {
                Text(format(value)).monospacedDigit()
                if let entry = status, entry.state == .approx {
                    Image(systemName: "tildecircle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(entry.annotation ?? "approximate")
                }
            }
        } else {
            Text(placeholder)
                .foregroundStyle(.tertiary)
                .help(status?.annotation ?? "Not computed yet")
        }
    }

    private var placeholder: String {
        switch status?.state {
        case .timeout: "timeout"
        case .skipped: "skipped"
        case .none, .pending: "—"
        default: "—"
        }
    }
}

struct StatusChip: View {
    let status: IssueStatus

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Colour is never the only signal — the SF Symbol carries the same
    /// meaning for colour-blind users and in monochrome.
    private var tint: Color {
        switch status {
        case .open: .blue
        case .inProgress: .orange
        case .blocked: .red
        case .review: .purple
        case .deferred, .draft: .gray
        case .pinned, .hooked: .teal
        case .closed: .green
        case .tombstone: .secondary
        case .unknown: .secondary
        }
    }
}
