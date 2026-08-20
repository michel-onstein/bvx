import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

/// The interactive tutorial.
@MainActor
@Suite("Tutorial")
struct TutorialTests {

    /// A tutorial backed by its own defaults, so tests neither read nor
    /// disturb the real progress.
    private func isolated() -> (Tutorial, UserDefaults) {
        let suite = UserDefaults(suiteName: "bvx.tutorial.test.\(UUID().uuidString)")!
        return (Tutorial(defaults: suite), suite)
    }

    @Test("Every section is well formed")
    func sectionsAreWellFormed() {
        let sections = Tutorial.sections
        #expect(sections.count >= 8)

        for section in sections {
            #expect(!section.id.isEmpty)
            #expect(!section.title.isEmpty)
            #expect(!section.summary.isEmpty)
            #expect(!section.body.isEmpty)
        }
        // Ids are the persistence key, so a duplicate would make two sections
        // share one read state.
        let ids = sections.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A section teaches at most one surface")
    func surfacesAreUnique() {
        let taught = Tutorial.sections.compactMap(\.surface)
        // Two sections claiming the same surface would make "learn this view"
        // ambiguous.
        #expect(Set(taught).count == taught.count)
    }

    @Test("Progress persists and is keyed by id")
    func progressPersists() {
        let suite = UserDefaults(suiteName: "bvx.tutorial.test.\(UUID().uuidString)")!
        let first = Tutorial(defaults: suite)
        let id = Tutorial.sections[1].id

        first.markComplete(id)
        #expect(first.isComplete(id))

        // A fresh instance over the same defaults sees the same progress.
        let second = Tutorial(defaults: suite)
        #expect(second.isComplete(id))
        #expect(second.completed.count == 1)
    }

    @Test("Unknown ids in stored progress are dropped")
    func staleProgressIsDropped() {
        let suite = UserDefaults(suiteName: "bvx.tutorial.test.\(UUID().uuidString)")!
        suite.set(["welcome", "a-section-that-no-longer-exists"], forKey: "bvx.tutorial.completed")

        let tutorial = Tutorial(defaults: suite)
        // A renamed section must not inflate the progress count forever.
        #expect(tutorial.completed == ["welcome"])
        #expect(tutorial.progress < 1)
    }

    @Test("Progress runs from nothing to everything")
    func progressRange() {
        let (tutorial, _) = isolated()
        #expect(tutorial.progress == 0)

        for section in Tutorial.sections {
            tutorial.markComplete(section.id)
        }
        #expect(tutorial.progress == 1)

        tutorial.reset()
        #expect(tutorial.progress == 0)
        #expect(tutorial.completed.isEmpty)
    }

    @Test("A section can be marked unread again")
    func markIncomplete() {
        let (tutorial, _) = isolated()
        let id = Tutorial.sections[0].id

        tutorial.markComplete(id)
        tutorial.markIncomplete(id)
        #expect(!tutorial.isComplete(id))
        #expect(tutorial.completed.isEmpty)
    }

    @Test("Advancing marks the current section read and moves on")
    func advance() {
        let (tutorial, _) = isolated()
        tutorial.selection = Tutorial.sections[0].id

        tutorial.advance()

        #expect(tutorial.isComplete(Tutorial.sections[0].id))
        #expect(tutorial.selection == Tutorial.sections[1].id)
    }

    @Test("Advancing past the last section stays there")
    func advanceAtTheEnd() {
        let (tutorial, _) = isolated()
        let last = Tutorial.sections[Tutorial.sections.count - 1].id
        tutorial.selection = last

        tutorial.advance()

        // Marked read, but there is nowhere further to go.
        #expect(tutorial.isComplete(last))
        #expect(tutorial.selection == last)
    }

    @Test("A new tutorial opens at the first unread section")
    func opensAtFirstUnread() {
        let suite = UserDefaults(suiteName: "bvx.tutorial.test.\(UUID().uuidString)")!
        suite.set([Tutorial.sections[0].id], forKey: "bvx.tutorial.completed")

        let tutorial = Tutorial(defaults: suite)
        // Resuming where you left off beats starting over.
        #expect(tutorial.selection == Tutorial.sections[1].id)
    }

    @Test("Each taught surface resolves to its section")
    func sectionForSurface() {
        let (tutorial, _) = isolated()
        for section in Tutorial.sections {
            guard let surface = section.surface else { continue }
            #expect(tutorial.section(for: surface)?.id == section.id)
        }
    }

    @Test("Section bodies render as Markdown")
    func bodiesAreMarkdown() {
        // The bodies go through the same component bead descriptions use, so
        // the table and code support already built gets used rather than
        // duplicated. A body that is not detected as Markdown would render
        // its own syntax verbatim.
        for section in Tutorial.sections {
            #expect(
                MarkdownParser.looksLikeMarkdown(section.body),
                "\(section.id) would render verbatim")
        }
    }

    @Test("A section with a table parses as one")
    func tablesInBodies() {
        let withTables = Tutorial.sections.filter { $0.body.contains("|---|") }
        #expect(!withTables.isEmpty, "no section exercises the table renderer")

        for section in withTables {
            let blocks = MarkdownParser.parse(section.body)
            let hasTable = blocks.contains {
                if case .table = $0 { return true } else { return false }
            }
            #expect(hasTable, "\(section.id)'s table did not parse")
        }
    }

    @Test("The tutorial window renders")
    func rendersTutorial() throws {
        let result = try Snapshot.render(
            TutorialView(initialSection: "list"),
            name: "tutorial",
            size: CGSize(width: 860, height: 600)
        )
        #expect(result.inkCoverage() > 0.01, "tutorial drew nothing")
    }
}
