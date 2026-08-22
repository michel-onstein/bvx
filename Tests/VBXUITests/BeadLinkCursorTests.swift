import AppKit
import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The pointer and tooltip over a linked bead id.
///
/// `vbx-tdk` shipped believing the attribute approach worked, because the
/// tests asserted what SwiftUI was *told* rather than what AppKit received.
/// These assert the second thing: where the cursor rect actually lands.
@MainActor
@Suite("Bead link cursors")
struct BeadLinkCursorTests {

    private let titles = ["vbx-8ou": "Bind git correlation engine through the bridge"]

    /// Hosts prose and returns the host, laid out.
    private func hosted(_ source: String, width: CGFloat = 420) -> NSHostingView<AnyView> {
        let view = MarkdownText(source: source, beadTitles: titles)
            .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 80)

        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(host.frame, display: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }

    @Test("The backing field still carries the link, and still drops the cursor")
    func backingFieldState() throws {
        // Both halves are load-bearing. The link is what the rects are derived
        // from; the missing cursor attribute is why this overlay exists at all.
        // If a future SwiftUI starts honouring `appKit.cursor`, this fails and
        // the overlay can be deleted.
        let host = hosted("work on vbx-8ou first to unblock this")
        let field = try #require(firstTextField(in: host), "no text field backing the prose")
        let attributed = field.attributedStringValue
        let full = NSRange(location: 0, length: attributed.length)

        var linked: [NSRange] = []
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            if value != nil { linked.append(range) }
        }
        #expect(linked.count == 1, "expected one link, found \(linked.count)")

        var cursors = 0
        attributed.enumerateAttribute(.cursor, in: full) { value, _, _ in
            if value != nil { cursors += 1 }
        }
        #expect(cursors == 0, "SwiftUI now carries appKit.cursor — the overlay is redundant")
    }

    @Test("A cursor rect covers the linked id")
    func cursorRectCoversTheLink() throws {
        let host = hosted("work on vbx-8ou first to unblock this")
        let field = try #require(firstTextField(in: host))

        let rects = BeadLinkCursorView.linkRects(near: field, relativeTo: field)
        #expect(rects.count == 1, "expected one link rect, got \(rects.count)")

        let link = try #require(rects.first)
        #expect(link.bead == "vbx-8ou")
        #expect(link.rect.width > 0 && link.rect.height > 0, "the rect is empty")

        // It must cover the id rather than the whole line: the phrase is much
        // longer than the id, so a rect spanning the field would mean the
        // pointer changed over ordinary prose too.
        #expect(
            link.rect.width < field.bounds.width * 0.6,
            "rect spans \(link.rect.width) of \(field.bounds.width) — that is the whole line")
        // And it starts after "work on ", not at the leading edge.
        #expect(link.rect.minX > 0, "the rect starts at the leading edge, before the id")
    }

    @Test("Prose with no known bead gets no cursor rects")
    func unknownIDGetsNothing() throws {
        // A stale id stays plain text, so there is nothing to point at.
        let host = hosted("vbx-nope was closed long ago")
        guard let field = firstTextField(in: host) else { return }
        #expect(BeadLinkCursorView.linkRects(near: field, relativeTo: field).isEmpty)
    }

    @Test("The overlay never takes a click")
    func overlayIsTransparentToClicks() {
        // The link underneath has to stay clickable and the text selectable.
        let view = BeadLinkCursorView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        #expect(view.hitTest(NSPoint(x: 100, y: 20)) == nil)
    }
}
