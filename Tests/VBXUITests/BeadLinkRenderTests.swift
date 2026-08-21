import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// Linkification of bead ids mentioned in prose.
///
/// The interesting cases are all about *where* linking must not happen: inside
/// code, inside an explicit link, and for ids the workspace does not hold.
@MainActor
@Suite("Bead links")
struct BeadLinkRenderTests {

    private let titles = [
        "vbx-8ou": "Bind git correlation engine through the bridge",
        "vbx-v49": "History view: bead-to-commit correlation",
    ]

    private func component(_ source: String) -> MarkdownText {
        MarkdownText(source: source, beadTitles: titles)
    }

    /// The ids carrying a link attribute, in order.
    private func linkedIDs(_ attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            guard let link = run.link, let id = BeadURL.bead(in: link) else { return nil }
            return id
        }
    }

    @Test("An id in plain prose becomes a link")
    func linksPlainProse() {
        let source = "work on vbx-8ou first to unblock this"
        // Premise: this is not Markdown at all, so it takes the plain path.
        #expect(!MarkdownParser.looksLikeMarkdown(source))

        let attributed = component(source).plainAttributed(source)
        #expect(linkedIDs(attributed) == ["vbx-8ou"])
    }

    @Test("An id inside inline code stays literal")
    func skipsInlineCode() {
        // The regression this guards: linkifying the raw source instead of the
        // parsed spans would turn an id inside a snippet into a link, which
        // changes what the snippet says.
        let attributed = component("run `br show vbx-8ou --json` to see it")
            .inlineAttributed("run `br show vbx-8ou --json` to see it")
        #expect(linkedIDs(attributed).isEmpty)
    }

    @Test("An id outside code is still linked when code sits beside it")
    func linksAroundCode() {
        let source = "vbx-8ou is next; run `br show vbx-v49` for the other"
        let attributed = component(source).inlineAttributed(source)
        // Only the bare mention links; the one inside the snippet does not.
        #expect(linkedIDs(attributed) == ["vbx-8ou"])
    }

    @Test("An explicit Markdown link is left as the author wrote it")
    func skipsExplicitLinks() {
        let source = "see [vbx-8ou](https://example.com/x) for detail"
        let attributed = component(source).inlineAttributed(source)
        // The run already carries a link, so it is not rewritten to vbx://.
        #expect(linkedIDs(attributed).isEmpty)
    }

    @Test("An id the workspace does not hold is not linked")
    func skipsUnknownIDs() {
        let source = "superseded by vbx-999"
        let attributed = component(source).plainAttributed(source)
        #expect(linkedIDs(attributed).isEmpty)
    }

    @Test("The link carries the target's title as a tooltip")
    func carriesTitle() {
        let source = "work on vbx-8ou first"
        let attributed = component(source).plainAttributed(source)
        let tooltips = attributed.runs.compactMap(\.appKit.toolTip)
        #expect(tooltips == ["Bind git correlation engine through the bridge"])
    }

    @Test("With no workspace titles, nothing is linked")
    func inertWithoutTitles() {
        let source = "work on vbx-8ou first"
        let attributed = MarkdownText(source: source).plainAttributed(source)
        #expect(linkedIDs(attributed).isEmpty)
    }

    @Test("Emphasis around an id survives the linking")
    func linksInsideEmphasis() {
        let source = "**vbx-8ou** is the blocker"
        let attributed = component(source).inlineAttributed(source)
        #expect(linkedIDs(attributed) == ["vbx-8ou"])
    }

    @Test("The inspector renders a description containing a bead link")
    func inspectorRendersLinks() async throws {
        let store = await Fixture.loadedStore()
        store.select(id: "vbx-3")
        // The store must be able to answer "does this id exist" for linking.
        #expect(!store.beadTitles.isEmpty)

        let result = try Snapshot.render(
            InspectorView().environmentObject(store),
            name: "inspector-bead-links",
            size: CGSize(width: 340, height: 900)
        )
        #expect(result.inkCoverage() > 0.015)
        await store.close()
    }
}
