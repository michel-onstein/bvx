import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// The Open panel's folder guard.
///
/// Every case here is driven through the real engine probe rather than a stub,
/// because the property worth protecting is not "the guard returns what it was
/// told" — it is that the guard and the loader agree.
@Suite("Open panel guard")
struct OpenPanelGuardTests {

    private var demoFixture: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo")
            .path
    }

    @Test("A folder holding .beads is offered")
    func acceptsWorkspaceFolder() {
        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.canOpen(demoFixture))
        #expect(guardDelegate.panel(NSNull(), shouldEnable: URL(fileURLWithPath: demoFixture)))
    }

    @Test("The .beads directory itself is offered")
    func acceptsBeadsDirectory() {
        let path = URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads").path
        #expect(OpenPanelGuard().canOpen(path))
    }

    @Test("A bead data file is offered")
    func acceptsDataFile() throws {
        let beads = URL(fileURLWithPath: demoFixture).appendingPathComponent(".beads")
        let file = try #require(
            try FileManager.default.contentsOfDirectory(atPath: beads.path)
                .first { $0.hasSuffix(".jsonl") })

        #expect(OpenPanelGuard().canOpen(beads.appendingPathComponent(file).path))
    }

    @Test("A workspace root whose .beads live in the repositories below it is offered")
    func acceptsMultiRepoRoot() throws {
        // The case the literal "must contain .beads" rule breaks. A root
        // configured this way holds no .beads of its own, and refusing it
        // would make multi-repository workspaces unreachable from the panel.
        let root = try Self.temporaryDirectory()
        let config = root.appendingPathComponent(".bv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
            repos:
              - path: alpha
            """.write(
            to: config.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        let guardDelegate = OpenPanelGuard()

        #expect(guardDelegate.canOpen(root.path))
        #expect(guardDelegate.result(for: root.path).kind == "workspace")
    }

    @Test("A folder with no bead data is refused, with a reason")
    func refusesEmptyFolder() throws {
        let empty = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        #expect(!guardDelegate.canOpen(empty.path))
        #expect(!guardDelegate.panel(NSNull(), shouldEnable: empty))
        // A greyed-out row with no explanation is the thing users file bugs
        // about, so the refusal has to carry one.
        #expect(!guardDelegate.result(for: empty.path).reason.isEmpty)
        #expect(guardDelegate.refusal(for: empty.path).contains(empty.lastPathComponent))
    }

    @Test("Validation is the gate, not the greying")
    func validationRefuses() throws {
        let empty = try Self.temporaryDirectory()
        let guardDelegate = OpenPanelGuard()

        // shouldEnable only greys the row; a path typed into Go-to-folder never
        // passes through it. Validation is what actually stops the open.
        #expect(throws: (any Error).self) {
            try guardDelegate.panel(NSNull(), validate: empty)
        }
        try guardDelegate.panel(NSNull(), validate: URL(fileURLWithPath: demoFixture))
    }

    @Test("A path that does not exist is refused rather than crashing")
    func refusesMissingPath() throws {
        let missing = try Self.temporaryDirectory().appendingPathComponent("nowhere")
        #expect(!OpenPanelGuard().canOpen(missing.path))
    }

    @Test("Repeated questions about one folder are answered once")
    func cachesAnswers() {
        var asked = 0
        let guardDelegate = OpenPanelGuard { path in
            asked += 1
            return ProbeResult(path: path, canOpen: true, kind: "jsonl")
        }

        // The panel asks about every visible row on every redraw; without the
        // cache, scrolling a large folder would re-probe on each frame.
        for _ in 0..<50 { _ = guardDelegate.canOpen("/some/path") }

        #expect(asked == 1)
    }

    @Test("What the guard offers, the store can actually open")
    func agreesWithTheStore() async {
        // The invariant the whole design exists for. A guard that says yes and
        // a store that then fails is worse than no guard at all.
        let guardDelegate = OpenPanelGuard()
        #expect(guardDelegate.canOpen(demoFixture))

        let store = await ProjectStore()
        await store.open(path: demoFixture)
        let failed = await store.loadError

        #expect(failed == nil)
        await store.close()
    }

    @Test("What the guard refuses, the store would have failed to open")
    func refusalMatchesTheStore() async throws {
        let empty = try Self.temporaryDirectory()
        #expect(!OpenPanelGuard().canOpen(empty.path))

        let store = await ProjectStore()
        await store.open(path: empty.path)
        let failed = await store.loadError

        #expect(failed != nil)
        await store.close()
    }

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
