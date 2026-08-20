import Foundation

/// The four top-level filters bv binds to `o`, `r`, `c` and `a`.
public enum IssueFilter: String, CaseIterable, Sendable, Identifiable {
    /// Open and in-progress.
    case open
    /// Actionable: open with no unresolved blocking dependency.
    case ready
    case closed
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .ready: "Ready"
        case .closed: "Closed"
        case .all: "All"
        }
    }

    public var symbolName: String {
        switch self {
        case .open: "circle"
        case .ready: "bolt.circle"
        case .closed: "checkmark.circle"
        case .all: "tray.full"
        }
    }

    /// bv's single-key binding for this filter.
    public var shortcut: Character {
        switch self {
        case .open: "o"
        case .ready: "r"
        case .closed: "c"
        case .all: "a"
        }
    }
}

/// bv's sort cycle, reachable with `s`.
public enum SortMode: String, CaseIterable, Sendable, Identifiable {
    /// Priority ascending, then created descending — bv's default.
    case `default`
    case createdAscending
    case createdDescending
    case priority
    case updated
    /// bvx addition: order by computed impact. Requires Phase 2.
    case impact

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: "Default"
        case .createdAscending: "Created ↑"
        case .createdDescending: "Created ↓"
        case .priority: "Priority"
        case .updated: "Recently Updated"
        case .impact: "Impact"
        }
    }

    /// True when this ordering needs Phase-2 metrics, so the UI can disable it
    /// until they land rather than sorting by silent zeros.
    public var requiresPhase2: Bool { self == .impact }
}

/// Applies filters, search and sorting. Pure and synchronous so it can run
/// during view updates without touching the engine.
public struct IssueQuery: Sendable {
    public var filter: IssueFilter
    public var searchText: String
    public var labels: Set<String>
    public var assignees: Set<String>
    public var sort: SortMode

    public init(
        filter: IssueFilter = .open,
        searchText: String = "",
        labels: Set<String> = [],
        assignees: Set<String> = [],
        sort: SortMode = .default
    ) {
        self.filter = filter
        self.searchText = searchText
        self.labels = labels
        self.assignees = assignees
        self.sort = sort
    }

    /// - Parameters:
    ///   - actionable: ids the engine reports as actionable. Required for
    ///     `.ready`, because readiness is a graph property, not a field.
    ///   - metrics: used only by `.impact` sorting.
    public func apply(
        to issues: [Issue],
        actionable: Set<String> = [],
        metrics: GraphMetrics? = nil
    ) -> [Issue] {
        var result = issues.filter { matches($0, actionable: actionable) }
        result = Self.rank(result, query: searchText)
        return sorted(result, metrics: metrics)
    }

    private func matches(_ issue: Issue, actionable: Set<String>) -> Bool {
        switch filter {
        case .open where !issue.status.isOpen: return false
        case .ready where !actionable.contains(issue.id): return false
        case .closed where !issue.status.isClosed: return false
        case .all where issue.status.isTombstone: return false
        default: break
        }
        if !labels.isEmpty, labels.isDisjoint(with: Set(issue.labels)) { return false }
        if !assignees.isEmpty {
            guard let a = issue.assignee, assignees.contains(a) else { return false }
        }
        return true
    }

    private func sorted(_ issues: [Issue], metrics: GraphMetrics?) -> [Issue] {
        // A search query imposes its own relevance order; re-sorting would
        // discard it.
        guard searchText.isEmpty else { return issues }

        switch sort {
        case .default:
            return issues.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
        case .createdAscending:
            return issues.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        case .createdDescending:
            return issues.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .priority:
            return issues.sorted {
                $0.priority != $1.priority ? $0.priority < $1.priority : $0.id < $1.id
            }
        case .updated:
            return issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .impact:
            guard let pr = metrics?.pageRank else { return issues }
            return issues.sorted {
                let a = pr[$0.id] ?? 0, b = pr[$1.id] ?? 0
                return a != b ? a > b : $0.id < $1.id
            }
        }
    }

    /// Filters to matches and orders them by descending fuzzy score.
    public static func rank(_ issues: [Issue], query: String) -> [Issue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return issues }

        return
            issues
            .compactMap { issue -> (Issue, Int)? in
                guard let score = fuzzyScore(issue: issue, query: q) else { return nil }
                return (issue, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .map(\.0)
    }

    /// Subsequence match over the fields bv indexes, with a bonus for stronger
    /// match kinds so exact and prefix hits outrank scattered subsequences.
    static func fuzzyScore(issue: Issue, query: String) -> Int? {
        let q = query.lowercased()
        var best: Int?

        func consider(_ haystack: String, weight: Int) {
            guard !haystack.isEmpty else { return }
            let h = haystack.lowercased()
            var score: Int?
            if h == q {
                score = 1000
            } else if h.hasPrefix(q) {
                score = 700
            } else if h.contains(q) {
                score = 400
            } else if isSubsequence(q, of: h) {
                score = 150
            }
            if let s = score {
                let total = s + weight
                if best == nil || total > best! { best = total }
            }
        }

        consider(issue.id, weight: 60)
        consider(issue.title, weight: 50)
        for label in issue.labels { consider(label, weight: 25) }
        consider(issue.assignee ?? "", weight: 10)
        consider(issue.description, weight: 0)
        return best
    }

    /// True when every character of `needle` appears in `haystack` in order.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var i = needle.startIndex
        guard i != needle.endIndex else { return true }
        for ch in haystack where ch == needle[i] {
            i = needle.index(after: i)
            if i == needle.endIndex { return true }
        }
        return false
    }
}

extension Array where Element == Issue {
    /// All labels present, sorted, with their counts.
    public var labelCounts: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for issue in self {
            for label in issue.labels { counts[label, default: 0] += 1 }
        }
        return counts.map { (label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// All assignees present, sorted by name.
    public var assignees: [String] {
        Set(compactMap(\.assignee)).filter { !$0.isEmpty }.sorted()
    }

    public func grouped(by status: IssueStatus) -> [Issue] {
        filter { $0.status == status }
    }
}
