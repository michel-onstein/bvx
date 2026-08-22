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
    /// Handed in rather than read from the environment, and that is load-bearing.
    ///
    /// `Table` builds a cell's subgraph when the row scrolls into view, and
    /// that subgraph does not carry the `environmentObject` injected around
    /// `ContentView` — so an `@EnvironmentObject` here resolves for the rows
    /// present at first layout and traps on the first row created afterwards.
    /// It looked fine on any workspace small enough to fit on screen and
    /// crashed on the first scroll of one that did not. Every other column
    /// captures ``IssueListView``'s store in its cell closure; this is the same
    /// thing, made explicit because the cell is its own `View`.
    @ObservedObject var store: ProjectStore
    let issue: Issue

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
