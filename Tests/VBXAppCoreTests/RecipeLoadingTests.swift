import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Recipes are available once a workspace is open.
///
/// The bug these guard: `loadRecipes()` was only ever called from the sidebar
/// section's `.task`, which renders before any workspace has loaded. It
/// returned early on `isLoaded` and never ran again, so the list was always
/// empty while the engine had eleven recipes the whole time.
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
@Test("Opening a workspace loads its recipes")
func openingLoadsRecipes() async {
    // The assertion whose absence let this ship. Nothing about the engine ever
    // changed; only whether anything asked it at a moment it could answer.
    let store = await loadedStore()

    #expect(store.isLoaded)
    #expect(!store.recipes.recipes.isEmpty, "a workspace opened with no recipes loaded")
    // bv's built-ins travel with the engine, so any workspace has them.
    let names = store.recipes.recipes.map(\.recipe.name)
    #expect(names.contains("actionable"), "expected bv's built-ins, got \(names)")

    await store.close()
}

@MainActor
@Test("Reloading keeps the recipes, since a workspace can gain or lose one")
func reloadingKeepsRecipes() async {
    let store = await loadedStore()
    let before = store.recipes.recipes.count
    #expect(before > 0)

    await store.reload(force: true)

    #expect(store.recipes.recipes.count == before, "reload emptied the recipe list")

    await store.close()
}

@MainActor
@Test("A loaded recipe can actually be applied")
func loadedRecipesAreUsable() async {
    // Guards the shape of the fix: loading a list that cannot be applied would
    // satisfy the test above while leaving the feature just as inert.
    let store = await loadedStore()
    #expect(store.activeRecipe == nil)

    await store.applyRecipe(named: "actionable")

    #expect(store.activeRecipe?.name == "actionable")
    #expect(store.recipeIDs != nil, "applying produced no selection")
    #expect(store.loadError == nil)

    store.clearRecipe()
    #expect(store.activeRecipe == nil)

    await store.close()
}

@MainActor
@Test("Without a workspace there are no recipes to show")
func noWorkspaceMeansNoRecipes() async {
    // Not a failure: an empty section with nothing open is correct, and it is
    // also why this bug was easy to mistake for "recipes do nothing".
    let store = ProjectStore()
    await store.loadRecipes()
    #expect(store.recipes.recipes.isEmpty)
}
