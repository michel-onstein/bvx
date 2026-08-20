import BVXCore
import CBVXEngine
import Foundation

/// Errors surfaced across the engine boundary.
public enum EngineError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case callFailed(method: String, message: String)
    case decodeFailed(method: String, underlying: String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Could not open workspace: \(m)"
        case .callFailed(let method, let m): "Engine call \(method) failed: \(m)"
        case .decodeFailed(let method, let u): "Could not decode \(method) response: \(u)"
        case .notOpen: "No workspace is open."
        }
    }
}

/// The envelope every C entry point returns.
private struct Envelope: Decodable {
    var ok: Bool
    var error: String?
    var handle: Int64?
    var data: JSONValueBox?
}

/// Holds `data` as raw bytes so each caller can decode it into its own type.
private struct JSONValueBox: Decodable {
    let raw: Data
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode whatever shape arrived; the concrete type is the caller's
        // business, and this keeps one generic decode path.
        let any = try container.decode(AnyCodable.self)
        raw = try JSONSerialization.data(withJSONObject: any.value, options: [.fragmentsAllowed])
    }
}

private struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else if let v = try? c.decode([AnyCodable].self) {
            value = v.map(\.value)
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else {
            value = NSNull()
        }
    }
}

/// An open bead workspace, backed by bv's Go analysis engine running
/// in-process.
///
/// Actor-isolated because the underlying session is a single handle: calls are
/// serialised here, while the concurrency that matters (the two-phase
/// analyser's worker pool) lives inside Go.
public actor BeadsEngine {
    private var handle: Int64?

    public init() {}

    deinit {
        if let handle { bvx_close(handle) }
    }

    /// Opens a workspace directory, `.beads` directory, or data file.
    ///
    /// Returns once Phase-1 metrics are ready; Phase 2 continues in the
    /// background and is observable through ``metrics()``.
    public func open(path: String, skipPhase2: Bool = false) throws -> WorkspaceInfo {
        close()

        let config = ["path": path, "skip_phase2": skipPhase2] as [String: Any]
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(decoding: configData, as: UTF8.self)

        let envelope = try configString.withCString { cfg -> Envelope in
            guard let result = bvx_open(UnsafeMutablePointer(mutating: cfg)) else {
                throw EngineError.openFailed("engine returned no response")
            }
            defer { bvx_free(result) }
            return try Self.decodeEnvelope(from: result)
        }

        guard envelope.ok, let h = envelope.handle else {
            throw EngineError.openFailed(envelope.error ?? "unknown error")
        }
        handle = h
        return try call("info", as: WorkspaceInfo.self)
    }

    public func close() {
        if let h = handle {
            bvx_close(h)
            handle = nil
        }
    }

    public var isOpen: Bool { handle != nil }

    // MARK: - Typed methods

    public func info() throws -> WorkspaceInfo { try call("info", as: WorkspaceInfo.self) }

    public func issues() throws -> [Issue] {
        try call("issues", as: IssuesResponse.self).issues
    }

    public func metrics() throws -> GraphMetrics { try call("metrics", as: GraphMetrics.self) }

    /// Blocks inside the engine until Phase 2 finishes, then returns the
    /// complete metrics. Call from a background task; never from the main actor.
    public func waitForPhase2() throws -> GraphMetrics {
        try call("wait_phase2", as: GraphMetrics.self)
    }

    /// Forces a full re-analysis with every metric enabled.
    ///
    /// Needed when the session was opened with `skipPhase2`, or when a metric
    /// timed out: those states are "ready" with no values, so waiting again
    /// would never produce anything.
    public func computeFullMetrics() throws -> GraphMetrics {
        try call("compute_phase2", as: GraphMetrics.self)
    }

    public func reload() throws -> WorkspaceInfo { try call("reload", as: WorkspaceInfo.self) }

    public func actionableIDs() throws -> Set<String> {
        Set(try call("actionable", as: ActionableResponse.self).ids)
    }

    public func executionPlan() throws -> ExecutionPlan {
        try call("plan", as: ExecutionPlan.self)
    }

    public func graphEdges() throws -> [GraphEdge] {
        try call("graph", as: GraphResponse.self).edges
    }

    public func unblocks(_ id: String) throws -> [String] {
        try call("unblocks", request: ["id": id], as: UnblocksResponse.self).unblocks
    }

    public func triage() throws -> Triage {
        try call("triage", as: Triage.self)
    }

    public func labelHealth() throws -> LabelAnalysis {
        try call("label_health", as: LabelAnalysis.self)
    }

    /// Cross-label dependency flow: which label blocks which, and how hard.
    public func labelFlow() throws -> LabelFlow {
        try call("label_flow", as: LabelFlow.self)
    }

    /// Labels ranked by attention needed, each with its score decomposition.
    public func labelAttention() throws -> LabelAttention {
        try call("label_attention", as: LabelAttention.self)
    }

    /// Renders bv's Markdown report, Mermaid diagrams included.
    ///
    /// The content is always returned; `path` additionally writes it, which the
    /// CLI uses. The app writes it itself, through the save panel's URL, so it
    /// keeps working under the App Sandbox.
    public func exportMarkdown(title: String, path: String? = nil) throws -> MarkdownExport {
        var request: [String: Any] = ["title": title]
        if let path { request["path"] = path }
        return try call("export_markdown", request: request, as: MarkdownExport.self)
    }

    // MARK: - Git correlation
    //
    // The report is built by reading the object store directly, so these work
    // under the App Sandbox where a `git` subprocess would not. The first call
    // walks the history and is slow; the engine caches it until the bead set
    // changes.

    /// The whole bead-to-commit correlation report.
    public func history(limit: Int = 0, refresh: Bool = false) throws -> HistoryReport {
        try call("history", request: request(limit: limit, refresh: refresh), as: HistoryReport.self)
    }

    /// One bead's causal chain and the insights drawn from it.
    public func causality(_ id: String) throws -> CausalityResult {
        try call("causality", request: ["id": id], as: CausalityResult.self)
    }

    /// Beads that touched the same files, commits or window as `id`.
    public func relatedWork(_ id: String, limit: Int = 0) throws -> RelatedWork {
        var req: [String: Any] = ["id": id]
        if limit > 0 { req["limit"] = limit }
        return try call("related", request: req, as: RelatedWork.self)
    }

    /// Which beads have touched a file. A path containing `*`, `?` or `[` is
    /// treated as a glob.
    public func beads(touching path: String) throws -> FileBeadLookup {
        try call("file_beads", request: ["path": path], as: FileBeadLookup.self)
    }

    /// Files ranked by how many beads have touched them.
    public func fileHotspots(limit: Int = 25) throws -> FileHotspots {
        try call("file_hotspots", request: ["limit": limit], as: FileHotspots.self)
    }

    /// Files that change alongside `path`.
    public func fileRelations(
        _ path: String, threshold: Double = 0.3, limit: Int = 20
    ) throws -> CoChangeResult {
        try call(
            "file_relations",
            request: ["path": path, "threshold": threshold, "limit": limit],
            as: CoChangeResult.self)
    }

    /// Commits no bead accounts for.
    public func orphanCommits(limit: Int = 0) throws -> OrphanReport {
        try call("orphans", request: request(limit: limit, refresh: false), as: OrphanReport.self)
    }

    private func request(limit: Int, refresh: Bool) -> [String: Any] {
        var req: [String: Any] = [:]
        if limit > 0 { req["limit"] = limit }
        if refresh { req["refresh"] = true }
        return req
    }

    /// Raw JSON for methods bvx surfaces but does not yet model, such as
    /// `triage`, `impact`, `label_health` and `eta`.
    public func rawJSON(_ method: String, request: [String: Any]? = nil) throws -> Data {
        try invoke(method, request: request)
    }

    // MARK: - Plumbing

    private struct IssuesResponse: Decodable { var issues: [Issue] }
    private struct ActionableResponse: Decodable { var ids: [String] }
    private struct GraphResponse: Decodable { var edges: [GraphEdge] }
    private struct UnblocksResponse: Decodable { var unblocks: [String] }

    private func call<T: Decodable>(
        _ method: String, request: [String: Any]? = nil, as type: T.Type
    ) throws -> T {
        let data = try invoke(method, request: request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw EngineError.decodeFailed(method: method, underlying: String(describing: error))
        }
    }

    private func invoke(_ method: String, request: [String: Any]?) throws -> Data {
        guard let h = handle else { throw EngineError.notOpen }

        var requestString = ""
        if let request {
            let d = try JSONSerialization.data(withJSONObject: request)
            requestString = String(decoding: d, as: UTF8.self)
        }

        let envelope: Envelope = try method.withCString { m in
            try requestString.withCString { r in
                guard
                    let result = bvx_call(
                        h,
                        UnsafeMutablePointer(mutating: m),
                        requestString.isEmpty ? nil : UnsafeMutablePointer(mutating: r)
                    )
                else {
                    throw EngineError.callFailed(method: method, message: "no response")
                }
                // Freed on every path, including the throwing ones, so a
                // failed call cannot leak the engine's malloc'd buffer.
                defer { bvx_free(result) }
                return try Self.decodeEnvelope(from: result)
            }
        }

        guard envelope.ok else {
            throw EngineError.callFailed(method: method, message: envelope.error ?? "unknown error")
        }
        guard let box = envelope.data else { return Data("{}".utf8) }
        return box.raw
    }

    private static func decodeEnvelope(from cString: UnsafeMutablePointer<CChar>) throws -> Envelope {
        let data = Data(String(cString: cString).utf8)
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: raw) { return date }
            if let date = iso8601Plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unrecognised date \(raw)")
            )
        }
        return d
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain = ISO8601DateFormatter()
}
