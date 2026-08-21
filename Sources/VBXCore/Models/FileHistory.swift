import Foundation

/// A bead that has touched a file.
public struct BeadReference: Codable, Sendable, Hashable, Identifiable {
    public var beadID: String
    public var title: String
    public var status: String
    public var commitSHAs: [String]
    public var lastTouch: Date?
    public var totalChanges: Int

    public var id: String { beadID }

    private enum CodingKeys: String, CodingKey {
        case title, status
        case beadID = "bead_id"
        case commitSHAs = "commit_shas"
        case lastTouch = "last_touch"
        case totalChanges = "total_changes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        commitSHAs = try c.decodeIfPresent([String].self, forKey: .commitSHAs) ?? []
        lastTouch = try? c.decodeIfPresent(Date.self, forKey: .lastTouch)
        totalChanges = try c.decodeIfPresent(Int.self, forKey: .totalChanges) ?? 0
    }
}

/// Which beads have touched one file.
public struct FileBeadLookup: Codable, Sendable, Hashable {
    public var filePath: String
    public var openBeads: [BeadReference]
    public var closedBeads: [BeadReference]
    public var totalBeads: Int

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case openBeads = "open_beads"
        case closedBeads = "closed_beads"
        case totalBeads = "total_beads"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        openBeads = try c.decodeIfPresent([BeadReference].self, forKey: .openBeads) ?? []
        closedBeads = try c.decodeIfPresent([BeadReference].self, forKey: .closedBeads) ?? []
        totalBeads = try c.decodeIfPresent(Int.self, forKey: .totalBeads) ?? 0
    }

    public init() {
        filePath = ""
        openBeads = []
        closedBeads = []
        totalBeads = 0
    }

    public static let empty = FileBeadLookup()
}

/// A file many beads have touched.
public struct FileHotspot: Codable, Sendable, Hashable, Identifiable {
    public var filePath: String
    public var totalBeads: Int
    public var openBeads: Int
    public var closedBeads: Int

    public var id: String { filePath }

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case totalBeads = "total_beads"
        case openBeads = "open_beads"
        case closedBeads = "closed_beads"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        totalBeads = try c.decodeIfPresent(Int.self, forKey: .totalBeads) ?? 0
        openBeads = try c.decodeIfPresent(Int.self, forKey: .openBeads) ?? 0
        closedBeads = try c.decodeIfPresent(Int.self, forKey: .closedBeads) ?? 0
    }
}

public struct FileIndexStats: Codable, Sendable, Hashable {
    public var totalFiles: Int
    public var totalBeadLinks: Int
    public var filesWithMultipleBeads: Int

    private enum CodingKeys: String, CodingKey {
        case totalFiles = "total_files"
        case totalBeadLinks = "total_bead_links"
        case filesWithMultipleBeads = "files_with_multiple_beads"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalFiles = try c.decodeIfPresent(Int.self, forKey: .totalFiles) ?? 0
        totalBeadLinks = try c.decodeIfPresent(Int.self, forKey: .totalBeadLinks) ?? 0
        filesWithMultipleBeads =
            try c.decodeIfPresent(Int.self, forKey: .filesWithMultipleBeads) ?? 0
    }

    public init() {
        totalFiles = 0
        totalBeadLinks = 0
        filesWithMultipleBeads = 0
    }
}

public struct FileHotspots: Codable, Sendable, Hashable {
    public var hotspots: [FileHotspot]
    public var stats: FileIndexStats

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotspots = try c.decodeIfPresent([FileHotspot].self, forKey: .hotspots) ?? []
        stats = try c.decodeIfPresent(FileIndexStats.self, forKey: .stats) ?? FileIndexStats()
    }

    private enum CodingKeys: String, CodingKey { case hotspots, stats }

    public init() {
        hotspots = []
        stats = FileIndexStats()
    }

    public static let empty = FileHotspots()
}

/// A file that changes alongside another.
public struct CoChangeEntry: Codable, Sendable, Hashable, Identifiable {
    public var filePath: String
    public var coChangeCount: Int
    public var totalCommits: Int
    public var correlation: Double
    public var sampleCommits: [String]

    public var id: String { filePath }

    private enum CodingKeys: String, CodingKey {
        case correlation
        case filePath = "file_path"
        case coChangeCount = "co_change_count"
        case totalCommits = "total_commits"
        case sampleCommits = "sample_commits"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        coChangeCount = try c.decodeIfPresent(Int.self, forKey: .coChangeCount) ?? 0
        totalCommits = try c.decodeIfPresent(Int.self, forKey: .totalCommits) ?? 0
        correlation = try c.decodeIfPresent(Double.self, forKey: .correlation) ?? 0
        sampleCommits = try c.decodeIfPresent([String].self, forKey: .sampleCommits) ?? []
    }
}

public struct CoChangeResult: Codable, Sendable, Hashable {
    public var filePath: String
    public var totalCommits: Int
    public var relatedFiles: [CoChangeEntry]
    public var threshold: Double

    private enum CodingKeys: String, CodingKey {
        case threshold
        case filePath = "file_path"
        case totalCommits = "total_commits"
        case relatedFiles = "related_files"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        totalCommits = try c.decodeIfPresent(Int.self, forKey: .totalCommits) ?? 0
        relatedFiles = try c.decodeIfPresent([CoChangeEntry].self, forKey: .relatedFiles) ?? []
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0
    }

    public init() {
        filePath = ""
        totalCommits = 0
        relatedFiles = []
        threshold = 0
    }

    public static let empty = CoChangeResult()
}

// MARK: - Orphans

/// A bead an orphan commit might belong to.
public struct ProbableBead: Codable, Sendable, Hashable, Identifiable {
    public var beadID: String
    public var beadTitle: String
    public var beadStatus: String
    /// 0…100.
    public var confidence: Int
    public var reasons: [String]

    public var id: String { beadID }

    private enum CodingKeys: String, CodingKey {
        case confidence, reasons
        case beadID = "bead_id"
        case beadTitle = "bead_title"
        case beadStatus = "bead_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        beadTitle = try c.decodeIfPresent(String.self, forKey: .beadTitle) ?? ""
        beadStatus = try c.decodeIfPresent(String.self, forKey: .beadStatus) ?? ""
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }
}

public struct OrphanSignalHit: Codable, Sendable, Hashable, Identifiable {
    public var signal: String
    public var details: String
    public var weight: Int

    public var id: String { signal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signal = try c.decodeIfPresent(String.self, forKey: .signal) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case signal, details, weight }
}

/// A commit no bead accounts for.
public struct OrphanCandidate: Codable, Sendable, Hashable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var message: String
    public var author: String
    public var authorEmail: String
    public var timestamp: Date?
    public var files: [String]
    /// 0…100.
    public var suspicionScore: Int
    public var probableBeads: [ProbableBead]
    public var signals: [OrphanSignalHit]

    public var id: String { sha }

    private enum CodingKeys: String, CodingKey {
        case sha, message, author, timestamp, files, signals
        case shortSHA = "short_sha"
        case authorEmail = "author_email"
        case suspicionScore = "suspicion_score"
        case probableBeads = "probable_beads"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        shortSHA = try c.decodeIfPresent(String.self, forKey: .shortSHA) ?? String(sha.prefix(7))
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorEmail = try c.decodeIfPresent(String.self, forKey: .authorEmail) ?? ""
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        suspicionScore = try c.decodeIfPresent(Int.self, forKey: .suspicionScore) ?? 0
        probableBeads = try c.decodeIfPresent([ProbableBead].self, forKey: .probableBeads) ?? []
        signals = try c.decodeIfPresent([OrphanSignalHit].self, forKey: .signals) ?? []
    }

    public var subject: String {
        message.components(separatedBy: .newlines).first ?? message
    }
}

public struct OrphanStats: Codable, Sendable, Hashable {
    public var totalCommits: Int
    public var correlatedCount: Int
    public var orphanCount: Int
    public var orphanRatio: Double
    public var avgSuspicion: Double

    private enum CodingKeys: String, CodingKey {
        case totalCommits = "total_commits"
        case correlatedCount = "correlated_count"
        case orphanCount = "orphan_count"
        case orphanRatio = "orphan_ratio"
        case avgSuspicion = "avg_suspicion_score"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCommits = try c.decodeIfPresent(Int.self, forKey: .totalCommits) ?? 0
        correlatedCount = try c.decodeIfPresent(Int.self, forKey: .correlatedCount) ?? 0
        orphanCount = try c.decodeIfPresent(Int.self, forKey: .orphanCount) ?? 0
        orphanRatio = try c.decodeIfPresent(Double.self, forKey: .orphanRatio) ?? 0
        avgSuspicion = try c.decodeIfPresent(Double.self, forKey: .avgSuspicion) ?? 0
    }

    public init() {
        totalCommits = 0
        correlatedCount = 0
        orphanCount = 0
        orphanRatio = 0
        avgSuspicion = 0
    }
}

public struct OrphanReport: Codable, Sendable, Hashable {
    public var gitRange: String
    public var dataHash: String
    public var stats: OrphanStats
    public var candidates: [OrphanCandidate]

    private enum CodingKeys: String, CodingKey {
        case stats, candidates
        case gitRange = "git_range"
        case dataHash = "data_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRange = try c.decodeIfPresent(String.self, forKey: .gitRange) ?? ""
        dataHash = try c.decodeIfPresent(String.self, forKey: .dataHash) ?? ""
        stats = try c.decodeIfPresent(OrphanStats.self, forKey: .stats) ?? OrphanStats()
        candidates = try c.decodeIfPresent([OrphanCandidate].self, forKey: .candidates) ?? []
    }

    public init() {
        gitRange = ""
        dataHash = ""
        stats = OrphanStats()
        candidates = []
    }

    public static let empty = OrphanReport()
}

// MARK: - Related work

public struct RelatedWorkBead: Codable, Sendable, Hashable, Identifiable {
    public var beadID: String
    public var title: String
    public var status: String
    public var relationType: String
    /// 0…100.
    public var relevance: Int
    public var reason: String
    public var sharedFiles: [String]
    public var sharedCommits: [String]

    public var id: String { "\(relationType)-\(beadID)" }

    private enum CodingKeys: String, CodingKey {
        case title, status, relevance, reason
        case beadID = "bead_id"
        case relationType = "relation_type"
        case sharedFiles = "shared_files"
        case sharedCommits = "shared_commits"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beadID = try c.decodeIfPresent(String.self, forKey: .beadID) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        relationType = try c.decodeIfPresent(String.self, forKey: .relationType) ?? ""
        relevance = try c.decodeIfPresent(Int.self, forKey: .relevance) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        sharedFiles = try c.decodeIfPresent([String].self, forKey: .sharedFiles) ?? []
        sharedCommits = try c.decodeIfPresent([String].self, forKey: .sharedCommits) ?? []
    }
}

public struct RelatedWork: Codable, Sendable, Hashable {
    public var targetBeadID: String
    public var targetTitle: String
    public var fileOverlap: [RelatedWorkBead]
    public var commitOverlap: [RelatedWorkBead]
    public var dependencyCluster: [RelatedWorkBead]
    public var concurrent: [RelatedWorkBead]
    public var totalRelated: Int

    private enum CodingKeys: String, CodingKey {
        case concurrent
        case targetBeadID = "target_bead_id"
        case targetTitle = "target_title"
        case fileOverlap = "file_overlap"
        case commitOverlap = "commit_overlap"
        case dependencyCluster = "dependency_cluster"
        case totalRelated = "total_related"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetBeadID = try c.decodeIfPresent(String.self, forKey: .targetBeadID) ?? ""
        targetTitle = try c.decodeIfPresent(String.self, forKey: .targetTitle) ?? ""
        fileOverlap = try c.decodeIfPresent([RelatedWorkBead].self, forKey: .fileOverlap) ?? []
        commitOverlap = try c.decodeIfPresent([RelatedWorkBead].self, forKey: .commitOverlap) ?? []
        dependencyCluster =
            try c.decodeIfPresent([RelatedWorkBead].self, forKey: .dependencyCluster) ?? []
        concurrent = try c.decodeIfPresent([RelatedWorkBead].self, forKey: .concurrent) ?? []
        totalRelated = try c.decodeIfPresent(Int.self, forKey: .totalRelated) ?? 0
    }

    public init() {
        targetBeadID = ""
        targetTitle = ""
        fileOverlap = []
        commitOverlap = []
        dependencyCluster = []
        concurrent = []
        totalRelated = 0
    }

    public static let empty = RelatedWork()

    /// The four relation groups, in the order the inspector shows them.
    public var groups: [(name: String, beads: [RelatedWorkBead])] {
        [
            ("Shared files", fileOverlap),
            ("Shared commits", commitOverlap),
            ("Dependency cluster", dependencyCluster),
            ("Worked on concurrently", concurrent),
        ].filter { !$0.beads.isEmpty }
    }
}
