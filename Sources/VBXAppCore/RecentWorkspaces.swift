import Foundation

/// The workspaces opened most recently, for the File menu.
///
/// Deliberately not `NSDocumentController`'s recent-documents list: vbx is not
/// document-based, and what it reopens is a *workspace directory* rather than a
/// file, so the system list would both mis-describe the entries and fight the
/// app over which of them is current.
@MainActor
public final class RecentWorkspaces: ObservableObject {

    /// How many are kept. Five is what the request asked for, and it is about
    /// the length at which a menu is still scannable without reading.
    public static let limit = 5

    /// One remembered workspace.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let path: String
        /// What the menu shows: the folder's own name.
        public let name: String
        public var id: String { path }
    }

    @Published public private(set) var paths: [String] = []

    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - defaults: injected so tests do not write into the real preferences,
    ///     and so two tests cannot see each other's entries.
    public init(defaults: UserDefaults = .standard, key: String = "recentWorkspaces") {
        self.defaults = defaults
        self.key = key
        self.paths = defaults.stringArray(forKey: key) ?? []
    }

    /// The entries worth showing, newest first.
    ///
    /// Paths that have since been moved or deleted are filtered out rather than
    /// listed and left to fail on click. They stay in storage, though: an
    /// external drive that is merely unmounted should not cost the user their
    /// history.
    public var entries: [Entry] {
        paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Entry(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
    }

    /// Records a workspace as the most recent.
    ///
    /// Re-opening something already in the list moves it to the top rather than
    /// adding it twice, which is what makes the list read as "where I have
    /// been" instead of "what I have clicked".
    public func record(_ path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var updated = paths.filter { $0 != standardized }
        updated.insert(standardized, at: 0)
        if updated.count > Self.limit {
            updated.removeLast(updated.count - Self.limit)
        }
        paths = updated
        defaults.set(updated, forKey: key)
    }

    /// Empties the list.
    public func clear() {
        paths = []
        defaults.removeObject(forKey: key)
    }
}
