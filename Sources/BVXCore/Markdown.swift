import Foundation

/// A block-level element of a Markdown document.
///
/// Only the constructs that actually appear in bead prose are modelled —
/// headings, paragraphs, lists, fenced code, quotes and rules. Inline spans
/// (emphasis, code, links) are left in the text and resolved at render time by
/// `AttributedString`, which already handles them correctly.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case codeBlock(language: String?, code: String)
    case quote(String)
    case rule
    case table(headers: [String], rows: [[String]], alignments: [MarkdownTableAlignment])
}

/// Column alignment declared by a table's delimiter row.
///
/// `---` and `:---` both mean leading; the colon only changes the outcome on
/// the right-hand side, which is what separates centre from trailing.
public enum MarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

public enum MarkdownParser {

    /// Splits `source` into block-level elements.
    ///
    /// Deliberately line-based rather than a full CommonMark implementation:
    /// bead descriptions are short prose, and a dependency on a full parser
    /// would buy very little. Anything it does not recognise stays a paragraph,
    /// so no text is ever dropped.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(joinSoftWrapped(paragraph)))
            paragraph.removeAll()
        }

        let lines = source.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: everything up to the closing fence is verbatim.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                    !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                {
                    code.append(lines[index])
                    index += 1
                }
                index += 1  // consume the closing fence (or run off the end)
                blocks.append(
                    .codeBlock(
                        language: language.isEmpty ? nil : language,
                        code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Table: a header row followed by a delimiter row.
            //
            // This has to be tested before the paragraph fallback, because
            // `joinSoftWrapped` would otherwise collapse every row onto one
            // line — correct for prose, destructive for a table.
            if trimmed.contains("|"), index + 1 < lines.count,
                let alignments = tableHead(header: line, delimiter: lines[index + 1])
            {
                flushParagraph()
                let headers = normaliseRow(splitTableRow(line), to: alignments.count)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(normaliseRow(splitTableRow(candidate), to: alignments.count))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
                continue
            }

            // Horizontal rule: three or more of - _ * alone on a line.
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                    let next = bulletItem(lines[index].trimmingCharacters(in: .whitespaces))
                {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if let item = numberedItem(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                    let next = numberedItem(lines[index].trimmingCharacters(in: .whitespaces))
                {
                    items.append(next)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(joinSoftWrapped(quoted)))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    /// Joins the lines of a paragraph the way Markdown means them.
    ///
    /// A lone newline inside a paragraph is a *soft* break and renders as a
    /// space; preserving it literally breaks sentences mid-clause wherever the
    /// author happened to wrap. A hard break — two trailing spaces, or a
    /// trailing backslash — is kept.
    static func joinSoftWrapped(_ lines: [String]) -> String {
        var out = ""
        var previousWasHardBreak = false

        for (index, raw) in lines.enumerated() {
            let isHardBreak = raw.hasSuffix("  ") || raw.hasSuffix("\\")
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("\\") { text = String(text.dropLast()) }

            if index > 0 {
                out += previousWasHardBreak ? "\n" : " "
            }
            out += text
            previousWasHardBreak = isHardBreak
        }
        return out
    }

    // MARK: - Line classifiers

    static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard (1...6).contains(level) else { return nil }
        let rest = String(line.dropFirst(level))
        // "#hashtag" is not a heading; ATX requires a space after the run.
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tables

    /// Splits one table row into trimmed cells.
    ///
    /// The optional leading and trailing pipes are dropped first, so `| a | b |`
    /// and `a | b` both yield two cells. A pipe written `\|` is literal content
    /// and does not split the row.
    static func splitTableRow(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text = String(text.dropFirst()) }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text = String(text.dropLast()) }

        var cells: [String] = []
        var current = ""
        var escaped = false

        for character in text {
            if escaped {
                // Only the pipe is meaningfully escapable here. Anything else
                // keeps its backslash, so code-ish cell content survives.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "|":
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Reads a delimiter row (`|---|:--:|---:|`) into per-column alignments.
    ///
    /// Returns nil unless every cell is a run of dashes carrying optional
    /// alignment colons.
    static func tableDelimiter(_ line: String) -> [MarkdownTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        for cell in splitTableRow(trimmed) {
            var body = Substring(cell)
            let leading = body.hasPrefix(":")
            if leading { body = body.dropFirst() }
            let trailing = body.hasSuffix(":")
            if trailing { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }

            switch (leading, trailing) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// The alignments of the table `header` opens, or nil if it opens none.
    ///
    /// The delimiter row must carry exactly as many cells as the header — GFM's
    /// own rule, and the one that stops prose like `use a | b to pipe` followed
    /// by a `---` rule from being misread as a one-column table.
    static func tableHead(header: String, delimiter: String) -> [MarkdownTableAlignment]? {
        guard !header.trimmingCharacters(in: .whitespaces).isEmpty,
            let alignments = tableDelimiter(delimiter),
            splitTableRow(header).count == alignments.count
        else { return nil }
        return alignments
    }

    /// Pads or truncates a row to the table's column count.
    ///
    /// A ragged row otherwise shifts every cell after it into the wrong
    /// column, which misreports the data rather than merely looking untidy.
    static func normaliseRow(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" } || line.allSatisfy { $0 == "*" }
            || line.allSatisfy { $0 == "_" }
    }

    // MARK: - Detection

    /// True when `source` contains Markdown worth rendering as such.
    ///
    /// Conservative on purpose. Bead prose is full of identifiers like
    /// `data_hash` and `issue_id`, so single underscores are *not* treated as
    /// emphasis — mangling a field name is worse than leaving one italic
    /// unrendered. Only unambiguous constructs count.
    public static func looksLikeMarkdown(_ source: String) -> Bool {
        guard !source.isEmpty else { return false }

        if source.contains("```") { return true }
        if source.contains("`") { return true }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if parseHeading(line) != nil { return true }
            if bulletItem(line) != nil { return true }
            if numberedItem(line) != nil { return true }
            if line.hasPrefix("> ") { return true }
            if isRule(line) { return true }
        }

        if source.contains("**") { return true }
        if containsLink(source) { return true }

        // A pipe only signals a table when a delimiter row follows it, so
        // prose containing a stray pipe stays plain text.
        let lines = source.components(separatedBy: .newlines)
        for index in lines.indices.dropLast() where lines[index].contains("|") {
            if tableHead(header: lines[index], delimiter: lines[index + 1]) != nil { return true }
        }
        return false
    }

    /// Matches an inline link: `[label](target)` with both parts non-empty.
    static func containsLink(_ source: String) -> Bool {
        guard let open = source.firstIndex(of: "[") else { return false }
        let afterOpen = source.index(after: open)
        guard afterOpen < source.endIndex,
            let close = source[afterOpen...].firstIndex(of: "]")
        else { return false }
        let afterClose = source.index(after: close)
        guard afterClose < source.endIndex, source[afterClose] == "(",
            let paren = source[afterClose...].firstIndex(of: ")")
        else { return false }

        let label = source[afterOpen..<close]
        let target = source[source.index(after: afterClose)..<paren]
        return !label.isEmpty && !target.isEmpty
    }
}
