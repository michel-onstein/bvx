import Foundation

/// Finds references to other beads inside prose, and builds the URLs that
/// select them.
///
/// The scan is membership-driven rather than pattern-driven: it collects
/// id-shaped tokens and keeps only the ones the workspace actually holds. Two
/// things fall out of that choice.
///
/// - **No id format is hardcoded.** A workspace whose ids look like
///   `whois-q1rfj` and one whose ids look like `vbx-3` both work, and a
///   multi-repository workspace mixing several prefixes needs no extra rule.
/// - **A stale id stays plain text.** Descriptions outlive the beads they cite,
///   and a link that selects nothing is worse than no link at all.
public enum BeadReferences {

    /// Characters that may appear inside a bead id.
    ///
    /// The set is what bounds a token: `vbx-8ou,` yields `vbx-8ou` because the
    /// comma ends the run, while `vbx-8ou-old` yields one unknown token and so
    /// is left alone.
    private static func isIDCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// Ranges of `text` that name a bead in `known`, in order and
    /// non-overlapping.
    public static func ranges(in text: String, known: Set<String>) -> [Range<String.Index>] {
        guard !known.isEmpty, !text.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard isIDCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, isIDCharacter(text[end]) {
                end = text.index(after: end)
            }
            if known.contains(String(text[index..<end])) {
                found.append(index..<end)
            }
            index = end
        }
        return found
    }
}

/// vbx's own URL scheme.
///
/// Inline bead links in the inspector and links arriving from outside the app
/// use the same shape, so one handler serves both and there is only one place
/// where a malformed URL is rejected.
public enum BeadURL {
    public static let scheme = "vbx"

    /// `vbx://open?bead=<id>`
    public static func open(bead id: String) -> URL? {
        open(bead: id, workspace: nil)
    }

    /// `vbx://open?workspace=<path>&bead=<id>`, with either part optional.
    public static func open(bead id: String?, workspace: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        var items: [URLQueryItem] = []
        if let workspace, !workspace.isEmpty {
            items.append(URLQueryItem(name: "workspace", value: workspace))
        }
        if let id, !id.isEmpty {
            items.append(URLQueryItem(name: "bead", value: id))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The bead id a vbx URL names, if it names one.
    public static func bead(in url: URL) -> String? {
        query(url, named: "bead")
    }

    /// The workspace path a vbx URL names, if it names one.
    public static func workspace(in url: URL) -> String? {
        query(url, named: "workspace")
    }

    private static func query(_ url: URL, named name: String) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
        return (value?.isEmpty ?? true) ? nil : value
    }
}
