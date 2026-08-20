import BVXAppCore
import BVXCore
import SwiftUI

/// Interactive dependency graph on a Canvas, with pan, zoom and hit-testing.
struct GraphView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var layout: GraphLayout = .empty
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var hovered: String?
    @State private var isLaidOut = false

    /// Node radius encodes PageRank when it is available.
    private func radius(for id: String) -> CGFloat {
        guard let pr = store.metrics.pageRank, let value = pr[id], let maxPR = pr.values.max(),
            maxPR > 0
        else { return 16 }
        return 13 + 16 * CGFloat(value / maxPR)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                Canvas { context, _ in
                    context.translateBy(x: pan.width, y: pan.height)
                    context.scaleBy(x: zoom, y: zoom)
                    draw(in: &context)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            pan = CGSize(
                                width: dragStart.width + value.translation.width,
                                height: dragStart.height + value.translation.height)
                        }
                        .onEnded { _ in dragStart = pan }
                )
                .onTapGesture { location in select(at: location) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = node(at: point)?.id
                    case .ended: hovered = nil
                    }
                }
                .onAppear { center(in: geo.size) }
            }

            controls
        }
        .background(.background.secondary)
        .task(id: layoutKey) { await rebuild() }
        .overlay {
            if !isLaidOut {
                ProgressView("Laying out graph…")
            } else if layout.nodes.isEmpty {
                EmptyStateView(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "Nothing to plot",
                    message: "No beads match the current filter."
                )
            }
        }
    }

    /// Recompute only when the visible set or edges actually change.
    private var layoutKey: String {
        "\(store.visibleIssues.count)-\(store.edges.count)-\(store.query.filter.rawValue)-\(store.query.searchText)"
    }

    private func rebuild() async {
        let ids = store.visibleIssues.map(\.id)
        let edges = store.edges
        isLaidOut = false
        // Layout is pure and can be expensive, so keep it off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            GraphLayoutEngine.layout(nodes: ids, edges: edges)
        }.value
        layout = result
        isLaidOut = true
    }

    private func center(in size: CGSize) {
        guard layout.size.width > 0 else { return }
        pan = CGSize(
            width: max(0, (size.width - layout.size.width * zoom) / 2),
            height: 20)
        dragStart = pan
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext) {
        let selected = store.selection
        let highlighted = hovered ?? selected

        // Edges first so nodes sit on top.
        for edge in layout.edges {
            var path = Path()
            path.move(to: edge.start)
            // Gentle vertical bezier; ranks flow top to bottom.
            let mid = (edge.start.y + edge.end.y) / 2
            path.addCurve(
                to: edge.end,
                control1: CGPoint(x: edge.start.x, y: mid),
                control2: CGPoint(x: edge.end.x, y: mid))

            let touches = highlighted == edge.from || highlighted == edge.to
            let color: Color = edge.isBackEdge ? .red : (touches ? .accentColor : .secondary)
            context.stroke(
                path,
                with: .color(color.opacity(touches ? 0.95 : (edge.isBackEdge ? 0.8 : 0.32))),
                style: StrokeStyle(
                    lineWidth: touches ? 2.4 : 1.3,
                    dash: edge.isBackEdge ? [5, 3] : []
                )
            )
        }

        for node in layout.nodes {
            let r = radius(for: node.id)
            let rect = CGRect(
                x: node.position.x - r, y: node.position.y - r, width: r * 2, height: r * 2)
            let issue = store.issuesByID[node.id]
            let isSelected = node.id == selected
            let isHovered = node.id == hovered

            context.fill(Circle().path(in: rect), with: .color(fill(for: issue)))

            if node.inCycle {
                // Cycle membership gets its own unmistakable ring.
                context.stroke(
                    Circle().path(in: rect.insetBy(dx: -3, dy: -3)),
                    with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
            }
            if isSelected || isHovered {
                context.stroke(
                    Circle().path(in: rect.insetBy(dx: -4, dy: -4)),
                    with: .color(.accentColor), lineWidth: isSelected ? 3 : 2)
            }
            if store.actionable.contains(node.id) {
                context.stroke(Circle().path(in: rect), with: .color(.yellow), lineWidth: 2)
            }

            let label = Text(node.id).font(.system(size: 9, weight: .medium))
            context.draw(
                context.resolve(label.foregroundStyle(.primary)),
                at: CGPoint(x: node.position.x, y: node.position.y + r + 9))
        }
    }

    private func fill(for issue: Issue?) -> Color {
        guard let issue else { return .gray }
        switch issue.status {
        case .open: return .blue
        case .inProgress: return .orange
        case .blocked: return .red
        case .review: return .purple
        case .closed: return .green.opacity(0.55)
        case .deferred, .draft: return .gray
        default: return .secondary
        }
    }

    // MARK: - Interaction

    private func node(at point: CGPoint) -> LayoutNode? {
        let p = CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
        // Nearest node within its own radius wins.
        return layout.nodes
            .map { ($0, hypot($0.position.x - p.x, $0.position.y - p.y)) }
            .filter { $0.1 <= radius(for: $0.0.id) + 4 }
            .min { $0.1 < $1.1 }?.0
    }

    private func select(at point: CGPoint) {
        if let hit = node(at: point) { store.selection = hit.id }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { zoom = max(0.25, zoom - 0.15) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { zoom = min(3, zoom + 0.15) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button { zoom = 1; pan = .zero; dragStart = .zero } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset view")
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !layout.cycles.isEmpty {
                Label(
                    "\(layout.cycles.count) dependency cycle\(layout.cycles.count == 1 ? "" : "s")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .padding(6)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .help(layout.cycles.map { $0.joined(separator: " → ") }.joined(separator: "\n"))
            }

            GraphLegend(hasPageRank: store.metrics.pageRank != nil)
        }
        .padding(10)
    }
}

struct GraphLegend: View {
    let hasPageRank: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Legend").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            legendRow(.blue, "Open")
            legendRow(.orange, "In progress")
            legendRow(.red, "Blocked")
            legendRow(.green.opacity(0.55), "Closed")
            HStack(spacing: 5) {
                Circle().strokeBorder(.yellow, lineWidth: 2).frame(width: 9, height: 9)
                Text("Actionable").font(.caption2)
            }
            Text(hasPageRank ? "Size = PageRank" : "Size = uniform (metrics pending)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2)
        }
    }
}
