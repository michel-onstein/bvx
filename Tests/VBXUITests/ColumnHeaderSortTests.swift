import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

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

/// The order the table declares its columns in.
///
/// SwiftUI's `Table` builds its columns from a result builder, and the built
/// value exposes no list of headers to inspect, so there is nothing to assert
/// against at runtime. Reading the source is the only way to pin the order —
/// and the order is exactly the kind of thing an unrelated edit reshuffles
/// without anyone noticing.
@Suite("Table column order")
struct TableColumnOrderTests {

    /// Headers in declaration order, read from `IssueListView.swift`.
    private static func declaredColumns() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VBXUI/IssueListView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        var headers: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TableColumn(\"") else { continue }
            let afterQuote = trimmed.dropFirst("TableColumn(\"".count)
            guard let close = afterQuote.firstIndex(of: "\"") else { continue }
            headers.append(String(afterQuote[afterQuote.startIndex..<close]))
        }
        return headers
    }

    @Test("Priority is the column immediately after ID")
    func priorityFollowsID() throws {
        let headers = try Self.declaredColumns()
        let id = try #require(headers.firstIndex(of: "ID"), "no ID column found")
        let priority = try #require(headers.firstIndex(of: "P"), "no priority column found")
        #expect(
            priority == id + 1,
            "priority must follow ID directly; got \(headers)")
    }

    @Test("The columns the view is built from are all present")
    func columnsPresent() throws {
        let headers = try Self.declaredColumns()
        // Guards the parser itself: if it silently matched nothing, the order
        // assertion above would have nothing to fail on.
        #expect(headers.count >= 9, "parsed too few columns: \(headers)")
        for expected in ["ID", "P", "Title", "Status", "Labels", "Updated"] {
            #expect(headers.contains(expected), "\(expected) column missing from \(headers)")
        }
    }
}
