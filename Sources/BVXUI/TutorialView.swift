import BVXAppCore
import BVXCore
import SwiftUI

/// The interactive tutorial, in its own window.
///
/// bv binds this to `` ` `` and needs it more than bvx does — a TUI has no
/// menu bar to explore. It earns its place here by explaining the ideas that
/// are *not* discoverable: why a metric can be absent, why readiness is a
/// graph property, why hybrid ranking is not the default.
public struct TutorialView: View {
    @StateObject private var tutorial = Tutorial()
    /// Set when the tutorial is opened from a specific surface, so it lands
    /// on that surface's section rather than at the beginning.
    public var initialSection: String?

    public init(initialSection: String? = nil) {
        self.initialSection = initialSection
    }

    public var body: some View {
        NavigationSplitView {
            List(tutorial.sections, selection: $tutorial.selection) { section in
                row(section).tag(section.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .safeAreaInset(edge: .bottom) { progressFooter }
        } detail: {
            if let id = tutorial.selection,
                let section = tutorial.sections.first(where: { $0.id == id })
            {
                detail(section)
            } else {
                EmptyStateView(
                    symbol: "book",
                    title: "Tutorial",
                    message: "Choose a section to begin."
                )
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onAppear {
            if let initialSection { tutorial.selection = initialSection }
        }
    }

    private func row(_ section: TutorialSection) -> some View {
        HStack(spacing: 8) {
            Image(
                systemName: tutorial.isComplete(section.id)
                    ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(tutorial.isComplete(section.id) ? Color.green : .secondary)
            .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(.callout)
                Text(section.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // bv's key for the same thing, so someone arriving from the TUI
            // can map what they already know onto this.
            if let key = section.terminalKey {
                Text(key)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private var progressFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: tutorial.progress)
            HStack {
                Text("\(tutorial.completed.count) of \(tutorial.sections.count) read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { tutorial.reset() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func detail(_ section: TutorialSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(section.title).font(.title2.weight(.semibold))
                // Rendered through the same component bead descriptions use,
                // so the tables and code blocks already built get used rather
                // than duplicated.
                MarkdownText(source: section.body, font: .body)

                Divider()

                HStack {
                    Toggle(
                        "Mark as read",
                        isOn: Binding(
                            get: { tutorial.isComplete(section.id) },
                            set: { done in
                                done
                                    ? tutorial.markComplete(section.id)
                                    : tutorial.markIncomplete(section.id)
                            })
                    )
                    .toggleStyle(.checkbox)

                    Spacer()

                    if section.id != tutorial.sections.last?.id {
                        Button("Next") { tutorial.advance() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
        }
    }
}

/// The "learn this view" link each surface shows.
///
/// Context-sensitive: it opens the tutorial at the section for the surface
/// currently on screen, rather than at the beginning.
public struct TutorialLink: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button {
            openWindow(id: "tutorial", value: sectionID)
        } label: {
            Label("Learn this view", systemImage: "questionmark.circle")
        }
        .help("Open the tutorial at this view's section")
    }

    /// The section for the current surface, falling back to the first.
    private var sectionID: String {
        Tutorial.sections.first { $0.surface == store.surface }?.id
            ?? Tutorial.sections.first?.id
            ?? "welcome"
    }
}
