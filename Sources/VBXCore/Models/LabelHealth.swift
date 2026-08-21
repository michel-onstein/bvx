import Foundation

/// How the engine rates a label's health.
public enum HealthLevel: String, Codable, Sendable, Hashable {
    case healthy
    case warning
    case critical
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "healthy": self = .healthy
        case "warning": self = .warning
        case "critical": self = .critical
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Work-completion rate for one label.
public struct VelocityMetrics: Codable, Sendable, Hashable {
    public var closedLast7Days: Int
    public var closedLast30Days: Int
    public var avgDaysToClose: Double
    public var trendDirection: String
    public var trendPercent: Double
    public var velocityScore: Int

    private enum CodingKeys: String, CodingKey {
        case closedLast7Days = "closed_last_7_days"
        case closedLast30Days = "closed_last_30_days"
        case avgDaysToClose = "avg_days_to_close"
        case trendDirection = "trend_direction"
        case trendPercent = "trend_percent"
        case velocityScore = "velocity_score"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closedLast7Days = try c.decodeIfPresent(Int.self, forKey: .closedLast7Days) ?? 0
        closedLast30Days = try c.decodeIfPresent(Int.self, forKey: .closedLast30Days) ?? 0
        avgDaysToClose = try c.decodeIfPresent(Double.self, forKey: .avgDaysToClose) ?? 0
        trendDirection = try c.decodeIfPresent(String.self, forKey: .trendDirection) ?? "stable"
        trendPercent = try c.decodeIfPresent(Double.self, forKey: .trendPercent) ?? 0
        velocityScore = try c.decodeIfPresent(Int.self, forKey: .velocityScore) ?? 0
    }

    /// Arrow reflecting the trend direction.
    public var trendSymbol: String {
        switch trendDirection {
        case "improving": "arrow.up.right"
        case "declining": "arrow.down.right"
        default: "arrow.right"
        }
    }
}

/// Health of a single label.
public struct LabelHealth: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var issueCount: Int
    public var openCount: Int
    public var closedCount: Int
    public var blockedCount: Int
    public var health: Int
    public var healthLevel: HealthLevel
    public var velocity: VelocityMetrics?
    public var issues: [String]

    public var id: String { label }

    private enum CodingKeys: String, CodingKey {
        case label, health, velocity, issues
        case issueCount = "issue_count"
        case openCount = "open_count"
        case closedCount = "closed_count"
        case blockedCount = "blocked_count"
        case healthLevel = "health_level"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        openCount = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        closedCount = try c.decodeIfPresent(Int.self, forKey: .closedCount) ?? 0
        blockedCount = try c.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        health = try c.decodeIfPresent(Int.self, forKey: .health) ?? 0
        healthLevel = HealthLevel(
            rawValue: try c.decodeIfPresent(String.self, forKey: .healthLevel) ?? "")
        velocity = try? c.decodeIfPresent(VelocityMetrics.self, forKey: .velocity)
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
    }

    /// Fraction of this label's work that is done, for a progress bar.
    public var completion: Double {
        issueCount > 0 ? Double(closedCount) / Double(issueCount) : 0
    }
}

/// The engine's label analysis for the whole workspace.
public struct LabelAnalysis: Codable, Sendable, Hashable {
    public var totalLabels: Int
    public var healthyCount: Int
    public var warningCount: Int
    public var criticalCount: Int
    public var labels: [LabelHealth]
    public var attentionNeeded: [String]

    private enum CodingKeys: String, CodingKey {
        case labels
        case totalLabels = "total_labels"
        case healthyCount = "healthy_count"
        case warningCount = "warning_count"
        case criticalCount = "critical_count"
        case attentionNeeded = "attention_needed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalLabels = try c.decodeIfPresent(Int.self, forKey: .totalLabels) ?? 0
        healthyCount = try c.decodeIfPresent(Int.self, forKey: .healthyCount) ?? 0
        warningCount = try c.decodeIfPresent(Int.self, forKey: .warningCount) ?? 0
        criticalCount = try c.decodeIfPresent(Int.self, forKey: .criticalCount) ?? 0
        labels = try c.decodeIfPresent([LabelHealth].self, forKey: .labels) ?? []
        attentionNeeded = try c.decodeIfPresent([String].self, forKey: .attentionNeeded) ?? []
    }

    public init(
        totalLabels: Int = 0, healthyCount: Int = 0, warningCount: Int = 0,
        criticalCount: Int = 0, labels: [LabelHealth] = [], attentionNeeded: [String] = []
    ) {
        self.totalLabels = totalLabels
        self.healthyCount = healthyCount
        self.warningCount = warningCount
        self.criticalCount = criticalCount
        self.labels = labels
        self.attentionNeeded = attentionNeeded
    }

    public static let empty = LabelAnalysis()
}
