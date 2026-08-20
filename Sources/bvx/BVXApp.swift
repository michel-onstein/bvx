import BVXAppCore
import BVXCore
import SwiftUI

@main
struct BVXApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 620)
                .task { await store.openInitialWorkspace() }
        }
        .windowToolbarStyle(.unified)
        .commands { BVXCommands(store: store) }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

/// Menu-bar commands. Every action lives here first so it gets a real macOS
/// key equivalent and shows up in Help search; the vim-style single-key
/// bindings in `TerminalKeys` are an additive layer on top.
struct BVXCommands: Commands {
    @ObservedObject var store: ProjectStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Workspace…") { store.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Reload") { Task { await store.reload() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!store.isLoaded)
        }

        CommandMenu("View") {
            ForEach(ViewSurface.allCases) { surface in
                Button(surface.displayName) { store.surface = surface }
                    .keyboardShortcut(surface.keyEquivalent, modifiers: .command)
            }
            Divider()
            ForEach(IssueFilter.allCases) { filter in
                Button("Filter: \(filter.displayName)") { store.query.filter = filter }
            }
            Divider()
            Button("Compute Full Metrics") { Task { await store.computePhase2() } }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(store.metrics.hasPhase2Values || !store.isLoaded)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle("Terminal keys (bv single-key shortcuts)", isOn: $store.terminalKeysEnabled)
                Text(
                    "When on, bv's bindings — j/k, o/r/c/a, b/i/g/E — work whenever "
                        + "no text field has focus. Menu shortcuts always work."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Analysis") {
                Toggle("Skip expensive metrics on open", isOn: $store.skipPhase2)
                Text(
                    "Skips PageRank, betweenness, HITS and cycle detection. "
                        + "They can still be computed on demand."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
    }
}
