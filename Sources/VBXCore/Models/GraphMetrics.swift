import Foundation

/// Outcome of computing one Phase-2 metric.
///
/// This exists so the UI can never render a missing value as a real zero.
/// bv reports the same four states; vbx must preserve the distinction or a
/// timed-out betweenness would read as "this node is not a bottleneck".
public enum MetricState: String, Codable, Sendable, Hashable {
    case computed
    case approx
    case timeout
    case skipped
    case pending

    public var isUsable: Bool { self == .computed || self == .approx }

    public var displayName: String {
        switch self {
        case .computed: "Computed"
        case .approx: "Approximate"
        case .timeout: "Timed out"
        case .skipped: "Skipped"
        case .pending: "Computing…"
        }
    }
}

/// Per-metric status, including why a metric is unusable and how long it took.
public struct MetricStatusEntry: Codable, Sendable, Hashable {
    public var state: MetricState
    public var reason: String?
    /// Sample size when `state == .approx`.
    public var sample: Int?
    public var milliseconds: Double?

    private enum CodingKeys: String, CodingKey {
        case state, reason, sample, milliseconds = "ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .state) ?? "pending"
        state = MetricState(rawValue: raw) ?? .pending
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        sample = try c.decodeIfPresent(Int.self, forKey: .sample)
        milliseconds = try c.decodeIfPresent(Double.self, forKey: .milliseconds)
    }

    public init(state: MetricState, reason: String? = nil, sample: Int? = nil, milliseconds: Double? = nil) {
        self.state = state
        self.reason = reason
        self.sample = sample
        self.milliseconds = milliseconds
    }

    /// Short annotation to show beside a value, e.g. "approx (n=120)".
    public var annotation: String? {
        switch state {
        case .computed: nil
        case .approx: sample.map { "approx (n=\($0))" } ?? "approx"
        case .timeout: milliseconds.map { "timed out (\(Int($0)) ms)" } ?? "timed out"
        case .skipped: reason.map { "skipped: \($0)" } ?? "skipped"
        case .pending: "computing…"
        }
    }
}

/// Status of every Phase-2 metric.
public struct MetricStatus: Codable, Sendable, Hashable {
    public var pageRank: MetricStatusEntry?
    public var betweenness: MetricStatusEntry?
    public var eigenvector: MetricStatusEntry?
    public var hits: MetricStatusEntry?
    public var critical: MetricStatusEntry?
    public var cycles: MetricStatusEntry?
    public var kCore: MetricStatusEntry?
    public var articulation: MetricStatusEntry?
    public var slack: MetricStatusEntry?

    private enum CodingKeys: String, CodingKey {
        case pageRank = "PageRank"
        case betweenness = "Betweenness"
        case eigenvector = "Eigenvector"
        case hits = "HITS"
        case critical = "Critical"
        case cycles = "Cycles"
        case kCore = "KCore"
        case articulation = "Articulation"
        case slack = "Slack"
    }
}

/// Snapshot of the dependency graph's computed metrics.
///
/// Phase-1 fields are always populated. Phase-2 dictionaries are `nil` until
/// `phase2Ready`, never zero-filled.
public struct GraphMetrics: Codable, Sendable, Hashable {
    public var nodeCount: Int
    public var edgeCount: Int
    public var density: Double
    public var inDegree: [String: Int]
    public var outDegree: [String: Int]
    public var topologicalOrder: [String]
    public var phase2Ready: Bool
    public var status: MetricStatus?

    public var pageRank: [String: Double]?
    public var betweenness: [String: Double]?
    public var eigenvector: [String: Double]?
    public var hubs: [String: Double]?
    public var authorities: [String: Double]?
    public var criticalPath: [String: Double]?
    public var slack: [String: Double]?
    public var coreNumber: [String: Int]?
    public var articulation: [String]?
    public var cycles: [[String]]?
    public var pageRankRank: [String: Int]?
    public var betweennessRank: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case nodeCount = "node_count"
        case edgeCount = "edge_count"
        case density
        case inDegree = "in_degree"
        case outDegree = "out_degree"
        case topologicalOrder = "topological_order"
        case phase2Ready = "phase2_ready"
        case status
        case pageRank = "pagerank"
        case betweenness, eigenvector, hubs, authorities, slack, cycles, articulation
        case criticalPath = "critical_path"
        case coreNumber = "core_number"
        case pageRankRank = "pagerank_rank"
        case betweennessRank = "betweenness_rank"
    }

    public static let empty = GraphMetrics(
        nodeCount: 0, edgeCount: 0, density: 0,
        inDegree: [:], outDegree: [:], topologicalOrder: [],
        phase2Ready: false, status: nil
    )

    public init(
        nodeCount: Int, edgeCount: Int, density: Double,
        inDegree: [String: Int], outDegree: [String: Int],
        topologicalOrder: [String], phase2Ready: Bool, status: MetricStatus?
    ) {
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.density = density
        self.inDegree = inDegree
        self.outDegree = outDegree
        self.topologicalOrder = topologicalOrder
        self.phase2Ready = phase2Ready
        self.status = status
    }

    /// True when Phase-2 metrics actually carry values.
    ///
    /// Distinct from `phase2Ready`, which is also true when every metric was
    /// *skipped* — ready with nothing in it. The UI needs the stronger test to
    /// decide whether "compute metrics" still has work to do.
    public var hasPhase2Values: Bool {
        phase2Ready && !(pageRank?.isEmpty ?? true)
    }

    /// Number of issues that depend on `id` — i.e. how many it blocks.
    public func blocks(_ id: String) -> Int { inDegree[id] ?? 0 }
    /// Number of issues `id` is waiting on.
    public func blockedBy(_ id: String) -> Int { outDegree[id] ?? 0 }

    /// The set of ids that participate in at least one dependency cycle.
    public var cyclicNodes: Set<String> {
        guard let cycles else { return [] }
        return Set(cycles.flatMap { $0 })
    }
}

/// One edge of the dependency graph.
public struct GraphEdge: Codable, Sendable, Hashable, Identifiable {
    public var from: String
    public var to: String
    public var type: DependencyType

    public var id: String { "\(from)->\(to)" }

    private enum CodingKeys: String, CodingKey { case from, to, type }

    public init(from: String, to: String, type: DependencyType) {
        self.from = from
        self.to = to
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        type = DependencyType(rawValue: try c.decodeIfPresent(String.self, forKey: .type) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(type.rawValue, forKey: .type)
    }
}
