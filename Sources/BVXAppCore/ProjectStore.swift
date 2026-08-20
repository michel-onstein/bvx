import AppKit
import BVXCore
import BVXEngine
import Combine
import SwiftUI

/// The view surfaces in the sidebar.
public enum ViewSurface: String, CaseIterable, Identifiable, Sendable {
    case list, board, graph, tree, insights, plan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: "List"
        case .board: "Board"
        case .graph: "Graph"
        case .tree: "Tree"
        case .insights: "Insights"
        case .plan: "Plan"
        }
    }

    public var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .tree: "list.bullet.indent"
        case .insights: "chart.bar.xaxis"
        case .plan: "flowchart"
        }
    }

    /// Command-key equivalent. bv's own single-letter binding is applied
    /// separately by the terminal-keys layer.
    public var keyEquivalent: KeyEquivalent {
        switch self {
        case .list: "1"
        case .board: "2"
        case .graph: "3"
        case .tree: "4"
        case .insights: "5"
        case .plan: "6"
        }
    }

    /// bv's single-key shortcut for this surface.
    public var terminalKey: Character {
        switch self {
        case .list: "l"
        case .board: "b"
        case .graph: "g"
        case .tree: "E"
        case .insights: "i"
        case .plan: "p"
        }
    }
}

/// Observable application state for one workspace.
@MainActor
public final class ProjectStore: ObservableObject {
    @Published public private(set) var issues: [Issue] = []
    @Published public private(set) var metrics: GraphMetrics = .empty
    @Published public private(set) var actionable: Set<String> = []
    @Published public private(set) var plan: ExecutionPlan = .empty
    @Published public private(set) var edges: [GraphEdge] = []
    @Published public private(set) var info: WorkspaceInfo?
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var phase2InFlight = false

    @Published public var surface: ViewSurface = .list
    @Published public var query = IssueQuery()
    @Published public var selection: Issue.ID?
    @Published public var terminalKeysEnabled = true
    @Published public var skipPhase2 = false

    private let engine = BeadsEngine()

    public init() {}

    public var isLoaded: Bool { info != nil }

    /// Issues after the active filter, search and sort.
    public var visibleIssues: [Issue] {
        query.apply(to: issues, actionable: actionable, metrics: metrics)
    }

    public var selectedIssue: Issue? {
        guard let selection else { return nil }
        return issues.first { $0.id == selection }
    }

    public var issuesByID: [String: Issue] {
        Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
    }

    // MARK: - Loading

    /// Opens the workspace named by the first CLI argument, the BVX_WORKSPACE
    /// environment variable, or the current directory — in that order.
    public func openInitialWorkspace() async {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            await open(path: path)
        } else if let env = ProcessInfo.processInfo.environment["BVX_WORKSPACE"] {
            await open(path: env)
        } else {
            await open(path: FileManager.default.currentDirectoryPath)
        }
    }

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder, a .beads directory, or a bead data file."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(path: url.path) }
    }

    public func open(path: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let info = try await engine.open(path: path, skipPhase2: skipPhase2)
            self.info = info
            try await refreshAll()
            if !skipPhase2 { await computePhase2() }
        } catch {
            self.loadError = error.localizedDescription
            self.info = nil
            self.issues = []
            self.metrics = .empty
            self.actionable = []
            self.plan = .empty
            self.edges = []
        }
    }

    public func reload() async {
        guard isLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await engine.reload()
            try await refreshAll()
            await computePhase2()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshAll() async throws {
        issues = try await engine.issues()
        metrics = try await engine.metrics()
        actionable = try await engine.actionableIDs()
        plan = try await engine.executionPlan()
        edges = try await engine.graphEdges()
        if selection == nil || !issues.contains(where: { $0.id == selection }) {
            selection = visibleIssues.first?.id
        }
    }

    /// Waits for the expensive metrics off the main actor, then republishes.
    ///
    /// Gating on `hasPhase2Values` rather than `phase2Ready` matters: a session
    /// opened with metrics skipped reports ready with nothing in it, and
    /// waiting again would return the same emptiness forever.
    public func computePhase2() async {
        guard isLoaded, !metrics.hasPhase2Values, !phase2InFlight else { return }
        phase2InFlight = true
        defer { phase2InFlight = false }
        do {
            metrics =
                metrics.phase2Ready
                ? try await engine.computeFullMetrics()
                : try await engine.waitForPhase2()
            actionable = try await engine.actionableIDs()
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func close() async {
        await engine.close()
    }

    // MARK: - Derived data

    /// Ids that closing `id` would make actionable.
    public func unblocks(_ id: String) async -> [String] {
        (try? await engine.unblocks(id)) ?? []
    }

    public var labelCounts: [(label: String, count: Int)] { issues.labelCounts }

    /// Dependencies of `issue` paired with the issue they point at.
    public func blockers(of issue: Issue) -> [(Dependency, Issue?)] {
        let byID = issuesByID
        return issue.dependencies.map { ($0, byID[$0.dependsOnID]) }
    }

    /// Issues that list `issue` as a dependency.
    public func dependents(of issue: Issue) -> [Issue] {
        issues.filter { candidate in
            candidate.dependencies.contains { $0.dependsOnID == issue.id }
        }
    }

    /// A one-line health report used by the headless self-check and the
    /// status bar, so both describe the workspace the same way.
    public func summaryLine() -> String {
        guard let info else { return "no workspace" }
        return "\(info.displayName): \(issues.count) beads, \(actionable.count) ready, "
            + "\(metrics.nodeCount) nodes / \(metrics.edgeCount) edges, "
            + "phase2=\(metrics.phase2Ready)"
    }
}
