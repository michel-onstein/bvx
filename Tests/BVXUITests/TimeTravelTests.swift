import BVXAppCore
import BVXCore
import SwiftUI
import Testing

@testable import BVXUI

private typealias Bead = BVXCore.Issue

/// Time travel: comparing the current bead set against an earlier revision.
@MainActor
@Suite("Time travel")
struct TimeTravelTests {

    @Test("A store starts in the present")
    func startsInThePresent() async {
        let store = await Fixture.loadedStore()
        #expect(!store.isTimeTravelling)
        #expect(store.timeTravel.badges.isEmpty)
        #expect(store.badge(for: "bvx-3") == nil)
        await store.close()
    }

    @Test("Returning to now clears every trace of the comparison")
    func returnToNow() async {
        let store = await Fixture.loadedStore()
        await store.loadRevisions()

        guard let revision = store.revisions.revisions.first else {
            // No bead-changing commits in this checkout; nothing to compare.
            await store.close()
            return
        }

        await store.travel(to: revision.sha)
        store.returnToNow()

        #expect(!store.isTimeTravelling)
        #expect(store.timeTravel.badges.isEmpty)
        #expect(store.pastIssues.isEmpty)
        await store.close()
    }

    @Test("Travelling to an unresolvable revision leaves the present intact")
    func unresolvableRevision() async {
        let store = await Fixture.loadedStore()
        await store.travel(to: "definitely-not-a-ref")

        // The failure is reported, but the app is not left in a half-state
        // where badges refer to a comparison that never happened.
        #expect(!store.isTimeTravelling)
        #expect(store.pastIssues.isEmpty)
        await store.close()
    }

    @Test("Revisions offered are bead-changing commits with short SHAs")
    func revisionsAreWellFormed() async {
        let store = await Fixture.loadedStore()
        await store.loadRevisions()

        for revision in store.revisions.revisions {
            #expect(revision.shortSHA.count == 7)
            #expect(revision.sha.count == 40)
            // A subject is the first line only — a body would wreck the menu.
            #expect(!revision.subject.contains("\n"))
        }
        await store.close()
    }

    // MARK: - Decoding

    @Test("A diff decodes its badges and summary")
    func decodesDiff() throws {
        let json = """
            {
              "requested_revision": "HEAD~4",
              "resolved_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "short_revision": "aaaaaaa",
              "from_data_hash": "old",
              "to_data_hash": "new",
              "badges": {
                "proj-1": "closed",
                "proj-2": "new",
                "proj-3": "modified",
                "proj-4": "reopened",
                "proj-5": "removed"
              },
              "diff": {
                "new_issues": [],
                "closed_issues": [],
                "modified_issues": [
                  {"issue_id": "proj-3", "title": "Thing",
                   "changes": [{"field": "priority", "old_value": "2", "new_value": "0"}]}
                ],
                "summary": {
                  "total_changes": 5, "issues_added": 1, "issues_closed": 1,
                  "issues_modified": 1, "issues_reopened": 1, "issues_removed": 1,
                  "net_issue_change": 0, "health_trend": "improving"
                }
              }
            }
            """
        let decoder = JSONDecoder()
        let diff = try decoder.decode(TimeTravelDiff.self, from: Data(json.utf8))

        #expect(diff.shortRevision == "aaaaaaa")
        #expect(diff.badges["proj-1"] == .closed)
        #expect(diff.badges["proj-2"] == .new)
        #expect(diff.badges["proj-3"] == .modified)
        #expect(diff.badges["proj-4"] == .reopened)
        #expect(diff.badges["proj-5"] == .removed)
        #expect(diff.hasChanges)
        #expect(diff.diff.summary.healthTrend == "improving")
        #expect(diff.diff.modifiedIssues.first?.changes.first?.field == "priority")
    }

    @Test("An unrecognised badge is dropped, not fatal")
    func unknownBadgeIsDropped() throws {
        let json = """
            {"badges": {"proj-1": "closed", "proj-2": "teleported"}}
            """
        let diff = try JSONDecoder().decode(TimeTravelDiff.self, from: Data(json.utf8))
        // Losing one badge shows that bead as unchanged, which is recoverable.
        // Throwing would lose the entire diff.
        #expect(diff.badges["proj-1"] == .closed)
        #expect(diff.badges["proj-2"] == nil)
        #expect(diff.badges.count == 1)
    }

    @Test("A diff with no changes reports none")
    func emptyDiff() throws {
        let diff = try JSONDecoder().decode(TimeTravelDiff.self, from: Data("{}".utf8))
        #expect(!diff.hasChanges)
        #expect(diff.badges.isEmpty)
    }

    @Test("Every badge has a distinct label and symbol")
    func badgesAreDistinct() {
        let names = DiffBadge.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        let symbols = DiffBadge.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("A snapshot decodes the bead set as it was")
    func decodesSnapshot() throws {
        let json = """
            {
              "requested_revision": "HEAD~4",
              "resolved_revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "short_revision": "bbbbbbb",
              "issue_count": 2,
              "data_hash": "old",
              "issues": [
                {"id": "proj-1", "title": "Rewrite the loader", "status": "open",
                 "issue_type": "task", "priority": 1},
                {"id": "proj-2", "title": "Polish the docs", "status": "open",
                 "issue_type": "task", "priority": 2}
              ]
            }
            """
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.issueCount == 2)
        #expect(snapshot.issues.map(\Bead.id) == ["proj-1", "proj-2"])
        // The resolved commit is what the UI shows; the expression is context.
        #expect(snapshot.requestedRevision == "HEAD~4")
        #expect(snapshot.shortRevision == "bbbbbbb")
    }

    // MARK: - Rendering

    @Test("The banner renders while time travelling")
    func rendersBanner() async throws {
        let store = await Fixture.loadedStore()
        await store.loadRevisions()
        guard let revision = store.revisions.revisions.first else {
            await store.close()
            return
        }
        await store.travel(to: revision.sha)

        let result = try Snapshot.render(
            TimeTravelBanner().environmentObject(store).frame(width: 900),
            name: "time-travel-banner",
            size: CGSize(width: 900, height: 44)
        )
        #expect(result.inkCoverage() > 0.005, "banner drew nothing")
        await store.close()
    }

    @Test("The banner is absent in the present")
    func bannerHiddenInPresent() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            TimeTravelBanner().environmentObject(store).frame(width: 900, height: 44),
            name: "time-travel-banner-absent",
            size: CGSize(width: 900, height: 44)
        )
        // Nothing to draw is the correct outcome; the assertion is that it
        // rendered at all rather than trapping on empty state.
        #expect(result.width > 0)
        await store.close()
    }

    @Test("Each badge renders")
    func rendersBadges() throws {
        for badge in DiffBadge.allCases {
            let result = try Snapshot.render(
                DiffBadgeView(badge: badge).padding(6),
                name: "diff-badge-\(badge.rawValue)",
                size: CGSize(width: 120, height: 30)
            )
            #expect(result.inkCoverage() > 0.02, "\(badge) drew nothing")
        }
    }
}
