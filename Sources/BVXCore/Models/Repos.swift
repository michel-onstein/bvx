import Foundation

/// One repository in a multi-repository workspace.
public struct RepoInfo: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// The id prefix this repo's beads carry, e.g. `api-`.
    public var prefix: String
    public var issueCount: Int
    /// Why this repository failed to load, if it did.
    ///
    /// Reported rather than fatal: the other repositories are still usable,
    /// and silently dropping one would make its beads look closed.
    public var error: String

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, prefix, error
        case issueCount = "issue_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }

    public init(name: String, prefix: String, issueCount: Int = 0, error: String = "") {
        self.name = name
        self.prefix = prefix
        self.issueCount = issueCount
        self.error = error
    }

    public var isHealthy: Bool { error.isEmpty }

    /// The prefix without its trailing separator, for a compact badge.
    public var badge: String {
        prefix.hasSuffix("-") ? String(prefix.dropLast()) : prefix
    }

    /// True when `id` belongs to this repository.
    public func owns(_ id: String) -> Bool {
        !prefix.isEmpty && id.hasPrefix(prefix)
    }
}

/// A dependency that leaves its repository.
public struct CrossRepoEdge: Codable, Sendable, Hashable, Identifiable {
    public var from: String
    public var to: String
    public var fromRepo: String
    public var toRepo: String
    public var type: String

    public var id: String { "\(from)→\(to)" }

    private enum CodingKeys: String, CodingKey {
        case from, to, type
        case fromRepo = "from_repo"
        case toRepo = "to_repo"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        fromRepo = try c.decodeIfPresent(String.self, forKey: .fromRepo) ?? ""
        toRepo = try c.decodeIfPresent(String.self, forKey: .toRepo) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
    }

    public init(from: String, to: String, fromRepo: String, toRepo: String, type: String = "blocks")
    {
        self.from = from
        self.to = to
        self.fromRepo = fromRepo
        self.toRepo = toRepo
        self.type = type
    }
}

/// The repositories a workspace aggregates.
public struct RepoList: Codable, Sendable, Hashable {
    public var isWorkspace: Bool
    public var configPath: String
    public var repos: [RepoInfo]
    public var crossRepoEdges: [CrossRepoEdge]

    private enum CodingKeys: String, CodingKey {
        case repos
        case isWorkspace = "is_workspace"
        case configPath = "config_path"
        case crossRepoEdges = "cross_repo_edges"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isWorkspace = try c.decodeIfPresent(Bool.self, forKey: .isWorkspace) ?? false
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath) ?? ""
        repos = try c.decodeIfPresent([RepoInfo].self, forKey: .repos) ?? []
        crossRepoEdges =
            try c.decodeIfPresent([CrossRepoEdge].self, forKey: .crossRepoEdges) ?? []
    }

    public init(isWorkspace: Bool = false, repos: [RepoInfo] = [], edges: [CrossRepoEdge] = []) {
        self.isWorkspace = isWorkspace
        self.configPath = ""
        self.repos = repos
        self.crossRepoEdges = edges
    }

    public static let empty = RepoList()

    /// The repository owning `id`, by longest matching prefix.
    ///
    /// Longest wins because `api-v2-` and `api-` can both match `api-v2-3`,
    /// and the shorter one would attribute the bead to the wrong repository.
    public func repo(owning id: String) -> RepoInfo? {
        repos
            .filter { $0.owns(id) }
            .max { $0.prefix.count < $1.prefix.count }
    }

    /// Ids on either end of a cross-repository dependency.
    ///
    /// These edges are the coordination cost of a multi-repo workspace, and
    /// they are invisible from inside either repository.
    public var crossRepoIDs: Set<String> {
        var ids = Set<String>()
        for edge in crossRepoEdges {
            ids.insert(edge.from)
            ids.insert(edge.to)
        }
        return ids
    }

    public var healthyRepos: [RepoInfo] { repos.filter(\.isHealthy) }
    public var failedRepos: [RepoInfo] { repos.filter { !$0.isHealthy } }
}
