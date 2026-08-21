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
@Test("Selecting a bead records a position, so back returns to the one before")
func rowSelectionRecordsAPosition() async throws {
    // This replaces a test that asserted the opposite. Row selection used to
    // refresh the current position in place, on the reasoning that `j`/`k`
    // browsing was not navigation — which left back unable to return to the
    // bead just read, the commonest thing to want back for.
    let store = await loadedStore()
    var clock = Date(timeIntervalSince1970: 1_000_000)
    store.navigationClock = { clock }

    let ids = store.issues.map(\.id)
    let first = try #require(ids.first)
    let second = try #require(ids.dropFirst().first)
    let third = try #require(ids.dropFirst(2).first)

    // Spaced beyond the coalescing window: three separate moves.
    for id in [first, second, third] {
        clock = clock.addingTimeInterval(ProjectStore.navigationCoalesceWindow * 2)
        store.selection = [id]
    }

    store.goBack()
    #expect(store.focusedID == second, "back did not return to the previously viewed bead")
    store.goBack()
    #expect(store.focusedID == first)

    store.goForward()
    #expect(store.focusedID == second)

    await store.close()
}

@MainActor
@Test("A fast run of selections collapses into the position it ends on")
func rapidSelectionRunCoalesces() async throws {
    // The reason the original rule existed, kept: with a 20-position cap,
    // holding a key down would otherwise evict every surface position within
    // one screenful. A run collapses, so back leaves the run rather than
    // crawling out of it row by row.
    let store = await loadedStore()
    var clock = Date(timeIntervalSince1970: 2_000_000)
    store.navigationClock = { clock }

    store.surface = .graph
    let before = store.navigationHistory.count
    let positionBeforeRun = store.currentNavigationEntry
    let ids = Array(store.issues.prefix(6).map(\.id))

    for id in ids {
        // Key repeat: each selection lands well inside the window.
        clock = clock.addingTimeInterval(ProjectStore.navigationCoalesceWindow / 5)
        store.selection = [id]
    }

    #expect(
        store.navigationHistory.count == before + 1,
        "a run of \(ids.count) selections recorded \(store.navigationHistory.count - before) positions")
    #expect(store.currentNavigationEntry?.bead == ids.last, "the run kept the wrong position")

    // One step leaves the whole run, rather than crawling back through six
    // rows — which is the point of collapsing it.
    store.goBack()
    #expect(
        store.currentNavigationEntry == positionBeforeRun,
        "back did not land on the position the run started from")

    await store.close()
}

@MainActor
@Test("Browsing cannot evict every position: the cap still holds")
func browsingRespectsTheCap() async throws {
    let store = await loadedStore()
    var clock = Date(timeIntervalSince1970: 3_000_000)
    store.navigationClock = { clock }

    // Deliberate, spaced selections — the case that does record one each.
    for id in store.issues.map(\.id) {
        clock = clock.addingTimeInterval(ProjectStore.navigationCoalesceWindow * 2)
        store.selection = [id]
    }

    #expect(store.navigationHistory.count <= ProjectStore.navigationHistoryLimit)
    #expect(store.navigationCursor == store.navigationHistory.count - 1)

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
