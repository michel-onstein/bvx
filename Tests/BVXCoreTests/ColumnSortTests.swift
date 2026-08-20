import Foundation
import Testing

@testable import BVXCore

private typealias Bead = BVXCore.Issue

/// Four beads whose every sortable field differs, so an ordering that ignores
/// its key produces a visibly wrong answer rather than a coincidentally
/// right one.
private func beads() -> [Bead] {
    [
        Issue(
            id: "a", title: "Zulu loader", status: .closed, priority: 1,
            createdAt: .init(timeIntervalSince1970: 300),
            updatedAt: .init(timeIntervalSince1970: 900),
            labels: ["core"]),
        Issue(
            id: "b", title: "Alpha parser", status: .open, priority: 0,
            createdAt: .init(timeIntervalSince1970: 200),
            updatedAt: .init(timeIntervalSince1970: 400),
            labels: ["zeta"]),
        Issue(
            id: "c", title: "Mike docs", status: .inProgress, priority: 3,
            createdAt: .init(timeIntervalSince1970: 100),
            updatedAt: .init(timeIntervalSince1970: 100),
            labels: ["docs"]),
        Issue(
            id: "d", title: "Bravo widget", status: .blocked, priority: 2,
            createdAt: .init(timeIntervalSince1970: 500),
            updatedAt: .init(timeIntervalSince1970: 1000),
            labels: ["mid"]),
    ]
}

/// Degrees and PageRank the engine would supply. `blocks` is in-degree,
/// `blockedBy` is out-degree.
private func metricsFixture(withPageRank: Bool = true) -> GraphMetrics {
    var m = GraphMetrics.empty
    m.inDegree = ["a": 3, "b": 1, "c": 0, "d": 2]
    m.outDegree = ["a": 0, "b": 2, "c": 3, "d": 1]
    if withPageRank {
        m.pageRank = ["a": 0.10, "b": 0.40, "c": 0.20, "d": 0.30]
    }
    return m
}

private func ids(
    _ column: SortColumn, ascending: Bool, metrics: GraphMetrics? = metricsFixture()
) -> [String] {
    IssueQuery(filter: .all, sort: .ordering(by: column, ascending: ascending))
        .apply(to: beads(), metrics: metrics)
        .map(\Bead.id)
}

// MARK: - One ordering per column

@Test("Ordering by id follows the id")
func sortByID() {
    #expect(ids(.id, ascending: true) == ["a", "b", "c", "d"])
    #expect(ids(.id, ascending: false) == ["d", "c", "b", "a"])
}

@Test("Ordering by title is case-insensitive and alphabetical")
func sortByTitle() {
    // Alpha, Bravo, Mike, Zulu
    #expect(ids(.title, ascending: true) == ["b", "d", "c", "a"])
    #expect(ids(.title, ascending: false) == ["a", "c", "d", "b"])
}

@Test("Ordering by status follows the workflow, not the alphabet")
func sortByStatus() {
    // open < in progress < blocked < closed. Alphabetically it would be
    // blocked, closed, in_progress, open — which is not what sorting a work
    // queue by status means.
    #expect(ids(.status, ascending: true) == ["b", "c", "d", "a"])
}

@Test("Ordering by priority puts P0 first")
func sortByPriority() {
    #expect(ids(.priority, ascending: true) == ["b", "a", "d", "c"])
    #expect(ids(.priority, ascending: false) == ["c", "d", "a", "b"])
}

@Test("Ordering by blocks uses the engine's in-degree")
func sortByBlocks() {
    #expect(ids(.blocks, ascending: false) == ["a", "d", "b", "c"])
    #expect(ids(.blocks, ascending: true) == ["c", "b", "d", "a"])
}

@Test("Ordering by blocked-by uses the engine's out-degree")
func sortByBlockedBy() {
    #expect(ids(.blockedBy, ascending: false) == ["c", "b", "d", "a"])
}

@Test("Ordering by PageRank uses the engine's scores")
func sortByPageRank() {
    #expect(ids(.pageRank, ascending: false) == ["b", "d", "c", "a"])
    #expect(ids(.pageRank, ascending: true) == ["a", "c", "d", "b"])
}

@Test("Ordering by labels is alphabetical")
func sortByLabels() {
    // core, docs, mid, zeta
    #expect(ids(.labels, ascending: true) == ["a", "c", "d", "b"])
    #expect(ids(.labels, ascending: false) == ["b", "d", "c", "a"])
}

@Test("Ordering by created and updated follows the timestamps")
func sortByDates() {
    #expect(ids(.created, ascending: true) == ["c", "b", "a", "d"])
    #expect(ids(.updated, ascending: false) == ["d", "a", "b", "c"])
}

// MARK: - The Phase-2 gate

@Test("A metric ordering is inert while its values are absent")
func metricSortInertBeforePhase2() {
    let before = ids(.pageRank, ascending: false, metrics: metricsFixture(withPageRank: false))
    // Untouched input order, not an order over absent values.
    #expect(before == ["a", "b", "c", "d"])

    // With no metrics object at all, the same holds.
    #expect(ids(.pageRank, ascending: false, metrics: nil) == ["a", "b", "c", "d"])

    // And once the values land, it really does sort.
    #expect(ids(.pageRank, ascending: false) != before)
}

@Test("Only the PageRank column needs Phase 2")
func onlyPageRankNeedsPhase2() {
    for column in SortColumn.allCases {
        #expect(column.requiresPhase2 == (column == .pageRank), "wrong gate on \(column)")
    }
}

// MARK: - Header state and sort mode agree

@Test("Every column and direction round-trips through a sort mode")
func orderingRoundTrip() {
    // This is what keeps a header click and bv's `s` cycle from disagreeing
    // about the current order: both read and write one value, and the mapping
    // between them loses nothing.
    for column in SortColumn.allCases {
        for ascending in [true, false] {
            let mode = SortMode.ordering(by: column, ascending: ascending)
            #expect(mode.column == column, "\(mode) lost its column")
            #expect(mode.ascending == ascending, "\(mode) lost its direction")
        }
    }
}

@Test("Every sort mode except the default names a column")
func everyModeHasAColumn() {
    for mode in SortMode.allCases where mode != .default {
        #expect(mode.column != nil, "\(mode) has no column")
    }
    // The default sorts on two keys at once, so it deliberately names none.
    #expect(SortMode.default.column == nil)
}

@Test("The named cycle is a subset of all orderings and contains the default")
func cycleCasesAreNamedOrderings() {
    #expect(SortMode.cycleCases.first == .default)
    for mode in SortMode.cycleCases {
        #expect(SortMode.allCases.contains(mode), "\(mode) is not a real ordering")
    }
    // bv's cycle is six long; the extra column orderings live on the headers.
    #expect(SortMode.cycleCases.count == 6)
}

@Test("Impact is the mode that needs Phase 2, in both directions")
func impactRequiresPhase2() {
    #expect(SortMode.impact.requiresPhase2)
    #expect(SortMode.impactAscending.requiresPhase2)
    #expect(!SortMode.default.requiresPhase2)
    #expect(!SortMode.blocksDescending.requiresPhase2)
}

// MARK: - Stability

@Test("Rows with equal keys keep a stable order")
func tieBreakIsStable() {
    // Every bead here has the same priority, so only the id tie-break
    // separates them. Without it the order would drift between redraws.
    let tied = (1...4).map { Issue(id: "id-\($0)", title: "t", status: .open, priority: 2) }
    let result = IssueQuery(filter: .all, sort: .priority).apply(to: tied)
    #expect(result.map(\Bead.id) == ["id-1", "id-2", "id-3", "id-4"])
}
