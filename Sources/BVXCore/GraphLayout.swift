import CoreGraphics
import Foundation

/// A positioned node in a laid-out dependency graph.
public struct LayoutNode: Sendable, Identifiable, Hashable {
    public var id: String
    public var position: CGPoint
    public var rank: Int
    /// True when the node participates in a dependency cycle.
    public var inCycle: Bool

    public init(id: String, position: CGPoint, rank: Int, inCycle: Bool = false) {
        self.id = id
        self.position = position
        self.rank = rank
        self.inCycle = inCycle
    }
}

/// A routed edge between two positioned nodes.
public struct LayoutEdge: Sendable, Identifiable, Hashable {
    public var from: String
    public var to: String
    public var start: CGPoint
    public var end: CGPoint
    /// True when this edge points backwards against the ranking, i.e. it
    /// closes a cycle. Drawn distinctly so the cycle is visible.
    public var isBackEdge: Bool

    public var id: String { "\(from)->\(to)" }
}

/// The result of laying out a graph.
public struct GraphLayout: Sendable {
    public var nodes: [LayoutNode]
    public var edges: [LayoutEdge]
    public var size: CGSize
    /// Strongly connected components with more than one member.
    public var cycles: [[String]]

    public static let empty = GraphLayout(nodes: [], edges: [], size: .zero, cycles: [])

    public func node(_ id: String) -> LayoutNode? { nodes.first { $0.id == id } }
}

/// Layered (Sugiyama-style) layout for dependency DAGs.
///
/// Rank equals dependency depth, which is the natural reading of a blocking
/// graph: everything on row 0 is unblocked, and each row below waits on the
/// row above. Cycles break layering, so they are condensed with Tarjan's
/// algorithm, ranked as a unit, then expanded — which makes a dependency cycle
/// *visible* rather than a footnote.
public enum GraphLayoutEngine {

    public struct Options: Sendable {
        public var nodeSpacing: CGFloat = 150
        public var rankSpacing: CGFloat = 110
        public var margin: CGFloat = 60

        public init() {}
    }

    public static func layout(
        nodes ids: [String],
        edges: [GraphEdge],
        options: Options = Options()
    ) -> GraphLayout {
        guard !ids.isEmpty else { return .empty }

        // Only blocking edges define the ordering; related/parent-child edges
        // are shown but must not influence rank.
        let blocking = edges.filter { $0.type.isBlocking }
        let idSet = Set(ids)

        // Adjacency: from -> [to]. An edge a->b means "a depends on b", so b
        // must be ranked above a.
        var successors: [String: [String]] = [:]
        for e in blocking where idSet.contains(e.from) && idSet.contains(e.to) {
            successors[e.from, default: []].append(e.to)
        }

        let components = tarjanSCC(nodes: ids, successors: successors)
        let cycles = components.filter { $0.count > 1 }

        // Map every node to its component representative so the condensed
        // graph is guaranteed acyclic.
        var componentOf: [String: Int] = [:]
        for (index, component) in components.enumerated() {
            for member in component { componentOf[member] = index }
        }

        // Condensed adjacency between components.
        var componentSuccessors: [Int: Set<Int>] = [:]
        for (from, tos) in successors {
            guard let cf = componentOf[from] else { continue }
            for to in tos {
                guard let ct = componentOf[to], ct != cf else { continue }
                componentSuccessors[cf, default: []].insert(ct)
            }
        }

        // Longest-path ranking over the condensation: a component's rank is
        // one more than the deepest thing it depends on.
        var componentRank: [Int: Int] = [:]
        var visiting: Set<Int> = []
        func rank(of component: Int) -> Int {
            if let cached = componentRank[component] { return cached }
            // Guard against re-entry; the condensation is acyclic so this only
            // fires on malformed input.
            guard !visiting.contains(component) else { return 0 }
            visiting.insert(component)
            defer { visiting.remove(component) }

            var best = 0
            for next in componentSuccessors[component] ?? [] {
                best = max(best, rank(of: next) + 1)
            }
            componentRank[component] = best
            return best
        }
        for index in components.indices { _ = rank(of: index) }

        // A component's rank is the length of the longest dependency chain
        // below it, so anything unblocked is rank 0 and sits at the top; each
        // row beneath waits on the row above.
        let maxRank = componentRank.values.max() ?? 0
        var rowsByRank: [Int: [String]] = [:]
        var nodeRank: [String: Int] = [:]
        for (member, component) in componentOf {
            let r = componentRank[component] ?? 0
            nodeRank[member] = r
            rowsByRank[r, default: []].append(member)
        }

        let cyclicNodes = Set(cycles.flatMap { $0 })

        // Order within a row by in-degree then id, so heavy blockers sit
        // toward the middle-left and the result is deterministic.
        var inDegree: [String: Int] = [:]
        for (_, tos) in successors {
            for to in tos { inDegree[to, default: 0] += 1 }
        }

        var layoutNodes: [LayoutNode] = []
        var positions: [String: CGPoint] = [:]
        let widest = rowsByRank.values.map(\.count).max() ?? 1
        let width = CGFloat(max(widest, 1) - 1) * options.nodeSpacing + options.margin * 2

        for r in 0...max(maxRank, 0) {
            let row = (rowsByRank[r] ?? []).sorted {
                let a = inDegree[$0] ?? 0, b = inDegree[$1] ?? 0
                return a != b ? a > b : $0 < $1
            }
            guard !row.isEmpty else { continue }
            let rowWidth = CGFloat(row.count - 1) * options.nodeSpacing
            let startX = (width - rowWidth) / 2
            for (i, id) in row.enumerated() {
                let p = CGPoint(
                    x: startX + CGFloat(i) * options.nodeSpacing,
                    y: options.margin + CGFloat(r) * options.rankSpacing
                )
                positions[id] = p
                layoutNodes.append(
                    LayoutNode(id: id, position: p, rank: r, inCycle: cyclicNodes.contains(id)))
            }
        }

        var layoutEdges: [LayoutEdge] = []
        for e in edges {
            guard let s = positions[e.from], let t = positions[e.to] else { continue }
            // A back edge points from a shallower rank to a deeper one.
            let isBack = (nodeRank[e.from] ?? 0) <= (nodeRank[e.to] ?? 0)
            layoutEdges.append(
                LayoutEdge(from: e.from, to: e.to, start: s, end: t, isBackEdge: isBack && e.type.isBlocking))
        }

        let height = options.margin * 2 + CGFloat(max(maxRank, 0)) * options.rankSpacing
        return GraphLayout(
            nodes: layoutNodes, edges: layoutEdges,
            size: CGSize(width: max(width, 320), height: max(height, 240)),
            cycles: cycles
        )
    }

    /// Tarjan's strongly-connected-components algorithm, iterative so a deep
    /// dependency chain cannot overflow the stack.
    static func tarjanSCC(nodes: [String], successors: [String: [String]]) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack: Set<String> = []
        var stack: [String] = []
        var result: [[String]] = []

        for root in nodes where indices[root] == nil {
            // Explicit work stack of (node, next-successor-offset).
            var work: [(node: String, next: Int)] = [(root, 0)]
            indices[root] = index
            lowlink[root] = index
            index += 1
            stack.append(root)
            onStack.insert(root)

            while !work.isEmpty {
                let (node, next) = work[work.count - 1]
                let neighbours = successors[node] ?? []

                if next < neighbours.count {
                    work[work.count - 1].next += 1
                    let child = neighbours[next]
                    if indices[child] == nil {
                        indices[child] = index
                        lowlink[child] = index
                        index += 1
                        stack.append(child)
                        onStack.insert(child)
                        work.append((child, 0))
                    } else if onStack.contains(child) {
                        lowlink[node] = min(lowlink[node] ?? 0, indices[child] ?? 0)
                    }
                } else {
                    work.removeLast()
                    if let parent = work.last?.node {
                        lowlink[parent] = min(lowlink[parent] ?? 0, lowlink[node] ?? 0)
                    }
                    if lowlink[node] == indices[node] {
                        var component: [String] = []
                        while let top = stack.popLast() {
                            onStack.remove(top)
                            component.append(top)
                            if top == node { break }
                        }
                        result.append(component.sorted())
                    }
                }
            }
        }
        return result
    }
}
