import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// What a launch with no explicit request lands on.
///
/// The bug these lock in: launched from the Dock or Finder, a GUI app's current
/// directory is `/`, discovery *opened* it, the open failed, and every launch
/// showed "Could not open workspace" before the user had asked for anything.
/// Discovery must probe its candidates and fall silent, leaving the neutral
/// "No workspace open" state to appear on its own.
private var fixture: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

/// A store whose recents list is its own, so tests neither read nor write the
/// user's real preferences and cannot see each other's entries.
@MainActor
private func storeWithOwnRecents() -> ProjectStore {
    let defaults = UserDefaults(suiteName: "vbx-launch-\(UUID().uuidString)")!
    let store = ProjectStore()
    store.recents = RecentWorkspaces(defaults: defaults, key: "recentWorkspaces")
    return store
}

/// A directory that exists and holds no bead data — what `/` is to a Dock
/// launch.
private func emptyDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-launch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// The real predicate: the engine's own probe, so these cases agree with what
/// `open(path:)` would actually do.
@MainActor
private func realProbe(_ path: String) -> Bool { ProjectStore.canOpen(path) }

@MainActor
@Test("Launch with nothing to discover opens nothing, and reports no error")
func launchWithNoCandidatesIsSilent() async throws {
    let store = storeWithOwnRecents()
    let elsewhere = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: elsewhere) }

    await store.openInitialWorkspace(
        arguments: [], environment: [:], currentDirectory: elsewhere, probe: realProbe)

    // No error is the whole fix: the empty state's Choose Workspace… button is
    // what the user should see, not an error triangle.
    #expect(store.loadError == nil)
    #expect(!store.isLoaded)
    #expect(store.issues.isEmpty)
}

@MainActor
@Test("Launch reopens the most recent workspace")
func launchReopensRecent() async throws {
    let store = storeWithOwnRecents()
    let elsewhere = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: elsewhere) }
    store.recents.record(fixture)

    await store.openInitialWorkspace(
        arguments: [], environment: [:], currentDirectory: elsewhere, probe: realProbe)

    #expect(store.loadError == nil)
    #expect(store.isLoaded)
    #expect(!store.issues.isEmpty)

    await store.close()
}

@MainActor
@Test("A path argument beats the recents list")
func argumentBeatsRecents() async throws {
    let store = storeWithOwnRecents()
    let stale = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: stale) }
    store.recents.record(stale)

    var opened: [String] = []
    await store.openInitialWorkspace(
        arguments: ["-NSSomeLaunchFlag", fixture],
        environment: ["VBX_WORKSPACE": stale],
        currentDirectory: stale
    ) { path in
        opened.append(path)
        return path == fixture || path == stale
    }

    // Asked about the argument first, and stopped there — the recents entry and
    // the environment variable were never consulted.
    #expect(opened == [fixture])
    #expect(store.info?.source.hasPrefix(fixture) == true)

    await store.close()
}

@MainActor
@Test("A recent that no longer opens is skipped for the next candidate")
func deadRecentIsSkipped() async throws {
    let store = storeWithOwnRecents()
    let dead = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: dead) }
    // Newest first, so the unopenable one is asked about before the fixture.
    store.recents.record(fixture)
    store.recents.record(dead)

    await store.openInitialWorkspace(
        arguments: [], environment: [:], currentDirectory: dead, probe: realProbe)

    #expect(store.loadError == nil)
    #expect(store.isLoaded)
    #expect(store.info?.source.hasPrefix(fixture) == true)

    await store.close()
}

@MainActor
@Test("The current directory is used only when it holds bead data")
func currentDirectoryIsProbed() async throws {
    let store = storeWithOwnRecents()

    await store.openInitialWorkspace(
        arguments: [], environment: [:], currentDirectory: fixture, probe: realProbe)

    #expect(store.isLoaded)

    await store.close()
}

@MainActor
@Test("A workspace named on the command line still reports why it failed")
func namedPathStillErrors() async throws {
    let store = storeWithOwnRecents()
    let empty = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: empty) }

    await store.openInitialWorkspace(
        arguments: [empty], environment: [:], currentDirectory: empty, probe: realProbe)

    // Discovery falls silent; a path the user actually named does not.
    #expect(store.loadError != nil)
    #expect(!store.isLoaded)
}

@MainActor
@Test("A launch argument that is not a path is not an error")
func strayArgumentIsNotAnError() async throws {
    let store = storeWithOwnRecents()
    let elsewhere = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: elsewhere) }

    // What Xcode hands a launched app: a flag's value, left behind once the
    // flag itself is dropped. It names nothing, so it must not produce an error.
    await store.openInitialWorkspace(
        arguments: ["-NSDocumentRevisionsDebugMode", "YES"],
        environment: [:], currentDirectory: elsewhere, probe: realProbe)

    #expect(store.loadError == nil)
    #expect(!store.isLoaded)
}

@MainActor
@Test("A restored window whose workspace moved lands in the neutral state")
func restoredWindowFallsSilent() async throws {
    let store = storeWithOwnRecents()
    let gone = NSTemporaryDirectory() + "/vbx-gone-\(UUID())"

    await store.openRestoredWorkspace(path: gone, probe: realProbe)

    #expect(store.loadError == nil)
    #expect(!store.isLoaded)
}

@MainActor
@Test("A restored window whose workspace still opens is restored")
func restoredWindowOpens() async throws {
    let store = storeWithOwnRecents()

    await store.openRestoredWorkspace(path: fixture, probe: realProbe)

    #expect(store.loadError == nil)
    #expect(store.isLoaded)

    await store.close()
}

@MainActor
@Test("Choosing a folder with no bead data still reports the error")
func explicitOpenStillErrors() async throws {
    let store = storeWithOwnRecents()
    let empty = try emptyDirectory()
    defer { try? FileManager.default.removeItem(atPath: empty) }

    // The guard against over-correcting: only discovery falls silent. A folder
    // picked in the Open panel, a bad vbx:// link or a recents entry clicked by
    // hand must keep saying what went wrong.
    await store.open(path: empty)

    #expect(store.loadError != nil)
    #expect(!store.isLoaded)
}
