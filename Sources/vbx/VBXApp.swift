import AppKit
import VBXAppCore
import VBXUI
import VBXCore
import CoreSpotlight
import SwiftUI

@main
struct VBXApp: App {
    @StateObject private var store = ProjectStore()
    @State private var showingExportWizard = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 620)
                .task { await store.openInitialWorkspace() }
                // vbx://open?workspace=...&bead=... - the same shape the
                // inspector's inline bead links use, so one handler serves
                // links from inside and outside the app.
                .onOpenURL { url in
                    Task { await store.open(url: url) }
                }
                // A bead opened from Spotlight.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let info = activity.userInfo else { return }
                    _ = store.openSpotlightItem(info)
                }
                .sheet(isPresented: $showingExportWizard) {
                    ExportWizard().environmentObject(store)
                }
        }
        .windowToolbarStyle(.unified)
        .commands { VBXCommands(store: store, showingExportWizard: $showingExportWizard) }

        // Its own window rather than a sheet: the tutorial is meant to be read
        // beside the app, not instead of it.
        WindowGroup(id: "tutorial", for: String.self) { $section in
            TutorialView(initialSection: section)
                .environmentObject(store)
        }
        .defaultSize(width: 860, height: 600)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

/// Menu-bar commands. Every action lives here first so it gets a real macOS
/// key equivalent and shows up in Help search; the vim-style single-key
/// bindings in `TerminalKeys` are an additive layer on top.
struct VBXCommands: Commands {
    @ObservedObject var store: ProjectStore
    @Binding var showingExportWizard: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Workspace…") { store.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Reload") { Task { await store.reload(force: true) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!store.isLoaded)
            Divider()
            Button("Export Markdown Report…") { Task { await store.exportMarkdown() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!store.isLoaded)
            Button("Export Static Site…") { showingExportWizard = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!store.isLoaded)
            Divider()
            Button("Install Command Line Tool…") { installCommandLineTool() }
                .disabled(!CommandLineTool.isAvailable)
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

        CommandGroup(replacing: .help) {
            Button("vbx Tutorial") { openWindow(id: "tutorial", value: "welcome") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

extension VBXCommands {
    /// Links the bundled `vbx-cli` somewhere on the user's PATH.
    ///
    /// The destination comes from a save panel because, under the App Sandbox,
    /// that grant is the only thing authorising the write — a hardcoded
    /// `/usr/local/bin` would simply fail.
    fileprivate func installCommandLineTool() {
        let alert = NSAlert()
        switch CommandLineTool.install() {
        case .installed(let path):
            alert.messageText = "Command line tool installed"
            alert.informativeText = "vbx-cli is linked at \(path)."
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Could not install the command line tool"
            alert.informativeText = message
        case .cancelled:
            return
        }
        alert.runModal()
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
            DeployCredentialsSettings()
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
