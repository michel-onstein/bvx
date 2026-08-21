import Foundation

/// A scored recommendation: what the engine thinks is worth doing next, and why.
public struct Recommendation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var status: IssueStatus
    public var priority: Int
    public var labels: [String]
    /// Composite impact score — PageRank, betweenness, blocker ratio,
    /// staleness and priority, weighted by the engine.
    public var score: Double
    /// Human-readable next action.
    public var action: String
    /// Why this scored where it did.
    public var reasons: [String]
    public var unblocksIDs: [String]
    public var blockedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, status, priority, labels, score, action, reasons
        case unblocksIDs = "unblocks_ids"
        case blockedBy = "blocked_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = IssueStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "open")
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
        blockedBy = try c.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
    }

    public init(
        id: String, title: String, status: IssueStatus = .open, priority: Int = 0,
        labels: [String] = [], score: Double = 0, action: String = "",
        reasons: [String] = [], unblocksIDs: [String] = [], blockedBy: [String] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.labels = labels
        self.score = score
        self.action = action
        self.reasons = reasons
        self.unblocksIDs = unblocksIDs
        self.blockedBy = blockedBy
    }
}

/// A cheap task that unlocks disproportionate downstream work.
public struct QuickWin: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var score: Double
    public var reason: String
    public var unblocksIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, score, reason
        case unblocksIDs = "unblocks_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
    }
}

/// Something that blocks significant downstream work.
public struct BlockerItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var unblocksCount: Int
    public var unblocksIDs: [String]
    /// Whether this blocker can itself be worked on right now.
    public var actionable: Bool
    public var blockedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, actionable
        case unblocksCount = "unblocks_count"
        case unblocksIDs = "unblocks_ids"
        case blockedBy = "blocked_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        unblocksCount = try c.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        unblocksIDs = try c.decodeIfPresent([String].self, forKey: .unblocksIDs) ?? []
        actionable = try c.decodeIfPresent(Bool.self, forKey: .actionable) ?? false
        blockedBy = try c.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
    }
}

/// The engine's triage: what to work on next, and what is holding things up.
public struct Triage: Codable, Sendable, Hashable {
    public var recommendations: [Recommendation]
    public var quickWins: [QuickWin]
    public var blockersToClear: [BlockerItem]

    private enum CodingKeys: String, CodingKey {
        case recommendations
        case quickWins = "quick_wins"
        case blockersToClear = "blockers_to_clear"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recommendations = try c.decodeIfPresent([Recommendation].self, forKey: .recommendations) ?? []
        quickWins = try c.decodeIfPresent([QuickWin].self, forKey: .quickWins) ?? []
        blockersToClear = try c.decodeIfPresent([BlockerItem].self, forKey: .blockersToClear) ?? []
    }

    public init(
        recommendations: [Recommendation] = [], quickWins: [QuickWin] = [],
        blockersToClear: [BlockerItem] = []
    ) {
        self.recommendations = recommendations
        self.quickWins = quickWins
        self.blockersToClear = blockersToClear
    }

    public static let empty = Triage()

    public var isEmpty: Bool {
        recommendations.isEmpty && quickWins.isEmpty && blockersToClear.isEmpty
    }
}
