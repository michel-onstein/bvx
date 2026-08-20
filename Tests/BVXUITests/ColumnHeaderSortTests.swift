import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

private typealias Bead = BVXCore.Issue

/// The bridge between the table's comparator-array sort binding and the
/// store's single sort value.
///
/// If this mapping loses anything, the header chevron and bv's `s` cycle end
/// up describing different orders — the failure the bead calls out.
@MainActor
@Suite("Column header sorting")
struct ColumnHeaderSortTests {

    @Test("Every column's comparator maps back to that same column")
    func comparatorRoundTrip() throws {
        for column in SortColumn.allCases {
            for ascending in [true, false] {
                let comparator = try #require(
                    IssueRow.comparator(for: column, ascending: ascending),
                    "no comparator for \(column)")
                #expect(IssueRow.column(of: comparator) == column, "\(column) did not round-trip")
                #expect(
                    (comparator.order == .forward) == ascending,
                    "\(column) lost its direction")
            }
        }
    }

    @Test("A row copies the engine's numbers rather than recomputing them")
    func rowCarriesEngineValues() {
        var metrics = GraphMetrics.empty
        metrics.inDegree = ["x": 4]
        metrics.outDegree = ["x": 2]
        metrics.pageRank = ["x": 0.25]

        let row = IssueRow(
            issue: Issue(id: "x", title: "Thing", status: .open, priority: 1),
            metrics: metrics)

        #expect(row.blocks == 4)
        #expect(row.blockedBy == 2)
        #expect(row.pageRank == 0.25)
        #expect(row.id == "x")
    }

    @Test("A row with no PageRank keeps it absent, not zero")
    func absentMetricStaysAbsent() {
        let row = IssueRow(
            issue: Issue(id: "x", title: "Thing", status: .open, priority: 1),
            metrics: .empty)
        // The cell renders the metric's status from this; a zero here would
        // render as a real score of 0.0000.
        #expect(row.pageRank == nil)
        // The comparator still needs a value, but it is only ever consulted
        // once the gate has let a PageRank sort through.
        #expect(row.pageRankKey == 0)
    }

    @Test("A header click drives the store's sort, and the store drives the chevron")
    func headerAndStoreAgree() async {
        let store = await Fixture.loadedStore()

        // What a click on the Title header writes.
        store.query.sort = .ordering(by: .title, ascending: true)
        #expect(store.query.sort == .titleAscending)

        // What the header chevron then reads back.
        let column = store.query.sort.column
        #expect(column == .title)
        #expect(store.query.sort.ascending)

        // And the list really is in that order.
        let titles = store.visibleIssues.map { $0.title.lowercased() }
        #expect(titles == titles.sorted())

        await store.close()
    }

    @Test("The list is ordered by whichever column the sort names")
    func listFollowsColumn() async {
        let store = await Fixture.loadedStore()

        store.query.sort = .ordering(by: .id, ascending: true)
        let ascending = store.visibleIssues.map(\Bead.id)
        store.query.sort = .ordering(by: .id, ascending: false)
        let descending = store.visibleIssues.map(\Bead.id)

        #expect(ascending == ascending.sorted())
        #expect(descending == ascending.reversed())

        await store.close()
    }

    @Test("The issue list renders with a column sort applied")
    func rendersSortedList() async throws {
        let store = await Fixture.loadedStore()
        store.query.sort = .ordering(by: .blocks, ascending: false)

        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "list-sorted-by-blocks",
            size: CGSize(width: 1100, height: 600)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }
}
