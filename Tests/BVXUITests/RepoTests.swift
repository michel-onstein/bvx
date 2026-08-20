import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

private typealias Bead = BVXCore.Issue

/// Multi-repository workspaces.
@MainActor
@Suite("Repositories")
struct RepoTests {

    /// Two repositories under one workspace, with a dependency between them.
    private func workspaceStore() async throws -> (ProjectStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-workspace-\(UUID().uuidString)")
        let manager = FileManager.default

        func writeRepo(_ name: String, _ content: String) throws {
            let dir = root.appendingPathComponent("\(name)/.beads")
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(
                to: dir.appendingPathComponent("issues.jsonl"),
                atomically: true, encoding: .utf8)
        }

        // Both repositories hold an issue "1"; without namespacing one would
        // silently overwrite the other in every id-keyed map.
        try writeRepo(
            "api",
            #"{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1,"#
                + #""dependencies":[{"issue_id":"1","depends_on_id":"web-1","type":"blocks"}]}"# + "\n"
                + #"{"id":"2","title":"API docs","status":"open","issue_type":"docs","priority":2}"#
                + "\n")
        try writeRepo(
            "web",
            #"{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}"#
                + "\n")

        let configDir = root.appendingPathComponent(".bv")
        try manager.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
            name: Demo workspace
            repos:
              - name: api
                path: api
                prefix: "api-"
              - name: web
                path: web
                prefix: "web-"
            """.write(
                to: configDir.appendingPathComponent("workspace.yaml"),
                atomically: true, encoding: .utf8)

        let store = ProjectStore()
        await store.open(path: root.path)
        await store.computePhase2()
        return (store, root)
    }

    @Test("A single-repository workspace has no repository section")
    func singleRepoIsNotAWorkspace() async {
        let store = await Fixture.loadedStore()
        // Not an error — it simply has one repo, and the picker is absent
        // rather than showing one inert row.
        #expect(!store.repos.isWorkspace)
        #expect(store.repos.repos.isEmpty)
        #expect(store.repo(of: "bvx-3") == nil)
        await store.close()
    }

    @Test("A workspace aggregates every repository with namespaced ids")
    func aggregates() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.repos.isWorkspace)
        #expect(store.repos.repos.map(\.name) == ["api", "web"])
        #expect(store.issues.count == 3)

        let ids = Set(store.issues.map(\Bead.id))
        #expect(ids == ["api-1", "api-2", "web-1"])
        // The unqualified id must not survive, or the two repos can collide.
        #expect(!ids.contains("1"))

        await store.close()
    }

    @Test("Each bead reports the repository it came from")
    func repoAttribution() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.repo(of: "api-1")?.name == "api")
        #expect(store.repo(of: "web-1")?.name == "web")
        #expect(store.repo(of: "nothing-3") == nil)

        await store.close()
    }

    @Test("Cross-repository dependencies are identified")
    func crossRepoEdges() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.repos.crossRepoEdges.count == 1)
        // api-1 waits on web-1 — an edge invisible from inside either repo,
        // which is the whole reason to aggregate them.
        #expect(store.isCrossRepo("api-1"))
        #expect(store.isCrossRepo("web-1"))
        #expect(!store.isCrossRepo("api-2"))

        await store.close()
    }

    @Test("The repository filter narrows the list and composes with search")
    func repoFilter() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let all = store.visibleIssues.count
        store.repoFilter = ["api"]
        let apiOnly = store.visibleIssues
        #expect(apiOnly.count < all)
        #expect(apiOnly.allSatisfy { $0.id.hasPrefix("api-") })

        // Composes rather than overriding: the search narrows within the repo.
        store.query.searchText = "docs"
        #expect(store.visibleIssues.allSatisfy { $0.id.hasPrefix("api-") })
        #expect(store.visibleIssues.count <= apiOnly.count)

        store.query.searchText = ""
        store.repoFilter = []
        #expect(store.visibleIssues.count == all)

        await store.close()
    }

    // MARK: - Prefix resolution

    @Test("The longest matching prefix wins")
    func longestPrefixWins() {
        // `api-v2-` and `api-` both match `api-v2-3`; the shorter one would
        // attribute the bead to the wrong repository.
        let list = RepoList(
            isWorkspace: true,
            repos: [
                RepoInfo(name: "api", prefix: "api-"),
                RepoInfo(name: "api-v2", prefix: "api-v2-"),
            ])
        #expect(list.repo(owning: "api-v2-3")?.name == "api-v2")
        #expect(list.repo(owning: "api-7")?.name == "api")
        #expect(list.repo(owning: "web-1") == nil)
    }

    @Test("A badge drops the prefix separator")
    func badgeFormat() {
        #expect(RepoInfo(name: "api", prefix: "api-").badge == "api")
        #expect(RepoInfo(name: "api", prefix: "api").badge == "api")
    }

    @Test("A repository that failed to load is flagged, not hidden")
    func failedRepoIsReported() throws {
        let json = """
            {"is_workspace":true,
             "repos":[
               {"name":"api","prefix":"api-","issue_count":4},
               {"name":"web","prefix":"web-","issue_count":0,"error":"no .beads directory"}
             ],
             "cross_repo_edges":[]}
            """
        let list = try JSONDecoder().decode(RepoList.self, from: Data(json.utf8))

        // Silently dropping it would make its beads look closed.
        #expect(list.repos.count == 2)
        #expect(list.healthyRepos.map(\.name) == ["api"])
        #expect(list.failedRepos.map(\.name) == ["web"])
        #expect(list.failedRepos.first?.error == "no .beads directory")
    }

    @Test("An empty repo list decodes as a single-repo workspace")
    func emptyDecodes() throws {
        let list = try JSONDecoder().decode(RepoList.self, from: Data("{}".utf8))
        #expect(!list.isWorkspace)
        #expect(list.repos.isEmpty)
        #expect(list.crossRepoIDs.isEmpty)
    }

    // MARK: - Rendering

    @Test("The sidebar shows the repository picker for a workspace")
    func rendersPicker() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try Snapshot.render(
            SidebarView().environmentObject(store),
            name: "sidebar-repos",
            size: CGSize(width: 240, height: 800)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("The list shows repository badges")
    func rendersBadges() async throws {
        let (store, root) = try await workspaceStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try Snapshot.render(
            IssueListView().environmentObject(store),
            name: "list-repo-badges",
            size: CGSize(width: 1100, height: 400)
        )
        #expect(result.inkCoverage() > 0.01)
        await store.close()
    }

    @Test("A cross-repo badge renders differently from a plain one")
    func badgeVariants() throws {
        let repo = RepoInfo(name: "api", prefix: "api-")
        let plain = try Snapshot.render(
            RepoBadge(repo: repo).padding(6),
            name: "repo-badge",
            size: CGSize(width: 90, height: 26))
        let crossing = try Snapshot.render(
            RepoBadge(repo: repo, isCrossRepo: true).padding(6),
            name: "repo-badge-cross",
            size: CGSize(width: 90, height: 26))

        #expect(plain.inkCoverage() > 0.02)
        // The crossing badge carries an extra glyph, so it draws more.
        #expect(crossing.inkCoverage() > plain.inkCoverage())
    }
}
