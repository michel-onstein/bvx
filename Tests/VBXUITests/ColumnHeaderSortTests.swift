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

/// The identifiers that persist a user's column layout.
///
/// Read from source for the same reason as the order above: SwiftUI's `Table`
/// exposes no list of its columns to inspect at runtime. These identifiers are
/// a storage contract — they are already in users' preferences once shipped —
/// so a duplicate or a rename is a silent data problem, not a compile error.
@Suite("Column customization IDs")
struct ColumnCustomizationTests {

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VBXUI/IssueListView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.customizationID(...)` argument, in declaration order.
    private static func customizationIDs() throws -> [String] {
        try source()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".customizationID(") }
            .map { line in
                let inner = line.dropFirst(".customizationID(".count).dropLast()
                return String(inner)
            }
    }

    @Test("Every column carries a customization ID")
    func everyColumnHasAnID() throws {
        let columns = try Self.source()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("TableColumn(\"") }
        let ids = try Self.customizationIDs()

        // A column without one cannot be hidden, reordered, or remembered —
        // it silently opts out of the whole feature.
        #expect(
            ids.count == columns.count,
            "\(columns.count) columns but \(ids.count) customization IDs")
    }

    @Test("No two columns share a customization ID")
    func idsAreUnique() throws {
        let ids = try Self.customizationIDs()
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }

        // The bug this caught in review: PageRank was given the `blocks`
        // identifier, so hiding one would have acted on the other and both
        // would have shared a saved width.
        #expect(duplicates.isEmpty, "duplicated customization IDs: \(duplicates.keys.sorted())")
    }

    @Test("IDs come from SortColumn rather than being written out twice")
    func idsAreDerivedFromSortColumn() throws {
        let ids = try Self.customizationIDs()
        // Only the type glyph has no ordering and so no SortColumn case.
        let literals = ids.filter { !$0.hasPrefix("SortColumn.") }
        #expect(
            literals == ["\"type\""],
            "unexpected hand-written IDs \(literals); derive them from SortColumn")
    }

    @Test("The identifier and the type glyph cannot be hidden")
    func essentialColumnsAreNotHideable() throws {
        let text = try Self.source()
        // Every bead link, context menu and URL is keyed by the id; the glyph
        // column is headerless and would list as a blank menu row. Both are
        // deliberately exempt, and a later tidy-up must not quietly re-enable
        // them.
        let exemptions = text.components(separatedBy: ".disabledCustomizationBehavior(.visibility)")
            .count - 1
        #expect(exemptions == 2, "expected exactly 2 non-hideable columns, found \(exemptions)")
    }
}
