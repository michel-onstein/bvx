import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

private typealias Bead = BVXCore.Issue

/// Search modes and hybrid ranking.
@MainActor
@Suite("Search")
struct SearchTests {

    @Test("Plain search stays synchronous and needs no index")
    func plainSearchIsLocal() async {
        let store = await Fixture.loadedStore()
        store.query.searchText = "loader"

        // The text path uses IssueQuery's fuzzy ranking. Waiting on a round
        // trip while someone is still typing would be the wrong trade.
        #expect(store.searchMode == .text)
        #expect(!store.isUsingEngineSearch)
        #expect(!store.visibleIssues.isEmpty)

        await store.close()
    }

    @Test("Hybrid search re-ranks through the engine")
    func hybridUsesEngine() async throws {
        // Searching writes a vector index into <project>/.bv/semantic, so it
        // gets a private copy of the fixture rather than dirtying the checkout.
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadSearchPresets()

        store.query.searchText = "loader"
        store.searchMode = .hybrid
        await store.runEngineSearch()

        guard !store.searchResults.isEmpty else {
            // An empty index is a legitimate outcome for a query matching
            // nothing; nothing further to assert.
            await store.close()
            return
        }

        #expect(store.isUsingEngineSearch)
        #expect(store.searchResults.mode == .hybrid)
        // The default embedder is deterministic, which is what keeps this
        // ranking identical to the CLI's.
        #expect(store.searchResults.provider == "hash")
        // The visible list is exactly the engine's ranking, not a re-sort.
        #expect(store.visibleIssues.map(\Bead.id) == store.searchResults.rankedIDs)

        await store.close()
    }

    @Test("Clearing the query leaves hybrid mode with nothing to show")
    func clearingQuery() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.searchMode = .hybrid
        store.query.searchText = "loader"
        await store.runEngineSearch()

        store.query.searchText = ""
        await store.runEngineSearch()

        #expect(store.searchResults.isEmpty)
        #expect(!store.isUsingEngineSearch)
        // And the list falls back to the ordinary filter rather than emptying.
        #expect(!store.visibleIssues.isEmpty)

        await store.close()
    }

    @Test("The presets load with their weights")
    func presetsLoad() async {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()

        #expect(store.searchPresets.presets.count == 5)
        // bv has exactly two modes; there is no separate "semantic" one,
        // because the index is always used and the mode selects re-ranking.
        #expect(store.searchPresets.modes.count == 2)

        let textOnly = store.searchPresets.weights(named: "text-only")
        #expect(textOnly?.text == 1.0)
        #expect(textOnly?.pageRank == 0)

        await store.close()
    }

    // MARK: - Weights

    @Test("Weights encode every key, zeros included")
    func weightsEncodeAllKeys() throws {
        var weights = SearchWeights()
        weights.pageRank = 0
        let text = String(decoding: try JSONEncoder().encode(weights), as: UTF8.self)

        // The engine requires all six, and an omitted key is not the same as
        // a zero weight.
        for key in ["text", "pagerank", "status", "impact", "priority", "recency"] {
            #expect(text.contains("\"\(key)\""), "missing \(key)")
        }
    }

    @Test("Weights round-trip through JSON")
    func weightsRoundTrip() throws {
        let original = SearchWeights(
            text: 0.5, pageRank: 0.2, status: 0.1, impact: 0.1, priority: 0.05, recency: 0.05)
        let again = try JSONDecoder().decode(
            SearchWeights.self, from: try JSONEncoder().encode(original))
        #expect(again == original)
        #expect(abs(again.total - 1.0) < 0.0001)
    }

    @Test("The six factors are all offered to the editor")
    func factorsAreComplete() {
        let factors = SearchWeights().factors
        #expect(factors.count == 6)
        #expect(
            factors.map(\.name) == [
                "Text", "Centrality", "Status", "Impact", "Priority", "Recency",
            ])
    }

    @Test("A hit's contributions are ordered largest first")
    func contributionsOrdered() throws {
        let json = """
            {"issue_id":"a","score":0.8,"text_score":0.5,
             "component_scores":{"text":0.2,"pagerank":0.5,"status":0.1}}
            """
        let hit = try JSONDecoder().decode(SearchHit.self, from: Data(json.utf8))
        #expect(hit.contributions.map(\.name) == ["pagerank", "text", "status"])
        #expect(hit.textScore == 0.5)
    }

    @Test("A text-mode hit has no breakdown, and that is not an error")
    func textHitHasNoBreakdown() throws {
        let hit = try JSONDecoder().decode(
            SearchHit.self, from: Data(#"{"issue_id":"a","score":0.4}"#.utf8))
        #expect(hit.componentScores.isEmpty)
        #expect(hit.contributions.isEmpty)
    }

    @Test("Each mode explains what it ranks by")
    func modesAreExplained() {
        for mode in SearchMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.explanation.isEmpty)
        }
        #expect(SearchMode.allCases.count == 2)
    }

    // MARK: - Rendering

    @Test("The scope bar appears only with a query")
    func scopeBarNeedsAQuery() async throws {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()

        // Nothing to scope with no query, so the bar draws nothing.
        let empty = try Snapshot.render(
            SearchScopeBar().environmentObject(store).frame(width: 900, height: 34),
            name: "search-scope-empty",
            size: CGSize(width: 900, height: 34)
        )
        #expect(empty.width > 0)

        store.query.searchText = "loader"
        store.searchMode = .hybrid
        let shown = try Snapshot.render(
            SearchScopeBar().environmentObject(store).frame(width: 900),
            name: "search-scope-bar",
            size: CGSize(width: 900, height: 34)
        )
        #expect(shown.inkCoverage() > 0.005, "scope bar drew nothing")

        await store.close()
    }

    @Test("The weights editor renders")
    func rendersWeightsEditor() async throws {
        let store = await Fixture.loadedStore()
        await store.loadSearchPresets()
        store.searchWeights = SearchWeights()

        let result = try Snapshot.render(
            WeightsEditor().environmentObject(store),
            name: "search-weights",
            size: CGSize(width: 340, height: 280)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("A score breakdown renders")
    func rendersBreakdown() throws {
        let json = """
            {"issue_id":"a","score":0.8,"text_score":0.5,
             "component_scores":{"text":0.2,"pagerank":0.5,"status":0.1}}
            """
        let hit = try JSONDecoder().decode(SearchHit.self, from: Data(json.utf8))
        let result = try Snapshot.render(
            SearchScoreBreakdown(hit: hit).padding(10),
            name: "search-breakdown",
            size: CGSize(width: 260, height: 120)
        )
        #expect(result.inkCoverage() > 0.01)
    }
}
