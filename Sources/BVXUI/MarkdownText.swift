import BVXCore
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

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(source)
    }

    var body: some View {
        if !MarkdownParser.looksLikeMarkdown(source) {
            Text(source)
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

        case .rule:
            Divider().padding(.vertical, 1)
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
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            return Text(attributed)
        }
        return Text(text)
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
