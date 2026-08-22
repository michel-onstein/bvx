import AppKit
import SwiftUI
import VBXCore

/// Gives linked bead ids a pointing-hand cursor and a tooltip.
///
/// ## Why this is not just an attribute
///
/// ``MarkdownText`` sets `appKit.cursor` and `appKit.toolTip` on each linked
/// range, and neither survives. Measured by hosting the real view and reading
/// the backing AppKit string: `.link`, the foreground colour and the underline
/// all arrive, while `.cursor` and `.toolTip` are absent. With
/// `.textSelection(.enabled)` SwiftUI hosts the prose in a private
/// `SelectionTextField`, and that bridge drops both — so the click works, the
/// styling works, and every hover affordance silently does not.
///
/// This overlay puts them back the only way available at this deployment
/// target: find the backing field, ask it where the links are, and add real
/// cursor and tooltip rects. `.pointerStyle(.link)` would be the modern
/// spelling and is macOS 15.
///
/// Like ``HiddenColumnMarkers`` it depends on an implementation detail, so it
/// **fails soft** — no field found means no cursor rects and prose that still
/// renders — and it **never intercepts a click**, or it would break the link it
/// exists to advertise, along with text selection.
struct BeadLinkCursors: NSViewRepresentable {
    /// Changing prose rebuilds the rects; the value itself is not read.
    let source: String
    /// Titles by bead id, for the tooltip.
    let beadTitles: [String: String]

    func makeNSView(context: Context) -> BeadLinkCursorView {
        let view = BeadLinkCursorView()
        view.beadTitles = beadTitles
        return view
    }

    func updateNSView(_ view: BeadLinkCursorView, context: Context) {
        view.beadTitles = beadTitles
        view.refresh()
    }
}

/// Holds the cursor and tooltip rects for one run of linked prose.
final class BeadLinkCursorView: NSView {

    /// One linked id on screen.
    struct LinkRect {
        let rect: NSRect
        let bead: String
    }

    var beadTitles: [String: String] = [:]
    private(set) var linkRects: [LinkRect] = []

    override var isFlipped: Bool { true }

    /// Never takes a click. The link underneath must stay clickable and the
    /// text selectable; this view exists only to own cursor and tooltip rects.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let found = Self.linkRects(near: self, relativeTo: self)
        guard found.map(\.rect) != linkRects.map(\.rect) else { return }
        linkRects = found
        window?.invalidateCursorRects(for: self)
        removeAllToolTips()
        for link in linkRects {
            if let title = beadTitles[link.bead] {
                addToolTip(link.rect, owner: title as NSString, userData: nil)
            }
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for link in linkRects {
            addCursorRect(link.rect, cursor: .pointingHand)
        }
    }

    /// Where the linked ids are, in `target`'s coordinates.
    ///
    /// The ranges are not re-derived from the prose: the backing field's own
    /// attributed string still carries `.link` on exactly the id, so enumerating
    /// that attribute asks the renderer where it actually put things rather than
    /// guessing alongside it.
    static func linkRects(near view: NSView, relativeTo target: NSView) -> [LinkRect] {
        guard let root = ancestor(of: view) else { return [] }

        var result: [LinkRect] = []
        for field in textFields(in: root) {
            let attributed = field.attributedStringValue
            guard attributed.length > 0 else { continue }

            attributed.enumerateAttribute(
                .link, in: NSRange(location: 0, length: attributed.length)
            ) { value, range, _ in
                guard let bead = beadID(from: value) else { return }
                for rect in rects(for: range, in: attributed, bounds: field.bounds) {
                    let converted = target.convert(rect, from: field)
                    result.append(LinkRect(rect: converted, bead: bead))
                }
            }
        }
        return result
    }

    /// The bead an attribute value names, if it names one.
    private static func beadID(from value: Any?) -> String? {
        switch value {
        case let url as URL: return BeadURL.bead(in: url)
        case let string as String: return URL(string: string).flatMap(BeadURL.bead(in:))
        default: return nil
        }
    }

    /// The subtree to search: the overlay's sibling content, not the whole
    /// window. Walking up a couple of levels finds the hosted text without
    /// dragging in every other field on screen.
    private static func ancestor(of view: NSView) -> NSView? {
        var current = view.superview
        for _ in 0..<3 {
            guard let candidate = current else { return nil }
            if !textFields(in: candidate).isEmpty { return candidate }
            current = candidate.superview
        }
        return current
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
    }

    /// The on-screen rectangles a character range occupies.
    ///
    /// Laid out through `NSLayoutManager` rather than measured with string
    /// widths: prose wraps, so one range can span lines and produce more than
    /// one rectangle.
    private static func rects(
        for range: NSRange, in attributed: NSAttributedString, bounds: NSRect
    ) -> [NSRect] {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: .infinity))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, _ in
            rects.append(rect)
        }
        return rects
    }
}
