import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The priority cell is the one table cell that is a `View` of its own — it
/// needs `@State` for the popover — which made it the one cell that could read
/// the store from the environment. It cannot: a `Table` cell's subgraph loses
/// its ancestors' environment objects when the row set changes, and the read
/// traps rather than degrading. See `docs/project_notes/BUGS.md`.
///
/// Both tests here fail by **crashing** rather than by reporting, because that
/// is how the bug fails: `EnvironmentObject.wrappedValue` calls
/// `fatalError`. A test process that dies on this file is the regression.
@MainActor
@Suite("Priority cell")
struct PriorityCellTests {

    /// The reproduction: render the list, change the rows, lay out again.
    ///
    /// One keystroke into the search field was enough. The first render is
    /// always fine — which is why every existing snapshot test passed while
    /// the app crashed within seconds of use — so the second layout, after a
    /// mutation, is the whole point of the test.
    @Test("Changing the row set does not take the priority column down with it")
    func survivesRowSetChange() async throws {
        let store = await Fixture.loadedStore()
        let live = Snapshot.hosted(
            IssueListView().environmentObject(store),
            size: CGSize(width: 1000, height: 520))
        live.settle()

        // A search that matches something, one that matches nothing, and a
        // filter change: three different ways for the table to rebuild rows.
        for text in ["a", "", "no-bead-has-this-in-its-title"] {
            store.query.searchText = text
            live.settle(0.1)
        }
        store.query.searchText = ""
        for filter in IssueFilter.allCases {
            store.query.filter = filter
            live.settle(0.1)
        }
        store.query.filter = .all

        live.settle()
        let result = try Snapshot.capture(live, name: "issue-list-after-row-churn")
        #expect(
            result.inkCoverage() > 0.015,
            "list looks blank after the row set changed (ink \(result.inkCoverage()))")
        await store.close()
    }

    /// The invariant, stated directly: nothing in this cell may come from the
    /// environment. Hosted with no `environmentObject` at all, so reaching for
    /// one is fatal.
    @Test("The priority cell renders with nothing in the environment")
    func needsNothingFromTheEnvironment() async throws {
        let store = await Fixture.loadedStore()
        let issue = try #require(store.visibleIssues.first)

        let result = try Snapshot.render(
            PriorityCell(issue: issue, store: store).padding(4),
            name: "priority-cell",
            size: CGSize(width: 60, height: 26)
        )
        #expect(
            result.inkCoverage() > 0.02,
            "priority label did not draw (ink \(result.inkCoverage()))")
        await store.close()
    }
}
