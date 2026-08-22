import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Per-segment tooltips on the view switcher.
///
/// The switcher is `.labelStyle(.iconOnly)`, so the glyph is the only clue what
/// a segment does. One tooltip on the whole control said "Switch view" twelve
/// times, which answers a question nobody was asking.
@MainActor
@Suite("View switcher tooltips")
struct SegmentTooltipTests {

    @Test("Every view has a distinct tooltip naming it")
    func tooltipsAreDistinctAndNameTheView() {
        let tooltips = ContentView.surfaceTooltips

        #expect(tooltips.count == ViewSurface.allCases.count)
        #expect(Set(tooltips).count == tooltips.count, "two segments share a tooltip")

        // Built from displayName, so the tooltip, the sidebar row and the View
        // menu cannot drift apart.
        for (surface, tooltip) in zip(ViewSurface.allCases, tooltips) {
            #expect(
                tooltip.hasPrefix(surface.displayName),
                "\(tooltip) does not name \(surface.displayName)")
            #expect(
                tooltip.contains("⌘\(surface.keyEquivalent.character)"),
                "\(tooltip) does not carry the shortcut")
        }
    }

    @Test("The tooltips actually reach the segments")
    func tooltipsLandOnTheControl() {
        // The assertion that matters, and the one whose absence would have let
        // this ship broken: `.help` on the labels inside the picker reaches
        // nothing — measured, every segment nil — so the tooltips are written
        // onto the AppKit control directly and this checks they arrived.
        let control = NSSegmentedControl()
        control.segmentCount = ViewSurface.allCases.count

        SegmentTooltipView.apply(ContentView.surfaceTooltips, to: control)

        for index in 0..<control.segmentCount {
            #expect(
                control.toolTip(forSegment: index) == ContentView.surfaceTooltips[index],
                "segment \(index) carries \(control.toolTip(forSegment: index) ?? "nil")")
        }
    }

    @Test("A short list labels what it can rather than crashing")
    func fewerTooltipsThanSegmentsIsSurvivable() {
        // A mismatch should degrade, not trap — but the count is asserted above
        // precisely because a silent off-by-one would label every view with its
        // neighbour's name, which is worse than no tooltip.
        let control = NSSegmentedControl()
        control.segmentCount = 3
        SegmentTooltipView.apply(["One"], to: control)

        #expect(control.toolTip(forSegment: 0) == "One")
        #expect(control.toolTip(forSegment: 1) == nil)
    }

    @Test("The picker still renders with the tooltip layer behind it")
    func pickerStillRenders() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            ContentView().environmentObject(store),
            name: "content-with-segment-tooltips",
            size: CGSize(width: 1100, height: 600))
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }
}
