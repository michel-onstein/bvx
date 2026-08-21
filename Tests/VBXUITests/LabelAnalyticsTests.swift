import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The two label-scoped analytics surfaces. Both are presentation over engine
/// payloads, so the tests check that the payload arrives intact and that the
/// view draws it.
@MainActor
@Suite("Label analytics")
struct LabelAnalyticsTests {

    @Test("Cross-label flow loads with the workspace")
    func flowLoads() async {
        let store = await Fixture.loadedStore()

        #expect(!store.labelFlow.labels.isEmpty)
        // The matrix is indexed by the label list's positions, so a ragged
        // matrix would make every cell read the wrong pair.
        #expect(store.labelFlow.flowMatrix.count == store.labelFlow.labels.count)
        for row in store.labelFlow.flowMatrix {
            #expect(row.count == store.labelFlow.labels.count)
        }

        await store.close()
    }

    @Test("An out-of-range cell is absent, not zero")
    func cellBoundsAreExplicit() {
        let flow = LabelFlow(
            labels: ["a", "b"],
            flowMatrix: [[0, 3], [1, 0]])

        #expect(flow.count(from: 0, to: 1) == 3)
        #expect(flow.count(from: 1, to: 0) == 1)
        // "No such cell" and "no dependencies between these labels" are
        // different facts, and the heat map colours them differently.
        #expect(flow.count(from: 0, to: 0) == 0)
        #expect(flow.count(from: 5, to: 0) == nil)
        #expect(flow.count(from: 0, to: 5) == nil)
    }

    @Test("The heat scale ignores the diagonal")
    func peakExcludesDiagonal() {
        // A label depending on itself is not flow between labels. If the
        // diagonal set the scale, every real cell would wash out.
        let flow = LabelFlow(
            labels: ["a", "b"],
            flowMatrix: [[99, 3], [1, 42]])
        #expect(flow.peakCount == 3)
    }

    @Test("Attention scores load, ranked and decomposed")
    func attentionLoads() async {
        let store = await Fixture.loadedStore()
        let attention = store.labelAttention

        #expect(!attention.labels.isEmpty)
        for (index, score) in attention.labels.enumerated() {
            #expect(score.rank == index + 1)
            #expect(score.normalizedScore >= 0 && score.normalizedScore <= 1)
        }
        // Descending by score, as the engine ordered them.
        let scores = attention.labels.map(\.attentionScore)
        #expect(scores == scores.sorted(by: >))

        await store.close()
    }

    @Test("A score carries all four factors, with velocity marked as reducing")
    func factorsAreDecomposed() {
        let score = LabelAttentionScore(
            label: "core", attentionScore: 2.5, normalizedScore: 0.8, rank: 1,
            pageRankSum: 0.4, stalenessFactor: 1.5, blockImpact: 3, velocityFactor: 0.7)

        let factors = score.factors
        #expect(factors.count == 4)
        #expect(factors.map(\.name) == ["Centrality", "Staleness", "Block impact", "Velocity"])
        // Velocity divides in bv's formula, so more of it means *less*
        // attention — the arrow has to point the other way.
        #expect(factors.last?.raises == false)
        let raising = factors.dropLast().filter { $0.raises }
        #expect(raising.count == 3)
    }

    @Test("The flow matrix renders")
    func rendersFlowMatrix() async throws {
        let store = await Fixture.loadedStore()
        store.surface = .flow

        let result = try Snapshot.render(
            FlowMatrixView().environmentObject(store),
            name: "flow-matrix",
            size: CGSize(width: 700, height: 520)
        )
        #expect(result.inkCoverage() > 0.01, "flow matrix drew nothing")
        // Header labels, the scale's tints and the grid give real variety.
        #expect(result.distinctColors() > 4)
        await store.close()
    }

    @Test("The attention view renders")
    func rendersAttention() async throws {
        let store = await Fixture.loadedStore()
        store.surface = .attention

        let result = try Snapshot.render(
            AttentionView().environmentObject(store),
            name: "attention",
            size: CGSize(width: 700, height: 520)
        )
        #expect(result.inkCoverage() > 0.01, "attention view drew nothing")
        await store.close()
    }

    @Test("Both surfaces are reachable and distinctly keyed")
    func surfacesAreDistinct() {
        #expect(ViewSurface.allCases.contains(.flow))
        #expect(ViewSurface.allCases.contains(.attention))

        // A duplicated shortcut would silently shadow an existing surface.
        let terminalKeys = ViewSurface.allCases.map(\.terminalKey)
        #expect(Set(terminalKeys).count == terminalKeys.count)
        let commandKeys = ViewSurface.allCases.map(\.keyEquivalent.character)
        #expect(Set(commandKeys).count == commandKeys.count)
    }
}
