import BVXAppCore
import BVXCore
import SwiftUI

/// Kanban board, one column per status, with per-column stats and rich cards.
struct BoardView: View {
    @EnvironmentObject var store: ProjectStore

    private var columns: [IssueStatus] {
        // Show the standard columns plus any non-standard status actually
        // present, so unusual beads are never invisible.
        let present = Set(store.visibleIssues.map(\.status))
        let extras = present.subtracting(IssueStatus.boardColumns)
            .sorted { $0.sortOrder < $1.sortOrder }
        return IssueStatus.boardColumns + extras
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.rawValue) { status in
                    BoardColumn(
                        status: status,
                        issues: store.visibleIssues.filter { $0.status == status }
                    )
                }
            }
            .padding(12)
        }
        .background(.background.secondary)
    }
}

struct BoardColumn: View {
    @EnvironmentObject var store: ProjectStore
    let status: IssueStatus
    let issues: [Issue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.symbolName)
                Text(status.displayName).font(.headline)
                Spacer()
                Text("\(issues.count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            if !issues.isEmpty {
                Text(columnSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { issue in
                        BoardCard(issue: issue)
                            .onTapGesture { store.selection = issue.id }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    /// Column stats: how much of this column is actionable, and total estimate.
    private var columnSubtitle: String {
        let ready = issues.filter { store.actionable.contains($0.id) }.count
        let minutes = issues.compactMap(\.estimatedMinutes).reduce(0, +)
        var parts: [String] = []
        if ready > 0 { parts.append("\(ready) ready") }
        if minutes > 0 { parts.append("~\(minutes / 60)h") }
        return parts.joined(separator: " · ")
    }
}

/// Four-line card: id + priority, title, labels, and dependency indicators.
struct BoardCard: View {
    @EnvironmentObject var store: ProjectStore
    let issue: Issue

    private var isSelected: Bool { store.selection == issue.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: issue.type.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if store.actionable.contains(issue.id) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2).foregroundStyle(.yellow)
                        .help("Actionable now")
                }
                Text(issue.priorityLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(issue.priority <= 1 ? .orange : .secondary)
            }

            Text(issue.title)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if issue.labels.count > 3 {
                        Text("+\(issue.labels.count - 3)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 10) {
                let blockedBy = store.metrics.blockedBy(issue.id)
                let blocks = store.metrics.blocks(issue.id)
                if blockedBy > 0 {
                    Label("\(blockedBy)", systemImage: "lock")
                        .font(.caption2).foregroundStyle(.red)
                        .help("Blocked by \(blockedBy)")
                }
                if blocks > 0 {
                    Label("\(blocks)", systemImage: "arrow.triangle.branch")
                        .font(.caption2).foregroundStyle(.blue)
                        .help("Blocks \(blocks)")
                }
                if let assignee = issue.assignee, !assignee.isEmpty {
                    Spacer()
                    Text(assignee).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
