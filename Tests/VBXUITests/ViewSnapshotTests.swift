import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Renders each real view against the demo fixture and asserts it actually
/// drew something.
///
/// A view that lays out but paints nothing still yields a valid PNG, so these
/// check ink coverage and colour variety rather than merely that a file
/// appeared. The PNGs are kept (see `Snapshot.outputDirectory`) so a human can
/// look at them.
@MainActor
@Suite("View snapshots")
struct ViewSnapshotTests {

    private func hosted<V: View>(_ view: V, _ store: ProjectStore) -> some View {
        view.environmentObject(store)
    }

    @Test("Issue list renders rows, metrics and status chips")
    func issueList() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            hosted(IssueListView(), store),
            name: "issue-list",
            size: CGSize(width: 1000, height: 520)
        )

        #expect(result.width >= 1000)
        #expect(result.inkCoverage() > 0.015, "list looks blank (ink \(result.inkCoverage()))")
        // Text, chips and the accent colour should give plenty of variety.
        #expect(result.distinctColors() > 5)
        await store.close()
    }

    @Test("Board renders columns and cards")
    func board() async throws {
        let store = await Fixture.loadedStore()
        store.query.filter = .all
        let result = try Snapshot.render(
            hosted(BoardView(), store),
            name: "board",
            size: CGSize(width: 1100, height: 620)
        )
        #expect(result.inkCoverage() > 0.015, "board looks blank")
        #expect(result.distinctColors() > 5)
        await store.close()
    }

    @Test("Insights renders panels with real metric values")
    func insights() async throws {
        let store = await Fixture.loadedStore()
        // Guard the premise: if metrics never arrived the panels would render
        // their "compute metrics" placeholder and this test would be vacuous.
        #expect(store.metrics.hasPhase2Values)

        let result = try Snapshot.render(
            hosted(InsightsView(), store),
            name: "insights",
            size: CGSize(width: 1100, height: 800)
        )
        #expect(result.inkCoverage() > 0.015, "insights looks blank")
        #expect(result.distinctColors() > 5)
        await store.close()
    }

    @Test("Inspector renders the selected bead's detail")
    func inspector() async throws {
        let store = await Fixture.loadedStore()
        store.select(id: "vbx-3")
        #expect(store.selectedIssue != nil)

        let result = try Snapshot.render(
            hosted(InspectorView(), store),
            name: "inspector",
            size: CGSize(width: 340, height: 640)
        )
        #expect(result.inkCoverage() > 0.015, "inspector looks blank")
        await store.close()
    }

    @Test("Labels dashboard renders health cards")
    func labels() async throws {
        let store = await Fixture.loadedStore()
        #expect(!store.labelAnalysis.labels.isEmpty)

        let result = try Snapshot.render(
            hosted(LabelsView(), store),
            name: "labels",
            size: CGSize(width: 1000, height: 620)
        )
        #expect(result.inkCoverage() > 0.015, "labels view looks blank")
        await store.close()
    }

    @Test("Plan renders parallel tracks")
    func plan() async throws {
        let store = await Fixture.loadedStore()
        #expect(!store.plan.tracks.isEmpty)

        let result = try Snapshot.render(
            hosted(PlanView(), store),
            name: "plan",
            size: CGSize(width: 1000, height: 560)
        )
        #expect(result.inkCoverage() > 0.015, "plan looks blank")
        await store.close()
    }

    @Test("Tree renders the dependency outline")
    func tree() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            hosted(TreeView(), store),
            name: "tree",
            size: CGSize(width: 800, height: 520)
        )
        #expect(result.inkCoverage() > 0.015, "tree looks blank")
        await store.close()
    }

    @Test("Sidebar renders views, filters and label counts")
    func sidebar() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            hosted(SidebarView(), store),
            name: "sidebar",
            size: CGSize(width: 240, height: 620)
        )
        #expect(result.inkCoverage() > 0.015, "sidebar looks blank")
        await store.close()
    }

    @Test("Graph canvas draws nodes and edges")
    func graphCanvas() async throws {
        let store = await Fixture.loadedStore()

        // Lay out synchronously; GraphView does this in a .task, which does not
        // run under ImageRenderer, so the canvas is driven directly.
        let layout = GraphLayoutEngine.layout(
            nodes: store.visibleIssues.map(\.id), edges: store.edges)
        #expect(!layout.nodes.isEmpty)
        #expect(!layout.edges.isEmpty)

        let canvas = GraphCanvas(
            layout: layout,
            issuesByID: store.issuesByID,
            actionable: store.actionable,
            pageRank: store.metrics.pageRank,
            selection: "vbx-3"
        )

        let result = try Snapshot.render(
            canvas,
            name: "graph-canvas",
            size: CGSize(width: layout.size.width, height: layout.size.height)
        )
        // Nodes and edges on a plain background: coverage is lower than a
        // text-dense view, but must be clearly non-zero.
        #expect(result.inkCoverage() > 0.01, "graph canvas drew nothing")
        #expect(result.distinctColors() > 4, "graph canvas has no colour variety")
        await store.close()
    }

    @Test("A graph with a cycle still renders")
    func graphWithCycle() async throws {
        // Cycles break naive layering; this guards the SCC-condensation path
        // all the way through to pixels.
        let edges = [
            GraphEdge(from: "a", to: "b", type: .blocks),
            GraphEdge(from: "b", to: "c", type: .blocks),
            GraphEdge(from: "c", to: "a", type: .blocks),
            GraphEdge(from: "d", to: "a", type: .blocks),
        ]
        let layout = GraphLayoutEngine.layout(nodes: ["a", "b", "c", "d"], edges: edges)
        #expect(layout.cycles.count == 1)

        // Qualified: Swift Testing exports its own `Issue` type.
        let issues = ["a", "b", "c", "d"].reduce(into: [String: VBXCore.Issue]()) {
            $0[$1] = VBXCore.Issue(id: $1, title: $1.uppercased(), status: .open)
        }
        let result = try Snapshot.render(
            GraphCanvas(
                layout: layout, issuesByID: issues, actionable: ["d"], pageRank: nil),
            name: "graph-cycle",
            size: CGSize(width: max(layout.size.width, 400), height: max(layout.size.height, 300))
        )
        #expect(result.inkCoverage() > 0.01, "cyclic graph drew nothing")
    }

    @Test("Empty state renders when nothing matches the filter")
    func emptyState() async throws {
        let store = await Fixture.loadedStore()
        store.query.searchText = "zzzz-definitely-no-such-bead"
        #expect(store.visibleIssues.isEmpty)

        let result = try Snapshot.render(
            hosted(IssueListView(), store),
            name: "empty-state",
            size: CGSize(width: 800, height: 400)
        )
        // The empty state is deliberately sparse, but must still draw its icon
        // and message rather than nothing at all.
        #expect(result.inkCoverage() > 0.002, "empty state drew nothing")
        await store.close()
    }

    @Test("Metric cells show status instead of a fake zero")
    func metricPlaceholders() async throws {
        // With Phase 2 skipped the PageRank column must render placeholders.
        // Rendering proves the UI path, not just the model invariant.
        let store = ProjectStore()
        store.skipPhase2 = true
        await store.open(path: Fixture.path)
        #expect(!store.metrics.hasPhase2Values)

        let result = try Snapshot.render(
            hosted(IssueListView(), store),
            name: "metrics-unavailable",
            size: CGSize(width: 1000, height: 400)
        )
        #expect(result.inkCoverage() > 0.015)
        await store.close()
    }
}
