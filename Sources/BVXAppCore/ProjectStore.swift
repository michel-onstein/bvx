import AppKit
import UniformTypeIdentifiers
import BVXCore
import BVXEngine
import Combine
import SwiftUI

/// The view surfaces in the sidebar.
public enum ViewSurface: String, CaseIterable, Identifiable, Sendable {
    case list, board, graph, tree, insights, plan, labels, flow, attention, history, alerts, sprint

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: "List"
        case .board: "Board"
        case .graph: "Graph"
        case .tree: "Tree"
        case .insights: "Insights"
        case .plan: "Plan"
        case .labels: "Labels"
        case .flow: "Flow"
        case .attention: "Attention"
        case .history: "History"
        case .alerts: "Alerts"
        case .sprint: "Sprint"
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
        case .labels: "tag"
        case .flow: "square.grid.3x3"
        case .attention: "exclamationmark.bubble"
        case .history: "clock.arrow.circlepath"
        case .alerts: "bell.badge"
        case .sprint: "chart.line.downtrend.xyaxis"
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
        case .labels: "7"
        case .flow: "8"
        case .attention: "9"
        case .history: "0"
        case .alerts: "-"
        case .sprint: "="
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
        case .labels: "]"
        case .flow: "F"
        case .attention: "A"
        case .history: "t"
        case .alerts: "!"
        case .sprint: "S"
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
    @Published public private(set) var labelAnalysis: LabelAnalysis = .empty
    @Published public private(set) var labelFlow: LabelFlow = .empty
    @Published public private(set) var labelAttention: LabelAttention = .empty
    @Published public private(set) var triage: Triage = .empty
    @Published public private(set) var info: WorkspaceInfo?
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var phase2InFlight = false

    @Published public var surface: ViewSurface = .list
    @Published public var query = IssueQuery()
    @Published public var selection: Issue.ID?
    @Published public var terminalKeysEnabled = true
    @Published public var skipPhase2 = false
    @Published public private(set) var isWatching = false
    @Published public private(set) var lastReloadAt: Date?
    @Published public private(set) var lastExportPath: String?

    // MARK: Correlation
    //
    // History is loaded on demand rather than with the workspace: walking the
    // object store is the most expensive thing the engine does, and most
    // sessions never open the History view at all.
    @Published public private(set) var history: HistoryReport = .empty
    @Published public private(set) var orphans: OrphanReport = .empty
    @Published public private(set) var hotspots: FileHotspots = .empty
    @Published public private(set) var feedback: CorrelationFeedbackReport = .empty
    @Published public private(set) var historyLoaded = false
    @Published public private(set) var historyLoading = false
    /// Why history is unavailable — most often "not a git repository".
    @Published public private(set) var historyError: String?

    // MARK: Time travel
    //
    // Time travel is an overlay rather than a mode switch: the workspace's own
    // analysis stays on the current bead set, and the chosen revision supplies
    // a comparison. Swapping the loaded set wholesale would leave every metric
    // describing a graph that is no longer on screen.
    @Published public private(set) var revisions: RevisionList = .empty
    @Published public private(set) var timeTravel: TimeTravelDiff = .empty
    /// The historical bead set, for showing a bead as it was.
    @Published public private(set) var pastIssues: [String: Issue] = [:]
    @Published public private(set) var timeTravelLoading = false

    // MARK: Sprints
    @Published public private(set) var sprints: SprintList = .empty
    @Published public private(set) var burndown: Burndown = .empty
    @Published public private(set) var capacity: Capacity = .empty
    @Published public private(set) var sprintError: String?
    /// Which sprint the dashboard is showing. Empty means the active one.
    @Published public var selectedSprintID: String = ""
    @Published public var capacityAgents: Int = 1

    // MARK: Recipes
    @Published public private(set) var recipes: RecipeList = .empty
    /// The recipe currently applied, if any.
    @Published public private(set) var activeRecipe: Recipe?
    /// The ids that recipe selected, in its order. Nil when none is applied.
    @Published public private(set) var recipeIDs: [String]?
    @Published public private(set) var recipeTruncated = false

    // MARK: Alerts
    @Published public private(set) var alerts: AlertReport = .empty
    @Published public private(set) var baseline: BaselineInfo = .empty
    @Published public var alertSeverityFilter: AlertSeverity?
    @Published public var alertTypeFilter: String?
    @Published public var alertLabelFilter: String?
    /// Deliver critical alerts as notifications while watching.
    @Published public var notifyOnCriticalAlerts = false

    private let engine = BeadsEngine()
    private let watcher = FileWatchService()
    private let notifier = AlertNotifier()
    private var triageNeedsRefresh = false
    /// Unblocks lists already reported by the plan and triage, so the inspector
    /// can show the count immediately instead of flashing 0 while an async
    /// round-trip resolves.
    private var unblocksCache: [String: [String]] = [:]

    public init() {}

    public var isLoaded: Bool { info != nil }

    /// Issues after the active recipe or filter, search and sort.
    ///
    /// A recipe replaces the filter and the sort — that is what applying one
    /// means — but the search box still narrows, because searching within a
    /// recipe's results is the obvious thing to want and losing the recipe on
    /// the first keystroke is not.
    public var visibleIssues: [Issue] {
        guard let recipeIDs else {
            return query.apply(to: issues, actionable: actionable, metrics: metrics)
        }
        let byID = issuesByID
        let selected = recipeIDs.compactMap { byID[$0] }
        guard !query.searchText.isEmpty else { return selected }
        return IssueQuery.rank(selected, query: query.searchText)
    }

    public var selectedIssue: Issue? {
        guard let selection else { return nil }
        return issues.first { $0.id == selection }
    }

    public var issuesByID: [String: Issue] {
        Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
    }

    /// Bead titles keyed by id, for linkifying ids mentioned in prose.
    ///
    /// Deliberately tolerant of a duplicate id — a multi-repository workspace
    /// can carry one — because a tooltip is not worth trapping over.
    public var beadTitles: [String: String] {
        Dictionary(issues.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Selects `id` if the workspace holds it. Returns whether it did.
    ///
    /// The guard is what keeps a stale reference — in prose, or in a URL from
    /// outside the app — from clearing the current selection.
    @discardableResult
    public func select(id: String) -> Bool {
        guard issues.contains(where: { $0.id == id }) else { return false }
        selection = id
        return true
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
            startWatching()
            if !skipPhase2 { await computePhase2() }
        } catch {
            stopWatching()
            self.loadError = error.localizedDescription
            self.info = nil
            self.issues = []
            self.metrics = .empty
            self.actionable = []
            self.plan = .empty
            self.edges = []
        }
    }

    /// Re-reads the source. When the engine reports the data hash unchanged,
    /// nothing is republished — this is what makes watching cheap enough to
    /// leave on.
    @discardableResult
    public func reload(force: Bool = false) async -> Bool {
        guard isLoaded else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await engine.reload()
            info = fresh
            guard fresh.changed || force else { return false }

            try await refreshAll()
            if !skipPhase2 { await computePhase2() }
            // Every correlation attribution was computed against the old bead
            // set, so the report is stale. It is marked unloaded rather than
            // re-walked here: the walk is expensive and only matters if the
            // History view is actually open.
            historyLoaded = false
            lastReloadAt = Date()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    // MARK: - Watching

    /// Starts live reload for the currently open workspace.
    public func startWatching() {
        guard let source = info?.source, !isWatching else { return }
        watcher.start(watching: source) { [weak self] in
            Task { @MainActor in
                await self?.reload()
            }
        }
        isWatching = watcher.isWatching
    }

    public func stopWatching() {
        watcher.stop()
        isWatching = false
    }

    private func refreshAll() async throws {
        issues = try await engine.issues()
        metrics = try await engine.metrics()
        actionable = try await engine.actionableIDs()
        plan = try await engine.executionPlan()
        edges = try await engine.graphEdges()
        // Label analytics are advisory, so a failure here must not block the
        // load — a workspace with no labels at all is perfectly valid.
        labelAnalysis = (try? await engine.labelHealth()) ?? .empty
        labelFlow = (try? await engine.labelFlow()) ?? .empty
        labelAttention = (try? await engine.labelAttention()) ?? .empty
        // Alerts are cheap once the analysis exists, and they are the one
        // thing a user wants to see without asking.
        await refreshAlerts()
        // Triage depends on Phase-2 scores; it is refreshed again once they land.
        triage = (try? await engine.triage()) ?? .empty
        rebuildUnblocksCache()
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
            triageNeedsRefresh = true
            metrics =
                metrics.phase2Ready
                ? try await engine.computeFullMetrics()
                : try await engine.waitForPhase2()
            actionable = try await engine.actionableIDs()
            // Recommendations are scored from PageRank and betweenness, so
            // they are only meaningful once Phase 2 has landed.
            if triageNeedsRefresh {
                triage = (try? await engine.triage()) ?? triage
                triageNeedsRefresh = false
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func close() async {
        stopWatching()
        await engine.close()
    }

    // MARK: - Sprints

    /// Loads the sprint list, the selected sprint's burndown and the capacity
    /// simulation.
    public func loadSprints() async {
        guard isLoaded else { return }
        sprintError = nil

        sprints = (try? await engine.sprints()) ?? .empty
        // No sprint file at all is a normal state for a workspace, not an
        // error, so it is reported by the empty list rather than a message.
        guard !sprints.sprints.isEmpty else {
            burndown = .empty
            await loadCapacity()
            return
        }

        do {
            let target = selectedSprintID.isEmpty ? "current" : selectedSprintID
            burndown = try await engine.burndown(sprintID: target)
        } catch {
            // The commonest case by far: sprints exist but none spans today.
            burndown = .empty
            sprintError = error.localizedDescription
        }
        await loadCapacity()
    }

    /// Re-runs the capacity simulation at the current agent count.
    public func loadCapacity() async {
        guard isLoaded else { return }
        capacity = (try? await engine.capacity(agents: capacityAgents)) ?? .empty
    }

    // MARK: - Recipes

    public func loadRecipes() async {
        guard isLoaded else { return }
        recipes = (try? await engine.recipes()) ?? .empty
    }

    /// Applies a recipe: filter, sort and view, together.
    ///
    /// The selection and its order come from the engine, so a recipe means the
    /// same thing here as it does to `bv --recipe`.
    public func applyRecipe(named name: String) async {
        guard isLoaded else { return }
        do {
            let applied = try await engine.applyRecipe(named: name)
            activeRecipe = applied.recipe
            recipeIDs = applied.issueIDs
            recipeTruncated = applied.truncated
            // A recipe that asks for the graph gets it; the rest leave the
            // current surface alone rather than yanking the user elsewhere.
            if applied.recipe.view.impliedSurface == "graph" { surface = .graph }
            if selection == nil || !applied.issueIDs.contains(selection ?? "") {
                selection = applied.issueIDs.first
            }
        } catch {
            loadError = error.localizedDescription
            clearRecipe()
        }
    }

    /// Returns to the ordinary filter and sort.
    public func clearRecipe() {
        activeRecipe = nil
        recipeIDs = nil
        recipeTruncated = false
    }

    public func saveRecipe(_ recipe: Recipe) async {
        do {
            try await engine.saveRecipe(recipe)
            await loadRecipes()
            // Re-apply so the edit is visible immediately rather than after
            // the next click.
            if activeRecipe?.name == recipe.name {
                await applyRecipe(named: recipe.name)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func deleteRecipe(named name: String) async {
        do {
            try await engine.deleteRecipe(named: name)
            if activeRecipe?.name == name { clearRecipe() }
            await loadRecipes()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Alerts

    /// Re-runs the drift check with the current filters.
    public func refreshAlerts() async {
        guard isLoaded else { return }
        let previous = Set(alerts.alerts.filter { $0.severity == .critical }.map(\.id))

        alerts =
            (try? await engine.alerts(
                severity: alertSeverityFilter,
                type: alertTypeFilter,
                label: alertLabelFilter)) ?? .empty
        baseline = (try? await engine.baselineInfo()) ?? .empty

        // Only alerts that were not there a moment ago are announced. Without
        // this every reload would re-notify about the same standing problem,
        // and the notifications would quickly be ignored.
        let fresh = alerts.alerts.filter { $0.severity == .critical && !previous.contains($0.id) }
        if notifyOnCriticalAlerts, !fresh.isEmpty {
            await notifier.deliver(fresh)
        }
    }

    /// Records the current graph as the point drift is measured from.
    public func saveBaseline(description: String) async {
        guard isLoaded else { return }
        do {
            baseline = try await engine.saveBaseline(description: description)
            // A new baseline changes every delta, so the alerts are recomputed
            // rather than left describing the previous one.
            await refreshAlerts()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Time travel

    /// True when a revision is selected and the list is showing diff badges.
    public var isTimeTravelling: Bool { !timeTravel.resolvedRevision.isEmpty }

    /// Loads the revisions the scrubber can jump to.
    public func loadRevisions() async {
        guard isLoaded, revisions.revisions.isEmpty else { return }
        revisions = (try? await engine.revisions()) ?? .empty
    }

    /// Compares the current bead set against `revision`.
    ///
    /// Any expression git accepts works; what gets displayed afterwards is the
    /// *resolved* commit, because `HEAD~3` names a different commit tomorrow.
    public func travel(to revision: String) async {
        guard isLoaded, !timeTravelLoading else { return }
        timeTravelLoading = true
        defer { timeTravelLoading = false }

        do {
            timeTravel = try await engine.diff(since: revision)
            let snapshot = try await engine.snapshot(at: revision)
            pastIssues = Dictionary(
                snapshot.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            historyError = error.localizedDescription
            returnToNow()
        }
    }

    /// Leaves time travel.
    public func returnToNow() {
        timeTravel = .empty
        pastIssues = [:]
    }

    /// The badge a bead earned between the chosen revision and now.
    public func badge(for id: Issue.ID) -> DiffBadge? {
        timeTravel.badges[id]
    }

    /// The bead as it was at the chosen revision, if it existed then.
    public func pastIssue(_ id: Issue.ID) -> Issue? {
        pastIssues[id]
    }

    // MARK: - Correlation

    /// Loads the git correlation report, once.
    ///
    /// Idempotent, so a view can call it from `.task` on every appearance
    /// without paying for a second walk. Pass `refresh` to force one.
    public func loadHistory(refresh: Bool = false) async {
        guard isLoaded, !historyLoading else { return }
        guard refresh || !historyLoaded else { return }

        historyLoading = true
        historyError = nil
        defer { historyLoading = false }

        do {
            history = try await engine.history(refresh: refresh)
            // These read the same cached report, so they are cheap once the
            // walk is done.
            orphans = (try? await engine.orphanCommits()) ?? .empty
            hotspots = (try? await engine.fileHotspots()) ?? .empty
            feedback = (try? await engine.correlationFeedback()) ?? .empty
            historyLoaded = true
        } catch {
            // A workspace outside a git repository is a normal state, not a
            // failure of the app — the History view says so rather than the
            // whole window showing an error.
            historyError = error.localizedDescription
            historyLoaded = false
            history = .empty
            orphans = .empty
            hotspots = .empty
        }
    }

    /// The commits linked to one bead, newest first.
    public func commits(for id: Issue.ID) -> [CorrelatedCommit] {
        history.histories[id]?.commits ?? []
    }

    /// One bead's causal chain, fetched on demand.
    public func causality(for id: Issue.ID) async -> CausalityResult? {
        try? await engine.causality(id)
    }

    public func relatedWork(for id: Issue.ID) async -> RelatedWork? {
        try? await engine.relatedWork(id)
    }

    public func beads(touching path: String) async -> FileBeadLookup? {
        try? await engine.beads(touching: path)
    }

    public func fileRelations(for path: String) async -> CoChangeResult? {
        try? await engine.fileRelations(path)
    }

    public func patch(sha: String, path: String? = nil) async -> CommitPatch? {
        try? await engine.commitPatch(sha: sha, path: path)
    }

    /// Records a verdict on one commit-to-bead link and republishes the report.
    ///
    /// The report is re-read rather than patched locally: rejecting a link
    /// also rebuilds the commit index and the orphan list, and reproducing
    /// that here would be a second implementation of the same rule.
    public func recordCorrelation(
        sha: String, beadID: String, confirmed: Bool, reason: String = ""
    ) async {
        do {
            if confirmed {
                try await engine.confirmCorrelation(sha: sha, beadID: beadID, reason: reason)
            } else {
                try await engine.rejectCorrelation(sha: sha, beadID: beadID, reason: reason)
            }
            history = try await engine.history()
            orphans = (try? await engine.orphanCommits()) ?? orphans
            feedback = (try? await engine.correlationFeedback()) ?? feedback
        } catch {
            historyError = error.localizedDescription
        }
    }

    // MARK: - Export

    /// Renders the Markdown report and asks the user where to save it.
    ///
    /// The engine returns the content and this writes it, rather than letting
    /// the engine write directly, so the save panel's grant is what authorises
    /// the write — which is what keeps it working under the App Sandbox.
    public func exportMarkdown() async {
        guard let info else { return }
        do {
            let report = try await engine.exportMarkdown(title: "\(info.displayName) — Bead Report")

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(info.displayName)-beads.md"
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.message = "Save the Markdown report"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
            lastExportPath = url.path
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Derived data

    /// Ids that closing `id` would make actionable.
    ///
    /// Answers from the cache when the plan or triage already reported it,
    /// falling back to the engine for beads neither covers.
    public func unblocks(_ id: String) async -> [String] {
        if let cached = unblocksCache[id] { return cached }
        let fetched = (try? await engine.unblocks(id)) ?? []
        unblocksCache[id] = fetched
        return fetched
    }

    /// Synchronous lookup for views that must render without awaiting.
    /// Returns nil when the value is not yet known, which the UI shows as
    /// "—" rather than as a misleading zero.
    public func knownUnblocks(_ id: String) -> [String]? { unblocksCache[id] }

    private func rebuildUnblocksCache() {
        var cache: [String: [String]] = [:]
        for track in plan.tracks {
            for item in track.items { cache[item.id] = item.unblocks }
        }
        for rec in triage.recommendations where cache[rec.id] == nil {
            cache[rec.id] = rec.unblocksIDs
        }
        for win in triage.quickWins where cache[win.id] == nil {
            cache[win.id] = win.unblocksIDs
        }
        for blocker in triage.blockersToClear where cache[blocker.id] == nil {
            cache[blocker.id] = blocker.unblocksIDs
        }
        unblocksCache = cache
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
