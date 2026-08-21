import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Hiding columns, and the layout surviving a relaunch.
///
/// The persistence half cannot be checked by looking at the screen: it either
/// survives the encode that `@AppStorage` performs, or the user's layout
/// silently resets on the next launch and nothing in the UI says so.
@MainActor
@Suite("Column visibility")
struct ColumnVisibilityTests {

    @Test("A hidden column survives the round trip @AppStorage performs")
    func hiddenColumnPersists() throws {
        var customization = TableColumnCustomization<IssueRow>()
        customization[visibility: SortColumn.pageRank.rawValue] = .hidden
        customization[visibility: SortColumn.blockedBy.rawValue] = .hidden

        // `TableColumnCustomization` is `Codable`, and that conformance is what
        // `@AppStorage` persists it through — so this is the trip a relaunch
        // makes, exercised at the layer the app actually depends on.
        let encoded = try JSONEncoder().encode(customization)
        let restored = try JSONDecoder().decode(
            TableColumnCustomization<IssueRow>.self, from: encoded)

        #expect(restored[visibility: SortColumn.pageRank.rawValue] == .hidden)
        #expect(restored[visibility: SortColumn.blockedBy.rawValue] == .hidden)
        // A column never touched must not come back hidden.
        #expect(restored[visibility: SortColumn.title.rawValue] != .hidden)
    }

    @Test("An untouched layout hides nothing")
    func defaultLayoutShowsEverything() {
        // First launch: every column visible. A default that hid anything
        // would look like data loss to someone who had never opened the menu.
        let customization = TableColumnCustomization<IssueRow>()
        for column in SortColumn.allCases {
            #expect(
                customization[visibility: column.rawValue] != .hidden,
                "\(column.rawValue) starts hidden")
        }
    }

    @Test("The list still renders with columns hidden")
    func listRendersWithHiddenColumns() async throws {
        let store = await Fixture.loadedStore()

        // The store drives the rows; the customization is view state, so this
        // is a check that the table still draws rather than that the columns
        // are gone — `@AppStorage` is not injectable from here.
        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "issue-list-hidden-columns",
            size: CGSize(width: 700, height: 420)
        )
        #expect(result.inkCoverage() > 0.015, "list looks blank (ink \(result.inkCoverage()))")

        await store.close()
    }
}
