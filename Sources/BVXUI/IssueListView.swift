import BVXAppCore
import BVXCore
import SwiftUI

/// Native sortable table. Metric columns render a placeholder rather than a
/// zero until Phase 2 lands.
///
/// Sorting is driven from ``ProjectStore/query``'s single `sort` value rather
/// than from table-local state. The toolbar menu, bv's `s` cycle and a header
/// click all write that one value, so the header chevron and the cycle can
/// never disagree about the current order.
struct IssueListView: View {
    @EnvironmentObject var store: ProjectStore

    /// Bridges SwiftUI's comparator-array sort binding to the store's ordering.
    ///
    /// Read: the store's mode becomes the comparator the header chevron draws.
    /// Written: the clicked column becomes a mode — unless it is a metric
    /// column whose values have not been computed, which is refused so the
    /// header cannot appear to sort by nothing.
    private var sortOrder: Binding<[KeyPathComparator<IssueRow>]> {
        Binding(
            get: {
                guard let column = store.query.sort.column,
                    let comparator = IssueRow.comparator(
                        for: column, ascending: store.query.sort.ascending)
                else { return [] }
                return [comparator]
            },
            set: { comparators in
                guard let first = comparators.first,
                    let column = IssueRow.column(of: first)
                else { return }
                let ascending = first.order == .forward
                guard !(column.requiresPhase2 && !store.metrics.hasPhase2Values) else { return }
                store.query.sort = .ordering(by: column, ascending: ascending)
            }
        )
    }

    private var rows: [IssueRow] {
        let metrics = store.metrics
        return store.visibleIssues.map { IssueRow(issue: $0, metrics: metrics) }
    }

    var body: some View {
        Table(rows, selection: $store.selection, sortOrder: sortOrder) {
            TableColumn("ID", value: \.id) { row in
                Text(row.issue.id).monospaced().font(.callout)
            }
            .width(min: 70, ideal: 96, max: 160)

            // The type glyph has no header to click and no useful ordering of
            // its own, so it stays an unsorted column.
            TableColumn("") { row in
                Image(systemName: row.issue.type.symbolName)
                    .foregroundStyle(.secondary)
                    .help(row.issue.type.displayName)
            }
            .width(22)

            TableColumn("Title", value: \.titleKey) { row in
                HStack(spacing: 6) {
                    // The badge leads the title while time travelling: it is
                    // the reason the row is interesting.
                    if let badge = store.badge(for: row.id) {
                        DiffBadgeView(badge: badge)
                    }
                    if let repo = store.repo(of: row.id) {
                        RepoBadge(repo: repo, isCrossRepo: store.isCrossRepo(row.id))
                    }
                    Text(row.issue.title).lineLimit(1)
                    if store.actionable.contains(row.id) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Actionable now")
                    }
                }
            }
            .width(min: 200, ideal: 360)

            TableColumn("Status", value: \.statusKey) { row in
                StatusChip(status: row.issue.status)
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("P", value: \.priority) { row in
                Text(row.issue.priorityLabel)
                    .monospacedDigit()
                    .foregroundStyle(row.issue.priority <= 1 ? .primary : .secondary)
            }
            .width(30)

            TableColumn("Blocks", value: \.blocks) { row in
                Text(row.blocks == 0 ? "—" : "\(row.blocks)")
                    .monospacedDigit()
                    .foregroundStyle(row.blocks > 0 ? .primary : .tertiary)
                    .help("Issues that depend on this one")
            }
            .width(52)

            TableColumn("Blocked by", value: \.blockedBy) { row in
                Text(row.blockedBy == 0 ? "—" : "\(row.blockedBy)")
                    .monospacedDigit()
                    .foregroundStyle(row.blockedBy > 0 ? .primary : .tertiary)
            }
            .width(74)

            // Sortable in the same way as the rest, but the binding refuses
            // the write until Phase 2 has values — see `sortOrder` above.
            TableColumn("PageRank", value: \.pageRankKey) { row in
                MetricCell(
                    value: row.pageRank,
                    status: store.metrics.status?.pageRank,
                    format: { String(format: "%.4f", $0) }
                )
            }
            .width(min: 76, ideal: 86, max: 120)

            TableColumn("Labels", value: \.labelsKey) { row in
                Text(row.issue.labels.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Updated", value: \.updatedKey) { row in
                Text(
                    row.issue.updatedAt.map {
                        Self.relative.localizedString(for: $0, relativeTo: .now)
                    } ?? "—"
                )
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

/// One table row: a bead, plus the engine values its columns sort on.
///
/// The wrapper exists because SwiftUI's sortable columns need a key path on
/// the row value, and the metrics live in the store rather than on `Issue`.
/// Nothing is computed here — every number is copied from the engine's
/// metrics, and `pageRank` stays optional so an absent value renders as its
/// status rather than as a zero.
struct IssueRow: Identifiable {
    let issue: Issue
    let blocks: Int
    let blockedBy: Int
    let pageRank: Double?

    var id: Issue.ID { issue.id }
    var priority: Int { issue.priority }

    // Sort keys. Lowercased for text so ordering is not case-split, and
    // defaulted for dates so a bead with no timestamp sorts oldest rather
    // than being dropped.
    var titleKey: String { issue.title.lowercased() }
    var statusKey: Int { issue.status.workflowRank }
    var labelsKey: String { issue.labels.joined(separator: ",").lowercased() }
    var createdKey: Date { issue.createdAt ?? .distantPast }
    var updatedKey: Date { issue.updatedAt ?? .distantPast }
    /// Absent PageRank sorts as zero *for the comparator only*; the binding
    /// refuses the sort outright until Phase 2 lands, so this is never the
    /// ordering the user actually sees.
    var pageRankKey: Double { pageRank ?? 0 }

    init(issue: Issue, metrics: GraphMetrics) {
        self.issue = issue
        self.blocks = metrics.blocks(issue.id)
        self.blockedBy = metrics.blockedBy(issue.id)
        self.pageRank = metrics.pageRank?[issue.id]
    }

    /// The comparator that renders `column` in the given direction.
    static func comparator(
        for column: SortColumn, ascending: Bool
    ) -> KeyPathComparator<IssueRow>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .id: return KeyPathComparator(\IssueRow.id, order: order)
        case .title: return KeyPathComparator(\IssueRow.titleKey, order: order)
        case .status: return KeyPathComparator(\IssueRow.statusKey, order: order)
        case .priority: return KeyPathComparator(\IssueRow.priority, order: order)
        case .blocks: return KeyPathComparator(\IssueRow.blocks, order: order)
        case .blockedBy: return KeyPathComparator(\IssueRow.blockedBy, order: order)
        case .pageRank: return KeyPathComparator(\IssueRow.pageRankKey, order: order)
        case .labels: return KeyPathComparator(\IssueRow.labelsKey, order: order)
        case .created: return KeyPathComparator(\IssueRow.createdKey, order: order)
        case .updated: return KeyPathComparator(\IssueRow.updatedKey, order: order)
        }
    }

    /// The column a comparator came from.
    ///
    /// Matching on the key path is what lets the header write back into the
    /// store's single sort value instead of into table-local state.
    static func column(of comparator: KeyPathComparator<IssueRow>) -> SortColumn? {
        switch comparator.keyPath {
        case \IssueRow.id: .id
        case \IssueRow.titleKey: .title
        case \IssueRow.statusKey: .status
        case \IssueRow.priority: .priority
        case \IssueRow.blocks: .blocks
        case \IssueRow.blockedBy: .blockedBy
        case \IssueRow.pageRankKey: .pageRank
        case \IssueRow.labelsKey: .labels
        case \IssueRow.createdKey: .created
        case \IssueRow.updatedKey: .updated
        default: nil
        }
    }
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
