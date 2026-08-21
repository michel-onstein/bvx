import VBXAppCore
import VBXCore
import SwiftUI

/// Dependency outline. Each root is an unblocked bead; children are the beads
/// waiting on it, so expanding walks *downstream* through the graph.
struct TreeView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            ForEach(roots) { issue in
                TreeRow(
                    issue: issue,
                    depth: 0,
                    expanded: $expanded,
                    visited: [issue.id]
                )
            }
        }
        .listStyle(.inset)
        .overlay {
            if roots.isEmpty {
                EmptyStateView(
                    symbol: "list.bullet.indent",
                    title: "Nothing to show",
                    message: "No beads match the current filter."
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Expand All") { expanded = Set(store.issues.map(\.id)) }
                Button("Collapse All") { expanded.removeAll() }
            }
        }
    }

    /// Roots are beads nothing in the visible set blocks — the natural entry
    /// points of each dependency chain.
    private var roots: [Issue] {
        let visible = store.visibleIssues
        let visibleIDs = Set(visible.map(\.id))
        return visible.filter { issue in
            store.metrics.blockedBy(issue.id) == 0
                || !issue.blockingDependencies.contains { visibleIDs.contains($0.dependsOnID) }
        }
    }
}

struct TreeRow: View {
    @EnvironmentObject var store: ProjectStore
    let issue: Issue
    let depth: Int
    @Binding var expanded: Set<String>
    /// Ids already on this path, so a dependency cycle cannot recurse forever.
    let visited: Set<String>

    private var children: [Issue] {
        store.dependents(of: issue).filter { !visited.contains($0.id) }
    }

    private var isExpanded: Bool { expanded.contains(issue.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)

                if children.isEmpty {
                    Color.clear.frame(width: 14)
                } else {
                    Button {
                        if isExpanded { expanded.remove(issue.id) } else { expanded.insert(issue.id) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: issue.status.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(issue.title).lineLimit(1)

                if store.actionable.contains(issue.id) {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Spacer()
                if !children.isEmpty {
                    Text("\(children.count)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("Beads waiting on this one")
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { store.select(id: issue.id) }
            .background(
                store.isSelected(issue.id)
                    ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )

            if isExpanded {
                ForEach(children) { child in
                    TreeRow(
                        issue: child,
                        depth: depth + 1,
                        expanded: $expanded,
                        visited: visited.union([child.id])
                    )
                }
            }
        }
    }
}
