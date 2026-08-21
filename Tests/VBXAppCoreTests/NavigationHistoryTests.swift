import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Back and forward through the view history.
///
/// The cursor rules are the whole substance here: every one of these tests
/// passes against an implementation that pops instead of moving a cursor,
/// right up until forward is asked for something.
private var fixture: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@MainActor
private func loadedStore() async -> ProjectStore {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: fixture)
    return store
}

@MainActor
@Test("A freshly opened workspace can go neither back nor forward")
func historyStartsAtRest() async {
    let store = await loadedStore()

    // Seeded with one position: there is a "here", but nowhere to return to.
    #expect(store.navigationHistory.count == 1)
    #expect(!store.canGoBack)
    #expect(!store.canGoForward)

    await store.close()
}

@MainActor
@Test("Back returns to the previous surface and forward comes back")
func backAndForwardRoundTrip() async {
    let store = await loadedStore()
    store.surface = .graph
    store.surface = .insights

    #expect(store.canGoBack)
    #expect(!store.canGoForward, "forward must be closed at the newest position")

    store.goBack()
    #expect(store.surface == .graph)
    #expect(store.canGoForward, "back must leave a forward branch to return through")

    store.goBack()
    #expect(store.surface == .list)
    #expect(!store.canGoBack, "back must stop at the oldest position")

    store.goForward()
    #expect(store.surface == .graph)
    store.goForward()
    #expect(store.surface == .insights)
    #expect(!store.canGoForward)

    await store.close()
}

@MainActor
@Test("Restoring a position does not itself record one")
func restoreDoesNotRecord() async {
    let store = await loadedStore()
    store.surface = .graph
    store.surface = .insights
    let recorded = store.navigationHistory

    store.goBack()
    store.goBack()
    store.goForward()

    // The regression this guards: if restoring recorded, back would append the
    // position it just arrived at and the history would grow every time it was
    // used — with forward truncated away on the first move.
    #expect(store.navigationHistory == recorded, "navigating rewrote the history")

    await store.close()
}

@MainActor
@Test("A new move from mid-history discards the forward branch")
func newNavigationTruncatesForward() async {
    let store = await loadedStore()
    store.surface = .graph
    store.surface = .insights
    store.goBack()
    #expect(store.canGoForward)

    store.surface = .labels

    #expect(!store.canGoForward, "the abandoned branch must not remain reachable")
    #expect(store.navigationHistory.map(\.surface) == [.list, .graph, .labels])

    await store.close()
}

@MainActor
@Test("Arriving where you already are records nothing")
func redundantNavigationIsNotRecorded() async {
    let store = await loadedStore()
    store.surface = .graph
    let count = store.navigationHistory.count

    store.surface = .graph
    #expect(store.navigationHistory.count == count)

    await store.close()
}

@MainActor
@Test("The history keeps the last 20 positions and evicts the oldest")
func historyIsCappedAtTwenty() async {
    let store = await loadedStore()

    // Alternate so no two consecutive positions are equal and each is really
    // recorded, then overshoot the cap.
    for step in 0..<30 {
        store.surface = step.isMultiple(of: 2) ? .graph : .list
    }

    #expect(store.navigationHistory.count == ProjectStore.navigationHistoryLimit)
    #expect(store.navigationCursor == ProjectStore.navigationHistoryLimit - 1)
    // The cursor must still address the newest entry after eviction shifts
    // every index down; an off-by-one here breaks back at the boundary.
    #expect(store.currentNavigationEntry?.surface == store.surface)
    #expect(store.canGoBack)

    await store.close()
}

@MainActor
@Test("Jumping to a bead is a position, and back returns to the previous one")
func beadJumpIsNavigable() async throws {
    let store = await loadedStore()
    let ids = store.issues.map(\.id)
    let first = try #require(ids.first)
    let second = try #require(ids.dropFirst().first)

    store.select(id: first)
    store.select(id: second)
    #expect(store.focusedID == second)

    store.goBack()
    #expect(store.focusedID == first, "back did not restore the bead jumped from")

    store.goForward()
    #expect(store.focusedID == second)

    await store.close()
}

@MainActor
@Test("Browsing rows updates the current position instead of pushing one")
func rowSelectionDoesNotPushPositions() async {
    let store = await loadedStore()
    store.surface = .graph
    let count = store.navigationHistory.count

    // What `j`/`k` and a table click do: write the selection directly. Pushing
    // per row would evict all 20 positions within one screenful of browsing.
    for id in store.issues.prefix(5).map(\.id) {
        store.selection = [id]
    }

    #expect(store.navigationHistory.count == count, "row browsing pushed positions")
    // The current position still has to track where the user actually is, or
    // back from the next surface would return to a stale row.
    #expect(store.currentNavigationEntry?.bead == store.focusedID)

    await store.close()
}

@MainActor
@Test("A position whose bead is gone still restores its surface")
func missingBeadStillRestoresSurface() async {
    let store = await loadedStore()

    // A bead that vanished under the history — closed, or dropped by a reload.
    // Injected rather than deleted, because `issues` is read-only from here;
    // what matters is the guard in restore, which this addresses directly.
    store.navigationHistory = [
        NavigationEntry(surface: .list, bead: "vbx-no-such-bead"),
        NavigationEntry(surface: .graph, bead: nil),
    ]
    store.navigationCursor = 1

    // Refusing to move would strand the user on the position they are leaving.
    store.goBack()
    #expect(store.surface == .list)
    #expect(store.selection.isEmpty)

    await store.close()
}
