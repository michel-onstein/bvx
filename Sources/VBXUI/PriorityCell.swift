import VBXAppCore
import VBXCore
import SwiftUI

/// A bead's priority, editable by double-clicking it.
///
/// The picker is the small part. The write behind it goes through `br` — see
/// ``BeadWriter`` for why nothing here may touch the JSONL — and it is the
/// first time vbx changes bead data at all, so the states where it must refuse
/// are as much of the design as the states where it works.
struct PriorityCell: View {
    let issue: Issue

    /// Handed in, never read from the environment.
    ///
    /// A `Table` cell is not an ordinary child view: SwiftUI hosts each cell's
    /// body in a subgraph of its own, and when the row set changes — a search
    /// keystroke, a filter, a reload after a write — the cell is re-evaluated
    /// in a subgraph that no longer carries the ancestors' environment
    /// objects. `@EnvironmentObject` there is not "occasionally stale", it
    /// traps: *No ObservableObject of type ProjectStore found*, on the main
    /// thread, during layout. It survived review because the first render is
    /// fine; only the second one crashes.
    ///
    /// This is also why the other columns in ``IssueListView`` read `store`
    /// from the enclosing view rather than through a cell of their own. A
    /// stored reference cannot go missing, so the popover and its write are
    /// covered by the same change — a popover gets a fresh environment too.
    @ObservedObject var store: ProjectStore

    @State private var isPicking = false
    @State private var isWriting = false

    /// bv's range. Beyond P4 is backlog, and `br` rejects it.
    private static let priorities = 0...4

    var body: some View {
        Text(issue.priorityLabel)
            .monospacedDigit()
            .foregroundStyle(issue.priority <= 1 ? .primary : .secondary)
            // The whole cell is the target, not just the two glyphs: a 30pt
            // column is already a small thing to hit twice.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isWriting ? 0.4 : 1)
            .onTapGesture(count: 2) {
                guard store.canEditBeads else { return }
                isPicking = true
            }
            .help(store.editingUnavailableReason ?? "Double-click to change the priority")
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                picker
            }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Priority")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            ForEach(Self.priorities, id: \.self) { value in
                Button {
                    apply(value)
                } label: {
                    HStack(spacing: 8) {
                        // A checkmark rather than only a highlight: which one
                        // is current has to survive the popover's own
                        // selection styling.
                        Image(systemName: value == issue.priority ? "checkmark" : "")
                            .frame(width: 12)
                        Text("P\(value)")
                            .monospacedDigit()
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 120)
    }

    private func apply(_ value: Int) {
        isPicking = false
        guard value != issue.priority else { return }
        isWriting = true
        Task {
            await store.setPriority(value, for: issue.id)
            isWriting = false
        }
    }
}
