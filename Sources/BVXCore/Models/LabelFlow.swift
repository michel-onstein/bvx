import Foundation

/// One blocking relationship between two labels.
public struct LabelDependency: Codable, Sendable, Hashable, Identifiable {
    public var fromLabel: String
    public var toLabel: String
    public var issueCount: Int
    public var issueIDs: [String]

    public var id: String { "\(fromLabel)→\(toLabel)" }

    private enum CodingKeys: String, CodingKey {
        case fromLabel = "from_label"
        case toLabel = "to_label"
        case issueCount = "issue_count"
        case issueIDs = "issue_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromLabel = try c.decodeIfPresent(String.self, forKey: .fromLabel) ?? ""
        toLabel = try c.decodeIfPresent(String.self, forKey: .toLabel) ?? ""
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        issueIDs = try c.decodeIfPresent([String].self, forKey: .issueIDs) ?? []
    }

    public init(fromLabel: String, toLabel: String, issueCount: Int, issueIDs: [String] = []) {
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.issueCount = issueCount
        self.issueIDs = issueIDs
    }
}

/// A chain of labels that work flows through.
public struct LabelPath: Codable, Sendable, Hashable, Identifiable {
    public var labels: [String]
    public var length: Int
    public var issueCount: Int
    public var totalWeight: Double

    public var id: String { labels.joined(separator: "→") }

    private enum CodingKeys: String, CodingKey {
        case labels, length
        case issueCount = "issue_count"
        case totalWeight = "total_weight"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        length = try c.decodeIfPresent(Int.self, forKey: .length) ?? 0
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        totalWeight = try c.decodeIfPresent(Double.self, forKey: .totalWeight) ?? 0
    }
}

/// How work flows between labels: which label blocks which, and how hard.
public struct LabelFlow: Codable, Sendable, Hashable {
    /// Labels in matrix order. `flowMatrix[from][to]` is indexed by this.
    public var labels: [String]
    /// Dependency counts, `[from][to]`.
    public var flowMatrix: [[Int]]
    public var dependencies: [LabelDependency]
    public var criticalPaths: [LabelPath]
    /// Labels the engine identifies as causing the most blockage.
    public var bottleneckLabels: [String]
    public var totalCrossLabelDeps: Int

    private enum CodingKeys: String, CodingKey {
        case labels, dependencies
        case flowMatrix = "flow_matrix"
        case criticalPaths = "critical_paths"
        case bottleneckLabels = "bottleneck_labels"
        case totalCrossLabelDeps = "total_cross_label_deps"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        flowMatrix = try c.decodeIfPresent([[Int]].self, forKey: .flowMatrix) ?? []
        dependencies = try c.decodeIfPresent([LabelDependency].self, forKey: .dependencies) ?? []
        criticalPaths = try c.decodeIfPresent([LabelPath].self, forKey: .criticalPaths) ?? []
        bottleneckLabels = try c.decodeIfPresent([String].self, forKey: .bottleneckLabels) ?? []
        totalCrossLabelDeps = try c.decodeIfPresent(Int.self, forKey: .totalCrossLabelDeps) ?? 0
    }

    public init(
        labels: [String] = [], flowMatrix: [[Int]] = [], dependencies: [LabelDependency] = [],
        criticalPaths: [LabelPath] = [], bottleneckLabels: [String] = [],
        totalCrossLabelDeps: Int = 0
    ) {
        self.labels = labels
        self.flowMatrix = flowMatrix
        self.dependencies = dependencies
        self.criticalPaths = criticalPaths
        self.bottleneckLabels = bottleneckLabels
        self.totalCrossLabelDeps = totalCrossLabelDeps
    }

    public static let empty = LabelFlow()

    /// The count at one cell, or nil when the indices fall outside the matrix.
    ///
    /// Returning nil rather than 0 keeps "no such cell" distinguishable from
    /// "no dependencies between these two labels", which the heat map colours
    /// differently.
    public func count(from: Int, to: Int) -> Int? {
        guard flowMatrix.indices.contains(from), flowMatrix[from].indices.contains(to) else {
            return nil
        }
        return flowMatrix[from][to]
    }

    /// The largest single cell, used to scale the heat map.
    ///
    /// The diagonal is excluded: a label depending on itself is not flow
    /// between labels, and letting it set the scale would wash out everything
    /// that is.
    public var peakCount: Int {
        var peak = 0
        for (row, counts) in flowMatrix.enumerated() {
            for (column, value) in counts.enumerated() where row != column {
                peak = max(peak, value)
            }
        }
        return peak
    }

    /// The dependencies behind one cell, for the drilldown.
    public func dependencies(from: String, to: String) -> [LabelDependency] {
        dependencies.filter { $0.fromLabel == from && $0.toLabel == to }
    }
}

/// How much attention one label needs, with the factors that produced the
/// score.
///
/// bv's formula is `(pagerank_sum × staleness × block_impact) / velocity`, and
/// every factor is carried through — a rank on its own says a label is in
/// trouble without saying why.
public struct LabelAttentionScore: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var attentionScore: Double
    public var normalizedScore: Double
    public var rank: Int

    public var pageRankSum: Double
    public var stalenessFactor: Double
    public var blockImpact: Double
    public var velocityFactor: Double

    public var openCount: Int
    public var blockedCount: Int
    public var staleCount: Int

    public var id: String { label }

    private enum CodingKeys: String, CodingKey {
        case label, rank
        case attentionScore = "attention_score"
        case normalizedScore = "normalized_score"
        case pageRankSum = "pagerank_sum"
        case stalenessFactor = "staleness_factor"
        case blockImpact = "block_impact"
        case velocityFactor = "velocity_factor"
        case openCount = "open_count"
        case blockedCount = "blocked_count"
        case staleCount = "stale_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        attentionScore = try c.decodeIfPresent(Double.self, forKey: .attentionScore) ?? 0
        normalizedScore = try c.decodeIfPresent(Double.self, forKey: .normalizedScore) ?? 0
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        pageRankSum = try c.decodeIfPresent(Double.self, forKey: .pageRankSum) ?? 0
        stalenessFactor = try c.decodeIfPresent(Double.self, forKey: .stalenessFactor) ?? 0
        blockImpact = try c.decodeIfPresent(Double.self, forKey: .blockImpact) ?? 0
        velocityFactor = try c.decodeIfPresent(Double.self, forKey: .velocityFactor) ?? 0
        openCount = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        blockedCount = try c.decodeIfPresent(Int.self, forKey: .blockedCount) ?? 0
        staleCount = try c.decodeIfPresent(Int.self, forKey: .staleCount) ?? 0
    }

    public init(
        label: String, attentionScore: Double = 0, normalizedScore: Double = 0, rank: Int = 0,
        pageRankSum: Double = 0, stalenessFactor: Double = 0, blockImpact: Double = 0,
        velocityFactor: Double = 0, openCount: Int = 0, blockedCount: Int = 0, staleCount: Int = 0
    ) {
        self.label = label
        self.attentionScore = attentionScore
        self.normalizedScore = normalizedScore
        self.rank = rank
        self.pageRankSum = pageRankSum
        self.stalenessFactor = stalenessFactor
        self.blockImpact = blockImpact
        self.velocityFactor = velocityFactor
        self.openCount = openCount
        self.blockedCount = blockedCount
        self.staleCount = staleCount
    }

    /// The score's factors, in the order bv's formula multiplies them.
    ///
    /// Velocity divides rather than multiplies, which is why it is labelled
    /// as reducing attention rather than adding to it.
    public var factors: [(name: String, value: Double, raises: Bool)] {
        [
            ("Centrality", pageRankSum, true),
            ("Staleness", stalenessFactor, true),
            ("Block impact", blockImpact, true),
            ("Velocity", velocityFactor, false),
        ]
    }
}

/// Labels ranked by attention needed.
public struct LabelAttention: Codable, Sendable, Hashable {
    public var labels: [LabelAttentionScore]
    public var topAttention: [String]
    public var lowAttention: [String]
    public var maxScore: Double
    public var minScore: Double
    public var totalLabels: Int

    private enum CodingKeys: String, CodingKey {
        case labels
        case topAttention = "top_attention"
        case lowAttention = "low_attention"
        case maxScore = "max_score"
        case minScore = "min_score"
        case totalLabels = "total_labels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decodeIfPresent([LabelAttentionScore].self, forKey: .labels) ?? []
        topAttention = try c.decodeIfPresent([String].self, forKey: .topAttention) ?? []
        lowAttention = try c.decodeIfPresent([String].self, forKey: .lowAttention) ?? []
        maxScore = try c.decodeIfPresent(Double.self, forKey: .maxScore) ?? 0
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore) ?? 0
        totalLabels = try c.decodeIfPresent(Int.self, forKey: .totalLabels) ?? 0
    }

    public init(
        labels: [LabelAttentionScore] = [], topAttention: [String] = [],
        lowAttention: [String] = [], maxScore: Double = 0, minScore: Double = 0,
        totalLabels: Int = 0
    ) {
        self.labels = labels
        self.topAttention = topAttention
        self.lowAttention = lowAttention
        self.maxScore = maxScore
        self.minScore = minScore
        self.totalLabels = totalLabels
    }

    public static let empty = LabelAttention()

    public func score(for label: String) -> LabelAttentionScore? {
        labels.first { $0.label == label }
    }
}
