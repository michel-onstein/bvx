import Foundation

/// Where a workspace's bead data actually came from.
public enum SourceKind: String, Codable, Sendable {
    case jsonl
    case sqlite

    public var displayName: String {
        switch self {
        case .jsonl: "JSONL"
        case .sqlite: "SQLite"
        }
    }
}

/// What the engine reports after opening a workspace.
public struct WorkspaceInfo: Codable, Sendable, Hashable {
    /// The file actually read, after discovery.
    public var source: String
    public var kind: SourceKind
    public var issueCount: Int
    /// SHA-256 over the sorted issue set. Doubles as the reload gate and the
    /// value shown in the status bar for cross-checking against `bv`.
    public var dataHash: String
    /// Non-fatal loader complaints: malformed lines, empty files, and so on.
    public var warnings: [String]
    public var loadedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case source, kind, warnings
        case issueCount = "issue_count"
        case dataHash = "data_hash"
        case loadedAt = "loaded_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        kind = SourceKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "jsonl") ?? .jsonl
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        dataHash = try c.decodeIfPresent(String.self, forKey: .dataHash) ?? ""
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        if let raw = try c.decodeIfPresent(String.self, forKey: .loadedAt) {
            loadedAt = ISO8601DateFormatter().date(from: raw)
        }
    }

    public init(
        source: String, kind: SourceKind, issueCount: Int,
        dataHash: String, warnings: [String] = [], loadedAt: Date? = nil
    ) {
        self.source = source
        self.kind = kind
        self.issueCount = issueCount
        self.dataHash = dataHash
        self.warnings = warnings
        self.loadedAt = loadedAt
    }

    /// Directory shown in the window title.
    public var displayName: String {
        let url = URL(fileURLWithPath: source)
        // .../<project>/.beads/issues.jsonl -> <project>
        let beadsDir = url.deletingLastPathComponent()
        if beadsDir.lastPathComponent == ".beads" {
            return beadsDir.deletingLastPathComponent().lastPathComponent
        }
        return beadsDir.lastPathComponent
    }

    /// Short form of the data hash for the status bar.
    public var shortHash: String { String(dataHash.prefix(8)) }
}

/// One actionable item within a track, as the engine reports it.
public struct PlanItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var priority: Int
    public var status: IssueStatus
    /// Issues that become actionable once this one is done.
    public var unblocks: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, priority, status, unblocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        status = IssueStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "open")
        unblocks = try c.decodeIfPresent([String].self, forKey: .unblocks) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(priority, forKey: .priority)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(unblocks, forKey: .unblocks)
    }

    public init(id: String, title: String, priority: Int = 0, status: IssueStatus = .open, unblocks: [String] = []) {
        self.id = id
        self.title = title
        self.priority = priority
        self.status = status
        self.unblocks = unblocks
    }
}

/// One parallelisable stream of actionable work — a connected component of the
/// actionable subgraph, so two people in different tracks cannot collide.
public struct ExecutionTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var items: [PlanItem]
    /// Why the engine grouped these together.
    public var reason: String

    private enum CodingKeys: String, CodingKey {
        case id = "track_id"
        case items
        case reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        items = try c.decodeIfPresent([PlanItem].self, forKey: .items) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(items, forKey: .items)
        try c.encode(reason, forKey: .reason)
    }

    public init(id: String, items: [PlanItem], reason: String = "") {
        self.id = id
        self.items = items
        self.reason = reason
    }
}

/// The engine's execution plan: what can be worked on now, and in parallel.
public struct ExecutionPlan: Codable, Sendable, Hashable {
    public var tracks: [ExecutionTrack]
    public var totalActionable: Int
    public var totalBlocked: Int
    /// The single highest-impact item and why.
    public var highestImpact: String
    public var impactReason: String
    public var unblocksCount: Int

    private enum CodingKeys: String, CodingKey {
        case tracks, summary
        case totalActionable = "total_actionable"
        case totalBlocked = "total_blocked"
    }

    private enum SummaryKeys: String, CodingKey {
        case highestImpact = "highest_impact"
        case impactReason = "impact_reason"
        case unblocksCount = "unblocks_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decodeIfPresent([ExecutionTrack].self, forKey: .tracks) ?? []
        totalActionable = try c.decodeIfPresent(Int.self, forKey: .totalActionable) ?? 0
        totalBlocked = try c.decodeIfPresent(Int.self, forKey: .totalBlocked) ?? 0

        if let s = try? c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary) {
            highestImpact = try s.decodeIfPresent(String.self, forKey: .highestImpact) ?? ""
            impactReason = try s.decodeIfPresent(String.self, forKey: .impactReason) ?? ""
            unblocksCount = try s.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        } else {
            highestImpact = ""
            impactReason = ""
            unblocksCount = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(totalActionable, forKey: .totalActionable)
        try c.encode(totalBlocked, forKey: .totalBlocked)
        var s = c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
        try s.encode(highestImpact, forKey: .highestImpact)
        try s.encode(impactReason, forKey: .impactReason)
        try s.encode(unblocksCount, forKey: .unblocksCount)
    }

    public init(
        tracks: [ExecutionTrack], totalActionable: Int = 0, totalBlocked: Int = 0,
        highestImpact: String = "", impactReason: String = "", unblocksCount: Int = 0
    ) {
        self.tracks = tracks
        self.totalActionable = totalActionable
        self.totalBlocked = totalBlocked
        self.highestImpact = highestImpact
        self.impactReason = impactReason
        self.unblocksCount = unblocksCount
    }

    public static let empty = ExecutionPlan(tracks: [])
}
