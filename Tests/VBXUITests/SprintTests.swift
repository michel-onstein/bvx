import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// The sprint dashboard.
///
/// The demo fixture has no sprint file, which is a real state the dashboard
/// must handle — so the empty case is tested against it, and the populated
/// case against a fixture copy with a sprint written in.
@MainActor
@Suite("Sprints")
struct SprintTests {

    /// A workspace copy carrying one sprint spanning today.
    private func sprintStore() async throws -> (ProjectStore, URL) {
        let (store, directory) = try await Fixture.writableStore()
        let ids = store.issues.prefix(6).map(\.id)
        let start = Date().addingTimeInterval(-4 * 86_400)
        let end = Date().addingTimeInterval(5 * 86_400)

        let formatter = ISO8601DateFormatter()
        let line =
            #"{"id":"s1","name":"First sprint","start_date":"#
            + "\"\(formatter.string(from: start))\","
            + #""end_date":"# + "\"\(formatter.string(from: end))\","
            + #""bead_ids":["# + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]}\n"

        let path = directory.appendingPathComponent(".beads/sprints.jsonl")
        try line.write(to: path, atomically: true, encoding: .utf8)

        // Reopen so the engine sees the sprint file.
        let reopened = ProjectStore()
        await reopened.open(path: directory.path)
        await reopened.computePhase2()
        await store.close()
        return (reopened, directory)
    }

    @Test("A workspace with no sprint file is an empty dashboard, not an error")
    func noSprintFile() async {
        let store = await Fixture.loadedStore()
        await store.loadSprints()

        #expect(store.sprints.sprints.isEmpty)
        #expect(!store.burndown.isLoaded)
        // Capacity does not need a sprint, so it still computes.
        #expect(store.capacity.openIssueCount > 0)

        await store.close()
    }

    @Test("A sprint spanning today loads its burndown")
    func burndownLoads() async throws {
        let (store, directory) = try await sprintStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        await store.loadSprints()

        #expect(store.sprints.sprints.count == 1)
        #expect(store.sprints.active?.id == "s1")
        #expect(store.burndown.isLoaded)
        #expect(store.burndown.sprintID == "s1")
        #expect(store.burndown.totalIssues > 0)

        // The days must account for each other, or the header lies.
        #expect(
            store.burndown.totalDays
                == store.burndown.elapsedDays + store.burndown.remainingDays)
        // The ideal line spans the sprint; the actual points stop at today.
        #expect(store.burndown.idealLine.count == store.burndown.totalDays + 1)
        #expect(store.burndown.dailyPoints.count <= store.burndown.elapsedDays)

        await store.close()
    }

    @Test("Every burndown point accounts for the whole sprint")
    func pointsAccountForEveryBead() async throws {
        let (store, directory) = try await sprintStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadSprints()

        for point in store.burndown.dailyPoints {
            #expect(point.remaining + point.completed == store.burndown.totalIssues)
        }
        await store.close()
    }

    // MARK: - Derived values

    @Test("Ahead-or-behind is absent before the sprint starts")
    func aheadIsAbsentBeforeStart() throws {
        // Zero elapsed days means there is no ideal to compare against, and a
        // zero would read as "exactly on plan".
        let json = """
            {"sprint_id":"s1","total_days":10,"elapsed_days":0,"remaining_days":10,
             "total_issues":10,"completed_issues":0,"remaining_issues":10,
             "ideal_line":[{"date":"2026-01-01T00:00:00Z","remaining":10}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let burndown = try decoder.decode(Burndown.self, from: Data(json.utf8))
        #expect(burndown.aheadBy == nil)
        #expect(burndown.verdict.contains("not started"))
    }

    @Test("Ahead-or-behind compares against the ideal for the elapsed day")
    func aheadCompareToIdeal() throws {
        let json = """
            {"sprint_id":"s1","total_days":4,"elapsed_days":2,"remaining_days":2,
             "total_issues":8,"completed_issues":5,"remaining_issues":3,
             "actual_burn_rate":2.5,"on_track":true,
             "ideal_line":[
               {"date":"2026-01-01T00:00:00Z","remaining":8},
               {"date":"2026-01-02T00:00:00Z","remaining":6},
               {"date":"2026-01-03T00:00:00Z","remaining":4},
               {"date":"2026-01-04T00:00:00Z","remaining":2},
               {"date":"2026-01-05T00:00:00Z","remaining":0}
             ]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let burndown = try decoder.decode(Burndown.self, from: Data(json.utf8))
        // Two days in the ideal says 6 remaining; 3 actually remain, so the
        // sprint is 3 beads ahead.
        #expect(burndown.aheadBy == 3)
        #expect(burndown.completion == 0.625)
    }

    @Test("A sprint with no progress says why, rather than claiming to be on track")
    func verdictWithNoProgress() throws {
        let json = """
            {"sprint_id":"s1","total_days":10,"elapsed_days":4,
             "total_issues":10,"completed_issues":0,"remaining_issues":10,
             "actual_burn_rate":0,"on_track":false}
            """
        let burndown = try JSONDecoder().decode(Burndown.self, from: Data(json.utf8))
        #expect(!burndown.onTrack)
        #expect(burndown.verdict.contains("no rate"))
        // And no date is projected, rather than the epoch.
        #expect(burndown.projectedComplete == nil)
    }

    @Test("A finished sprint says so")
    func verdictWhenDone() throws {
        let json = """
            {"sprint_id":"s1","total_issues":5,"completed_issues":5,
             "remaining_issues":0,"elapsed_days":3,"on_track":true}
            """
        let burndown = try JSONDecoder().decode(Burndown.self, from: Data(json.utf8))
        #expect(burndown.verdict.contains("Every bead is closed"))
        #expect(burndown.completion == 1)
    }

    @Test("An empty sprint reports no completion rather than dividing by zero")
    func emptySprint() {
        #expect(Burndown.empty.completion == 0)
        #expect(Burndown.empty.aheadBy == nil)
        #expect(!Burndown.empty.isLoaded)
    }

    // MARK: - Capacity

    @Test("More agents never make the work take longer, and never beat the chain")
    func capacityScales() async {
        let store = await Fixture.loadedStore()
        store.capacityAgents = 1
        await store.loadCapacity()
        let one = store.capacity

        store.capacityAgents = 4
        await store.loadCapacity()
        let four = store.capacity

        #expect(four.effectiveMinutes <= one.effectiveMinutes)
        // The serial chain is the floor: no number of agents beats it.
        #expect(four.effectiveMinutes >= four.serialMinutes)
        #expect(one.serialMinutes + one.parallelMinutes == one.totalMinutes)

        await store.close()
    }

    @Test("The critical path follows blocking edges and is clickable")
    func criticalPath() async {
        let store = await Fixture.loadedStore()
        await store.loadCapacity()

        for id in store.capacity.criticalPath {
            // Every step must resolve, or the links go nowhere.
            #expect(store.issuesByID[id] != nil, "\(id) is not in the workspace")
        }
        await store.close()
    }

    // MARK: - Rendering

    @Test("The sprint dashboard renders with a sprint")
    func rendersWithSprint() async throws {
        let (store, directory) = try await sprintStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.loadSprints()

        let result = try Snapshot.render(
            SprintView().environmentObject(store),
            name: "sprint-dashboard",
            size: CGSize(width: 900, height: 900)
        )
        #expect(result.inkCoverage() > 0.01, "sprint dashboard drew nothing")
        // A chart with two lines and bars has real colour variety.
        #expect(result.distinctColors() > 4)
        await store.close()
    }

    @Test("The sprint dashboard renders without one")
    func rendersWithoutSprint() async throws {
        let store = await Fixture.loadedStore()
        await store.loadSprints()

        let result = try Snapshot.render(
            SprintView().environmentObject(store),
            name: "sprint-dashboard-empty",
            size: CGSize(width: 900, height: 600)
        )
        // The capacity section still has something to say.
        #expect(result.inkCoverage() > 0.005)
        await store.close()
    }

    @Test("The sprint surface is reachable and distinctly keyed")
    func surfaceIsReachable() {
        #expect(ViewSurface.allCases.contains(.sprint))
        let terminalKeys = ViewSurface.allCases.map(\.terminalKey)
        #expect(Set(terminalKeys).count == terminalKeys.count)
        let commandKeys = ViewSurface.allCases.map(\.keyEquivalent.character)
        #expect(Set(commandKeys).count == commandKeys.count)
    }
}
