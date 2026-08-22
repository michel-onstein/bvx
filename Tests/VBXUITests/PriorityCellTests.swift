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
}
