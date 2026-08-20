import AppKit
import BVXAppCore
import BVXCore
import SwiftUI

/// Applies bv's single-key bindings when no text field has focus.
///
/// The design decision here is that menu commands are the primary, native,
/// system-customisable path; this layer is additive so muscle memory carried
/// over from the terminal keeps working. Because a bare letter is only a
/// shortcut when the first responder does not accept text, typing "b" into the
/// search field never jumps to the board.
struct TerminalKeyCatcher: NSViewRepresentable {
    @EnvironmentObject var store: ProjectStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(store: store)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.store = store
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var store: ProjectStore?
        private var monitor: Any?

        func install(store: ProjectStore) {
            self.store = store
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        // The local event monitor fires on the main thread, so hopping into
        // MainActor isolation here is sound.
        @MainActor
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let store, store.terminalKeysEnabled, store.isLoaded else { return event }

            // Any modifier means it is a real menu shortcut; leave it alone.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty || modifiers == .shift else { return event }

            // Never steal keystrokes from a text field.
            if let responder = NSApp.keyWindow?.firstResponder,
                responder is NSTextView || responder is NSTextField
            {
                return event
            }

            guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
                let key = characters.first
            else { return event }

            return apply(key: key, to: store) ? nil : event
        }

        @MainActor
        private func apply(key: Character, to store: ProjectStore) -> Bool {
            // View surfaces.
            if let surface = ViewSurface.allCases.first(where: { $0.terminalKey == key }) {
                store.surface = surface
                return true
            }
            // Filters.
            if let filter = IssueFilter.allCases.first(where: { $0.shortcut == key }) {
                store.query.filter = filter
                return true
            }

            switch key {
            case "j": move(by: 1, in: store); return true
            case "k": move(by: -1, in: store); return true
            case "G": store.selection = store.visibleIssues.last?.id; return true
            case "s": cycleSort(store); return true
            default: return false
            }
        }

        @MainActor
        private func move(by delta: Int, in store: ProjectStore) {
            let visible = store.visibleIssues
            guard !visible.isEmpty else { return }
            guard let current = store.selection,
                let index = visible.firstIndex(where: { $0.id == current })
            else {
                store.selection = visible.first?.id
                return
            }
            let next = min(max(index + delta, 0), visible.count - 1)
            store.selection = visible[next].id
        }

        @MainActor
        private func cycleSort(_ store: ProjectStore) {
            let modes = SortMode.allCases
            guard let index = modes.firstIndex(of: store.query.sort) else { return }
            store.query.sort = modes[(index + 1) % modes.count]
        }
    }
}
