import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// ``PriorityCell`` must get its store handed in, never from the environment.
///
/// `Table` builds a cell's subgraph when the row scrolls into view, and that
/// subgraph does not carry the `environmentObject` injected around
/// `ContentView`. An `@EnvironmentObject` in the cell therefore resolves for
/// the rows on screen at first layout and traps on the first row created after
/// it — which is why this only ever showed up on a workspace with more beads
/// than fit in the window, and never on vbx's own.
///
/// Both tests below trap rather than fail if the dependency comes back. That is
/// the nature of the bug: `EnvironmentObject.error()` is a `fatalError`, so the
/// regression takes the process down instead of reporting an expectation.
@MainActor
@Suite("Priority cell")
struct PriorityCellTests {

    /// Every scroll view under `view`, depth first.
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { found += scrollViews(in: sub) }
        return found
    }

    @Test("Scrolling the list past the first screen of rows does not trap")
    func scrollingTheListCreatesCellsThatKeepTheirStore() async throws {
        let store = await Fixture.loadedStore()

        // Short on purpose: the bug needs rows that are *not* laid out on the
        // first pass, so the window has to be smaller than the table's content.
        let size = CGSize(width: 1000, height: 220)
        #expect(
            store.visibleIssues.count > 8,
            "the fixture must overflow a \(Int(size.height))pt window or this proves nothing")

        let root = IssueListView()
            .environmentObject(store)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        // The table resolves its rows on the run loop, not inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let scrolls = scrollViews(in: host)
        #expect(!scrolls.isEmpty, "no scroll view found — the table did not render")

        // Walk well past the content height so rows are built, released and
        // built again, which is what the running app does under a flick.
        for offset in stride(from: 0.0, through: 900.0, by: 40.0) {
            for scroll in scrolls {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @Test("The cell renders with no environmentObject anywhere above it")
    func rendersWithoutAnEnvironmentObjectAncestor() async throws {
        let store = await Fixture.loadedStore()
        let issue = try #require(store.visibleIssues.first)

        // Deliberately no `.environmentObject(store)`: this is the invariant
        // the fix establishes, stated directly.
        let result = try Snapshot.render(
            PriorityCell(store: store, issue: issue),
            name: "priority-cell-no-environment",
            size: CGSize(width: 60, height: 24))

        #expect(result.inkCoverage() > 0, "the priority label drew nothing")
    }

    // MARK: - The edit path that actually works
    //
    // Reported from a real build: "the editing of Priority is not in this
    // build". It was in the build; it simply could not be reached. `br` was
    // found and `canEditBeads` was true, so the gate was not the problem — the
    // double-click was. macOS bridges `Table` to `NSTableView`, which consumes
    // clicks for row selection, so a cell's `onTapGesture(count: 2)` never
    // fires. With the only affordance being an unmarked 30pt column, the
    // feature was invisible and inert at once.
    //
    // The context menu goes through `contextMenu(forSelectionType:)` — Table's
    // own mechanism rather than a gesture layered over it.

    @Test("Editing is available: br is found and nothing blocks a write")
    func editingIsAvailable() async {
        let store = await Fixture.loadedStore()
        // This is what ruled out the obvious explanation. If it ever fails,
        // the cause is the environment, not the UI.
        #expect(store.writer.isAvailable, "br was not found: \(String(describing: BeadWriter.locateBR()))")
        #expect(store.canEditBeads)
        #expect(store.editingUnavailableReason == nil)
    }

    @Test("A double-click on the priority cell opens nothing")
    func doubleClickDoesNotReachTheCell() async throws {
        // Pinned deliberately. This documents *why* the context menu exists, so
        // that removing it in favour of "the double-click already does this"
        // fails here rather than in someone's hands. If SwiftUI ever starts
        // delivering the gesture, this test fails and should be deleted along
        // with the note above — a passing double-click is good news.
        let store = await Fixture.loadedStore()
        let size = CGSize(width: 1000, height: 500)
        let root = IssueListView().environmentObject(store)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        func tables(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let t = view as? NSTableView { found.append(t) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }
        let table = try #require(tables(in: host).first, "the table did not render")
        #expect(table.numberOfRows > 0)

        let before = NSApp.windows.count
        // Column 1 is "P"; column 0 is the id.
        let rect = table.frameOfCell(atColumn: 1, row: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for count in [1, 2] {
            for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: phase, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        // A popover is an extra window. None appears.
        #expect(NSApp.windows.count == before, "a popover opened — the gesture now works")
    }

    @Test("Setting a priority on several beads writes each one")
    func setPriorityAcrossASelection() async throws {
        let (store, directory) = try await Fixture.writableStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let targets = Array(store.visibleIssues.prefix(2))
        try #require(targets.count == 2, "the fixture needs two beads")
        let ids = Set(targets.map(\.id))
        // Something none of them already is, or a no-op would look like success.
        let target = (0...4).first { value in
            !targets.contains { $0.priority == value }
        }
        let wanted = try #require(target)

        let failed = await store.setPriority(wanted, for: ids)
        #expect(failed.isEmpty, "could not write: \(failed) — \(String(describing: store.loadError))")

        // Read back from the store, which reloaded from what br wrote.
        for id in ids {
            let issue = store.issues.first { $0.id == id }
            #expect(issue?.priority == wanted, "\(id) is \(String(describing: issue?.priority))")
        }
    }

    @Test("A refused edit reports rather than failing silently")
    func refusedEditIsReported() async throws {
        let store = await Fixture.loadedStore()
        // Time travel is the state the store already refuses in; using it keeps
        // this honest about the real guard rather than mocking one.
        let id = try #require(store.visibleIssues.first?.id)
        struct Unreachable: Error {}
        store.writer = BeadWriter(locate: { nil }, runner: { _, _ in
            // Refusing happens before any process is spawned; reaching this
            // would mean the guard had stopped guarding.
            Issue.record("the runner must not be reached when br is absent")
            throw Unreachable()
        })
        #expect(!store.canEditBeads)
        #expect(store.editingUnavailableReason == "Install br to edit beads from vbx.")

        let failed = await store.setPriority(0, for: [id])
        #expect(failed == [id], "a refused write must report the ids it did not apply")
    }
}
