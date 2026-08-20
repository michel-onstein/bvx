import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

/// The static site export wizard.
@MainActor
@Suite("Export wizard")
struct ExportWizardTests {

    @Test("Building a bundle writes a real site")
    func buildsBundle() async throws {
        let store = await Fixture.loadedStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.buildSite(
            into: directory, title: "Demo", interactiveGraph: true, githubWorkflow: false)

        #expect(store.siteError == nil, "\(store.siteError ?? "")")
        #expect(store.siteBundle.isBuilt)
        #expect(store.siteBundle.issueCount == store.issues.count)
        #expect(store.siteBundle.totalBytes > 0)
        #expect(!store.siteBundle.files.isEmpty)

        // The bundle is on disk, not merely reported.
        #expect(FileManager.default.fileExists(atPath: directory.path))

        await store.close()
    }

    @Test("Files are listed largest first")
    func filesOrderedBySize() async throws {
        let store = await Fixture.loadedStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.buildSite(
            into: directory, title: "Demo", interactiveGraph: false, githubWorkflow: false)
        guard store.siteBundle.isBuilt else {
            await store.close()
            return
        }

        // A host's size limit is what a deploy actually fails on, so the file
        // about to blow it should be the first one shown.
        let sizes = store.siteBundle.files.map(\.bytes)
        #expect(sizes == sizes.sorted(by: >))
        #expect(store.siteBundle.largestFiles.count <= 6)

        await store.close()
    }

    @Test("Resetting clears every trace of a previous run")
    func resetClearsState() async throws {
        let store = await Fixture.loadedStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.buildSite(
            into: directory, title: "Demo", interactiveGraph: false, githubWorkflow: false)
        store.resetSiteExport()

        #expect(!store.siteBundle.isBuilt)
        #expect(!store.sitePreview.isRunning)
        #expect(!store.siteDeployment.isDeployed)
        #expect(store.siteError == nil)

        await store.close()
    }

    @Test("Deploying without a stored token says so instead of failing obscurely")
    func deployNeedsAToken() async throws {
        // The test process has no stored token, which is exactly the state a
        // first-time user is in.
        Keychain.delete(.githubToken)

        let store = await Fixture.loadedStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.buildSite(
            into: directory, title: "Demo", interactiveGraph: false, githubWorkflow: false)
        await store.deploySite(repo: "someone/site", isPrivate: false)

        #expect(!store.siteDeployment.isDeployed)
        #expect(store.siteError?.contains("token") == true)

        await store.close()
    }

    @Test("Cloudflare reports what it cannot do, with the command to run")
    func cloudflareInstructions() async throws {
        let store = await Fixture.loadedStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bvx-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.buildSite(
            into: directory, title: "Demo", interactiveGraph: false, githubWorkflow: false)
        let instructions = await store.cloudflareInstructions(project: "demo")

        // Saying plainly that this path is unavailable, and how to do it by
        // hand, beats a half-working reimplementation of wrangler's upload.
        #expect(!instructions.supported)
        #expect(!instructions.reason.isEmpty)
        #expect(instructions.command.contains("wrangler"))

        await store.close()
    }

    // MARK: - Keychain

    @Test("A credential round-trips through the Keychain")
    func keychainRoundTrip() {
        // Scoped to a credential the app really uses, then removed, so the
        // test leaves the login keychain as it found it.
        defer { Keychain.delete(.cloudflareToken) }

        #expect(Keychain.write(.cloudflareToken, value: "secret-value"))
        #expect(Keychain.read(.cloudflareToken) == "secret-value")
        #expect(Keychain.has(.cloudflareToken))

        // Writing again replaces rather than duplicating.
        #expect(Keychain.write(.cloudflareToken, value: "second-value"))
        #expect(Keychain.read(.cloudflareToken) == "second-value")

        #expect(Keychain.delete(.cloudflareToken))
        #expect(Keychain.read(.cloudflareToken) == nil)
        #expect(!Keychain.has(.cloudflareToken))
    }

    @Test("Writing an empty value removes the credential")
    func emptyValueDeletes() {
        defer { Keychain.delete(.cloudflareToken) }

        Keychain.write(.cloudflareToken, value: "something")
        // Clearing the field in the UI has to really remove the credential,
        // not store an empty secret that reads back as present.
        Keychain.write(.cloudflareToken, value: "   ")
        #expect(Keychain.read(.cloudflareToken) == nil)
    }

    @Test("Deleting a credential that was never stored is not an error")
    func deleteMissingIsFine() {
        #expect(Keychain.delete(.cloudflareToken))
    }

    // MARK: - Decoding

    @Test("A bundle payload decodes with its warnings")
    func decodesBundle() throws {
        let json = """
            {"output_dir":"/tmp/site","title":"Demo","issue_count":18,
             "total_bytes":1048576,
             "files":[{"path":"beads.db","bytes":1000000},{"path":"index.html","bytes":48576}],
             "warnings":["no embedded viewer assets"],
             "suggested_repo":"site","suggested_project":"site"}
            """
        let bundle = try JSONDecoder().decode(SiteBundle.self, from: Data(json.utf8))

        #expect(bundle.isBuilt)
        #expect(bundle.issueCount == 18)
        #expect(bundle.files.count == 2)
        // The bundle exists; a warning says what is incomplete about it.
        #expect(bundle.warnings == ["no embedded viewer assets"])
        #expect(bundle.formattedSize.contains("MB"))
    }

    @Test("An empty bundle is not built")
    func emptyBundle() {
        #expect(!SiteBundle.empty.isBuilt)
        #expect(!SitePreview.empty.isRunning)
        #expect(!SiteDeployment.empty.isDeployed)
    }

    @Test("A deployment decodes its Pages URL and warnings")
    func decodesDeployment() throws {
        let json = """
            {"repo":"me/site","branch":"gh-pages","created_repo":true,
             "remote":"https://github.com/me/site.git",
             "pages_url":"https://me.github.io/site/",
             "warnings":["enabling Pages: already configured"],
             "verify_hint":"Pages can take a minute."}
            """
        let deployment = try JSONDecoder().decode(SiteDeployment.self, from: Data(json.utf8))

        #expect(deployment.isDeployed)
        #expect(deployment.createdRepo)
        #expect(deployment.pagesURL == "https://me.github.io/site/")
        // A push that succeeded with a Pages hiccup is still a deployment;
        // reporting it as a failure would invite a pointless retry.
        #expect(deployment.warnings.count == 1)
    }

    // MARK: - Rendering

    @Test("The wizard renders its first step")
    func rendersWizard() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            ExportWizard().environmentObject(store),
            name: "export-wizard",
            size: CGSize(width: 620, height: 560)
        )
        #expect(result.inkCoverage() > 0.01, "wizard drew nothing")
        await store.close()
    }
}
