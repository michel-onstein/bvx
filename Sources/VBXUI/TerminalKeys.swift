import AppKit
import VBXAppCore
import VBXCore
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
            case "G":
                if let last = store.visibleIssues.last { store.select(id: last.id) }
                return true
            case "s": cycleSort(store); return true
            default: return false
            }
        }

        /// bv's `j`/`k`: move one cursor.
        ///
        /// Deliberately a single cursor even though the list supports
        /// multi-selection. `j` moving one end of a range would be a different
        /// gesture from what bv's binding means, and there is no modifier to
        /// distinguish "move" from "extend" in a single keypress.
        @MainActor
        private func move(by delta: Int, in store: ProjectStore) {
            let visible = store.visibleIssues
            guard !visible.isEmpty else { return }
            guard let current = store.focusedID,
                let index = visible.firstIndex(where: { $0.id == current })
            else {
                if let first = visible.first { store.select(id: first.id) }
                return
            }
            let next = min(max(index + delta, 0), visible.count - 1)
            store.select(id: visible[next].id)
        }

        /// bv's `s`: step through the named orderings.
        ///
        /// The cycle and the table's column headers write the same
        /// `query.sort`, so a header click can leave the sort on an ordering
        /// the cycle does not contain. That is not an error — `s` simply
        /// re-enters the cycle at its first entry.
        @MainActor
        private func cycleSort(_ store: ProjectStore) {
            let modes = SortMode.cycleCases
            guard let index = modes.firstIndex(of: store.query.sort) else {
                store.query.sort = modes[0]
                return
            }
            var next = index
            // Skip an ordering whose metrics have not been computed rather
            // than parking the list on a sort that cannot be applied.
            repeat {
                next = (next + 1) % modes.count
            } while modes[next].requiresPhase2 && !store.metrics.hasPhase2Values
                && next != index
            store.query.sort = modes[next]
        }
    }
}
