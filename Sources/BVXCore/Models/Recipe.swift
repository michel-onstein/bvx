import Foundation

/// Which beads a recipe selects.
public struct RecipeFilters: Codable, Sendable, Hashable {
    public var status: [String]
    public var priority: [Int]
    /// All of these must be present — bv's rule, unlike the sidebar's
    /// label filter, which takes any.
    public var tags: [String]
    public var excludeTags: [String]
    public var createdAfter: String
    public var createdBefore: String
    public var updatedAfter: String
    public var updatedBefore: String
    public var hasBlockers: Bool?
    public var actionable: Bool?
    public var titleContains: String
    public var idPrefix: String

    private enum CodingKeys: String, CodingKey {
        case status, priority, tags, actionable
        case excludeTags = "exclude_tags"
        case createdAfter = "created_after"
        case createdBefore = "created_before"
        case updatedAfter = "updated_after"
        case updatedBefore = "updated_before"
        case hasBlockers = "has_blockers"
        case titleContains = "title_contains"
        case idPrefix = "id_prefix"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent([String].self, forKey: .status) ?? []
        priority = try c.decodeIfPresent([Int].self, forKey: .priority) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        excludeTags = try c.decodeIfPresent([String].self, forKey: .excludeTags) ?? []
        createdAfter = try c.decodeIfPresent(String.self, forKey: .createdAfter) ?? ""
        createdBefore = try c.decodeIfPresent(String.self, forKey: .createdBefore) ?? ""
        updatedAfter = try c.decodeIfPresent(String.self, forKey: .updatedAfter) ?? ""
        updatedBefore = try c.decodeIfPresent(String.self, forKey: .updatedBefore) ?? ""
        hasBlockers = try c.decodeIfPresent(Bool.self, forKey: .hasBlockers)
        actionable = try c.decodeIfPresent(Bool.self, forKey: .actionable)
        titleContains = try c.decodeIfPresent(String.self, forKey: .titleContains) ?? ""
        idPrefix = try c.decodeIfPresent(String.self, forKey: .idPrefix) ?? ""
    }

    public init() {
        status = []
        priority = []
        tags = []
        excludeTags = []
        createdAfter = ""
        createdBefore = ""
        updatedAfter = ""
        updatedBefore = ""
        titleContains = ""
        idPrefix = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Empty values are omitted so a saved recipe reads as what the user
        // set, not as every field they left alone.
        if !status.isEmpty { try c.encode(status, forKey: .status) }
        if !priority.isEmpty { try c.encode(priority, forKey: .priority) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        if !excludeTags.isEmpty { try c.encode(excludeTags, forKey: .excludeTags) }
        if !createdAfter.isEmpty { try c.encode(createdAfter, forKey: .createdAfter) }
        if !createdBefore.isEmpty { try c.encode(createdBefore, forKey: .createdBefore) }
        if !updatedAfter.isEmpty { try c.encode(updatedAfter, forKey: .updatedAfter) }
        if !updatedBefore.isEmpty { try c.encode(updatedBefore, forKey: .updatedBefore) }
        if let hasBlockers { try c.encode(hasBlockers, forKey: .hasBlockers) }
        if let actionable { try c.encode(actionable, forKey: .actionable) }
        if !titleContains.isEmpty { try c.encode(titleContains, forKey: .titleContains) }
        if !idPrefix.isEmpty { try c.encode(idPrefix, forKey: .idPrefix) }
    }

    /// A one-line description of what this recipe selects, for the sidebar.
    public var summary: String {
        var parts: [String] = []
        if !status.isEmpty { parts.append(status.joined(separator: "/")) }
        if let actionable { parts.append(actionable ? "actionable" : "blocked") }
        if let hasBlockers, actionable == nil {
            parts.append(hasBlockers ? "blocked" : "unblocked")
        }
        if !tags.isEmpty { parts.append("+" + tags.joined(separator: " +")) }
        if !excludeTags.isEmpty { parts.append("−" + excludeTags.joined(separator: " −")) }
        if !priority.isEmpty { parts.append("P" + priority.map(String.init).joined(separator: "/")) }
        if !updatedAfter.isEmpty { parts.append("updated <\(updatedAfter)") }
        if !createdAfter.isEmpty { parts.append("created <\(createdAfter)") }
        return parts.isEmpty ? "everything" : parts.joined(separator: ", ")
    }
}

/// One key in a recipe's sort order.
public struct RecipeSortKey: Sendable, Hashable, Identifiable {
    public var field: String
    public var direction: String

    public var id: String { "\(field)-\(direction)" }

    public init(field: String, direction: String = "") {
        self.field = field
        self.direction = direction
    }

    public var isDescending: Bool { direction.lowercased() == "desc" }

    public var summary: String {
        isDescending ? "\(field) ↓" : "\(field) ↑"
    }
}

/// A recipe's sort order.
///
/// bv models this as a linked list — each `SortConfig` may carry a `secondary`
/// pointing at the next — which a Swift struct cannot hold directly. Flattening
/// the chain to an ordered list keeps every key rather than dropping the tail,
/// and reads better in an editor besides. Encoding rebuilds the nesting.
public struct RecipeSort: Codable, Sendable, Hashable {
    public var keys: [RecipeSortKey]

    private enum CodingKeys: String, CodingKey { case field, direction, secondary }

    public init(from decoder: Decoder) throws {
        var collected: [RecipeSortKey] = []
        var container: KeyedDecodingContainer<CodingKeys>? = try? decoder.container(
            keyedBy: CodingKeys.self)

        // Walk the chain. A key with no field ends it — an empty link carries
        // no ordering, and following past it would invent one.
        while let current = container {
            let field = (try? current.decodeIfPresent(String.self, forKey: .field)) ?? nil
            guard let field, !field.isEmpty else { break }
            let direction =
                ((try? current.decodeIfPresent(String.self, forKey: .direction)) ?? nil) ?? ""
            collected.append(RecipeSortKey(field: field, direction: direction))
            container = try? current.nestedContainer(
                keyedBy: CodingKeys.self, forKey: .secondary)
        }
        keys = collected
    }

    public init(keys: [RecipeSortKey] = []) {
        self.keys = keys
    }

    public init(field: String, direction: String = "") {
        self.keys = field.isEmpty ? [] : [RecipeSortKey(field: field, direction: direction)]
    }

    public func encode(to encoder: Encoder) throws {
        guard let first = keys.first else {
            // No keys means no sort block at all, rather than an empty one
            // that bv would read as a field named "".
            var c = encoder.singleValueContainer()
            try c.encodeNil()
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(first.field, forKey: .field)
        if !first.direction.isEmpty { try c.encode(first.direction, forKey: .direction) }
        if keys.count > 1 {
            try c.encode(RecipeSort(keys: Array(keys.dropFirst())), forKey: .secondary)
        }
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// The primary field, for the editor's single-key control.
    public var field: String { keys.first?.field ?? "" }
    public var direction: String { keys.first?.direction ?? "" }

    public var summary: String {
        keys.map(\.summary).joined(separator: ", ")
    }

    /// Sort fields a recipe may name.
    public static let fields = [
        "priority", "created", "updated", "title", "id", "pagerank", "betweenness",
    ]
}

public struct RecipeView: Codable, Sendable, Hashable {
    public var columns: [String]
    public var showGraph: Bool
    public var showMetrics: Bool
    public var groupBy: String
    public var collapsed: Bool
    public var maxItems: Int
    public var truncateTitle: Int

    private enum CodingKeys: String, CodingKey {
        case columns, collapsed
        case showGraph = "show_graph"
        case showMetrics = "show_metrics"
        case groupBy = "group_by"
        case maxItems = "max_items"
        case truncateTitle = "truncate_title"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        showGraph = try c.decodeIfPresent(Bool.self, forKey: .showGraph) ?? false
        showMetrics = try c.decodeIfPresent(Bool.self, forKey: .showMetrics) ?? false
        groupBy = try c.decodeIfPresent(String.self, forKey: .groupBy) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? 0
        truncateTitle = try c.decodeIfPresent(Int.self, forKey: .truncateTitle) ?? 0
    }

    public init() {
        columns = []
        showGraph = false
        showMetrics = false
        groupBy = ""
        collapsed = false
        maxItems = 0
        truncateTitle = 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !columns.isEmpty { try c.encode(columns, forKey: .columns) }
        if showGraph { try c.encode(showGraph, forKey: .showGraph) }
        if showMetrics { try c.encode(showMetrics, forKey: .showMetrics) }
        if !groupBy.isEmpty { try c.encode(groupBy, forKey: .groupBy) }
        if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        if maxItems > 0 { try c.encode(maxItems, forKey: .maxItems) }
        if truncateTitle > 0 { try c.encode(truncateTitle, forKey: .truncateTitle) }
    }

    /// The surface this recipe implies, if it asks for one.
    ///
    /// `show_graph` is bv's way of saying "this view is about the graph"; the
    /// rest keep whatever surface is open.
    public var impliedSurface: String? {
        showGraph ? "graph" : nil
    }
}

/// A reusable view configuration: filter, sort and presentation together.
public struct Recipe: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var filters: RecipeFilters
    public var sort: RecipeSort
    public var view: RecipeView
    public var metrics: [String]

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, description, filters, sort, view, metrics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        filters = try c.decodeIfPresent(RecipeFilters.self, forKey: .filters) ?? RecipeFilters()
        sort = try c.decodeIfPresent(RecipeSort.self, forKey: .sort) ?? RecipeSort()
        view = try c.decodeIfPresent(RecipeView.self, forKey: .view) ?? RecipeView()
        metrics = try c.decodeIfPresent([String].self, forKey: .metrics) ?? []
    }

    public init(
        name: String, description: String = "", filters: RecipeFilters = RecipeFilters(),
        sort: RecipeSort = RecipeSort(), view: RecipeView = RecipeView(), metrics: [String] = []
    ) {
        self.name = name
        self.description = description
        self.filters = filters
        self.sort = sort
        self.view = view
        self.metrics = metrics
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !description.isEmpty { try c.encode(description, forKey: .description) }
        try c.encode(filters, forKey: .filters)
        if !sort.isEmpty { try c.encode(sort, forKey: .sort) }
        try c.encode(view, forKey: .view)
        if !metrics.isEmpty { try c.encode(metrics, forKey: .metrics) }
    }
}

/// A recipe plus where it came from.
public struct RecipeEntry: Codable, Sendable, Hashable, Identifiable {
    public var recipe: Recipe
    public var source: String
    /// Built-ins have no file to write back to, so they cannot be edited.
    public var isBuiltin: Bool

    public var id: String { recipe.name }

    private enum CodingKeys: String, CodingKey {
        case recipe, source
        case isBuiltin = "is_builtin"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decode(Recipe.self, forKey: .recipe)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        isBuiltin = try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
    }

    public init(recipe: Recipe, source: String = "", isBuiltin: Bool = false) {
        self.recipe = recipe
        self.source = source
        self.isBuiltin = isBuiltin
    }
}

public struct RecipeList: Codable, Sendable, Hashable {
    public var recipes: [RecipeEntry]
    public var warnings: [String]
    /// Where project recipes are written: `<project>/.bv/recipes.yaml`.
    public var path: String

    private enum CodingKeys: String, CodingKey { case recipes, warnings, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decodeIfPresent([RecipeEntry].self, forKey: .recipes) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }

    public init(recipes: [RecipeEntry] = []) {
        self.recipes = recipes
        self.warnings = []
        self.path = ""
    }

    public static let empty = RecipeList()

    public var builtins: [RecipeEntry] { recipes.filter(\.isBuiltin) }
    public var userDefined: [RecipeEntry] { recipes.filter { !$0.isBuiltin } }
}

/// The beads a recipe selects, in the order it sorts them.
public struct AppliedRecipe: Codable, Sendable, Hashable {
    public var recipe: Recipe
    public var issueIDs: [String]
    /// How many matched before `max_items` truncated the list.
    public var matched: Int
    public var truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case recipe, matched, truncated
        case issueIDs = "issue_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decode(Recipe.self, forKey: .recipe)
        issueIDs = try c.decodeIfPresent([String].self, forKey: .issueIDs) ?? []
        matched = try c.decodeIfPresent(Int.self, forKey: .matched) ?? issueIDs.count
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
