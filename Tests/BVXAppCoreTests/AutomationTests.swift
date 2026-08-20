import BVXCore
import CoreSpotlight
import Foundation
import Testing

@testable import BVXAppCore

private typealias Bead = BVXCore.Issue

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

// MARK: - URL scheme

@MainActor
@Test("A bvx URL selects the bead it names")
func urlSelectsBead() async throws {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let url = try #require(BeadURL.open(bead: "bvx-3"))
    let handled = await store.open(url: url)

    #expect(handled)
    #expect(store.focusedID == "bvx-3")
    await store.close()
}

@MainActor
@Test("A bvx URL naming an unknown bead changes nothing")
func urlWithUnknownBead() async throws {
    let store = ProjectStore()
    await store.open(path: fixturePath)
    store.select(id: "bvx-3")

    let url = try #require(BeadURL.open(bead: "bvx-nope"))
    let handled = await store.open(url: url)

    // A stale link must not clear the selection, in a URL exactly as in prose.
    #expect(!handled)
    #expect(store.focusedID == "bvx-3")
    await store.close()
}

@MainActor
@Test("A foreign URL is declined so the system can handle it")
func foreignURL() async throws {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let url = try #require(URL(string: "https://example.com/open?bead=bvx-3"))
    let handled = await store.open(url: url)

    #expect(!handled)
    await store.close()
}

@MainActor
@Test("A workspace URL opens that workspace")
func urlOpensWorkspace() async throws {
    let store = ProjectStore()
    let url = try #require(BeadURL.open(bead: "bvx-3", workspace: fixturePath))

    let handled = await store.open(url: url)

    #expect(handled)
    #expect(store.isLoaded)
    #expect(store.focusedID == "bvx-3")
    await store.close()
}

// MARK: - Spotlight

@Test("A Spotlight activation resolves to its bead")
func spotlightActivation() {
    let userInfo: [AnyHashable: Any] = [CSSearchableItemActivityIdentifier: "bvx-3"]
    #expect(SpotlightIndexer.beadID(from: userInfo) == "bvx-3")
}

@Test(
    "A Spotlight activation with nothing usable resolves to nothing",
    arguments: [
        [:] as [AnyHashable: Any],
        [CSSearchableItemActivityIdentifier: ""],
        ["some-other-key": "bvx-3"],
    ])
func spotlightActivationWithoutID(userInfo: [AnyHashable: Any]) {
    #expect(SpotlightIndexer.beadID(from: userInfo) == nil)
}

@MainActor
@Test("A Spotlight activation selects the bead")
func spotlightSelects() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    #expect(store.openSpotlightItem([CSSearchableItemActivityIdentifier: "bvx-3"]))
    #expect(store.focusedID == "bvx-3")
    // An id the workspace does not hold leaves the selection alone.
    #expect(!store.openSpotlightItem([CSSearchableItemActivityIdentifier: "ghost-1"]))
    #expect(store.focusedID == "bvx-3")

    await store.close()
}

@Test("Indexing is inert without a bundle identifier")
func spotlightIsInert() async {
    // The test process has no bundle id, and CSSearchableIndex.default()
    // needs one. Indexing must be a no-op, not a crash — it is a
    // convenience, never a requirement.
    let indexer = SpotlightIndexer()
    await indexer.index(
        [Issue(id: "a", title: "Alpha", status: .open, priority: 1)],
        workspace: "/tmp/x")
    await indexer.clear()
    #expect(Bool(true))
}

// MARK: - Command line tool

@Test("Linking the tool creates a symlink and replaces an existing one")
func linkCommandLineTool() throws {
    let manager = FileManager.default
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bvx-cli-test-\(UUID().uuidString)")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }

    let source = directory.appendingPathComponent("bvx-cli")
    try "#!/bin/sh\n".write(to: source, atomically: true, encoding: .utf8)
    let destination = directory.appendingPathComponent("bin/bvx-cli")
    try manager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    let first = CommandLineTool.link(source: source, destination: destination)
    #expect(first == .installed(path: destination.path))
    let resolved = try manager.destinationOfSymbolicLink(atPath: destination.path)
    #expect(resolved == source.path)

    // Running it again repoints an existing link rather than refusing —
    // which is usually the whole reason to run it twice.
    let second = CommandLineTool.link(source: source, destination: destination)
    #expect(second == .installed(path: destination.path))
}

@Test("Linking reports a failure rather than trapping")
func linkFailure() {
    let source = URL(fileURLWithPath: "/tmp/bvx-cli-does-not-matter")
    // A destination inside a directory that does not exist cannot be created.
    let destination = URL(fileURLWithPath: "/nonexistent-root-\(UUID().uuidString)/bvx-cli")

    let result = CommandLineTool.link(source: source, destination: destination)
    guard case .failed = result else {
        Issue.record("expected a failure, got \(result)")
        return
    }
}
