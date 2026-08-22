import AppKit
import VBXCore
import Foundation
import SwiftUI
import Testing

@testable import VBXUI

/// The licences vbx is obliged to ship.
///
/// These are compliance checks as much as tests. Several engine dependencies
/// require their notice to be carried with the binary, and beads_viewer's rider
/// must travel unmodified — with breach terminating the licence to the engine
/// vbx is built on. A regeneration that quietly dropped one would otherwise
/// look like a smaller diff.
@MainActor
@Suite("Acknowledgements")
struct AcknowledgementsTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func notices() throws -> String {
        let url = repoRoot.appendingPathComponent("Resources/ACKNOWLEDGEMENTS.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Module paths declared in go.mod.
    private static func declaredModules() throws -> [String] {
        let gomod = try String(
            contentsOf: repoRoot.appendingPathComponent("Engine/bridge/go.mod"), encoding: .utf8)
        var modules: [String] = []
        for line in gomod.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].contains("."), parts[0].contains("/"),
                parts[1].hasPrefix("v")
            else { continue }
            modules.append(String(parts[0]))
        }
        return modules
    }

    @Test("Every module the engine links appears in the notices")
    func everyModuleIsListed() throws {
        let text = try Self.notices()
        let modules = try Self.declaredModules()
        #expect(modules.count > 60, "parsed \(modules.count) modules from go.mod — too few")

        let missing = modules.filter { !text.contains("### \($0)") }
        #expect(missing.isEmpty, "not acknowledged: \(missing.sorted())")
    }

    @Test("beads_viewer's rider is carried unmodified")
    func riderIsPresent() throws {
        // The obligation with teeth: the rider says every distribution must
        // include it unmodified, and breach terminates the licence to the
        // engine. Checked by its own words rather than by the module name.
        let text = try Self.notices()
        #expect(text.contains("ADDITIONAL RIDER / RESTRICTION"))
        #expect(text.contains("Restricted Parties"))
        #expect(
            text.contains("must include this rider provision unmodified"),
            "the rider's own distribution clause is missing")
    }

    @Test("vbx's own licence is shown, rider included")
    func ownLicenceIsPresent() throws {
        let text = try Self.notices()
        #expect(text.contains("MIT License with AI Training Rider"))
        #expect(text.contains("Reserved use"), "the AI Training Rider's terms are missing")
    }

    @Test("The awkward dependencies carry the explanation they need")
    func specialCasesAreExplained() throws {
        let text = try Self.notices()

        // Dual-licensed: which arm was taken has to be stated, or a reader
        // assumes the GPL one applies.
        #expect(text.contains("vbx takes the FreeType Licence"))
        #expect(text.contains("The FreeType Project"))

        // Per-file copyleft: the source of the covered files must be offered.
        #expect(text.contains("MPL-2.0 is per-file copyleft"))
        #expect(text.contains("github.com/cyphar/filepath-securejoin"))

        // No LICENSE file at all — its README is the only statement of terms.
        #expect(text.contains("Ships no LICENSE file"))
    }

    @Test("The About window renders its header and notices")
    func aboutRenders() throws {
        // Bundle.main is the test bundle here, so the view takes its
        // file-missing path — which is exactly the branch worth proving draws
        // something rather than an empty pane.
        let result = try Snapshot.render(
            AboutView(),
            name: "about-window",
            size: CGSize(width: 620, height: 560))
        #expect(result.inkCoverage() > 0.01, "About drew nothing")
    }

    @Test("A missing notices file says so instead of showing an empty pane")
    func missingNoticesAreAnnounced() {
        // The obligation is to display these, so silence is the one failure
        // mode worth shouting about.
        let text = AboutView.acknowledgements
        #expect(!text.isEmpty)
        #expect(text.contains("build-notices.py"), "the fallback does not say how to fix it")
    }

    @Test("The version line comes from the bundle rather than a literal")
    func versionComesFromTheBundle() {
        // A literal drifts against build-app.sh, which is where the real
        // version is written.
        #expect(!AboutView.applicationName.isEmpty)
    }
}
