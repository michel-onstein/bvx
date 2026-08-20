import Foundation
import Testing

@testable import BVXCore

/// Decoding of the correlation payloads.
///
/// The JSON here is the engine's real wire shape, snake_case keys and all. A
/// mismatch would not throw — the models default every field — so it would
/// silently render an empty History view, which is exactly the failure these
/// lock out.
private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(json.utf8))
}

private let reportJSON = """
    {
      "generated_at": "2026-08-20T10:00:00Z",
      "data_hash": "abc123",
      "git_range": "1111111..9999999",
      "latest_commit_sha": "9999999abcdef",
      "stats": {
        "total_beads": 3,
        "beads_with_commits": 2,
        "total_commits": 12,
        "unique_authors": 2,
        "avg_commits_per_bead": 2.5,
        "method_distribution": {"explicit_id": 3, "co_committed": 2}
      },
      "histories": {
        "proj-1": {
          "bead_id": "proj-1",
          "title": "Rewrite the loader",
          "status": "closed",
          "last_author": "ada",
          "events": [
            {
              "bead_id": "proj-1",
              "event_type": "created",
              "timestamp": "2026-08-01T10:00:00Z",
              "commit_sha": "1111111",
              "commit_message": "Add initial beads",
              "author": "ada"
            },
            {
              "bead_id": "proj-1",
              "event_type": "closed",
              "timestamp": "2026-08-05T10:00:00Z",
              "commit_sha": "3333333",
              "commit_message": "Done",
              "author": "ada"
            }
          ],
          "milestones": {
            "created": {
              "bead_id": "proj-1", "event_type": "created",
              "timestamp": "2026-08-01T10:00:00Z", "commit_sha": "1111111",
              "commit_message": "Add initial beads", "author": "ada"
            }
          },
          "commits": [
            {
              "sha": "2222222aaaaaaa",
              "short_sha": "2222222",
              "message": "Closes proj-1: loader returns an error\\n\\nBody here.",
              "author": "ada",
              "author_email": "ada@example.com",
              "timestamp": "2026-08-03T10:00:00Z",
              "files": [
                {"path": "src/loader.go", "action": "M", "insertions": 12, "deletions": 3}
              ],
              "method": "explicit_id",
              "confidence": 0.95,
              "reason": "commit message references proj-1 (closes)"
            }
          ],
          "cycle_time": {"create_to_close": 345600000000000}
        }
      },
      "commit_index": {"2222222aaaaaaa": ["proj-1"]}
    }
    """

@Test("A history report decodes with its stats, events and commits")
func decodesHistoryReport() throws {
    let report = try decode(HistoryReport.self, reportJSON)

    #expect(report.dataHash == "abc123")
    #expect(report.gitRange == "1111111..9999999")
    #expect(report.stats.totalCommits == 12)
    #expect(report.stats.beadsWithCommits == 2)
    #expect(report.stats.methodDistribution["explicit_id"] == 3)

    let history = try #require(report.histories["proj-1"])
    #expect(history.title == "Rewrite the loader")
    #expect(history.events.map(\.eventType) == [.created, .closed])
    #expect(history.milestones?.created?.commitSHA == "1111111")
    #expect(report.commitIndex["2222222aaaaaaa"] == ["proj-1"])
}

@Test("Confidence crosses the bridge unrounded")
func confidenceIsExact() throws {
    let report = try decode(HistoryReport.self, reportJSON)
    let commit = try #require(report.histories["proj-1"]?.commits.first)

    // The engine owns this number. Rounding it here would quietly disagree
    // with what `bv` reports for the same link.
    #expect(commit.confidence == 0.95)
    #expect(commit.confidencePercent == "95%")
    #expect(commit.confidenceLevel == "very high")
    #expect(commit.method == .explicitID)
}

@Test(
    "Confidence bands match bv's own thresholds",
    arguments: [
        (0.95, "very high"), (0.90, "very high"),
        (0.80, "high"), (0.75, "high"),
        (0.60, "moderate"), (0.50, "moderate"),
        (0.40, "low"), (0.30, "low"),
        (0.10, "very low"),
    ])
func confidenceBands(value: Double, expected: String) {
    let commit = CorrelatedCommit(sha: "x", confidence: value)
    #expect(commit.confidenceLevel == expected, "\(value) should be \(expected)")
}

@Test("A commit's subject is its first line")
func commitSubject() throws {
    let report = try decode(HistoryReport.self, reportJSON)
    let commit = try #require(report.histories["proj-1"]?.commits.first)
    #expect(commit.subject == "Closes proj-1: loader returns an error")
}

@Test("File changes keep their line counts")
func fileChanges() throws {
    let report = try decode(HistoryReport.self, reportJSON)
    let file = try #require(report.histories["proj-1"]?.commits.first?.files.first)
    #expect(file.path == "src/loader.go")
    #expect(file.insertions == 12)
    #expect(file.deletions == 3)
    #expect(file.actionName == "modified")
}

@Test("A cycle time formats, and an absent one stays absent")
func cycleTime() throws {
    let report = try decode(HistoryReport.self, reportJSON)
    let cycle = try #require(report.histories["proj-1"]?.cycleTime)

    // Four days in nanoseconds.
    #expect(CycleTime.describe(cycle.createToClose) == "4d")
    // A bead that never closed has no cycle time, and "0s" would claim it
    // took no time at all.
    #expect(CycleTime.describe(nil) == nil)
    #expect(CycleTime.describe(0) == nil)
}

@Test("An unrecognised correlation method decodes rather than throwing")
func openCorrelationMethod() throws {
    let json = """
        {"sha":"a","method":"future_method","confidence":0.5}
        """
    let commit = try decode(CorrelatedCommit.self, json)
    #expect(commit.method == .unknown("future_method"))
    // A method bv adds later must not make the whole report undecodable —
    // that would drop every link, not just the new one.
    #expect(commit.method.displayName == "future_method")
}

@Test("An unrecognised event type decodes rather than throwing")
func openEventType() throws {
    let json = """
        {"bead_id":"a","event_type":"archived","commit_sha":"x"}
        """
    let event = try decode(BeadEvent.self, json)
    #expect(event.eventType == .unknown("archived"))
}

@Test("An empty report is valid and empty, not a decode failure")
func emptyReport() throws {
    let report = try decode(HistoryReport.self, "{}")
    #expect(report.histories.isEmpty)
    #expect(report.stats.totalCommits == 0)
    #expect(report.allCommits.isEmpty)
}

@Test("All commits are ordered newest first")
func allCommitsOrdered() throws {
    let report = try decode(HistoryReport.self, reportJSON)
    let all = report.allCommits
    #expect(all.count == 1)
    #expect(all.first?.bead == "proj-1")
}

// MARK: - Orphans

@Test("An orphan report decodes with its signals and probable beads")
func decodesOrphanReport() throws {
    let json = """
        {
          "git_range": "1111111..9999999",
          "data_hash": "abc123",
          "stats": {
            "total_commits": 12, "correlated_count": 9, "orphan_count": 3,
            "orphan_ratio": 0.25, "avg_suspicion_score": 42.5
          },
          "candidates": [
            {
              "sha": "4444444bbbbbbb",
              "short_sha": "4444444",
              "message": "Tweak an unrelated helper",
              "author": "grace",
              "author_email": "grace@example.com",
              "timestamp": "2026-08-04T10:00:00Z",
              "files": ["src/unrelated.go"],
              "suspicion_score": 55,
              "probable_beads": [
                {
                  "bead_id": "proj-1", "bead_title": "Rewrite the loader",
                  "bead_status": "closed", "confidence": 55,
                  "reasons": ["1 file(s) also touched by this bead"]
                }
              ],
              "signals": [{"signal": "files", "details": "1 shared file(s)", "weight": 40}]
            }
          ]
        }
        """
    let report = try decode(OrphanReport.self, json)

    #expect(report.stats.orphanCount == 3)
    #expect(report.stats.orphanRatio == 0.25)

    let candidate = try #require(report.candidates.first)
    #expect(candidate.author == "grace")
    #expect(candidate.suspicionScore == 55)
    #expect(candidate.probableBeads.first?.beadID == "proj-1")
    #expect(candidate.signals.first?.weight == 40)
    #expect(candidate.subject == "Tweak an unrelated helper")
}

// MARK: - Causality and related work

@Test("A causality result decodes its chain and insights")
func decodesCausality() throws {
    let json = """
        {
          "chain": {
            "bead_id": "proj-1", "title": "Rewrite the loader", "status": "closed",
            "edge_count": 3, "total_time": 345600000000000, "is_complete": true,
            "events": [
              {"id": 0, "type": "created", "timestamp": "2026-08-01T10:00:00Z",
               "description": "Bead created"},
              {"id": 1, "type": "blocked", "timestamp": "2026-08-02T10:00:00Z",
               "description": "Blocked by proj-9", "blocker_id": "proj-9",
               "caused_by_id": 0, "enables_ids": [2]}
            ]
          },
          "insights": {
            "total_duration": 345600000000000,
            "blocked_duration": 86400000000000,
            "blocked_percentage": 25.0,
            "commit_count": 4,
            "summary": "Spent a quarter of its life blocked.",
            "recommendations": ["Unblock proj-9 earlier"],
            "blocked_periods": [
              {"start_time": "2026-08-02T10:00:00Z", "end_time": "2026-08-03T10:00:00Z",
               "duration": 86400000000000, "blocker_id": "proj-9"}
            ]
          }
        }
        """
    let result = try decode(CausalityResult.self, json)

    let chain = try #require(result.chain)
    #expect(chain.isComplete)
    #expect(chain.events.count == 2)
    #expect(chain.events.last?.type == .blocked)
    #expect(chain.events.last?.blockerID == "proj-9")
    #expect(chain.events.last?.causedByID == 0)

    let insights = try #require(result.insights)
    #expect(insights.blockedPercentage == 25.0)
    #expect(insights.blockedPeriods.count == 1)
    #expect(insights.recommendations == ["Unblock proj-9 earlier"])

    // Blocked is the one step the timeline shades as waiting rather than work.
    #expect(CausalEventType.blocked.isWaiting)
    #expect(!CausalEventType.commit.isWaiting)
}

@Test("Related work groups only the non-empty relations")
func decodesRelatedWork() throws {
    let json = """
        {
          "target_bead_id": "proj-1",
          "target_title": "Rewrite the loader",
          "total_related": 2,
          "file_overlap": [
            {"bead_id": "proj-4", "title": "Loader tests", "status": "open",
             "relation_type": "file_overlap", "relevance": 70,
             "reason": "3 shared files", "shared_files": ["src/loader.go"]}
          ],
          "commit_overlap": [],
          "dependency_cluster": [],
          "concurrent": [
            {"bead_id": "proj-7", "title": "Docs", "status": "closed",
             "relation_type": "concurrent", "relevance": 30, "reason": "same week"}
          ]
        }
        """
    let related = try decode(RelatedWork.self, json)

    #expect(related.targetBeadID == "proj-1")
    // Empty groups are dropped so the inspector shows no empty headings.
    let names = related.groups.map(\.name)
    #expect(names == ["Shared files", "Worked on concurrently"])
    #expect(related.groups.first?.beads.first?.relevance == 70)
}

// MARK: - File-centric payloads

@Test("A file lookup separates open from closed beads")
func decodesFileLookup() throws {
    let json = """
        {
          "file_path": "src/loader.go",
          "total_beads": 2,
          "open_beads": [
            {"bead_id": "proj-4", "title": "Loader tests", "status": "open",
             "commit_shas": ["2222222"], "last_touch": "2026-08-03T10:00:00Z",
             "total_changes": 5}
          ],
          "closed_beads": [
            {"bead_id": "proj-1", "title": "Rewrite the loader", "status": "closed",
             "commit_shas": ["2222222"], "total_changes": 12}
          ]
        }
        """
    let lookup = try decode(FileBeadLookup.self, json)
    #expect(lookup.totalBeads == 2)
    #expect(lookup.openBeads.first?.beadID == "proj-4")
    #expect(lookup.closedBeads.first?.totalChanges == 12)
}

@Test("Hotspots and co-change results decode")
func decodesHotspotsAndRelations() throws {
    let hotspots = try decode(
        FileHotspots.self,
        """
        {
          "hotspots": [
            {"file_path": "src/loader.go", "total_beads": 4,
             "open_beads": 1, "closed_beads": 3}
          ],
          "stats": {"total_files": 40, "total_bead_links": 90,
                    "files_with_multiple_beads": 12}
        }
        """)
    #expect(hotspots.hotspots.first?.totalBeads == 4)
    #expect(hotspots.stats.totalFiles == 40)

    let relations = try decode(
        CoChangeResult.self,
        """
        {
          "file_path": "src/loader.go",
          "total_commits": 10,
          "threshold": 0.3,
          "related_files": [
            {"file_path": "src/loader_test.go", "co_change_count": 7,
             "total_commits": 9, "correlation": 0.7,
             "sample_commits": ["2222222"]}
          ]
        }
        """)
    #expect(relations.relatedFiles.first?.correlation == 0.7)
    #expect(relations.relatedFiles.first?.filePath == "src/loader_test.go")
}
