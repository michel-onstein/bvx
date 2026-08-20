import Foundation
import Testing

@testable import BVXCore

// MARK: - Detection
//
// The detector decides whether prose is rendered as Markdown or verbatim.
// Over-eager detection is the dangerous direction: bead descriptions are full
// of identifiers, and italicising half of `data_hash` corrupts what the author
// wrote.

@Test(
    "Unambiguous Markdown is detected",
    arguments: [
        "# Heading",
        "## Sub heading",
        "- a bullet",
        "* a bullet",
        "+ a bullet",
        "1. numbered",
        "2) numbered",
        "> quoted",
        "---",
        "some `inline code`",
        "a ```fence```",
        "**bold**",
        "a [link](https://example.com)",
    ])
func detectsMarkdown(source: String) {
    #expect(MarkdownParser.looksLikeMarkdown(source), "should detect: \(source)")
}

@Test(
    "Plain prose is left alone",
    arguments: [
        "",
        "Just a sentence.",
        "Two sentences. No markup at all.",
        // Identifiers must not read as emphasis.
        "The data_hash and issue_id fields are compared.",
        "Set BV_MAX_LINE_SIZE_MB to raise the cap.",
        "snake_case_name and another_one",
        // A bare asterisk or hash is not markup.
        "5 * 3 = 15",
        "issue #42 was filed",
        "a - b is not a list",
        // A bracket without a link target.
        "an [aside] with no target",
    ])
func leavesPlainProseAlone(source: String) {
    #expect(
        !MarkdownParser.looksLikeMarkdown(source),
        "should NOT detect markdown in: \(source)")
}

// MARK: - Block parsing

@Test("Headings parse by level, and only with a space after the hashes")
func headings() {
    #expect(MarkdownParser.parse("# One") == [.heading(level: 1, text: "One")])
    #expect(MarkdownParser.parse("### Three") == [.heading(level: 3, text: "Three")])
    // Seven hashes is not a heading level.
    #expect(MarkdownParser.parse("####### Nope") == [.paragraph("####### Nope")])
    // A hashtag is not a heading.
    #expect(MarkdownParser.parse("#hashtag") == [.paragraph("#hashtag")])
}

@Test("Consecutive bullets collapse into one list")
func bulletList() {
    let blocks = MarkdownParser.parse("- one\n- two\n- three")
    #expect(blocks == [.bulletList(["one", "two", "three"])])
}

@Test("Numbered lists accept both . and ) delimiters")
func numberedList() {
    #expect(MarkdownParser.parse("1. a\n2. b") == [.numberedList(["a", "b"])])
    #expect(MarkdownParser.parse("1) a\n2) b") == [.numberedList(["a", "b"])])
}

@Test("Fenced code keeps its content verbatim, including blank lines")
func codeBlock() {
    let source = "```swift\nlet a = 1\n\nlet b = 2\n```"
    #expect(
        MarkdownParser.parse(source)
            == [.codeBlock(language: "swift", code: "let a = 1\n\nlet b = 2")])
}

@Test("An unterminated fence still yields a code block rather than dropping text")
func unterminatedCodeBlock() {
    // Truncated prose is common; losing the tail silently would be worse than
    // rendering it as code.
    let blocks = MarkdownParser.parse("```\nstill code")
    #expect(blocks == [.codeBlock(language: nil, code: "still code")])
}

@Test("Markdown inside a fence is not interpreted")
func fenceIsOpaque() {
    let blocks = MarkdownParser.parse("```\n# not a heading\n- not a list\n```")
    #expect(blocks == [.codeBlock(language: nil, code: "# not a heading\n- not a list")])
}

@Test("Consecutive quote lines join into one block")
func quote() {
    #expect(MarkdownParser.parse("> one\n> two") == [.quote("one two")])
}

@Test("Rules need three or more repeated marks")
func rules() {
    #expect(MarkdownParser.parse("---") == [.rule])
    #expect(MarkdownParser.parse("***") == [.rule])
    // Two dashes is prose, not a rule.
    #expect(MarkdownParser.parse("--") == [.paragraph("--")])
}

@Test("Blank lines separate paragraphs; single newlines do not")
func paragraphs() {
    // A lone newline is a soft break: it joins with a space rather than
    // splitting the sentence wherever the author happened to wrap.
    #expect(
        MarkdownParser.parse("one\ntwo\n\nthree")
            == [.paragraph("one two"), .paragraph("three")])
}

@Test("Hard breaks survive, soft breaks become spaces")
func lineBreaks() {
    // Two trailing spaces, or a trailing backslash, mean a real line break.
    #expect(MarkdownParser.joinSoftWrapped(["one  ", "two"]) == "one\ntwo")
    #expect(MarkdownParser.joinSoftWrapped(["one\\", "two"]) == "one\ntwo")
    #expect(MarkdownParser.joinSoftWrapped(["one", "two"]) == "one two")
    #expect(MarkdownParser.joinSoftWrapped(["only"]) == "only")
    #expect(MarkdownParser.joinSoftWrapped([]) == "")
}

@Test("A wrapped sentence reads as one line")
func wrappedSentenceJoins() {
    // Regression: the inspector broke this mid-clause after "the real".
    let source = "Wraps the C ABI in an actor so calls serialise while the real\nconcurrency stays inside Go."
    #expect(
        MarkdownParser.parse(source)
            == [.paragraph("Wraps the C ABI in an actor so calls serialise while the real concurrency stays inside Go.")])
}

@Test("Quotes soft-wrap too")
func quoteSoftWraps() {
    #expect(MarkdownParser.parse("> one\n> two") == [.quote("one two")])
}

@Test("A mixed document parses into the right sequence of blocks")
func mixedDocument() {
    let source = """
        ## Title

        Intro line.

        - first
        - second

        ```swift
        let x = 1
        ```

        > note

        Closing.
        """
    #expect(
        MarkdownParser.parse(source) == [
            .heading(level: 2, text: "Title"),
            .paragraph("Intro line."),
            .bulletList(["first", "second"]),
            .codeBlock(language: "swift", code: "let x = 1"),
            .quote("note"),
            .paragraph("Closing."),
        ])
}

@Test("No text is ever dropped")
func parsingIsLossless() {
    // Every non-blank source line must survive into some block. A parser that
    // silently swallows a line is worse than one that renders it plainly.
    let source = """
        # Heading
        Paragraph one.

        - item a
        - item b

        1. step one

        > quoted line

        ```
        code line
        ```

        Trailing paragraph.
        """
    var rendered = ""
    for block in MarkdownParser.parse(source) {
        switch block {
        case .heading(_, let t): rendered += t + "\n"
        case .paragraph(let t): rendered += t + "\n"
        case .bulletList(let items), .numberedList(let items):
            rendered += items.joined(separator: "\n") + "\n"
        case .codeBlock(_, let code): rendered += code + "\n"
        case .quote(let t): rendered += t + "\n"
        case .rule: rendered += "\n"
        case .table(let headers, let rows, _):
            rendered += headers.joined(separator: " ") + "\n"
            for row in rows { rendered += row.joined(separator: " ") + "\n" }
        }
    }

    for line in source.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("```") else { continue }
        // Strip the marker the parser legitimately consumes.
        let content =
            MarkdownParser.parseHeading(trimmed).map { block -> String in
                if case .heading(_, let t) = block { return t }
                return trimmed
            }
            ?? MarkdownParser.bulletItem(trimmed)
            ?? MarkdownParser.numberedItem(trimmed)
            ?? (trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : trimmed)

        #expect(rendered.contains(content), "lost line: \(line)")
    }
}

@Test("Empty and whitespace-only sources parse to nothing")
func emptySources() {
    #expect(MarkdownParser.parse("").isEmpty)
    #expect(MarkdownParser.parse("\n\n  \n").isEmpty)
}

// MARK: - Tables
//
// The regression these lock in: before table support, a pipe table beside any
// other Markdown fell through to the paragraph branch and `joinSoftWrapped`
// collapsed every row onto a single line.

@Test("A pipe table parses into headers and rows rather than a paragraph")
func parsesTable() {
    let source = """
        | Metric | Value |
        |---|---|
        | PageRank | 0.20 |
        | Betweenness | 0.35 |
        """
    #expect(MarkdownParser.looksLikeMarkdown(source))

    let blocks = MarkdownParser.parse(source)
    #expect(blocks.count == 1)
    guard case .table(let headers, let rows, let alignments) = blocks.first else {
        Issue.record("expected a table, got \(blocks)")
        return
    }
    #expect(headers == ["Metric", "Value"])
    #expect(rows == [["PageRank", "0.20"], ["Betweenness", "0.35"]])
    #expect(alignments == [.leading, .leading])
}

@Test("A table beside other Markdown still parses as a table")
func tableAmongProse() {
    // The bad case from the bug report: detection fired on the heading, and
    // the rows were then collapsed onto one line by the paragraph branch.
    let source = """
        ## Metrics

        | Metric | Value |
        |---|---|
        | PageRank | 0.20 |

        See **ADR-001**.
        """
    let blocks = MarkdownParser.parse(source)
    let tables = blocks.compactMap { block -> [[String]]? in
        if case .table(_, let rows, _) = block { return rows }
        return nil
    }
    #expect(tables.count == 1)
    #expect(tables.first == [["PageRank", "0.20"]])
    // And the prose around it survived as its own blocks.
    #expect(blocks.contains(.heading(level: 2, text: "Metrics")))
    #expect(blocks.contains(.paragraph("See **ADR-001**.")))
}

@Test("Leading and trailing pipes are optional")
func pipelessTable() {
    let blocks = MarkdownParser.parse("Metric | Value\n--- | ---\nPageRank | 0.20")
    guard case .table(let headers, let rows, _) = blocks.first else {
        Issue.record("expected a table, got \(blocks)")
        return
    }
    #expect(headers == ["Metric", "Value"])
    #expect(rows == [["PageRank", "0.20"]])
}

@Test("Alignment colons are read per column")
func tableAlignments() {
    let blocks = MarkdownParser.parse("| a | b | c | d |\n|:---|:--:|---:|---|\n| 1 | 2 | 3 | 4 |")
    guard case .table(_, _, let alignments) = blocks.first else {
        Issue.record("expected a table, got \(blocks)")
        return
    }
    #expect(alignments == [.leading, .center, .trailing, .leading])
}

@Test("A ragged row is padded or truncated to the column count")
func raggedRows() {
    let blocks = MarkdownParser.parse("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")
    guard case .table(_, let rows, _) = blocks.first else {
        Issue.record("expected a table, got \(blocks)")
        return
    }
    // Padding matters more than it looks: an unpadded short row would shift
    // every later cell into the wrong column.
    #expect(rows == [["1", "", ""], ["1", "2", "3"]])
}

@Test("Inline code survives inside a cell, pipes and all")
func tableCellContent() {
    let blocks = MarkdownParser.parse("| field | note |\n|---|---|\n| `a \\| b` | use it |")
    guard case .table(_, let rows, _) = blocks.first else {
        Issue.record("expected a table, got \(blocks)")
        return
    }
    // The escaped pipe is content, not a cell boundary.
    #expect(rows == [["`a | b`", "use it"]])
}

@Test(
    "Prose containing a pipe is not mistaken for a table",
    arguments: [
        "use a | b to pipe",
        "use a | b to pipe\n---",
        "a | b\nnot a delimiter",
        "| just one line |",
    ])
func pipeFalsePositives(source: String) {
    let blocks = MarkdownParser.parse(source)
    let isTable = blocks.contains { if case .table = $0 { return true } else { return false } }
    #expect(!isTable, "should not be a table: \(source)")
}

@Test("A table ends at the first line that is not a row")
func tableTermination() {
    let blocks = MarkdownParser.parse("| a |\n|---|\n| 1 |\nBack to prose.")
    #expect(blocks.count == 2)
    #expect(blocks.last == .paragraph("Back to prose."))
}
