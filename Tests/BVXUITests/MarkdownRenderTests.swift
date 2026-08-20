import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

/// Renders the Markdown component directly and through the inspector, so both
/// the block rendering and its integration are covered.
@MainActor
@Suite("Markdown rendering")
struct MarkdownRenderTests {

    private let sample = """
        ## Bridge design

        Wraps the C ABI in an `actor` so calls serialise.

        - envelope decoding, one error path
        - buffer ownership released via `defer`
        - cancellation maps to `bvx_cancel`

        1. open the workspace
        2. wait for Phase 2

        ```swift
        let info = try await engine.open(path: workspace)
        ```

        > A panic must never cross the boundary.

        ---

        See **ADR-001** for why the engine is reused.
        """

    @Test("Every block type renders")
    func rendersAllBlocks() throws {
        let result = try Snapshot.render(
            MarkdownText(source: sample).padding(16),
            name: "markdown-blocks",
            size: CGSize(width: 420, height: 620)
        )
        #expect(result.inkCoverage() > 0.015, "markdown drew nothing")
        // Headings, code background and the rule give more variety than plain
        // body text alone.
        #expect(result.distinctColors() > 4)
    }

    @Test("Plain prose renders without Markdown treatment")
    func plainProseRenders() throws {
        let plain = "The data_hash and issue_id fields are compared. 5 * 3 = 15."
        #expect(!MarkdownParser.looksLikeMarkdown(plain))

        let result = try Snapshot.render(
            MarkdownText(source: plain).padding(16),
            name: "markdown-plain",
            size: CGSize(width: 420, height: 120)
        )
        #expect(result.inkCoverage() > 0.01, "plain prose drew nothing")
    }

    @Test("The inspector renders a Markdown description")
    func inspectorRendersMarkdown() async throws {
        let store = await Fixture.loadedStore()
        store.select(id: "bvx-3")

        let issue = try #require(store.selectedIssue)
        // Guard the premise: if the fixture loses its Markdown this test would
        // silently stop testing anything.
        #expect(MarkdownParser.looksLikeMarkdown(issue.description))

        let result = try Snapshot.render(
            InspectorView().environmentObject(store),
            name: "inspector-markdown",
            size: CGSize(width: 340, height: 900)
        )
        #expect(result.inkCoverage() > 0.015)
        await store.close()
    }

    @Test("A table renders as a grid, not as collapsed prose")
    func rendersTable() throws {
        let source = """
            ## Metrics

            | Metric | Value | Rank |
            |:---|---:|:--:|
            | PageRank | 0.20 | 3 |
            | Betweenness | 0.35 | 1 |
            | Eigenvector | 0.11 | 7 |
            """
        // Guard the premise: if detection regressed, the snapshot below would
        // still draw ink — as one collapsed line — and pass for the wrong reason.
        let blocks = MarkdownParser.parse(source)
        #expect(blocks.contains { if case .table = $0 { return true } else { return false } })

        let result = try Snapshot.render(
            MarkdownText(source: source).padding(16),
            name: "markdown-table",
            size: CGSize(width: 420, height: 220)
        )
        #expect(result.inkCoverage() > 0.01, "table drew nothing")
    }

    @Test("An empty description renders nothing rather than crashing")
    func emptyDescription() throws {
        let result = try Snapshot.render(
            MarkdownText(source: "").padding(16),
            name: "markdown-empty",
            size: CGSize(width: 300, height: 80)
        )
        // Nothing to draw: the assertion is that rendering completed at all.
        #expect(result.width > 0)
    }
}
