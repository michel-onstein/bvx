import AppKit
import UniformTypeIdentifiers
import VBXCore
import VBXEngine
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

    @Published public var surface: ViewSurface = .list {
        didSet {
            guard surface != oldValue else { return }
            recordNavigation()
        }
    }
    @Published public var query = IssueQuery()

    // MARK: Navigation history
    //
    // Where the user has been, so back and forward can return. See
    // ``NavigationEntry`` for what counts as a position and why plain row
    // selection does not push one.

    /// Visited positions, oldest first, capped at ``navigationHistoryLimit``.
    @Published public internal(set) var navigationHistory: [NavigationEntry] = []

    /// Index into ``navigationHistory`` of where the user is now.
    ///
    /// A cursor rather than a stack pointer: going back moves it down and
    /// leaves the entries above intact, which is the only reason forward has
    /// anywhere to go.
    @Published public internal(set) var navigationCursor: Int = -1

    /// True while an entry is being restored.
    ///
    /// Restoring writes `surface` and `selection`, which are the very things
    /// that record history — without this, going back would record the arrival
    /// as a fresh navigation and forward would be truncated away instantly.
    var isRestoringNavigation = false

    /// True while ``select(id:)`` is deliberately jumping to a bead.
    ///
    /// Suppresses the in-place refresh so the entry being left keeps the bead
    /// it was recorded with, rather than being overwritten by the destination.
    var isJumpingToBead = false

    /// Every selected bead. Bound directly to the list's `Table`.
    ///
    /// A set rather than a single id, because the table supports shift- and
    /// command-click. Most of the app still means *one* bead, and reaches for
    /// ``focusedID`` or ``select(id:)`` instead.
    @Published public var selection: Set<Issue.ID> = [] {
        didSet { updateFocus(from: oldValue) }
    }

    /// The one bead the inspector shows and `j`/`k` move between.
    ///
    /// Distinct from the selection because a `Set` has no order: with three
    /// beads selected, "the first" is whichever the hash happens to yield, and
    /// the inspector would appear to jump around. This follows the bead most
    /// recently added instead, which is the one just clicked.
    @Published public private(set) var focusedID: Issue.ID?
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

    // MARK: Static site export
    @Published public private(set) var siteBundle: SiteBundle = .empty
    @Published public private(set) var sitePreview: SitePreview = .empty
    @Published public private(set) var siteDeployment: SiteDeployment = .empty
    @Published public private(set) var siteBusy = false
    @Published public private(set) var siteError: String?

    // MARK: Repositories
    @Published public private(set) var repos: RepoList = .empty
    /// Repositories the list is narrowed to. Empty means all of them.
    @Published public var repoFilter: Set<String> = []

    // MARK: Search
    //
    // The scope bar's mode. `.text` is the default because it is what the
    // fuzzy search in `IssueQuery` already approximates; hybrid is a
    // deliberate choice, because it reorders by things other than the words
    // you typed.
    @Published public var searchMode: SearchMode = .text
    @Published public var searchPreset: String = "default"
    @Published public var searchWeights: SearchWeights?
    @Published public private(set) var searchPresets: SearchPresetList = .empty
    @Published public private(set) var searchResults: SearchResults = .empty
    @Published public private(set) var searchInFlight = false

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
    private let spotlight = SpotlightIndexer()
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
        narrowToRepos(unfilteredVisibleIssues)
    }

    private var unfilteredVisibleIssues: [Issue] {
        // Hybrid search replaces the ordering entirely: its whole point is to
        // rank by things other than the words typed, so re-sorting afterwards
        // would discard the ranking that was asked for.
        if isUsingEngineSearch {
            let byID = issuesByID
            return searchResults.rankedIDs.compactMap { byID[$0] }
        }
        guard let recipeIDs else {
            return query.apply(to: issues, actionable: actionable, metrics: metrics)
        }
        let byID = issuesByID
        let selected = recipeIDs.compactMap { byID[$0] }
        guard !query.searchText.isEmpty else { return selected }
        return IssueQuery.rank(selected, query: query.searchText)
    }

    /// Narrows to the selected repositories, if any are selected.
    ///
    /// Applied last, on top of whatever chose the set — so a recipe, a search
    /// and a repository selection compose instead of overriding each other.
    private func narrowToRepos(_ candidates: [Issue]) -> [Issue] {
        guard !repoFilter.isEmpty, repos.isWorkspace else { return candidates }
        return candidates.filter { issue in
            guard let repo = repos.repo(owning: issue.id) else { return false }
            return repoFilter.contains(repo.name)
        }
    }

    /// The repository a bead belongs to, in a multi-repository workspace.
    public func repo(of id: Issue.ID) -> RepoInfo? {
        repos.repo(owning: id)
    }

    /// True when this bead sits on a dependency that crosses repositories.
    public func isCrossRepo(_ id: Issue.ID) -> Bool {
        repos.crossRepoIDs.contains(id)
    }

    /// Toggles one repository in the filter.
    public func toggleRepo(_ name: String) {
        if repoFilter.contains(name) {
            repoFilter.remove(name)
        } else {
            repoFilter.insert(name)
        }
    }

    /// The bead the inspector shows: the focused one, not "the first
    /// selected", which a `Set` cannot meaningfully offer.
    public var selectedIssue: Issue? {
        guard let focusedID else { return nil }
        return issues.first { $0.id == focusedID }
    }

    /// Every selected bead, in on-screen order.
    public var selectedIssues: [Issue] {
        let byID = issuesByID
        return orderedSelection().compactMap { byID[$0] }
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

    // MARK: - Automation entry points

    /// Handles a `vbx://` URL, opening a workspace and selecting a bead.
    ///
    /// Returns whether anything was acted on, so a caller can fall back to the
    /// system for a URL that was not ours.
    @discardableResult
    public func open(url: URL) async -> Bool {
        guard let workspace = BeadURL.workspace(in: url) ?? BeadURL.bead(in: url).map({ _ in "" })
        else { return false }

        // A workspace switch has to finish before the bead can be selected —
        // the bead may not exist until it does.
        if !workspace.isEmpty, workspace != info?.source {
            await open(path: workspace)
        }
        if let bead = BeadURL.bead(in: url) {
            return select(id: bead)
        }
        return !workspace.isEmpty
    }

    /// Handles a Spotlight activation.
    @discardableResult
    public func openSpotlightItem(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = SpotlightIndexer.beadID(from: userInfo) else { return false }
        return select(id: id)
    }

    /// Publishes the loaded beads to Spotlight.
    public func updateSpotlightIndex() async {
        guard let info else { return }
        await spotlight.index(issues, workspace: info.source)
    }

    /// Selects `id` alone, if the workspace holds it. Returns whether it did.
    ///
    /// *Replaces* the selection rather than extending it. Every caller — an
    /// inline bead link, a `vbx://` URL, a Spotlight hit, a drilldown from the
    /// flow matrix, alerts or the sprint critical path — means "show me this
    /// one", and adding to a selection the user built by hand would be a
    /// surprising way to answer that.
    ///
    /// The membership guard is what keeps a stale reference — in prose, or in
    /// a URL from outside the app — from clearing the current selection.
    @discardableResult
    public func select(id: String) -> Bool {
        guard issues.contains(where: { $0.id == id }) else { return false }
        // Jumping, not browsing: the position being left keeps the bead it was
        // recorded with, and the arrival is pushed as a position of its own so
        // back returns to where the jump started.
        isJumpingToBead = true
        selection = [id]
        isJumpingToBead = false
        recordNavigation()
        return true
    }

    /// True when `id` is part of the selection.
    public func isSelected(_ id: Issue.ID) -> Bool { selection.contains(id) }

    /// The ids as a single line, in on-screen order, joined with `", "`.
    ///
    /// Pure, so the joining and the ordering can be tested without a
    /// pasteboard.
    public func idList(for ids: Set<Issue.ID>) -> String {
        orderedSelection(ids).joined(separator: ", ")
    }

    /// Puts the ids on the general pasteboard.
    ///
    /// Returns what was written, or nil when there was nothing to write —
    /// copying an empty string would silently replace whatever the user had
    /// on the clipboard with nothing.
    @discardableResult
    public func copyIDs(_ ids: Set<Issue.ID>) -> String? {
        let text = idList(for: ids)
        guard !text.isEmpty else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// Keeps ``focusedID`` pointing at something sensible as the set changes.
    private func updateFocus(from previous: Set<Issue.ID>) {
        if let added = selection.subtracting(previous).first {
            // Newly added wins: it is the row the user just clicked.
            focusedID = added
        } else if let current = focusedID, !selection.contains(current) {
            // The focused bead was deselected. Anything still selected will
            // do; nothing selected means nothing focused.
            focusedID = selection.first
        } else if selection.isEmpty {
            focusedID = nil
        }
        noteFocusChanged()
    }

    /// The selected ids in the order they appear on screen.
    ///
    /// A `Set` is unordered, so anything user-visible built from the selection
    /// — a copied list of ids, a count read aloud — has to impose an order or
    /// it changes between identical actions.
    public func orderedSelection(_ ids: Set<Issue.ID>? = nil) -> [Issue.ID] {
        let wanted = ids ?? selection
        guard !wanted.isEmpty else { return [] }
        var ordered = visibleIssues.map(\.id).filter { wanted.contains($0) }
        // Anything selected but not currently visible — the filter changed
        // under it — still belongs in the list, sorted so the result is
        // reproducible.
        let missing = wanted.subtracting(ordered).sorted()
        ordered.append(contentsOf: missing)
        return ordered
    }

    // MARK: - Loading

    /// Opens the workspace named by the first CLI argument, the VBX_WORKSPACE
    /// environment variable, or the current directory — in that order.
    public func openInitialWorkspace() async {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            await open(path: path)
        } else if let env = ProcessInfo.processInfo.environment["VBX_WORKSPACE"] {
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
        // Held for the panel's lifetime: `delegate` is unowned, and the guard
        // is also the probe cache, so it must not be collected mid-browse.
        let guardDelegate = OpenPanelGuard()
        panel.delegate = guardDelegate
        defer { panel.delegate = nil }
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
            // Positions name beads, and the previous workspace's beads do not
            // exist in this one.
            resetNavigationHistory()
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
        repos = (try? await engine.repos()) ?? .empty
        // Spotlight is refreshed on every load so a deleted bead stops being
        // findable; the indexer replaces rather than merges for that reason.
        await updateSpotlightIndex()
        // Alerts are cheap once the analysis exists, and they are the one
        // thing a user wants to see without asking.
        await refreshAlerts()
        // Triage depends on Phase-2 scores; it is refreshed again once they land.
        triage = (try? await engine.triage()) ?? .empty
        rebuildUnblocksCache()
        // Drop ids the reload removed, and fall back to the first row when
        // that empties the selection — an empty inspector after a reload reads
        // as a broken app rather than as a changed bead set.
        let surviving = selection.filter { id in issues.contains { $0.id == id } }
        if surviving.isEmpty {
            selection = visibleIssues.first.map { [$0.id] } ?? []
        } else if surviving != selection {
            selection = surviving
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

    // MARK: - Search

    public func loadSearchPresets() async {
        guard isLoaded, searchPresets.presets.isEmpty else { return }
        searchPresets = (try? await engine.searchPresets()) ?? .empty
    }

    /// Runs the engine-backed search for the current query text.
    ///
    /// Only used in hybrid mode. The plain path stays on `IssueQuery`'s fuzzy
    /// ranking, which is synchronous and needs no index — searching should not
    /// wait on a round trip while someone is still typing.
    public func runEngineSearch() async {
        let text = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, searchMode == .hybrid, !text.isEmpty else {
            searchResults = .empty
            return
        }
        guard !searchInFlight else { return }

        searchInFlight = true
        defer { searchInFlight = false }
        searchResults =
            (try? await engine.search(
                text, mode: searchMode, limit: 50,
                preset: searchWeights == nil ? searchPreset : nil,
                weights: searchWeights)) ?? .empty
    }

    /// True when the list should show engine-ranked results.
    public var isUsingEngineSearch: Bool {
        searchMode == .hybrid && !query.searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && !searchResults.isEmpty
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
            // A recipe changes what is on screen, so a selection pointing
            // outside its results would leave the inspector showing a bead the
            // list no longer contains.
            let surviving = selection.intersection(applied.issueIDs)
            if surviving.isEmpty {
                selection = applied.issueIDs.first.map { [$0] } ?? []
            } else {
                selection = surviving
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

    // MARK: - Static site export

    /// Asks where to put the bundle, then builds it.
    ///
    /// The directory comes from an open panel because that grant is what
    /// authorises writing outside the app's container.
    public func chooseBundleDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for the static site bundle."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    public func buildSite(
        into directory: URL, title: String,
        interactiveGraph: Bool, githubWorkflow: Bool
    ) async {
        guard isLoaded, !siteBusy else { return }
        siteBusy = true
        siteError = nil
        defer { siteBusy = false }

        do {
            siteBundle = try await engine.exportSite(
                outputDir: directory.path, title: title,
                interactiveGraph: interactiveGraph, githubWorkflow: githubWorkflow)
            // A new bundle invalidates any previous deployment result.
            siteDeployment = .empty
        } catch {
            siteError = error.localizedDescription
            siteBundle = .empty
        }
    }

    /// Starts the local preview server for the built bundle.
    public func previewSite() async {
        guard siteBundle.isBuilt, !siteBusy else { return }
        siteBusy = true
        defer { siteBusy = false }
        do {
            sitePreview = try await engine.previewSite(bundlePath: siteBundle.outputDir)
        } catch {
            siteError = error.localizedDescription
            sitePreview = .empty
        }
    }

    /// Publishes the bundle to GitHub Pages using the stored token.
    public func deploySite(repo: String, isPrivate: Bool) async {
        guard siteBundle.isBuilt, !siteBusy else { return }
        guard let token = Keychain.read(.githubToken) else {
            siteError = "No GitHub token is stored. Add one in Settings first."
            return
        }

        siteBusy = true
        siteError = nil
        defer { siteBusy = false }

        do {
            siteDeployment = try await engine.deployToGitHub(
                bundlePath: siteBundle.outputDir, repo: repo,
                token: token, isPrivate: isPrivate)
        } catch {
            siteError = error.localizedDescription
            siteDeployment = .empty
        }
    }

    /// What to run for a Cloudflare deployment, which needs `wrangler`.
    public func cloudflareInstructions(project: String) async -> DeployInstructions {
        guard siteBundle.isBuilt else { return .empty }
        return (try? await engine.cloudflareInstructions(
            bundlePath: siteBundle.outputDir, project: project)) ?? .empty
    }

    /// Clears the wizard's state so a second run starts fresh.
    public func resetSiteExport() {
        siteBundle = .empty
        sitePreview = .empty
        siteDeployment = .empty
        siteError = nil
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
