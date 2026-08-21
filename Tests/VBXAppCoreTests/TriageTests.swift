import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@MainActor
@Test("Triage loads and every recommendation resolves to a real bead")
func triageLoads() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let triage = store.triage
    #expect(!triage.isEmpty)
    #expect(!triage.recommendations.isEmpty)

    let known = Set(store.issues.map(\.id))
    for rec in triage.recommendations {
        #expect(known.contains(rec.id), "recommendation \(rec.id) is not a bead in this workspace")
        #expect(!rec.title.isEmpty)
        // Anything the engine recommends must be reachable from the UI.
        #expect(store.issuesByID[rec.id] != nil)
    }

    await store.close()
}

@MainActor
@Test("Recommendations are ordered by descending score")
func recommendationsAreRanked() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let scores = store.triage.recommendations.map(\.score)
    #expect(scores == scores.sorted(by: >), "recommendations arrived out of rank order")

    await store.close()
}

@MainActor
@Test("Recommendation cross-references point at real beads")
func recommendationReferencesResolve() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let known = Set(store.issues.map(\.id))
    for rec in store.triage.recommendations {
        for id in rec.unblocksIDs {
            #expect(known.contains(id), "\(rec.id) claims to unblock unknown \(id)")
        }
        for id in rec.blockedBy {
            #expect(known.contains(id), "\(rec.id) claims to be blocked by unknown \(id)")
        }
    }

    for blocker in store.triage.blockersToClear {
        #expect(blocker.unblocksCount >= 0)
        // An actionable blocker cannot itself be waiting on something.
        if blocker.actionable {
            #expect(blocker.blockedBy.isEmpty)
        }
    }

    await store.close()
}

@Test("Triage decoding tolerates a payload with missing sections")
func triageDecodingIsTolerant() throws {
    // bv omits empty arrays; the model must treat that as empty, not fail.
    let json = #"{"recommendations":[{"id":"a","title":"A","score":1.5}]}"#
    let triage = try JSONDecoder().decode(Triage.self, from: Data(json.utf8))

    #expect(triage.recommendations.count == 1)
    #expect(triage.recommendations[0].score == 1.5)
    #expect(triage.quickWins.isEmpty)
    #expect(triage.blockersToClear.isEmpty)
    #expect(!triage.isEmpty)
}
