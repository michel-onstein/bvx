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

    @Test("The application name is never empty, even with no bundle")
    func applicationNameHasAFallback() {
        // Named for what it checks. It used to be called "the version line
        // comes from the bundle", which is how the version came to look
        // covered while nothing asserted it at all.
        #expect(!AboutView.applicationName.isEmpty)
    }

    // MARK: - The version line
    //
    // The version travels git tag -> scripts/version.sh -> PlistBuddy -> the
    // plist -> Bundle.main -> here. Nothing used to verify the last two hops:
    // `versionLine` read `Bundle.main` directly, and in a test process
    // `Bundle.main` is SwiftPM's helper binary with no version keys at all, so
    // it returned "" in every test and the About snapshot rendered a blank row
    // where the version belongs. The stamping could have broken silently and
    // every check would still have passed.
    //
    // Taking the dictionary as a parameter is what makes the formatting
    // testable at all; the packaging suite covers the stamping hop, by
    // comparing a built bundle's plist against scripts/version.sh.

    @Test("A stamped bundle shows the marketing version and the build number")
    func versionLineIsFormatted() {
        let line = AboutView.versionLine(from: [
            "CFBundleShortVersionString": "0.0.1",
            "CFBundleVersion": "42",
        ])
        #expect(line == "Version 0.0.1 (42)")
    }

    @Test("Without a build number, the version stands alone")
    func versionLineWithoutBuild() {
        let line = AboutView.versionLine(from: ["CFBundleShortVersionString": "1.2.3"])
        #expect(line == "Version 1.2.3")
    }

    @Test("An unstamped bundle shows nothing rather than a placeholder")
    func versionLineIsAbsentNotZero() {
        // Absent, never a stand-in: `Version 0.0.0 (0)` would be a claim, and a
        // wrong one. This is the case a test process actually hits.
        #expect(AboutView.versionLine(from: nil).isEmpty)
        #expect(AboutView.versionLine(from: [:]).isEmpty)

        // A build number with no marketing version says nothing usable either.
        #expect(AboutView.versionLine(from: ["CFBundleVersion": "42"]).isEmpty)
    }

    @Test("The header still draws when the version is absent")
    func headerDrawsWithoutAVersion() throws {
        // The state every test process is in: no bundle, so no version. What
        // this rules out is the header collapsing or drawing blank when the
        // line it used to reserve a row for is gone.
        //
        // Measured over the header band alone. A whole-image figure cannot
        // answer this — the notices pane below fills most of the frame and its
        // text alone clears any threshold, so a header that vanished entirely
        // would still have passed.
        #expect(AboutView.versionLine.isEmpty, "precondition: no bundle in a test process")

        let result = try Snapshot.render(
            AboutView(),
            name: "about-window-unstamped",
            size: CGSize(width: 620, height: 560))
        let header = CGRect(x: 0, y: 0, width: 620, height: 100)
        #expect(
            result.inkCoverage(in: header) > 0.01,
            "the header drew nothing without a version line")
    }
}
