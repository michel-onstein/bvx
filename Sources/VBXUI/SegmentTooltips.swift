import AppKit
import SwiftUI

/// Gives each segment of a segmented picker its own tooltip.
///
/// SwiftUI has no way to do this. `.help` on the `Label` inside the picker's
/// `ForEach` does not reach the segments — measured: with a `.help` on every
/// one of the twelve labels, `toolTip(forSegment:)` is nil for all twelve, and
/// the control's own tooltip is nil too. A segmented picker is rendered as a
/// single `NSSegmentedControl`, and per-segment tooltips are an AppKit-level
/// property with no SwiftUI surface.
///
/// The alternative the bead proposed — replacing the picker with an `HStack`
/// of toggle-styled buttons — would give each its own `.help`, but it costs the
/// picker's keyboard handling and its system styling for a tooltip. This keeps
/// the control and reaches past SwiftUI for the one property it does not
/// expose.
///
/// Placed as a `background`, so it takes no space and never intercepts a click.
/// **Fails soft**: no control found means no tooltips and a picker that still
/// works.
struct SegmentTooltips: NSViewRepresentable {
    /// One tooltip per segment, in the order the segments are declared.
    let tooltips: [String]

    func makeNSView(context: Context) -> SegmentTooltipView {
        let view = SegmentTooltipView()
        view.tooltips = tooltips
        return view
    }

    func updateNSView(_ view: SegmentTooltipView, context: Context) {
        view.tooltips = tooltips
        view.apply()
    }
}

/// Finds the segmented control beside it and labels its segments.
final class SegmentTooltipView: NSView {

    var tooltips: [String] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    /// Writes the tooltips onto the control, if it is there.
    func apply() {
        guard let control = Self.segmentedControl(near: self) else { return }
        Self.apply(tooltips, to: control)
    }

    /// Exposed for tests: assigns as many tooltips as there are segments.
    ///
    /// A mismatch is survivable rather than fatal — one fewer tooltip is
    /// better than a crash — but the count is asserted in tests, because a
    /// silent off-by-one would label every view with its neighbour's name,
    /// which is worse than no tooltip at all.
    static func apply(_ tooltips: [String], to control: NSSegmentedControl) {
        for index in 0..<min(tooltips.count, control.segmentCount) {
            control.setToolTip(tooltips[index], forSegment: index)
        }
    }

    /// The segmented control this view was placed behind.
    ///
    /// Searched from the nearest ancestor that contains one, rather than from
    /// the window: a toolbar holds several segmented pickers — view, filter,
    /// sort — and starting at the top would label the wrong one.
    static func segmentedControl(near view: NSView) -> NSSegmentedControl? {
        var current: NSView? = view.superview
        for _ in 0..<4 {
            guard let candidate = current else { return nil }
            if let found = firstSegmentedControl(in: candidate) { return found }
            current = candidate.superview
        }
        return nil
    }

    private static func firstSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let found = firstSegmentedControl(in: subview) { return found }
        }
        return nil
    }
}
