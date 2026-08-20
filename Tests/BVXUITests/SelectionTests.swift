import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

private typealias Bead = BVXCore.Issue

/// Multi-selection, and the single-bead cursor that lives alongside it.
@MainActor
@Suite("Selection")
struct SelectionTests {

    @Test("A loaded workspace starts with one bead selected")
    func startsWithOne() async {
        let store = await Fixture.loadedStore()
        #expect(store.selection.count == 1)
        #expect(store.focusedID != nil)
        #expect(store.selectedIssue != nil)
        await store.close()
    }

    @Test("Several beads can be selected at once")
    func selectsSeveral() async {
        let store = await Fixture.loadedStore()
        let ids = store.visibleIssues.prefix(3).map(\Bead.id)

        store.selection = Set(ids)

        #expect(store.selection.count == 3)
        #expect(store.selectedIssues.count == 3)
        for id in ids { #expect(store.isSelected(id)) }
        await store.close()
    }

    @Test("select(id:) replaces the selection rather than extending it")
    func selectReplaces() async {
        let store = await Fixture.loadedStore()
        let ids = store.visibleIssues.prefix(3).map(\Bead.id)
        store.selection = Set(ids)

        let target = store.visibleIssues[4].id
        store.select(id: target)

        // Every caller of select(id:) — an inline link, a URL, Spotlight, a
        // drilldown — means "show me this one". Adding to a hand-built
        // selection would be a surprising way to answer that.
        #expect(store.selection == [target])
        #expect(store.focusedID == target)
        await store.close()
    }

    @Test("Focus follows the bead most recently added")
    func focusFollowsTheNewest() async {
        let store = await Fixture.loadedStore()
        let first = store.visibleIssues[0].id
        let second = store.visibleIssues[1].id

        store.select(id: first)
        #expect(store.focusedID == first)

        // A Set has no order, so "the first selected" is whichever the hash
        // yields — the inspector would appear to jump around.
        store.selection.insert(second)
        #expect(store.focusedID == second)
        #expect(store.selectedIssue?.id == second)

        await store.close()
    }

    @Test("Deselecting the focused bead moves focus to something still selected")
    func focusSurvivesDeselection() async {
        let store = await Fixture.loadedStore()
        let ids = store.visibleIssues.prefix(2).map(\Bead.id)
        store.selection = Set(ids)
        let focused = try? #require(store.focusedID)

        store.selection.remove(focused ?? "")

        #expect(store.focusedID != focused)
        #expect(store.focusedID != nil)
        #expect(store.selection.contains(store.focusedID ?? ""))
        await store.close()
    }

    @Test("Clearing the selection clears the focus")
    func emptySelectionHasNoFocus() async {
        let store = await Fixture.loadedStore()
        store.selection = []
        #expect(store.focusedID == nil)
        // The inspector shows its empty state rather than a stale bead.
        #expect(store.selectedIssue == nil)
        await store.close()
    }

    // MARK: - Ordering

    @Test("The selection is ordered by what is on screen, not by the Set")
    func orderedByScreen() async {
        let store = await Fixture.loadedStore()
        let onScreen = store.visibleIssues.map(\Bead.id)
        let chosen = Set([onScreen[4], onScreen[0], onScreen[2]])

        store.selection = chosen
        let ordered = store.orderedSelection()

        // A Set is unordered, so anything user-visible built from it has to
        // impose an order or it changes between identical actions.
        #expect(ordered == [onScreen[0], onScreen[2], onScreen[4]])
        await store.close()
    }

    @Test("Ordering is stable across repeated calls")
    func orderingIsStable() async {
        let store = await Fixture.loadedStore()
        store.selection = Set(store.visibleIssues.prefix(5).map(\Bead.id))

        let first = store.orderedSelection()
        for _ in 0..<20 {
            #expect(store.orderedSelection() == first)
        }
        await store.close()
    }

    @Test("A selected bead the filter has hidden still appears in the order")
    func hiddenSelectionStillOrders() async {
        let store = await Fixture.loadedStore()
        let visibleID = store.visibleIssues[0].id
        // A closed bead the open filter hides.
        guard let hidden = store.issues.first(where: { $0.status.isClosed })?.id else {
            await store.close()
            return
        }

        store.selection = [visibleID, hidden]
        let ordered = store.orderedSelection()

        // Dropping it would silently copy fewer ids than the user selected.
        #expect(ordered.count == 2)
        #expect(ordered.contains(hidden))
        #expect(ordered.first == visibleID)
        await store.close()
    }

    // MARK: - Reload and recipes

    @Test("A reload keeps the selection it can and never leaves it empty")
    func reloadKeepsSelection() async {
        let store = await Fixture.loadedStore()
        let ids = Set(store.visibleIssues.prefix(3).map(\Bead.id))
        store.selection = ids

        await store.reload(force: true)

        // Every id still exists, so all three survive.
        #expect(store.selection == ids)
        #expect(store.focusedID != nil)
        await store.close()
    }

    @Test("Applying a recipe narrows the selection to its results")
    func recipeNarrowsSelection() async {
        let store = await Fixture.loadedStore()
        store.selection = Set(store.visibleIssues.map(\Bead.id))

        await store.applyRecipe(named: "actionable")
        guard let recipeIDs = store.recipeIDs, !recipeIDs.isEmpty else {
            await store.close()
            return
        }

        // A selection pointing outside the recipe's results would leave the
        // inspector showing a bead the list no longer contains.
        #expect(store.selection.isSubset(of: Set(recipeIDs)))
        #expect(!store.selection.isEmpty)
        await store.close()
    }

    // MARK: - Rendering

    @Test("The list renders with several beads selected")
    func rendersMultiSelection() async throws {
        let store = await Fixture.loadedStore()
        store.selection = Set(store.visibleIssues.prefix(4).map(\Bead.id))

        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "list-multi-selection",
            size: CGSize(width: 1100, height: 500)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("The inspector shows the focused bead when several are selected")
    func inspectorShowsFocused() async throws {
        let store = await Fixture.loadedStore()
        let first = store.visibleIssues[0].id
        store.select(id: first)
        store.selection.insert(store.visibleIssues[1].id)

        #expect(store.selectedIssue?.id == store.visibleIssues[1].id)

        let result = try Snapshot.render(
            InspectorView().environmentObject(store),
            name: "inspector-multi-selection",
            size: CGSize(width: 340, height: 700)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }
}
