import Foundation

/// A step in a bead's causal chain.
public enum CausalEventType: RawRepresentable, Codable, Sendable, Hashable {
    case created, claimed, commit, blocked, unblocked, closed, reopened
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "claimed": self = .claimed
        case "commit": self = .commit
        case "blocked": self = .blocked
        case "unblocked": self = .unblocked
        case "closed": self = .closed
        case "reopened": self = .reopened
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .created: "created"
        case .claimed: "claimed"
        case .commit: "commit"
        case .blocked: "blocked"
        case .unblocked: "unblocked"
        case .closed: "closed"
        case .reopened: "reopened"
        case .unknown(let raw): raw
        }
    }

    public var symbolName: String {
        switch self {
        case .created: "plus.circle"
        case .claimed: "hand.raised"
        case .commit: "arrow.triangle.branch"
        case .blocked: "exclamationmark.octagon"
        case .unblocked: "bolt.circle"
        case .closed: "checkmark.circle"
        case .reopened: "arrow.uturn.backward.circle"
        case .unknown: "circle"
        }
    }

    /// True when this step is waiting rather than working, which is what the
    /// timeline shades differently.
    public var isWaiting: Bool { self == .blocked }
}

public struct CausalEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var type: CausalEventType
    public var timestamp: Date?
    public var description: String
    public var commitSHA: String?
    public var blockerID: String?
    public var causedByID: Int?
    public var enablesIDs: [Int]
    /// Nanoseconds to the next event, as Go encodes a duration.
    public var durationNext: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, type, timestamp, description
        case commitSHA = "commit_sha"
        case blockerID = "blocker_id"
        case causedByID = "caused_by_id"
        case enablesIDs = "enables_ids"
        case durationNext = "duration_next"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        type = CausalEventType(rawValue: try c.decodeIfPresent(String.self, forKey: .type) ?? "")
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
        blockerID = try c.decodeIfPresent(String.self, forKey: .blockerID)
        causedByID = try c.decodeIfPresent(Int.self, forKey: .causedByID)
        enablesIDs = try c.decodeIfPresent([Int].self, forKey: .enablesIDs) ?? []
        durationNext = try? c.decodeIfPresent(Int64.self, forKey: .durationNext)
    }
}

public struct CausalChain: Codable, Sendable, Hashable {
    public var beadID: String
    public var title: String
    public var status: String
    public var events: [CausalEvent]
    public var edgeCount: Int
    public var startTime: Date?
    public var endTime: Date?
    public var totalTime: Int64
    public var isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case title, status, events
        case beadID = "bead_id"
        case edgeCount = "edge_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case totalTime = "total_time"
        case isComplete = "is_complete"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        events = try c.decodeIfPresent([CausalEvent].self, forKey: .events) ?? []
        edgeCount = try c.decodeIfPresent(Int.self, forKey: .edgeCount) ?? 0
        startTime = try? c.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try? c.decodeIfPresent(Date.self, forKey: .endTime)
        totalTime = try c.decodeIfPresent(Int64.self, forKey: .totalTime) ?? 0
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }
}

public struct BlockedPeriod: Codable, Sendable, Hashable, Identifiable {
    public var startTime: Date?
    public var endTime: Date?
    public var duration: Int64
    public var blockerID: String?

    public var id: String {
        "\(blockerID ?? "?")-\(startTime?.timeIntervalSince1970 ?? 0)"
    }

    private enum CodingKeys: String, CodingKey {
        case duration
        case startTime = "start_time"
        case endTime = "end_time"
        case blockerID = "blocker_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try? c.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try? c.decodeIfPresent(Date.self, forKey: .endTime)
        duration = try c.decodeIfPresent(Int64.self, forKey: .duration) ?? 0
        blockerID = try c.decodeIfPresent(String.self, forKey: .blockerID)
    }
}

public struct CausalInsights: Codable, Sendable, Hashable {
    public var totalDuration: Int64
    public var blockedDuration: Int64
    public var activeDuration: Int64
    public var blockedPercentage: Double
    public var blockedPeriods: [BlockedPeriod]
    public var criticalPath: [Int]
    public var criticalPathDesc: String
    public var commitCount: Int
    public var longestGap: Int64?
    public var longestGapDesc: String
    public var summary: String
    public var recommendations: [String]

    private enum CodingKeys: String, CodingKey {
        case summary, recommendations
        case totalDuration = "total_duration"
        case blockedDuration = "blocked_duration"
        case activeDuration = "active_duration"
        case blockedPercentage = "blocked_percentage"
        case blockedPeriods = "blocked_periods"
        case criticalPath = "critical_path"
        case criticalPathDesc = "critical_path_desc"
        case commitCount = "commit_count"
        case longestGap = "longest_gap"
        case longestGapDesc = "longest_gap_desc"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalDuration = try c.decodeIfPresent(Int64.self, forKey: .totalDuration) ?? 0
        blockedDuration = try c.decodeIfPresent(Int64.self, forKey: .blockedDuration) ?? 0
        activeDuration = try c.decodeIfPresent(Int64.self, forKey: .activeDuration) ?? 0
        blockedPercentage = try c.decodeIfPresent(Double.self, forKey: .blockedPercentage) ?? 0
        blockedPeriods = try c.decodeIfPresent([BlockedPeriod].self, forKey: .blockedPeriods) ?? []
        criticalPath = try c.decodeIfPresent([Int].self, forKey: .criticalPath) ?? []
        criticalPathDesc = try c.decodeIfPresent(String.self, forKey: .criticalPathDesc) ?? ""
        commitCount = try c.decodeIfPresent(Int.self, forKey: .commitCount) ?? 0
        longestGap = try? c.decodeIfPresent(Int64.self, forKey: .longestGap)
        longestGapDesc = try c.decodeIfPresent(String.self, forKey: .longestGapDesc) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        recommendations = try c.decodeIfPresent([String].self, forKey: .recommendations) ?? []
    }
}

public struct CausalityResult: Codable, Sendable, Hashable {
    public var chain: CausalChain?
    public var insights: CausalInsights?

    private enum CodingKeys: String, CodingKey {
        case chain, insights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chain = try? c.decodeIfPresent(CausalChain.self, forKey: .chain)
        insights = try? c.decodeIfPresent(CausalInsights.self, forKey: .insights)
    }
}
