import BVXCore
import Foundation
import Testing

@testable import BVXAppCore

/// Copies the demo fixture somewhere writable so a test can mutate it.
private func makeScratchWorkspace() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo/.beads/issues.jsonl")

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bvx-watch-\(UUID().uuidString)")
    let beads = dir.appendingPathComponent(".beads")
    try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: source, to: beads.appendingPathComponent("issues.jsonl"))
    return dir
}

@Test("The watcher fires on a real file change and debounces a burst")
func watcherFires() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let counter = Counter()
    let watcher = FileWatchService()
    watcher.debounce = 0.15

    watcher.start(watching: file.path) { counter.increment() }
    #expect(watcher.isWatching)
    defer { watcher.stop() }

    // Let FSEvents settle before writing, or the stream can miss the first event.
    try await Task.sleep(for: .milliseconds(400))

    // A burst of writes must collapse into a single notification.
    let original = try String(contentsOf: file, encoding: .utf8)
    for i in 0..<4 {
        try (original + "\n// touch \(i)\n").write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(20))
    }

    try await Task.sleep(for: .milliseconds(900))

    let fired = counter.value
    #expect(fired >= 1, "watcher never fired for a real write")
    #expect(fired <= 3, "debounce failed to collapse a burst of 4 writes (fired \(fired)×)")
}

@Test("Stopping the watcher silences it")
func watcherStops() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let counter = Counter()
    let watcher = FileWatchService()
    watcher.debounce = 0.1
    watcher.start(watching: file.path) { counter.increment() }
    try await Task.sleep(for: .milliseconds(300))

    watcher.stop()
    #expect(!watcher.isWatching)

    let after = counter.value
    try "changed".write(to: file, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(500))

    #expect(counter.value == after, "watcher fired after stop()")
}

@MainActor
@Test("Reload is hash gated: unchanged content does no work")
func storeReloadIsGated() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProjectStore()
    await store.open(path: dir.path)
    #expect(store.isLoaded)
    #expect(store.issues.count == 18)

    // No content change: reload must report that it did nothing.
    let didChange = await store.reload()
    #expect(!didChange)
    #expect(store.info?.changed == false)

    // A real change must be picked up.
    let file = dir.appendingPathComponent(".beads/issues.jsonl")
    let original = try String(contentsOf: file, encoding: .utf8)
    let added = original + #"{"id":"bvx-99","title":"Added later","status":"open","issue_type":"task","priority":2}"# + "\n"
    try added.write(to: file, atomically: true, encoding: .utf8)

    let didChangeNow = await store.reload()
    #expect(didChangeNow)
    #expect(store.issues.count == 19)
    #expect(store.issuesByID["bvx-99"] != nil)

    await store.close()
}

@MainActor
@Test("Opening a workspace starts watching, closing stops it")
func storeManagesWatchLifecycle() async throws {
    let dir = try makeScratchWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProjectStore()
    #expect(!store.isWatching)

    await store.open(path: dir.path)
    #expect(store.isWatching)

    await store.close()
    #expect(!store.isWatching)
}

/// Minimal thread-safe counter; the watcher callback arrives on its own queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
