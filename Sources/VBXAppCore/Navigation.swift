import Foundation
import VBXCore

/// One position the user has been in.
///
/// A position is the surface *plus* the bead in focus, not the surface alone.
/// Following a bead link changes the focused bead without changing the
/// surface, and that is a move the user expects back to undo — a surface-only
/// history would leave back doing nothing on exactly the wandering it exists
/// for.
public struct NavigationEntry: Equatable, Sendable {
    public let surface: ViewSurface
    public let bead: Issue.ID?

    public init(surface: ViewSurface, bead: Issue.ID?) {
        self.surface = surface
        self.bead = bead
    }
}

extension ProjectStore {

    /// How many positions are kept. The oldest is evicted past this.
    public static let navigationHistoryLimit = 20

    /// True when there is an older position to return to.
    public var canGoBack: Bool { navigationCursor > 0 }

    /// True when back has been used and there is a newer position ahead.
    public var canGoForward: Bool {
        navigationCursor >= 0 && navigationCursor < navigationHistory.count - 1
    }

    /// The position the user is in now, if any has been recorded.
    public var currentNavigationEntry: NavigationEntry? {
        guard navigationHistory.indices.contains(navigationCursor) else { return nil }
        return navigationHistory[navigationCursor]
    }

    /// Records where the user now is as a new position.
    ///
    /// Called for the two moves that count as navigation: changing surface,
    /// and jumping to a bead through ``select(id:)``. Plain row selection
    /// refreshes the current entry instead — see ``noteFocusChanged()``.
    func recordNavigation() {
        guard !isRestoringNavigation else { return }

        let entry = NavigationEntry(surface: surface, bead: focusedID)
        // Arriving where you already are is not a navigation. Without this,
        // a redundant write of the same surface would fill the history with
        // duplicates and push real positions out.
        if currentNavigationEntry == entry { return }

        // A new move from mid-history discards the forward branch, exactly as
        // a browser does. Keeping it would let forward jump to a position the
        // user never navigated from.
        if navigationCursor < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((navigationCursor + 1)...)
        }

        navigationHistory.append(entry)
        if navigationHistory.count > Self.navigationHistoryLimit {
            navigationHistory.removeFirst(navigationHistory.count - Self.navigationHistoryLimit)
        }
        navigationCursor = navigationHistory.count - 1
    }

    /// Keeps the current position's bead in step with the focus.
    ///
    /// Moving down the list with `j`/`k` is browsing, not navigation: pushing
    /// an entry per row would evict every real position within one screenful.
    /// The current entry is updated in place instead, so going back later
    /// returns to where the user actually was rather than to a stale row.
    func noteFocusChanged() {
        guard !isRestoringNavigation, !isJumpingToBead else { return }
        guard navigationHistory.indices.contains(navigationCursor) else { return }
        let current = navigationHistory[navigationCursor]
        guard current.surface == surface else { return }
        navigationHistory[navigationCursor] = NavigationEntry(surface: surface, bead: focusedID)
    }

    /// Seeds the history with the current position, discarding what was there.
    ///
    /// Called when a workspace opens: positions name beads, and beads from the
    /// previous workspace do not exist in this one.
    func resetNavigationHistory() {
        navigationHistory = [NavigationEntry(surface: surface, bead: focusedID)]
        navigationCursor = 0
    }

    /// Returns to the previous position. No-op at the oldest.
    public func goBack() {
        guard canGoBack else { return }
        navigationCursor -= 1
        restoreCurrentNavigationEntry()
    }

    /// Advances to the next position. No-op at the newest.
    public func goForward() {
        guard canGoForward else { return }
        navigationCursor += 1
        restoreCurrentNavigationEntry()
    }

    /// Puts the app back into the position at the cursor.
    ///
    /// A bead that has since vanished — closed, or gone in a reload — restores
    /// the surface and simply leaves the selection empty. Refusing to move at
    /// all would strand the user on a position they are trying to leave.
    private func restoreCurrentNavigationEntry() {
        guard let entry = currentNavigationEntry else { return }
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }

        surface = entry.surface
        if let bead = entry.bead, issues.contains(where: { $0.id == bead }) {
            selection = [bead]
        } else {
            selection = []
        }
    }
}
