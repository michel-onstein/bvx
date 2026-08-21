package engine

import (
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
)

// staleBeadsRepo builds a repository whose beads are long untouched, with one
// recent commit that names a bead in its message but touches no bead record.
//
// That commit is the divergence: vbx correlates it explicitly, bv never sees
// it, so without narrowing the bead looks freshly worked to triage and stale
// to bv.
func staleBeadsRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)

	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "open")+"\n"+
			bead("proj-2", "Polish the docs", "open")+"\n")
	b.commit("Add initial beads", "ada")

	// Recent, code-only, and names proj-1. The clock is set relative to now so
	// the commit falls inside the 14-day staleness threshold whenever the test
	// runs, while the bead records above stay in the distant past.
	b.when = time.Now().Add(-2 * time.Hour)
	b.write("src/loader.go", "package src\n\nfunc Load() error { return nil }\n")
	b.commit("Closes proj-1: loader returns an error", "ada")

	return b.dir
}

type triageStaleness struct {
	ProjectHealth struct {
		Staleness *struct {
			StaleCount     int    `json:"stale_count"`
			StalestIssueID string `json:"stalest_issue_id"`
		} `json:"staleness"`
	} `json:"project_health"`
}

// A commit that only mentions a bead must not make it look freshly worked.
//
// Verified against bv v0.20.0 on an equivalent repository: bv reported
// stale_count 3 where vbx reported 2, because vbx credited the explicit-only
// commit as activity. Staleness is 10 % of the triage score, so this moves the
// ranking, not just one field.
func TestTriageStalenessIgnoresExplicitOnlyCommits(t *testing.T) {
	s, err := Open(OpenConfig{Path: staleBeadsRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	out := call[triageStaleness](t, s, "triage", nil)
	if out.ProjectHealth.Staleness == nil {
		t.Fatal("no staleness reported; both beads are months old")
	}
	if got := out.ProjectHealth.Staleness.StaleCount; got != 2 {
		t.Errorf("stale_count is %d, want 2: a commit that merely names proj-1 "+
			"is not activity to bv, so proj-1 must still count as stale", got)
	}
}

// The History view keeps every correlation triage drops.
func TestTriageNarrowingLeavesTheCachedReportIntact(t *testing.T) {
	s, err := Open(OpenConfig{Path: staleBeadsRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	if _, err := s.triage(); err != nil {
		t.Fatalf("triage: %v", err)
	}

	result, err := s.correlationHistory(triageHistoryLimit, false)
	if err != nil {
		t.Fatalf("correlationHistory: %v", err)
	}
	history, ok := result.report.Histories["proj-1"]
	if !ok {
		t.Fatal("proj-1 missing from the report")
	}

	// The explicit-only commit is the History view's whole point: bv's own
	// patterns require a numeric suffix and miss every br-minted id.
	var explicit int
	for _, commit := range history.Commits {
		if commit.Method == correlation.MethodExplicitID {
			explicit++
		}
	}
	if explicit == 0 {
		t.Error("triage narrowing stripped explicit correlations from the shared report")
	}
}

// The narrowing keeps exactly the commits bv derives from the bead's events.
func TestHistoryForTriageKeepsOnlyEventCommits(t *testing.T) {
	report := &correlation.HistoryReport{
		Histories: map[string]correlation.BeadHistory{
			"proj-1": {
				BeadID: "proj-1",
				Events: []correlation.BeadEvent{{BeadID: "proj-1", CommitSHA: "aaa"}},
				Commits: []correlation.CorrelatedCommit{
					{SHA: "aaa", Method: correlation.MethodCoCommitted},
					{SHA: "bbb", Method: correlation.MethodExplicitID},
				},
			},
		},
	}

	narrowed := historyForTriage(report)
	kept := narrowed.Histories["proj-1"].Commits
	if len(kept) != 1 || kept[0].SHA != "aaa" {
		t.Errorf("kept %+v, want only the commit that also produced an event", kept)
	}

	// Selecting by method label rather than by event SHA would be wrong: a
	// commit that both names a bead and edits its record is explicit here and
	// a co-commit to bv, so it has to survive.
	if original := report.Histories["proj-1"].Commits; len(original) != 2 {
		t.Errorf("narrowing mutated the shared report: %+v", original)
	}
}

func TestHistoryForTriageHandlesNoReport(t *testing.T) {
	// Not being in a git repository is the commonest case, and triage still
	// has to answer.
	if historyForTriage(nil) != nil {
		t.Error("a nil report must narrow to nil")
	}
}
