import Foundation

/// How urgent an alert is.
public enum AlertSeverity: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case critical
    case warning
    case info

    public var id: String { rawValue }

    public init(rawValue: String) {
        switch rawValue {
        case "critical": self = .critical
        case "warning": self = .warning
        default: self = .info
        }
    }

    public var displayName: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }

    public var symbolName: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// Ordering for the grouped list: worst first.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .warning: 1
        case .info: 2
        }
    }
}

/// One drift or health alert.
public struct HealthAlert: Codable, Sendable, Hashable, Identifiable {
    public var type: String
    public var severity: AlertSeverity
    public var message: String
    public var baselineValue: Double
    public var currentValue: Double
    public var delta: Double
    public var details: [String]
    public var issueID: String
    public var label: String
    public var detectedAt: Date?
    public var unblocksCount: Int
    public var downstreamPrioritySum: Int

    /// Stable across reloads: the same condition on the same bead is the same
    /// alert, which is what stops a notification firing again on every reload.
    public var id: String { "\(type)|\(issueID)|\(label)|\(message)" }

    private enum CodingKeys: String, CodingKey {
        case type, severity, message, delta, details, label
        case baselineValue = "baseline_value"
        case currentValue = "current_value"
        case issueID = "issue_id"
        case detectedAt = "detected_at"
        case unblocksCount = "unblocks_count"
        case downstreamPrioritySum = "downstream_priority_sum"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        severity = AlertSeverity(
            rawValue: try c.decodeIfPresent(String.self, forKey: .severity) ?? "info")
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        baselineValue = try c.decodeIfPresent(Double.self, forKey: .baselineValue) ?? 0
        currentValue = try c.decodeIfPresent(Double.self, forKey: .currentValue) ?? 0
        delta = try c.decodeIfPresent(Double.self, forKey: .delta) ?? 0
        details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detectedAt = try? c.decodeIfPresent(Date.self, forKey: .detectedAt)
        unblocksCount = try c.decodeIfPresent(Int.self, forKey: .unblocksCount) ?? 0
        downstreamPrioritySum =
            try c.decodeIfPresent(Int.self, forKey: .downstreamPrioritySum) ?? 0
    }

    public init(
        type: String, severity: AlertSeverity, message: String,
        issueID: String = "", label: String = "", details: [String] = []
    ) {
        self.type = type
        self.severity = severity
        self.message = message
        self.baselineValue = 0
        self.currentValue = 0
        self.delta = 0
        self.details = details
        self.issueID = issueID
        self.label = label
        self.detectedAt = nil
        self.unblocksCount = 0
        self.downstreamPrioritySum = 0
    }

    /// The alert type as prose.
    public var typeDisplayName: String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// True when the alert carries a before-and-after worth showing.
    ///
    /// A delta of zero on an issue-derived alert is not a measurement, it is
    /// the absence of one — showing "0 → 0" would invent a comparison.
    public var hasDelta: Bool {
        baselineValue != 0 || currentValue != 0
    }
}

public struct AlertSummary: Codable, Sendable, Hashable {
    public var total: Int
    public var critical: Int
    public var warning: Int
    public var info: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        critical = try c.decodeIfPresent(Int.self, forKey: .critical) ?? 0
        warning = try c.decodeIfPresent(Int.self, forKey: .warning) ?? 0
        info = try c.decodeIfPresent(Int.self, forKey: .info) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case total, critical, warning, info }

    public init() {
        total = 0
        critical = 0
        warning = 0
        info = 0
    }
}

/// The saved baseline drift is measured from.
public struct BaselineInfo: Codable, Sendable, Hashable {
    public var exists: Bool
    public var path: String
    public var createdAt: Date?
    public var commitSHA: String
    public var commitMessage: String
    public var branch: String
    public var description: String
    public var summary: String

    private enum CodingKeys: String, CodingKey {
        case exists, path, branch, description, summary
        case createdAt = "created_at"
        case commitSHA = "commit_sha"
        case commitMessage = "commit_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA) ?? ""
        commitMessage = try c.decodeIfPresent(String.self, forKey: .commitMessage) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }

    public init() {
        exists = false
        path = ""
        commitSHA = ""
        commitMessage = ""
        branch = ""
        description = ""
        summary = ""
    }

    public static let empty = BaselineInfo()

    public var shortSHA: String { String(commitSHA.prefix(7)) }
}

/// The alerts panel's whole payload.
public struct AlertReport: Codable, Sendable, Hashable {
    public var alerts: [HealthAlert]
    public var hasBaseline: Bool
    public var summary: AlertSummary

    private enum CodingKeys: String, CodingKey {
        case alerts, summary
        case hasBaseline = "has_baseline"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alerts = try c.decodeIfPresent([HealthAlert].self, forKey: .alerts) ?? []
        hasBaseline = try c.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        summary = try c.decodeIfPresent(AlertSummary.self, forKey: .summary) ?? AlertSummary()
    }

    public init(alerts: [HealthAlert] = [], hasBaseline: Bool = false) {
        self.alerts = alerts
        self.hasBaseline = hasBaseline
        self.summary = AlertSummary()
    }

    public static let empty = AlertReport()

    /// Alerts grouped by severity, worst group first, with empty groups
    /// omitted so the panel shows no headings for nothing.
    public var grouped: [(severity: AlertSeverity, alerts: [HealthAlert])] {
        AlertSeverity.allCases
            .sorted { $0.rank < $1.rank }
            .map { severity in
                (severity, alerts.filter { $0.severity == severity })
            }
            .filter { !$0.1.isEmpty }
    }

    /// Every distinct alert type present, for the filter menu.
    public var types: [String] {
        Array(Set(alerts.map(\.type))).sorted()
    }

    /// Every distinct label mentioned, for the filter menu.
    public var labels: [String] {
        Array(Set(alerts.map(\.label).filter { !$0.isEmpty })).sorted()
    }
}
