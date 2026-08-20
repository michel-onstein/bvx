package engine

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// writeClosedOnlyWorkspace builds a workspace with nothing left to do.
func writeClosedOnlyWorkspace(dir string) error {
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		return err
	}
	content := `{"id":"a","title":"Done","status":"closed","issue_type":"task","priority":1}` + "\n"
	return os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(content), 0o644)
}

func TestSuggestReportsHygieneProblems(t *testing.T) {
	s := openFixture(t)

	var out struct {
		DataHash string `json:"data_hash"`
		Filters  struct {
			Type string `json:"type"`
		} `json:"filters"`
		Suggestions struct {
			Suggestions []struct {
				Type       string  `json:"type"`
				TargetBead string  `json:"target_bead"`
				Confidence float64 `json:"confidence"`
			} `json:"suggestions"`
			Stats struct {
				Total int `json:"total"`
			} `json:"stats"`
		} `json:"suggestions"`
	}
	out = call[struct {
		DataHash string `json:"data_hash"`
		Filters  struct {
			Type string `json:"type"`
		} `json:"filters"`
		Suggestions struct {
			Suggestions []struct {
				Type       string  `json:"type"`
				TargetBead string  `json:"target_bead"`
				Confidence float64 `json:"confidence"`
			} `json:"suggestions"`
			Stats struct {
				Total int `json:"total"`
			} `json:"stats"`
		} `json:"suggestions"`
	}](t, s, "suggest", nil)

	if out.DataHash == "" {
		t.Error("no data hash in the envelope")
	}
	// The nesting is bv's: a `suggestions` key holding another `suggestions`
	// array. Flattening it would break every caller written against bv.
	if out.Suggestions.Stats.Total != len(out.Suggestions.Suggestions) {
		t.Errorf("stats say %d, list has %d",
			out.Suggestions.Stats.Total, len(out.Suggestions.Suggestions))
	}
}

func TestSuggestRejectsAnUnknownType(t *testing.T) {
	s := openFixture(t)
	if _, err := s.Call("suggest", []byte(`{"type":"vibes"}`)); err == nil {
		t.Error("expected an error for an unknown suggestion type")
	}
	// The recognised spellings, singular and plural, are all accepted.
	for _, kind := range []string{
		"duplicate", "duplicates", "dependency", "dependencies",
		"label", "labels", "cycle", "cycles",
	} {
		if _, err := s.Call("suggest", []byte(`{"type":"`+kind+`"}`)); err != nil {
			t.Errorf("type %q was rejected: %v", kind, err)
		}
	}
}

func TestNextGatesOnClaimSafety(t *testing.T) {
	s := openFixture(t)

	var out struct {
		Actionable   bool   `json:"actionable"`
		ID           string `json:"id"`
		ClaimCommand string `json:"claim_command"`
		Message      string `json:"message"`
		Degraded     []struct {
			Code     string   `json:"code"`
			Severity string   `json:"severity"`
			Reasons  []string `json:"reasons"`
		} `json:"degraded"`
	}
	out = call[struct {
		Actionable   bool   `json:"actionable"`
		ID           string `json:"id"`
		ClaimCommand string `json:"claim_command"`
		Message      string `json:"message"`
		Degraded     []struct {
			Code     string   `json:"code"`
			Severity string   `json:"severity"`
			Reasons  []string `json:"reasons"`
		} `json:"degraded"`
	}](t, s, "next", nil)

	if !out.Actionable {
		t.Fatalf("nothing claimable in a fixture with two ready beads: %+v", out)
	}
	// Only c and d have nothing blocking them.
	if out.ID != "c" && out.ID != "d" {
		t.Errorf("offered %q, which is blocked", out.ID)
	}
	// The command is emitted only alongside a claimable pick, so a caller
	// cannot run it against a bead it should not touch.
	if out.ClaimCommand != "br update "+out.ID+" --status=in_progress" {
		t.Errorf("claim command is %q", out.ClaimCommand)
	}
}

func TestClaimBlockersNameEveryReason(t *testing.T) {
	byID := map[string]model.Issue{
		"blocked": {
			ID: "blocked", Status: model.StatusOpen, IssueType: model.TypeTask,
			Dependencies: []*model.Dependency{
				{IssueID: "blocked", DependsOnID: "open-one", Type: model.DepBlocks},
			},
		},
		"open-one": {ID: "open-one", Status: model.StatusOpen},
		"assigned": {ID: "assigned", Status: model.StatusOpen, Assignee: "ada"},
		"epic":     {ID: "epic", Status: model.StatusOpen, IssueType: model.TypeEpic},
		"closed":   {ID: "closed", Status: model.StatusClosed},
		"clean":    {ID: "clean", Status: model.StatusOpen, IssueType: model.TypeTask},
	}

	cases := map[string]string{
		"blocked":  "is blocked by",
		"assigned": "already assigned",
		"epic":     "is an epic",
		"closed":   "status is",
		"missing":  "absent from loaded Beads records",
	}
	for id, fragment := range cases {
		reasons := claimBlockers(id, byID)
		if len(reasons) == 0 {
			t.Errorf("%s was reported claimable", id)
			continue
		}
		found := false
		for _, reason := range reasons {
			if containsSubstring(reason, fragment) {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: reasons %v do not mention %q", id, reasons, fragment)
		}
	}

	if reasons := claimBlockers("clean", byID); len(reasons) != 0 {
		t.Errorf("a clean bead reported %v", reasons)
	}
}

func TestPriorityFiltersAndCounts(t *testing.T) {
	s := openFixture(t)

	type shape struct {
		Recommendations []struct {
			IssueID    string  `json:"issue_id"`
			Confidence float64 `json:"confidence"`
		} `json:"recommendations"`
		Filters struct {
			MaxResults int `json:"max_results"`
		} `json:"filters"`
		Summary struct {
			TotalIssues     int `json:"total_issues"`
			Recommendations int `json:"recommendations"`
			HighConfidence  int `json:"high_confidence"`
		} `json:"summary"`
	}

	all := call[shape](t, s, "priority", nil)
	if all.Filters.MaxResults != 10 {
		t.Errorf("default max results is %d, want 10", all.Filters.MaxResults)
	}
	// The total describes the workspace, not the filtered list.
	if all.Summary.TotalIssues != 5 {
		t.Errorf("summary reports %d issues, want 5", all.Summary.TotalIssues)
	}
	if all.Summary.Recommendations != len(all.Recommendations) {
		t.Errorf("summary says %d recommendations, list has %d",
			all.Summary.Recommendations, len(all.Recommendations))
	}

	limited := call[shape](t, s, "priority", map[string]any{"max_results": 1})
	if len(limited.Recommendations) > 1 {
		t.Errorf("max_results=1 returned %d", len(limited.Recommendations))
	}
	// High confidence is counted after truncation, so it describes what came
	// back rather than what was considered.
	if limited.Summary.HighConfidence > len(limited.Recommendations) {
		t.Errorf("high confidence %d exceeds the returned %d",
			limited.Summary.HighConfidence, len(limited.Recommendations))
	}
}

func TestInsightsCarriesFullStats(t *testing.T) {
	s, err := Open(OpenConfig{Path: newFixtureWorkspace(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	var out struct {
		DataHash  string `json:"data_hash"`
		FullStats struct {
			PageRank          map[string]float64 `json:"pagerank"`
			CriticalPathScore map[string]float64 `json:"critical_path_score"`
			CoreNumber        map[string]int     `json:"core_number"`
			Articulation      []string           `json:"articulation_points"`
		} `json:"full_stats"`
	}
	out = call[struct {
		DataHash  string `json:"data_hash"`
		FullStats struct {
			PageRank          map[string]float64 `json:"pagerank"`
			CriticalPathScore map[string]float64 `json:"critical_path_score"`
			CoreNumber        map[string]int     `json:"core_number"`
			Articulation      []string           `json:"articulation_points"`
		} `json:"full_stats"`
	}](t, s, "insights", nil)

	if out.DataHash == "" {
		t.Error("no data hash")
	}
	if len(out.FullStats.PageRank) == 0 {
		t.Error("no PageRank in full_stats")
	}
	// The key names differ from the accessor names; that is bv's choice and
	// a caller written against bv depends on it.
	if out.FullStats.Articulation == nil {
		t.Error("articulation_points came back null rather than a list")
	}
}

func TestLimitMapsKeepTheHighestValues(t *testing.T) {
	values := map[string]float64{"a": 1, "b": 5, "c": 3, "d": 5}
	limited := limitFloatMap(values, 2)
	if len(limited) != 2 {
		t.Fatalf("kept %d entries", len(limited))
	}
	// Ties break on key, so two runs over identical data agree — which the
	// parity harness depends on.
	if _, ok := limited["b"]; !ok {
		t.Errorf("dropped a highest value: %v", limited)
	}
	if _, ok := limited["d"]; !ok {
		t.Errorf("tie was not broken on key: %v", limited)
	}

	// Under the limit, the map passes straight through.
	if got := limitFloatMap(values, 10); len(got) != 4 {
		t.Errorf("a map under the limit was trimmed to %d", len(got))
	}
}

func TestGraphExportFormats(t *testing.T) {
	s := openFixture(t)
	for _, format := range []string{"json", "dot", "mermaid", "nonsense"} {
		var out struct {
			Format string `json:"format"`
		}
		out = call[struct {
			Format string `json:"format"`
		}](t, s, "graph_export", map[string]any{"format": format})

		want := format
		if format == "nonsense" {
			// Anything unrecognised falls back to JSON, as bv does.
			want = "json"
		}
		if out.Format != want {
			t.Errorf("format %q produced %q, want %q", format, out.Format, want)
		}
	}
}

func TestFileImpactRequiresFiles(t *testing.T) {
	s := openFixture(t)
	for _, req := range [][]byte{nil, []byte(`{}`), []byte(`{"files":[]}`)} {
		if _, err := s.Call("file_impact", req); err == nil {
			t.Errorf("expected an error for %q", req)
		}
	}
}

func TestTriageReportsItsHistoryStatus(t *testing.T) {
	// The fixture workspace is a bare temp directory with no git repository,
	// so the history walk cannot run. Triage must still answer, and must say
	// that the staleness signal is absent rather than low.
	s := openFixture(t)

	var out struct {
		Meta struct {
			HistoryStatus string `json:"history_status"`
		} `json:"meta"`
		Recommendations []struct {
			ID string `json:"id"`
		} `json:"recommendations"`
	}
	out = call[struct {
		Meta struct {
			HistoryStatus string `json:"history_status"`
		} `json:"meta"`
		Recommendations []struct {
			ID string `json:"id"`
		} `json:"recommendations"`
	}](t, s, "triage", nil)

	if out.Meta.HistoryStatus != "error" {
		t.Errorf("history status is %q, want error outside a repository",
			out.Meta.HistoryStatus)
	}
	if len(out.Recommendations) == 0 {
		t.Error("triage produced nothing without history")
	}
}

func TestTriageSkipsHistoryWhenNothingIsOpen(t *testing.T) {
	dir := t.TempDir()
	if err := writeClosedOnlyWorkspace(dir); err != nil {
		t.Fatal(err)
	}
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	var out struct {
		Meta struct {
			HistoryStatus string `json:"history_status"`
		} `json:"meta"`
	}
	out = call[struct {
		Meta struct {
			HistoryStatus string `json:"history_status"`
		} `json:"meta"`
	}](t, s, "triage", nil)

	// Paying for a commit walk to rank an empty queue is pure cost.
	if out.Meta.HistoryStatus != "skipped" {
		t.Errorf("history status is %q, want skipped", out.Meta.HistoryStatus)
	}
}

func TestRobotNowHonoursSourceDateEpoch(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	if got := robotNow().Unix(); got != 1788000000 {
		t.Errorf("robotNow() = %d, want the pinned epoch", got)
	}

	// An unparseable value falls back to the real clock rather than the Unix
	// epoch, which would make every bead look infinitely stale.
	t.Setenv("SOURCE_DATE_EPOCH", "not-a-number")
	if robotNow().Year() < 2020 {
		t.Error("an unparseable epoch was treated as 1970")
	}

	t.Setenv("SOURCE_DATE_EPOCH", "")
	if robotNow().Year() < 2020 {
		t.Error("an empty epoch was treated as 1970")
	}
}

func TestTriageIsDeterministicUnderAPinnedClock(t *testing.T) {
	t.Setenv("SOURCE_DATE_EPOCH", "1788000000")
	s := openFixture(t)

	type shape struct {
		Recommendations []struct {
			ID        string `json:"id"`
			Breakdown struct {
				StalenessNorm float64 `json:"staleness_norm"`
			} `json:"breakdown"`
		} `json:"recommendations"`
	}

	first := call[shape](t, s, "triage", nil)
	second := call[shape](t, s, "triage", nil)

	// Staleness is measured from "now". Without the pin these differ in the
	// sixth decimal between two calls, which is what made the parity harness
	// intermittently fail.
	if len(first.Recommendations) == 0 {
		t.Fatal("no recommendations")
	}
	for i := range first.Recommendations {
		if first.Recommendations[i].Breakdown.StalenessNorm !=
			second.Recommendations[i].Breakdown.StalenessNorm {
			t.Error("staleness moved between calls under a pinned clock")
		}
	}
}

func containsSubstring(haystack, needle string) bool {
	return len(needle) == 0 || indexOf(haystack, needle) >= 0
}
