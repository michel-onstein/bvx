import Foundation

/// One file in a built bundle.
public struct BundleFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var bytes: Int64

    public var id: String { path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case path, bytes }

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The result of building a static site bundle.
public struct SiteBundle: Codable, Sendable, Hashable {
    public var outputDir: String
    public var title: String
    public var issueCount: Int
    public var totalBytes: Int64
    public var files: [BundleFile]
    /// Non-fatal problems — a missing viewer asset, a graph that would not
    /// render. The bundle exists; these say what is incomplete about it.
    public var warnings: [String]
    public var suggestedRepo: String
    public var suggestedProject: String

    private enum CodingKeys: String, CodingKey {
        case title, files, warnings
        case outputDir = "output_dir"
        case issueCount = "issue_count"
        case totalBytes = "total_bytes"
        case suggestedRepo = "suggested_repo"
        case suggestedProject = "suggested_project"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        issueCount = try c.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        files = try c.decodeIfPresent([BundleFile].self, forKey: .files) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        suggestedRepo = try c.decodeIfPresent(String.self, forKey: .suggestedRepo) ?? ""
        suggestedProject = try c.decodeIfPresent(String.self, forKey: .suggestedProject) ?? ""
    }

    public init() {
        outputDir = ""
        title = ""
        issueCount = 0
        totalBytes = 0
        files = []
        warnings = []
        suggestedRepo = ""
        suggestedProject = ""
    }

    public static let empty = SiteBundle()

    public var isBuilt: Bool { !outputDir.isEmpty && totalBytes > 0 }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// The largest few files, which is what a host's size limit will care
    /// about.
    public var largestFiles: [BundleFile] { Array(files.prefix(6)) }
}

/// A running local preview.
public struct SitePreview: Codable, Sendable, Hashable {
    public var url: String
    public var port: Int
    public var bundlePath: String

    private enum CodingKeys: String, CodingKey {
        case url, port
        case bundlePath = "bundle_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath) ?? ""
    }

    public init() {
        url = ""
        port = 0
        bundlePath = ""
    }

    public static let empty = SitePreview()
    public var isRunning: Bool { !url.isEmpty }
}

/// The result of a GitHub Pages deployment.
public struct SiteDeployment: Codable, Sendable, Hashable {
    public var repo: String
    public var branch: String
    public var createdRepo: Bool
    public var remote: String
    public var pagesURL: String
    public var warnings: [String]
    public var verifyHint: String

    private enum CodingKeys: String, CodingKey {
        case repo, branch, remote, warnings
        case createdRepo = "created_repo"
        case pagesURL = "pages_url"
        case verifyHint = "verify_hint"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        createdRepo = try c.decodeIfPresent(Bool.self, forKey: .createdRepo) ?? false
        remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? ""
        pagesURL = try c.decodeIfPresent(String.self, forKey: .pagesURL) ?? ""
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        verifyHint = try c.decodeIfPresent(String.self, forKey: .verifyHint) ?? ""
    }

    public init() {
        repo = ""
        branch = ""
        createdRepo = false
        remote = ""
        pagesURL = ""
        warnings = []
        verifyHint = ""
    }

    public static let empty = SiteDeployment()
    public var isDeployed: Bool { !repo.isEmpty }
}

/// What to do about a target that cannot be driven in-process.
public struct DeployInstructions: Codable, Sendable, Hashable {
    public var supported: Bool
    public var reason: String
    public var command: String
    public var project: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case supported, reason, command, project }

    public init() {
        supported = false
        reason = ""
        command = ""
        project = ""
    }

    public static let empty = DeployInstructions()
}
