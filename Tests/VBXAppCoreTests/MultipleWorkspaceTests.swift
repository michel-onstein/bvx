import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// Several workspaces open at once.
///
/// The window plumbing was already there — `WindowGroup` has always made more
/// than one window. What made them two views of *one* workspace was the store
/// living on the `App`. These assert the property that move depends on: two
/// stores share nothing.
private var demoFixture: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

private func copiedFixture() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-window-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads"),
        to: directory.appendingPathComponent(".beads"))
    return directory
}

@MainActor
private func isolatedStore() -> ProjectStore {
    let store = ProjectStore()
    store.skipPhase2 = true
    // Its own recents, so these tests never touch the real preferences.
    let defaults = UserDefaults(suiteName: "vbx-window-\(UUID().uuidString)")!
    store.recents = RecentWorkspaces(defaults: defaults, key: "recentWorkspaces")
    return store
}

@MainActor
@Test("Two stores hold two different workspaces at once")
func storesAreIndependent() async throws {
    let second = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: second) }

    let a = isolatedStore()
    let b = isolatedStore()
    await a.open(path: demoFixture)
    await b.open(path: second.path)

    #expect(a.loadError == nil)
    #expect(b.loadError == nil)
    // The whole point: opening in one did not move the other.
    #expect(a.info?.source != b.info?.source)
    #expect(a.info?.source.contains(demoFixture) == true)

    await a.close()
    await b.close()
}

@MainActor
@Test("View, filter and selection do not leak between windows")
func viewStateIsPerWindow() async throws {
    let second = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: second) }

    let a = isolatedStore()
    let b = isolatedStore()
    await a.open(path: demoFixture)
    await b.open(path: second.path)

    a.surface = .graph
    a.query.labels = ["engine"]
    a.query.filter = .closed

    #expect(b.surface == .list, "the surface leaked between windows")
    #expect(b.query.labels.isEmpty, "the label filter leaked")
    #expect(b.query.filter != .closed, "the filter leaked")

    // Selection too — a Set on each store, not a shared one.
    let firstBead = try #require(a.issues.first?.id)
    a.select(id: firstBead)
    #expect(a.focusedID == firstBead)
    #expect(b.focusedID != firstBead || b.selection != a.selection)

    await a.close()
    await b.close()
}

@MainActor
@Test("Navigation history is per window")
func navigationHistoryIsPerWindow() async throws {
    let second = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: second) }

    let a = isolatedStore()
    let b = isolatedStore()
    await a.open(path: demoFixture)
    await b.open(path: second.path)

    a.surface = .graph
    a.surface = .insights

    #expect(a.canGoBack)
    #expect(!b.canGoBack, "one window's history reached another")

    await a.close()
    await b.close()
}

@MainActor
@Test("The recents list is shared, because the File menu is app-wide")
func recentsAreShared() {
    // Where you have been belongs to the person, not to one window: a
    // workspace opened in either window has to appear in the menu of both.
    #expect(RecentWorkspaces.shared === RecentWorkspaces.shared)

    let store = ProjectStore()
    #expect(store.recents === RecentWorkspaces.shared, "a new window got its own history")
}
