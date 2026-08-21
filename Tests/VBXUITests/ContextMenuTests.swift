import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

private typealias Bead = VBXCore.Issue

/// The list's context menu, and the Copy ID it starts with.
@MainActor
@Suite("Context menu")
struct ContextMenuTests {

    @Test("One bead copies its id")
    func copiesOneID() async {
        let store = await Fixture.loadedStore()
        let id = store.visibleIssues[0].id

        #expect(store.idList(for: [id]) == id)
        await store.close()
    }

    @Test("Several beads join with a comma and a space")
    func joinsSeveral() async {
        let store = await Fixture.loadedStore()
        let ids = store.visibleIssues.prefix(3).map(\Bead.id)

        let text = store.idList(for: Set(ids))

        #expect(text == ids.joined(separator: ", "))
        #expect(text.contains(", "))
        await store.close()
    }

    @Test("The joined order follows the screen, not the Set")
    func joinedOrderFollowsScreen() async {
        let store = await Fixture.loadedStore()
        let onScreen = store.visibleIssues.map(\Bead.id)
        // Deliberately out of screen order.
        let chosen: Set<Bead.ID> = [onScreen[5], onScreen[1], onScreen[3]]

        let text = store.idList(for: chosen)

        #expect(text == "\(onScreen[1]), \(onScreen[3]), \(onScreen[5])")
        await store.close()
    }

    @Test("Copying the same selection twice produces the same string")
    func copyIsStable() async {
        let store = await Fixture.loadedStore()
        let chosen = Set(store.visibleIssues.prefix(6).map(\Bead.id))

        let first = store.idList(for: chosen)
        for _ in 0..<25 {
            // A Set iterates in hash order, which is not stable between
            // instances. Without an imposed order the same action could put
            // two different strings on the clipboard.
            #expect(store.idList(for: chosen) == first)
        }
        await store.close()
    }

    @Test("An empty selection copies nothing rather than an empty string")
    func emptyCopiesNothing() async {
        let store = await Fixture.loadedStore()

        #expect(store.idList(for: []) == "")
        // Returning nil is the signal that the pasteboard was left alone —
        // replacing whatever the user had with an empty string is worse than
        // doing nothing.
        #expect(store.copyIDs([]) == nil)
        await store.close()
    }

    @Test("Copying really does reach the pasteboard")
    func reachesPasteboard() async {
        let store = await Fixture.loadedStore()
        let ids = Set(store.visibleIssues.prefix(2).map(\Bead.id))

        // The general pasteboard is shared machine state; this test writes to
        // it deliberately, and restores what was there afterwards.
        let previous = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previous { NSPasteboard.general.setString(previous, forType: .string) }
        }

        let written = store.copyIDs(ids)

        #expect(written != nil)
        #expect(NSPasteboard.general.string(forType: .string) == written)
        #expect(written == store.idList(for: ids))
        await store.close()
    }

    @Test("A hidden but selected bead is still copied")
    func copiesHiddenSelection() async {
        let store = await Fixture.loadedStore()
        let visibleID = store.visibleIssues[0].id
        guard let hidden = store.issues.first(where: { $0.status.isClosed })?.id else {
            await store.close()
            return
        }

        let text = store.idList(for: [visibleID, hidden])

        // Dropping it would copy fewer ids than were selected, silently.
        #expect(text.contains(hidden))
        #expect(text.contains(visibleID))
        await store.close()
    }

    @Test("The menu's label reflects how many beads it applies to")
    func labelReflectsCount() async {
        let store = await Fixture.loadedStore()
        // The one-vs-many distinction the menu makes: a count in the label is
        // what tells the user the action covers more than the row they
        // right-clicked.
        let one = store.idList(for: [store.visibleIssues[0].id])
        let many = store.idList(for: Set(store.visibleIssues.prefix(3).map(\Bead.id)))

        #expect(!one.contains(","))
        #expect(many.components(separatedBy: ", ").count == 3)
        await store.close()
    }

    @Test("The list still renders with the menu attached")
    func rendersWithMenu() async throws {
        let store = await Fixture.loadedStore()
        store.selection = Set(store.visibleIssues.prefix(2).map(\Bead.id))

        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "list-context-menu",
            size: CGSize(width: 1100, height: 400)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }
}
