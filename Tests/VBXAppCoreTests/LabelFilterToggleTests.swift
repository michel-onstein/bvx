import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Toggling a label filter from the row.
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
@Test("Toggling a label adds it, and toggling again removes it")
func togglingALabelIsSymmetric() async {
    let store = await loadedStore()
    #expect(store.query.labels.isEmpty)

    store.toggleLabelFilter("engine")
    #expect(store.query.labels == ["engine"])

    store.toggleLabelFilter("engine")
    #expect(store.query.labels.isEmpty, "the second toggle did not remove the label")

    await store.close()
}

@MainActor
@Test("The filter actually narrows the list, and widens again")
func togglingNarrowsTheList() async {
    let store = await loadedStore()
    let all = store.visibleIssues.count
    #expect(all > 0)

    store.toggleLabelFilter("engine")
    let filtered = store.visibleIssues.count
    #expect(filtered > 0, "no bead carries the label the fixture is filtered by")
    #expect(filtered < all, "the label filter changed nothing")
    #expect(store.visibleIssues.allSatisfy { $0.labels.contains("engine") })

    store.toggleLabelFilter("engine")
    #expect(store.visibleIssues.count == all, "removing the filter did not restore the list")

    await store.close()
}

@MainActor
@Test("Two labels compose rather than replacing each other")
func togglingTwoLabelsKeepsBoth() async {
    let store = await loadedStore()
    store.toggleLabelFilter("engine")
    store.toggleLabelFilter("ui")

    #expect(store.query.labels == ["engine", "ui"])
    // The filter keeps beads carrying *any* selected label, so adding one can
    // only widen the result — asserting it shrinks would encode the wrong rule.
    #expect(store.visibleIssues.allSatisfy {
        !$0.labels.filter { ["engine", "ui"].contains($0) }.isEmpty
    })

    await store.close()
}

@MainActor
@Test("Editing the filter by hand ends the active recipe")
func togglingClearsAnActiveRecipe() async {
    // A recipe writes `query` wholesale, so a filter the user has since edited
    // is no longer the recipe's. Leaving it active would keep the sidebar
    // claiming a recipe that no longer describes the screen.
    let store = await loadedStore()
    await store.applyRecipe(named: "actionable")
    #expect(store.activeRecipe != nil, "premise: a recipe is active")

    store.toggleLabelFilter("engine")

    #expect(store.activeRecipe == nil, "the recipe survived a manual filter change")
    #expect(store.query.labels.contains("engine"))

    await store.close()
}
