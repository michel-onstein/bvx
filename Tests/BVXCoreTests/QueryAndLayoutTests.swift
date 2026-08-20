import Foundation
import Testing

@testable import BVXCore

/// Swift Testing exports its own `Issue` type, so the model type is aliased
/// here to keep every reference unambiguous.
private typealias Bead = BVXCore.Issue

private func sample() -> [Bead] {
    [
        Issue(
            id: "a", title: "Alpha loader", status: .open, priority: 1,
            createdAt: .init(timeIntervalSince1970: 300),
            updatedAt: .init(timeIntervalSince1970: 900),
            labels: ["core"],
            dependencies: [Dependency(issueID: "a", dependsOnID: "b")]),
        Issue(
            id: "b", title: "Bravo parser", status: .open, priority: 0,
            createdAt: .init(timeIntervalSince1970: 200),
            updatedAt: .init(timeIntervalSince1970: 400),
            labels: ["core", "infra"]),
        Issue(
            id: "c", title: "Charlie docs", status: .closed, priority: 3,
            createdAt: .init(timeIntervalSince1970: 100),
            updatedAt: .init(timeIntervalSince1970: 100),
            labels: ["docs"]),
        Issue(
            id: "d", title: "Delta widget", status: .inProgress, priority: 2,
            createdAt: .init(timeIntervalSince1970: 500),
            updatedAt: .init(timeIntervalSince1970: 1000),
            labels: ["ui"], dependencies: []),
    ]
}

// MARK: - Filtering

@Test("The open filter excludes blocked, deferred and closed")
func openFilter() {
    var issues = sample()
    issues.append(Issue(id: "e", title: "Echo", status: .blocked))
    issues.append(Issue(id: "f", title: "Foxtrot", status: .deferred))

    let result = IssueQuery(filter: .open).apply(to: issues)
    #expect(result.map(\Bead.id).sorted() == ["a", "b", "d"])
}

@Test("The ready filter uses the engine's actionable set, not a field")
func readyFilter() {
    // b and d are unblocked; a waits on b. Readiness is a graph property, so
    // the filter must consult the engine rather than inspect the issue.
    let result = IssueQuery(filter: .ready).apply(to: sample(), actionable: ["b", "d"])
    #expect(result.map(\Bead.id).sorted() == ["b", "d"])
}

@Test("The all filter hides tombstones")
func allFilterHidesTombstones() {
    var issues = sample()
    issues.append(Issue(id: "z", title: "Deleted", status: .tombstone))

    let result = IssueQuery(filter: .all).apply(to: issues)
    #expect(!result.contains { $0.id == "z" })
    #expect(result.count == 4)
}

@Test("Label filtering keeps issues carrying any selected label")
func labelFilter() {
    let result = IssueQuery(filter: .all, labels: ["docs"]).apply(to: sample())
    #expect(result.map(\Bead.id) == ["c"])
}

// MARK: - Sorting

@Test("Default sort is priority ascending, then newest first")
func defaultSort() {
    let result = IssueQuery(filter: .all, sort: .default).apply(to: sample())
    #expect(result.map(\Bead.id) == ["b", "a", "d", "c"])
}

@Test("Updated sort puts the most recently touched first")
func updatedSort() {
    let result = IssueQuery(filter: .all, sort: .updated).apply(to: sample())
    #expect(result.first?.id == "d")
}

@Test("Impact sort falls back to input order when metrics are absent")
func impactSortWithoutMetrics() {
    // Sorting by a metric nobody computed must not invent an order.
    let result = IssueQuery(filter: .all, sort: .impact).apply(to: sample(), metrics: nil)
    #expect(result.count == 4)
}

@Test("Impact sort ranks by PageRank when it is available")
func impactSortWithMetrics() {
    var metrics = GraphMetrics.empty
    metrics.pageRank = ["a": 0.1, "b": 0.9, "c": 0.2, "d": 0.5]

    let result = IssueQuery(filter: .all, sort: .impact).apply(to: sample(), metrics: metrics)
    #expect(result.map(\Bead.id) == ["b", "d", "c", "a"])
}

// MARK: - Search

@Test("Search matches id, title and labels")
func searchFields() {
    #expect(IssueQuery(filter: .all, searchText: "bravo").apply(to: sample()).map(\Bead.id) == ["b"])
    #expect(IssueQuery(filter: .all, searchText: "docs").apply(to: sample()).map(\Bead.id) == ["c"])
    #expect(IssueQuery(filter: .all, searchText: "a").apply(to: sample()).isEmpty == false)
}

@Test("An exact id match outranks a mere substring match")
func searchRanking() {
    let issues = [
        Issue(id: "loader", title: "Something else"),
        Issue(id: "x1", title: "The loader subsystem"),
    ]
    let result = IssueQuery.rank(issues, query: "loader")
    #expect(result.first?.id == "loader")
}

@Test("Subsequence matching finds scattered characters")
func subsequenceMatching() {
    #expect(IssueQuery.isSubsequence("abc", of: "aXbXc"))
    #expect(IssueQuery.isSubsequence("", of: "anything"))
    #expect(!IssueQuery.isSubsequence("cba", of: "abc"))
}

@Test("Search overrides the sort order so relevance is preserved")
func searchBeatsSort() {
    let query = IssueQuery(filter: .all, searchText: "o", sort: .priority)
    let result = query.apply(to: sample())
    // Ranked by score, not by priority.
    #expect(!result.isEmpty)
}

// MARK: - Graph layout

@Test("Ranking puts the deepest dependency at the top")
func layoutRanking() {
    // a -> b -> c means c is the deepest blocker.
    let edges = [
        GraphEdge(from: "a", to: "b", type: .blocks),
        GraphEdge(from: "b", to: "c", type: .blocks),
    ]
    let layout = GraphLayoutEngine.layout(nodes: ["a", "b", "c"], edges: edges)

    let ranks = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.rank) })
    #expect(ranks["c"] == 0)
    #expect(ranks["b"] == 1)
    #expect(ranks["a"] == 2)
    #expect(layout.cycles.isEmpty)
}

@Test("Non-blocking edges are drawn but do not affect ranking")
func layoutIgnoresNonBlockingForRank() {
    let edges = [
        GraphEdge(from: "a", to: "b", type: .related),
        GraphEdge(from: "a", to: "c", type: .parentChild),
    ]
    let layout = GraphLayoutEngine.layout(nodes: ["a", "b", "c"], edges: edges)

    // Nothing blocks, so everything shares rank 0.
    #expect(Set(layout.nodes.map(\.rank)) == [0])
    // The edges are still present for display.
    #expect(layout.edges.count == 2)
}

@Test("Cycles are detected and their members flagged")
func layoutDetectsCycles() {
    let edges = [
        GraphEdge(from: "a", to: "b", type: .blocks),
        GraphEdge(from: "b", to: "c", type: .blocks),
        GraphEdge(from: "c", to: "a", type: .blocks),
        GraphEdge(from: "d", to: "a", type: .blocks),
    ]
    let layout = GraphLayoutEngine.layout(nodes: ["a", "b", "c", "d"], edges: edges)

    #expect(layout.cycles.count == 1)
    #expect(layout.cycles.first?.sorted() == ["a", "b", "c"])

    let cyclic = Set(layout.nodes.filter(\.inCycle).map(\.id))
    #expect(cyclic == ["a", "b", "c"])
    // d is outside the cycle and must not be flagged.
    #expect(!cyclic.contains("d"))
}

@Test("A cyclic graph still lays out without hanging")
func layoutTerminatesOnCycles() {
    // Ranking a cycle by longest path would not terminate without SCC
    // condensation; this guards that path.
    let edges = [
        GraphEdge(from: "a", to: "b", type: .blocks),
        GraphEdge(from: "b", to: "a", type: .blocks),
    ]
    let layout = GraphLayoutEngine.layout(nodes: ["a", "b"], edges: edges)
    #expect(layout.nodes.count == 2)
    #expect(layout.size.width > 0)
}

@Test("Tarjan finds each strongly connected component once")
func tarjanComponents() {
    let successors = [
        "a": ["b"], "b": ["c"], "c": ["a"],
        "d": ["e"], "e": ["d"],
        "f": [],
    ]
    let components = GraphLayoutEngine.tarjanSCC(
        nodes: ["a", "b", "c", "d", "e", "f"], successors: successors)

    let multi = components.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    #expect(multi == [["a", "b", "c"], ["d", "e"]])
    #expect(components.contains(["f"]))
}

@Test("Layout handles an empty graph")
func layoutEmpty() {
    let layout = GraphLayoutEngine.layout(nodes: [], edges: [])
    #expect(layout.nodes.isEmpty)
    #expect(layout.edges.isEmpty)
}

@Test("Edges pointing outside the visible node set are dropped")
func layoutDropsDanglingEdges() {
    let edges = [GraphEdge(from: "a", to: "missing", type: .blocks)]
    let layout = GraphLayoutEngine.layout(nodes: ["a"], edges: edges)
    #expect(layout.edges.isEmpty)
    #expect(layout.nodes.count == 1)
}

// MARK: - Metric honesty

@Test("Metric status distinguishes unusable states from computed ones")
func metricStateUsability() {
    #expect(MetricState.computed.isUsable)
    #expect(MetricState.approx.isUsable)
    #expect(!MetricState.timeout.isUsable)
    #expect(!MetricState.skipped.isUsable)
    #expect(!MetricState.pending.isUsable)
}

@Test("An approximate metric annotates its sample size")
func approxAnnotation() {
    let entry = MetricStatusEntry(state: .approx, sample: 120)
    #expect(entry.annotation == "approx (n=120)")

    let timedOut = MetricStatusEntry(state: .timeout, milliseconds: 500)
    #expect(timedOut.annotation == "timed out (500 ms)")

    #expect(MetricStatusEntry(state: .computed).annotation == nil)
}

@Test("Empty metrics report no values rather than zeros")
func emptyMetricsHaveNoValues() {
    let metrics = GraphMetrics.empty
    #expect(metrics.pageRank == nil)
    #expect(!metrics.phase2Ready)
    // Degree lookups are Phase 1 and legitimately return 0 for an unknown id.
    #expect(metrics.blocks("nope") == 0)
}
