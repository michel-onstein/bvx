import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Filters must not survive a workspace switch.
///
/// A label, an assignee, a repository name and a recipe's ids all name things
/// inside one workspace. Carried into another they typically match nothing, and
/// the resulting empty list reads as "this workspace has no beads" rather than
/// "you are still looking through the last workspace's filter".
private var demoFixture: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

/// A copy of the fixture at its own path, so opening it is a genuine switch.
///
/// The store identifies a workspace by its resolved source, so a second
/// workspace has to actually live somewhere else — reopening the same path
/// would exercise nothing.
private func copiedFixture() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-filter-reset-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads"),
        to: directory.appendingPathComponent(".beads"))
    return directory
}

@MainActor
@Test("Opening a different workspace clears filters chosen for the last one")
func openingAnotherWorkspaceResetsFilters() async throws {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: demoFixture)

    // Filters that name things in *this* workspace.
    store.query.filter = .closed
    store.query.searchText = "loader"
    store.query.labels = ["engine"]
    store.query.assignees = ["ada"]
    store.repoFilter = ["demo"]
    store.alertSeverityFilter = .critical
    store.alertTypeFilter = "stale"
    await store.applyRecipe(named: "actionable")
    #expect(store.activeRecipe != nil, "premise: a recipe is active before the switch")

    let second = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: second) }
    await store.open(path: second.path)

    #expect(store.loadError == nil)
    #expect(store.query.filter == IssueQuery().filter)
    #expect(store.query.searchText.isEmpty)
    #expect(store.query.labels.isEmpty)
    #expect(store.query.assignees.isEmpty)
    #expect(store.repoFilter.isEmpty)
    #expect(store.activeRecipe == nil)
    #expect(store.recipeIDs == nil)
    #expect(!store.recipeTruncated)
    #expect(store.alertSeverityFilter == nil)
    #expect(store.alertTypeFilter == nil)

    // The point of the whole change: the new workspace comes up showing its
    // beads, not an empty table with no visible cause.
    #expect(!store.visibleIssues.isEmpty, "the new workspace rendered empty")

    await store.close()
}

@MainActor
@Test("Reloading the same workspace keeps the filter the user is working in")
func reloadPreservesFilters() async throws {
    // The negative half, and it is not redundant: resetting inside refreshAll
    // would satisfy the test above while wiping the filter on every watcher
    // tick — reload exists precisely to keep the view stable while the file
    // changes underneath.
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: demoFixture)

    store.query.labels = ["engine"]
    store.query.searchText = "loader"
    await store.reload(force: true)

    #expect(store.query.labels == ["engine"], "reload discarded the label filter")
    #expect(store.query.searchText == "loader", "reload discarded the search text")

    await store.close()
}

@MainActor
@Test("Reopening the same workspace leaves its filters alone")
func reopeningSameWorkspaceKeepsFilters() async throws {
    // Opening the workspace already open is not a switch. Nothing in the
    // filter has gone stale, so there is nothing to clear.
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: demoFixture)

    store.query.labels = ["engine"]
    await store.open(path: demoFixture)

    #expect(store.query.labels == ["engine"])

    await store.close()
}

@MainActor
@Test("The view the user is on survives a workspace switch")
func surfaceIsNotAFilter() async throws {
    // Deliberate, and called out rather than reset silently: `surface` names
    // nothing inside the workspace, and someone comparing two workspaces in
    // the same view wants to stay in it.
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: demoFixture)
    store.surface = .graph

    let second = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: second) }
    await store.open(path: second.path)

    #expect(store.surface == .graph)

    await store.close()
}
