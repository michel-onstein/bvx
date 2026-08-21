import VBXCore
import SwiftUI

/// Renders bead prose, as Markdown when it contains any.
///
/// Plain text passes through untouched: a description that merely mentions
/// `snake_case` or a bare asterisk should read exactly as written, so the
/// Markdown path only engages when `looksLikeMarkdown` finds an unambiguous
/// construct.
struct MarkdownText: View {
    let source: String
    var font: Font = .callout
    /// Titles of the beads this workspace holds, keyed by id.
    ///
    /// An id in the prose becomes a link only when it appears here, and the
    /// title is what the link carries as its tooltip. Empty means no
    /// linkification at all, which is what keeps the component usable from
    /// contexts that have no workspace.
    var beadTitles: [String: String] = [:]

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(source)
    }

    var body: some View {
        if !MarkdownParser.looksLikeMarkdown(source) {
            // Plain prose still gets bead links: "work on vbx-8ou first" is
            // the commonest way one bead cites another, and it contains no
            // Markdown at all.
            plain(source)
                .font(font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 3 : 1)

        case .paragraph(let text):
            inline(text)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", content: item)
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", content: item)
                }
            }

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 2) {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Code must not re-wrap: a wrapped line changes what the code
                // says. It scrolls horizontally instead.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }

        case .quote(let text):
            // The rule is an overlay rather than an HStack sibling: a bare
            // Rectangle is greedy and would stretch to consume whatever
            // vertical space the container has left, drawing a bar far taller
            // than the quote itself. As an overlay it inherits the text height.
            inline(text)
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.tertiary)
                        .frame(width: 2)
                }

        case .table(let headers, let rows, let alignments):
            // A table does not reflow: narrowing a column would change which
            // cell a value sits under. It scrolls horizontally instead — the
            // same choice the code block makes, for the same reason.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                            inline(cell)
                                .font(font.weight(.semibold))
                                // Column alignment belongs on the first row's
                                // cells; Grid then applies it down the column.
                                .gridColumnAlignment(columnAlignment(alignments, column))
                        }
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(max(1, headers.count))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(font)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .rule:
            Divider().padding(.vertical, 1)
        }
    }

    private func columnAlignment(
        _ alignments: [MarkdownTableAlignment], _ column: Int
    ) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func listRow(marker: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(font)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            inline(content)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Resolves inline spans — emphasis, code, links — leaving block structure
    /// to the parser above. Falls back to the raw string if the span markup is
    /// malformed, so bad input still renders rather than vanishing.
    private func inline(_ text: String) -> Text {
        Text(inlineAttributed(text))
    }

    /// The attributed form of one inline span: Markdown spans resolved, bead
    /// ids linked. Split out from ``inline(_:)`` so tests can assert on the
    /// attributes rather than on a `Text` they cannot inspect.
    func inlineAttributed(_ text: String) -> AttributedString {
        guard
            var attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            return plainAttributed(text)
        }
        linkBeadReferences(in: &attributed)
        return attributed
    }

    /// Renders text with no Markdown interpretation, but still linked.
    private func plain(_ text: String) -> Text {
        Text(plainAttributed(text))
    }

    func plainAttributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        linkBeadReferences(in: &attributed)
        return attributed
    }

    /// Turns bead ids in `attributed` into links that select the bead.
    ///
    /// This runs on the *parsed* spans rather than the raw source, and that
    /// ordering is the whole point: after parsing, an id written inside `code`
    /// carries `.code` and is skipped, so it stays literal instead of becoming
    /// a link in the middle of a snippet. Runs that already carry a link — an
    /// explicit `[label](target)` — are left alone too.
    func linkBeadReferences(in attributed: inout AttributedString) {
        guard !beadTitles.isEmpty else { return }
        let known = Set(beadTitles.keys)

        // Collected first, applied after: setting an attribute splits the run
        // being iterated, and mutating mid-iteration would skip matches.
        var edits: [(range: Range<AttributedString.Index>, id: String)] = []

        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { continue }
            if run.link != nil { continue }

            let text = String(attributed[run.range].characters)
            for match in BeadReferences.ranges(in: text, known: known) {
                let lower = text.distance(from: text.startIndex, to: match.lowerBound)
                let upper = text.distance(from: text.startIndex, to: match.upperBound)
                // Both offsets come from this run's own characters, so they
                // are in bounds by construction.
                let start = attributed.index(run.range.lowerBound, offsetByCharacters: lower)
                let end = attributed.index(run.range.lowerBound, offsetByCharacters: upper)
                edits.append((start..<end, String(text[match])))
            }
        }

        for edit in edits {
            attributed[edit.range].link = BeadURL.open(bead: edit.id)
            // The title rides along as a tooltip so hovering answers "which
            // bead is that?" without a round trip through the list.
            attributed[edit.range].appKit.toolTip = beadTitles[edit.id]

            // The tint is set explicitly even though SwiftUI already draws a
            // link in the accent colour: relying on that default leaves the
            // styling at the mercy of whatever context the text is rendered
            // in, and it is the underline below that has to agree with it.
            attributed[edit.range].foregroundColor = .accentColor
            // Colour alone is a weak signal in dense prose — and no signal at
            // all for a colour-blind reader. The underline is the conventional
            // "this is a link" mark and needs no colour to read.
            attributed[edit.range].underlineStyle = .single
            // The pointer is the affordance that says "clickable" before you
            // click. Scoped to the linked range as an attribute rather than an
            // `onHover` on the whole `Text`, which would change the cursor over
            // unlinked prose too. `.pointerStyle(.link)` would be the modern
            // spelling but it is macOS 15 and this package targets 14.
            attributed[edit.range].appKit.cursor = .pointingHand
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        case 3: .subheadline.weight(.semibold)
        default: .callout.weight(.semibold)
        }
    }
}
