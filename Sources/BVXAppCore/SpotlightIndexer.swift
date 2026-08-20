import BVXCore
import CoreSpotlight
import Foundation

/// Publishes beads to Spotlight, so typing an id anywhere on the system finds
/// it and opens it in bvx.
///
/// Best-effort throughout, for the same reason the notifier is:
/// `CSSearchableIndex.default()` needs a bundle identifier, and the test suite
/// and the CLI both run without one. Indexing is a convenience, never a
/// requirement, so every path here degrades to doing nothing.
public actor SpotlightIndexer {
    /// The domain everything bvx indexes belongs to, so it can all be removed
    /// at once when a different workspace is opened.
    private static let domain = "com.qjam.bvx.beads"

    /// The workspace currently represented in the index.
    private var indexedWorkspace: String?

    public init() {}

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && CSSearchableIndex.isIndexingAvailable()
    }

    /// Replaces the index with `issues` from `workspace`.
    ///
    /// Replacing rather than merging matters: a bead deleted from the
    /// workspace must stop being findable, and an additive index would keep
    /// offering it forever.
    public func index(_ issues: [Issue], workspace: String) async {
        guard isAvailable else { return }
        let index = CSSearchableIndex.default()

        if indexedWorkspace != nil, indexedWorkspace != workspace {
            try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }

        let items = issues.map { issue -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = "\(issue.id) — \(issue.title)"
            attributes.contentDescription = issue.description.isEmpty
                ? issue.status.displayName
                : String(issue.description.prefix(400))
            // The id and labels become keywords, so both "bvx-8ou" and the
            // label find the bead.
            attributes.keywords = [issue.id, issue.status.rawValue] + issue.labels
            attributes.contentModificationDate = issue.updatedAt
            attributes.identifier = issue.id

            let item = CSSearchableItem(
                uniqueIdentifier: issue.id,
                domainIdentifier: Self.domain,
                attributeSet: attributes)
            return item
        }

        do {
            try await index.indexSearchableItems(items)
            indexedWorkspace = workspace
        } catch {
            // A failed index costs discoverability, not correctness.
            indexedWorkspace = nil
        }
    }

    /// Removes everything bvx has indexed.
    public func clear() async {
        guard isAvailable else { return }
        try? await CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        indexedWorkspace = nil
    }

    /// The bead a Spotlight activation refers to.
    ///
    /// Static and pure so it can be tested without an index.
    public static func beadID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo[CSSearchableItemActivityIdentifier] as? String,
            !id.isEmpty
        else { return nil }
        return id
    }
}
