import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The accent rule that shows where columns were hidden.
///
/// Serialized because every case here seeds `UserDefaults.standard` — the store
/// `@AppStorage` reads — and Swift Testing runs tests in parallel by default.
/// Two of these overlapping would each see the other's layout.
@MainActor
@Suite("Hidden column markers", .serialized)
struct HiddenColumnMarkerTests {

    private static let storageKey = "issueListColumnCustomization"

    /// Hosts the real list with `hidden` put away, and hands back the backing
    /// table alongside the overlay the markers are measured against.
    private func hostedTable(
        hiding hidden: [SortColumn]
    ) async throws -> (table: NSTableView, overlay: NSView, store: ProjectStore) {
        var customization = TableColumnCustomization<IssueRow>()
        for column in hidden {
            customization[visibility: column.rawValue] = .hidden
        }
        // @AppStorage persists this as JSON Data; seeding the same shape is
        // what puts a layout in front of the view before it is built.
        UserDefaults.standard.set(
            try JSONEncoder().encode(customization), forKey: Self.storageKey)

        let store = await Fixture.loadedStore()
        let host = NSHostingView(
            rootView: AnyView(
                IssueListView().environmentObject(store).frame(width: 900, height: 400)))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 400)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        // The table resolves its columns on the run loop, not inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let table = try #require(
            Self.firstTableView(in: host),
            "no NSTableView behind SwiftUI's Table — the markers cannot be placed")
        return (table, host, store)
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    private func cleanUp(_ store: ProjectStore) async {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        await store.close()
    }

    @Test("SwiftUI's Table is still backed by an NSTableView")
    func backingTableIsReachable() async throws {
        // This is the assumption the whole feature rests on, and it is an
        // implementation detail rather than a contract. If a future macOS backs
        // Table with something else, this fails loudly here instead of the
        // markers quietly never appearing.
        let (table, _, store) = try await hostedTable(hiding: [])
        #expect(table.tableColumns.count == 10)
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        await cleanUp(store)
    }

    @Test("Hiding Status marks the gap between Title and Blocks")
    func hidingStatusPlacesOneMarker() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [.status])

        // A hidden column stays in tableColumns, marked hidden — that is what
        // makes the run detectable at all.
        let status = try #require(
            table.tableColumns.first { $0.headerCell.stringValue == "Status" })
        #expect(status.isHidden, "Status did not hide")

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 1, "expected one marker, got \(markers.count)")
        #expect(markers.first?.titles == ["Status"])

        // It belongs between the two columns now adjacent, not somewhere else
        // on the row.
        let titleIndex = try #require(
            table.tableColumns.firstIndex { $0.headerCell.stringValue == "Title" })
        let blocksIndex = try #require(
            table.tableColumns.firstIndex { $0.headerCell.stringValue == "Blocks" })
        let titleRect = table.rect(ofColumn: titleIndex)
        let blocksRect = table.rect(ofColumn: blocksIndex)
        let x = try #require(markers.first?.x)
        #expect(
            x >= titleRect.maxX - 1 && x <= blocksRect.minX + 1,
            "marker at \(x) is outside \(titleRect.maxX)...\(blocksRect.minX)")

        await cleanUp(store)
    }

    @Test("Adjacent hidden columns collapse into a single marker")
    func adjacentHiddenColumnsShareAMarker() async throws {
        // The behaviour that makes "unhide the group" meaningful: two rules
        // side by side would be two clicks to undo one action.
        let (table, overlay, store) = try await hostedTable(hiding: [.blocks, .blockedBy])

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 1, "adjacent hidden columns drew \(markers.count) markers")
        #expect(markers.first?.titles == ["Blocks", "Blocked by"])

        await cleanUp(store)
    }

    @Test("Non-adjacent hidden columns get a marker each")
    func separatedHiddenColumnsGetTheirOwnMarkers() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [.status, .labels])

        let markers = HiddenColumnMarkerView.markers(in: table, relativeTo: overlay)
        #expect(markers.count == 2, "expected two separate markers, got \(markers.count)")
        #expect(markers.map(\.titles) == [["Status"], ["Labels"]])

        await cleanUp(store)
    }

    @Test("With nothing hidden there is no rule to draw")
    func nothingHiddenDrawsNothing() async throws {
        let (table, overlay, store) = try await hostedTable(hiding: [])
        #expect(HiddenColumnMarkerView.markers(in: table, relativeTo: overlay).isEmpty)
        await cleanUp(store)
    }

    @Test("Every column title maps to a customization ID")
    func titlesCoverEveryColumn() async throws {
        // The double-click restores columns by header title, so a title missing
        // from the map is a column that can be hidden and never brought back.
        let (table, _, store) = try await hostedTable(hiding: [])
        for column in table.tableColumns {
            let title = column.headerCell.stringValue
            // The type glyph is headerless and cannot be hidden, so it needs no
            // entry.
            guard !title.isEmpty else { continue }
            #expect(
                IssueListView.columnIDsByTitle[title] != nil,
                "\(title) has no customization ID, so it could not be unhidden")
        }
        await cleanUp(store)
    }

    @Test("The overlay only intercepts clicks on a rule")
    func overlayLetsOtherClicksThrough() {
        // Without this the overlay would swallow row selection, the header and
        // the context menu — a far worse bug than the one it fixes.
        let view = HiddenColumnMarkerView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(view.hitTest(NSPoint(x: 200, y: 100)) == nil, "empty overlay captured a click")
    }
}
