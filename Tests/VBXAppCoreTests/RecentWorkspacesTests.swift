import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// The File menu's recent-workspaces list.
///
/// Every case drives its own `UserDefaults` suite: the real one belongs to the
/// user, and two tests sharing a suite would see each other's entries under
/// Swift Testing's parallel execution.
@MainActor
private func isolatedRecents() -> (RecentWorkspaces, UserDefaults) {
    let name = "vbx-recents-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (RecentWorkspaces(defaults: defaults, key: "recentWorkspaces"), defaults)
}

/// Directories that actually exist, since the list hides paths that do not.
private func temporaryWorkspaces(_ count: Int) throws -> [String] {
    try (0..<count).map { index in
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-recent-\(index)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}

@MainActor
@Test("The most recently opened workspace comes first")
func recentsAreNewestFirst() throws {
    let (recents, _) = isolatedRecents()
    let paths = try temporaryWorkspaces(3)
    defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

    for path in paths { recents.record(path) }

    #expect(recents.entries.map(\.path) == paths.reversed())
    #expect(recents.entries.first?.name == URL(fileURLWithPath: paths[2]).lastPathComponent)
}

@MainActor
@Test("Re-opening a workspace moves it up rather than listing it twice")
func recordingAgainMovesToTheTop() throws {
    let (recents, _) = isolatedRecents()
    let paths = try temporaryWorkspaces(3)
    defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

    for path in paths { recents.record(path) }
    recents.record(paths[0])

    // Without the de-duplication the list reads as "what I have clicked"
    // rather than "where I have been", and one workspace can fill it.
    #expect(recents.entries.count == 3)
    #expect(recents.entries.first?.path == paths[0])
}

@MainActor
@Test("Only the last five are kept")
func recentsAreCappedAtFive() throws {
    let (recents, _) = isolatedRecents()
    let paths = try temporaryWorkspaces(8)
    defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

    for path in paths { recents.record(path) }

    #expect(recents.entries.count == RecentWorkspaces.limit)
    #expect(recents.entries.first?.path == paths.last)
    #expect(!recents.entries.contains { $0.path == paths[0] }, "the oldest survived the cap")
}

@MainActor
@Test("Clearing empties the list and the stored copy")
func clearingRemovesEverything() throws {
    let (recents, defaults) = isolatedRecents()
    let paths = try temporaryWorkspaces(2)
    defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

    for path in paths { recents.record(path) }
    recents.clear()

    #expect(recents.entries.isEmpty)
    // Cleared in storage too, or the list would return on the next launch.
    #expect(defaults.stringArray(forKey: "recentWorkspaces") == nil)
}

@MainActor
@Test("The list survives a relaunch")
func recentsPersist() throws {
    let name = "vbx-recents-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let paths = try temporaryWorkspaces(2)
    defer { paths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

    let first = RecentWorkspaces(defaults: defaults, key: "recentWorkspaces")
    for path in paths { first.record(path) }

    // A second instance over the same defaults is what the next launch builds.
    let second = RecentWorkspaces(defaults: defaults, key: "recentWorkspaces")
    #expect(second.entries.map(\.path) == paths.reversed())
}

@MainActor
@Test("A workspace that has since moved is not offered")
func missingWorkspacesAreHidden() throws {
    let (recents, _) = isolatedRecents()
    let paths = try temporaryWorkspaces(2)
    recents.record(paths[0])
    recents.record(paths[1])

    try FileManager.default.removeItem(atPath: paths[1])
    defer { try? FileManager.default.removeItem(atPath: paths[0]) }

    // Listing it and letting the click fail is the behaviour this avoids.
    #expect(recents.entries.map(\.path) == [paths[0]])
    // Still stored, though: an unmounted drive must not cost the user history.
    #expect(recents.paths.count == 2)
}

@MainActor
@Test("Opening a workspace records it; a failed open does not")
func openingRecordsOnlyOnSuccess() async throws {
    let store = ProjectStore()
    store.skipPhase2 = true
    let defaults = UserDefaults(suiteName: "vbx-recents-\(UUID().uuidString)")!
    store.recents = RecentWorkspaces(defaults: defaults, key: "recentWorkspaces")

    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
    await store.open(path: fixture)
    #expect(store.recents.entries.count == 1)

    // A path that cannot be loaded is not somewhere the user has been, and
    // offering it again would only reproduce the error.
    let empty = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    await store.open(path: empty.path)
    #expect(store.loadError != nil, "premise: this workspace does not load")
    #expect(store.recents.entries.count == 1, "a failed open was recorded")

    await store.close()
}
