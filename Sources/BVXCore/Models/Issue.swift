import Foundation

/// Lifecycle state of a bead.
///
/// Deliberately *open*: beads is an evolving ecosystem (bv itself accepts
/// Gastown orchestration statuses it does not enumerate), so an unrecognised
/// value decodes to `.unknown` and still renders. A closed enum would throw
/// during decoding and silently drop the issue from the graph, which would
/// change every downstream metric.
public enum IssueStatus: RawRepresentable, Codable, Sendable, Hashable {
    case open
    case inProgress
    case blocked
    case deferred
    case draft
    case pinned
    case hooked
    case review
    case closed
    case tombstone
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "in_progress": self = .inProgress
        case "blocked": self = .blocked
        case "deferred": self = .deferred
        case "draft": self = .draft
        case "pinned": self = .pinned
        case "hooked": self = .hooked
        case "review": self = .review
        case "closed": self = .closed
        case "tombstone": self = .tombstone
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .inProgress: "in_progress"
        case .blocked: "blocked"
        case .deferred: "deferred"
        case .draft: "draft"
        case .pinned: "pinned"
        case .hooked: "hooked"
        case .review: "review"
        case .closed: "closed"
        case .tombstone: "tombstone"
        case .unknown(let raw): raw
        }
    }

    /// The statuses bv treats as "open" for the ready/actionable calculation.
    /// Note this is narrower than "not closed": blocked and deferred are
    /// neither open nor closed.
    public var isOpen: Bool {
        self == .open || self == .inProgress
    }

    public var isClosed: Bool { self == .closed }
    public var isTombstone: Bool { self == .tombstone }

    /// Work still on the table, for the "all but archived" filter.
    public var isActive: Bool { !isClosed && !isTombstone }

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .deferred: "Deferred"
        case .draft: "Draft"
        case .pinned: "Pinned"
        case .hooked: "Hooked"
        case .review: "In Review"
        case .closed: "Closed"
        case .tombstone: "Deleted"
        case .unknown(let raw): raw.capitalized
        }
    }

    public var symbolName: String {
        switch self {
        case .open: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.octagon"
        case .deferred: "moon.zzz"
        case .draft: "pencil.line"
        case .pinned: "pin"
        case .hooked: "link"
        case .review: "eye"
        case .closed: "checkmark.circle.fill"
        case .tombstone: "trash"
        case .unknown: "questionmark.circle"
        }
    }

    /// Board column ordering; unknown statuses sort last.
    public var sortOrder: Int {
        switch self {
        case .draft: 0
        case .open: 1
        case .inProgress: 2
        case .review: 3
        case .blocked: 4
        case .deferred: 5
        case .pinned: 6
        case .hooked: 7
        case .closed: 8
        case .tombstone: 9
        case .unknown: 10
        }
    }

    /// The statuses that get a board column, in order.
    public static var boardColumns: [IssueStatus] {
        [.open, .inProgress, .review, .blocked, .closed]
    }
}

/// Kind of work a bead represents.
///
/// Open for the same reason as `IssueStatus`: bv considers *any* non-empty
/// type valid, reserving a separate "known type" notion for icon and sort
/// selection only.
public enum IssueType: RawRepresentable, Codable, Sendable, Hashable {
    case task
    case bug
    case feature
    case epic
    case chore
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "task": self = .task
        case "bug": self = .bug
        case "feature": self = .feature
        case "epic": self = .epic
        case "chore": self = .chore
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .task: "task"
        case .bug: "bug"
        case .feature: "feature"
        case .epic: "epic"
        case .chore: "chore"
        case .other(let raw): raw
        }
    }

    /// Matches bv's `IsKnownType`: drives icon and sort selection, not validity.
    public var isKnown: Bool {
        if case .other = self { return false }
        return true
    }

    public var displayName: String {
        switch self {
        case .task: "Task"
        case .bug: "Bug"
        case .feature: "Feature"
        case .epic: "Epic"
        case .chore: "Chore"
        case .other(let raw): raw.capitalized
        }
    }

    public var symbolName: String {
        switch self {
        case .task: "checklist"
        case .bug: "ant"
        case .feature: "sparkles"
        case .epic: "flag"
        case .chore: "wrench.and.screwdriver"
        case .other: "doc"
        }
    }
}

/// Relationship between two beads.
public enum DependencyType: RawRepresentable, Codable, Sendable, Hashable {
    case blocks
    case related
    case parentChild
    case discoveredFrom
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "blocks": self = .blocks
        case "related": self = .related
        case "parent-child": self = .parentChild
        case "discovered-from": self = .discoveredFrom
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .blocks: "blocks"
        case .related: "related"
        case .parentChild: "parent-child"
        case .discoveredFrom: "discovered-from"
        case .other(let raw): raw
        }
    }

    /// An *empty* type counts as blocking, matching bv's backward-compatibility
    /// rule for dependencies created before the typed system existed. Getting
    /// this wrong silently changes PageRank, betweenness, and the actionable set.
    public var isBlocking: Bool {
        switch self {
        case .blocks: true
        case .other(let raw): raw.isEmpty
        default: false
        }
    }
}

/// A dependency edge. `dependsOnID` is the bead that must be resolved first.
public struct Dependency: Codable, Sendable, Hashable, Identifiable {
    public var issueID: String
    public var dependsOnID: String
    public var type: DependencyType
    public var createdAt: Date?
    public var createdBy: String?

    public var id: String { "\(issueID)->\(dependsOnID):\(type.rawValue)" }

    public init(
        issueID: String,
        dependsOnID: String,
        type: DependencyType = .blocks,
        createdAt: Date? = nil,
        createdBy: String? = nil
    ) {
        self.issueID = issueID
        self.dependsOnID = dependsOnID
        self.type = type
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    private enum CodingKeys: String, CodingKey {
        case issueID = "issue_id"
        case dependsOnID = "depends_on_id"
        case dependsOnLegacy = "depends_on"
        case targetIDLegacy = "target_id"
        case type
        case createdAt = "created_at"
        case createdBy = "created_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        // bv accepts three spellings of the target field across JSONL vintages.
        dependsOnID =
            try c.decodeIfPresent(String.self, forKey: .dependsOnID)
            ?? c.decodeIfPresent(String.self, forKey: .dependsOnLegacy)
            ?? c.decodeIfPresent(String.self, forKey: .targetIDLegacy)
            ?? ""
        type = DependencyType(rawValue: try c.decodeIfPresent(String.self, forKey: .type) ?? "")
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(issueID, forKey: .issueID)
        try c.encode(dependsOnID, forKey: .dependsOnID)
        try c.encode(type.rawValue, forKey: .type)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
    }
}

/// A comment on a bead.
public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var issueID: String
    public var author: String
    public var text: String
    public var createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, issueID = "issue_id", author, text, createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // beads v1.0+ writes UUIDv7 strings; older data wrote integers. Both
        // must round-trip, or the comment is silently dropped from the issue.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = ""
        }
        issueID = try c.decodeIfPresent(String.self, forKey: .issueID) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(issueID, forKey: .issueID)
        try c.encode(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    public init(id: String, issueID: String, author: String, text: String, createdAt: Date?) {
        self.id = id
        self.issueID = issueID
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

/// A single trackable work item.
public struct Issue: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var design: String?
    public var acceptanceCriteria: String?
    public var notes: String?
    public var status: IssueStatus
    public var priority: Int
    public var type: IssueType
    public var assignee: String?
    public var estimatedMinutes: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var dueDate: Date?
    public var closedAt: Date?
    public var externalRef: String?
    public var labels: [String]
    public var dependencies: [Dependency]
    public var comments: [Comment]
    public var sourceRepo: String?

    /// Dependencies that actually block, which is what the graph metrics use.
    public var blockingDependencies: [Dependency] {
        dependencies.filter(\.type.isBlocking)
    }

    /// Days since the last update, used for the staleness signal.
    public func daysSinceUpdate(now: Date = Date()) -> Int? {
        guard let updatedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: updatedAt, to: now).day
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, design, notes, status, priority
        case acceptanceCriteria = "acceptance_criteria"
        case issueType = "issue_type"
        case assignee
        case estimatedMinutes = "estimated_minutes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case dueDate = "due_date"
        case closedAt = "closed_at"
        case externalRef = "external_ref"
        case labels, dependencies, comments
        case sourceRepo = "source_repo"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        design = try c.decodeIfPresent(String.self, forKey: .design)
        acceptanceCriteria = try c.decodeIfPresent(String.self, forKey: .acceptanceCriteria)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        status = IssueStatus(rawValue: try c.decodeIfPresent(String.self, forKey: .status) ?? "open")
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        type = IssueType(rawValue: try c.decodeIfPresent(String.self, forKey: .issueType) ?? "task")
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
        closedAt = try? c.decodeIfPresent(Date.self, forKey: .closedAt)
        externalRef = try c.decodeIfPresent(String.self, forKey: .externalRef)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        dependencies = try c.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        sourceRepo = try c.decodeIfPresent(String.self, forKey: .sourceRepo)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(design, forKey: .design)
        try c.encodeIfPresent(acceptanceCriteria, forKey: .acceptanceCriteria)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encode(type.rawValue, forKey: .issueType)
        try c.encodeIfPresent(assignee, forKey: .assignee)
        try c.encodeIfPresent(estimatedMinutes, forKey: .estimatedMinutes)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
        try c.encodeIfPresent(externalRef, forKey: .externalRef)
        try c.encode(labels, forKey: .labels)
        try c.encode(dependencies, forKey: .dependencies)
        try c.encode(comments, forKey: .comments)
        try c.encodeIfPresent(sourceRepo, forKey: .sourceRepo)
    }

    public init(
        id: String,
        title: String,
        description: String = "",
        status: IssueStatus = .open,
        priority: Int = 0,
        type: IssueType = .task,
        assignee: String? = nil,
        estimatedMinutes: Int? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        labels: [String] = [],
        dependencies: [Dependency] = [],
        comments: [Comment] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.type = type
        self.assignee = assignee
        self.estimatedMinutes = estimatedMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.dependencies = dependencies
        self.comments = comments
        self.design = nil
        self.acceptanceCriteria = nil
        self.notes = nil
        self.dueDate = nil
        self.closedAt = nil
        self.externalRef = nil
        self.sourceRepo = nil
    }
}

extension Issue {
    /// Priority rendered the way bv does it: lower number means higher priority.
    public var priorityLabel: String { "P\(priority)" }
}
