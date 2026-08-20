import Foundation

/// How a commit came to be attributed to a bead.
///
/// Open, like every other enum decoded from the engine: a method bv adds later
/// must not make a whole report undecodable.
public enum CorrelationMethod: RawRepresentable, Codable, Sendable, Hashable {
    /// The bead's record and the code changed in the same commit.
    case coCommitted
    /// The commit message names the bead.
    case explicitID
    /// Same author, inside the bead's active window.
    case temporalAuthor
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "co_committed": self = .coCommitted
        case "explicit_id": self = .explicitID
        case "temporal_author": self = .temporalAuthor
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .coCommitted: "co_committed"
        case .explicitID: "explicit_id"
        case .temporalAuthor: "temporal_author"
        case .unknown(let raw): raw
        }
    }

    public var displayName: String {
        switch self {
        case .coCommitted: "Same commit"
        case .explicitID: "Named in message"
        case .temporalAuthor: "Same author, same window"
        case .unknown(let raw): raw
        }
    }

    public var symbolName: String {
        switch self {
        case .coCommitted: "arrow.triangle.branch"
        case .explicitID: "text.quote"
        case .temporalAuthor: "clock"
        case .unknown: "questionmark"
        }
    }
}

/// A bead's lifecycle transition, read out of the beads file's history.
public enum BeadEventType: RawRepresentable, Codable, Sendable, Hashable {
    case created
    case claimed
    case closed
    case reopened
    case modified
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "claimed": self = .claimed
        case "closed": self = .closed
        case "reopened": self = .reopened
        case "modified": self = .modified
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .created: "created"
        case .claimed: "claimed"
        case .closed: "closed"
        case .reopened: "reopened"
        case .modified: "modified"
        case .unknown(let raw): raw
        }
    }

    public var displayName: String {
        switch self {
        case .created: "Created"
        case .claimed: "Claimed"
        case .closed: "Closed"
        case .reopened: "Reopened"
        case .modified: "Edited"
        case .unknown(let raw): raw.capitalized
        }
    }

    public var symbolName: String {
        switch self {
        case .created: "plus.circle"
        case .claimed: "hand.raised"
        case .closed: "checkmark.circle"
        case .reopened: "arrow.uturn.backward.circle"
        case .modified: "pencil"
        case .unknown: "circle"
        }
    }
}

/// One file changed by a commit.
public struct FileChange: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    /// `A`, `M`, `D` or `R`.
    public var action: String
    public var insertions: Int
    public var deletions: Int

    public var id: String { path }

    private enum CodingKeys: String, CodingKey {
        case path, action, insertions, deletions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? "M"
        insertions = try c.decodeIfPresent(Int.self, forKey: .insertions) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
    }

    public init(path: String, action: String = "M", insertions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.action = action
        self.insertions = insertions
        self.deletions = deletions
    }

    public var actionName: String {
        switch action {
        case "A": "added"
        case "D": "deleted"
        case "R": "renamed"
        default: "modified"
        }
    }
}

/// A commit linked to a bead, with the confidence of the link.
public struct CorrelatedCommit: Codable, Sendable, Hashable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var message: String
    public var author: String
    public var authorEmail: String
    public var timestamp: Date?
    public var files: [FileChange]
    public var method: CorrelationMethod
    /// 0…1. Never rounded away — the badge shows a percentage, but the value
    /// kept here is the engine's.
    public var confidence: Double
    public var reason: String

    public var id: String { sha }

    private enum CodingKeys: String, CodingKey {
        case sha, message, author, timestamp, files, method, confidence, reason
        case shortSHA = "short_sha"
        case authorEmail = "author_email"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        shortSHA = try c.decodeIfPresent(String.self, forKey: .shortSHA) ?? String(sha.prefix(7))
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorEmail = try c.decodeIfPresent(String.self, forKey: .authorEmail) ?? ""
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        files = try c.decodeIfPresent([FileChange].self, forKey: .files) ?? []
        method = CorrelationMethod(
            rawValue: try c.decodeIfPresent(String.self, forKey: .method) ?? "")
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    public init(
        sha: String, shortSHA: String? = nil, message: String = "", author: String = "",
        authorEmail: String = "", timestamp: Date? = nil, files: [FileChange] = [],
        method: CorrelationMethod = .coCommitted, confidence: Double = 0, reason: String = ""
    ) {
        self.sha = sha
        self.shortSHA = shortSHA ?? String(sha.prefix(7))
        self.message = message
        self.author = author
        self.authorEmail = authorEmail
        self.timestamp = timestamp
        self.files = files
        self.method = method
        self.confidence = confidence
        self.reason = reason
    }

    /// The commit's subject — its first line.
    public var subject: String {
        message.components(separatedBy: .newlines).first ?? message
    }

    /// bv's confidence bands, so the badge says the same thing `bv` does.
    public var confidenceLevel: String {
        switch confidence {
        case 0.9...: "very high"
        case 0.75..<0.9: "high"
        case 0.5..<0.75: "moderate"
        case 0.3..<0.5: "low"
        default: "very low"
        }
    }

    public var confidencePercent: String {
        String(format: "%.0f%%", confidence * 100)
    }
}

/// One lifecycle event.
public struct BeadEvent: Codable, Sendable, Hashable, Identifiable {
    public var beadID: String
    public var eventType: BeadEventType
    public var timestamp: Date?
    public var commitSHA: String
    public var commitMessage: String
    public var author: String

    public var id: String { "\(commitSHA)-\(eventType.rawValue)-\(beadID)" }

    private enum CodingKeys: String, CodingKey {
        case timestamp, author
        case beadID = "bead_id"
        case eventType = "event_type"
        case commitSHA = "commit_sha"
        case commitMessage = "commit_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        eventType = BeadEventType(
            rawValue: try c.decodeIfPresent(String.self, forKey: .eventType) ?? "")
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA) ?? ""
        commitMessage = try c.decodeIfPresent(String.self, forKey: .commitMessage) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
    }
}

/// How long a bead took, in nanoseconds as Go encodes a duration.
public struct CycleTime: Codable, Sendable, Hashable {
    public var claimToClose: Int64?
    public var createToClose: Int64?
    public var createToClaim: Int64?

    private enum CodingKeys: String, CodingKey {
        case claimToClose = "claim_to_close"
        case createToClose = "create_to_close"
        case createToClaim = "create_to_claim"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claimToClose = try? c.decodeIfPresent(Int64.self, forKey: .claimToClose)
        createToClose = try? c.decodeIfPresent(Int64.self, forKey: .createToClose)
        createToClaim = try? c.decodeIfPresent(Int64.self, forKey: .createToClaim)
    }

    /// Formats one of the durations, or nil when it was never reached.
    ///
    /// Nil rather than "0s": a bead that is not closed has no cycle time, and
    /// showing zero would claim it took no time at all.
    public static func describe(_ nanoseconds: Int64?) -> String? {
        guard let nanoseconds, nanoseconds > 0 else { return nil }
        let seconds = Double(nanoseconds) / 1_000_000_000
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds)
    }
}

/// The milestones bv reads out of a bead's events.
public struct BeadMilestones: Codable, Sendable, Hashable {
    public var created: BeadEvent?
    public var claimed: BeadEvent?
    public var closed: BeadEvent?
    public var reopened: BeadEvent?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = try? c.decodeIfPresent(BeadEvent.self, forKey: .created)
        claimed = try? c.decodeIfPresent(BeadEvent.self, forKey: .claimed)
        closed = try? c.decodeIfPresent(BeadEvent.self, forKey: .closed)
        reopened = try? c.decodeIfPresent(BeadEvent.self, forKey: .reopened)
    }

    private enum CodingKeys: String, CodingKey {
        case created, claimed, closed, reopened
    }
}

/// One bead's git history.
public struct BeadHistory: Codable, Sendable, Hashable, Identifiable {
    public var beadID: String
    public var title: String
    public var status: String
    public var events: [BeadEvent]
    public var milestones: BeadMilestones?
    public var commits: [CorrelatedCommit]
    public var cycleTime: CycleTime?
    public var lastAuthor: String

    public var id: String { beadID }

    private enum CodingKeys: String, CodingKey {
        case title, status, events, milestones, commits
        case beadID = "bead_id"
        case cycleTime = "cycle_time"
        case lastAuthor = "last_author"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        events = try c.decodeIfPresent([BeadEvent].self, forKey: .events) ?? []
        milestones = try? c.decodeIfPresent(BeadMilestones.self, forKey: .milestones)
        commits = try c.decodeIfPresent([CorrelatedCommit].self, forKey: .commits) ?? []
        cycleTime = try? c.decodeIfPresent(CycleTime.self, forKey: .cycleTime)
        lastAuthor = try c.decodeIfPresent(String.self, forKey: .lastAuthor) ?? ""
    }
}

/// Summary counts for a whole history report.
public struct HistoryStats: Codable, Sendable, Hashable {
    public var totalBeads: Int
    public var beadsWithCommits: Int
    public var totalCommits: Int
    public var uniqueAuthors: Int
    public var avgCommitsPerBead: Double
    public var methodDistribution: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case totalBeads = "total_beads"
        case beadsWithCommits = "beads_with_commits"
        case totalCommits = "total_commits"
        case uniqueAuthors = "unique_authors"
        case avgCommitsPerBead = "avg_commits_per_bead"
        case methodDistribution = "method_distribution"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalBeads = try c.decodeIfPresent(Int.self, forKey: .totalBeads) ?? 0
        beadsWithCommits = try c.decodeIfPresent(Int.self, forKey: .beadsWithCommits) ?? 0
        totalCommits = try c.decodeIfPresent(Int.self, forKey: .totalCommits) ?? 0
        uniqueAuthors = try c.decodeIfPresent(Int.self, forKey: .uniqueAuthors) ?? 0
        avgCommitsPerBead = try c.decodeIfPresent(Double.self, forKey: .avgCommitsPerBead) ?? 0
        methodDistribution =
            try c.decodeIfPresent([String: Int].self, forKey: .methodDistribution) ?? [:]
    }

    public init() {
        totalBeads = 0
        beadsWithCommits = 0
        totalCommits = 0
        uniqueAuthors = 0
        avgCommitsPerBead = 0
        methodDistribution = [:]
    }
}

/// The whole bead-to-commit correlation report.
public struct HistoryReport: Codable, Sendable, Hashable {
    public var generatedAt: Date?
    public var dataHash: String
    public var gitRange: String
    public var latestCommitSHA: String
    public var stats: HistoryStats
    public var histories: [String: BeadHistory]
    /// Commit SHA to the beads it was attributed to.
    public var commitIndex: [String: [String]]

    private enum CodingKeys: String, CodingKey {
        case stats, histories
        case generatedAt = "generated_at"
        case dataHash = "data_hash"
        case gitRange = "git_range"
        case latestCommitSHA = "latest_commit_sha"
        case commitIndex = "commit_index"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try? c.decodeIfPresent(Date.self, forKey: .generatedAt)
        dataHash = try c.decodeIfPresent(String.self, forKey: .dataHash) ?? ""
        gitRange = try c.decodeIfPresent(String.self, forKey: .gitRange) ?? ""
        latestCommitSHA = try c.decodeIfPresent(String.self, forKey: .latestCommitSHA) ?? ""
        stats = try c.decodeIfPresent(HistoryStats.self, forKey: .stats) ?? HistoryStats()
        histories = try c.decodeIfPresent([String: BeadHistory].self, forKey: .histories) ?? [:]
        commitIndex = try c.decodeIfPresent([String: [String]].self, forKey: .commitIndex) ?? [:]
    }

    public init() {
        generatedAt = nil
        dataHash = ""
        gitRange = ""
        latestCommitSHA = ""
        stats = HistoryStats()
        histories = [:]
        commitIndex = [:]
    }

    public static let empty = HistoryReport()

    /// Every linked commit, newest first, with the bead it belongs to.
    ///
    /// A commit attributed to two beads appears once per bead, because the
    /// confidence and the reason differ per link.
    public var allCommits: [(bead: String, commit: CorrelatedCommit)] {
        histories
            .flatMap { id, history in history.commits.map { (bead: id, commit: $0) } }
            .sorted {
                ($0.commit.timestamp ?? .distantPast) > ($1.commit.timestamp ?? .distantPast)
            }
    }
}
