package engine

import (
	"os"
	"path/filepath"
	"testing"
)

type alertsShape struct {
	HasBaseline bool `json:"has_baseline"`
	Alerts      []struct {
		Type     string   `json:"type"`
		Severity string   `json:"severity"`
		Message  string   `json:"message"`
		IssueID  string   `json:"issue_id"`
		Label    string   `json:"label"`
		Details  []string `json:"details"`
	} `json:"alerts"`
	Summary struct {
		Total    int `json:"total"`
		Critical int `json:"critical"`
		Warning  int `json:"warning"`
		Info     int `json:"info"`
	} `json:"summary"`
}

type baselineShape struct {
	Exists      bool   `json:"exists"`
	Path        string `json:"path"`
	Description string `json:"description"`
	Summary     string `json:"summary"`
	Stats       struct {
		NodeCount       int `json:"node_count"`
		EdgeCount       int `json:"edge_count"`
		OpenCount       int `json:"open_count"`
		ClosedCount     int `json:"closed_count"`
		ActionableCount int `json:"actionable_count"`
	} `json:"stats"`
}

type driftShape struct {
	HasDrift bool `json:"has_drift"`
	ExitCode int  `json:"exit_code"`
	Summary  struct {
		Critical int `json:"critical"`
		Warning  int `json:"warning"`
		Info     int `json:"info"`
	} `json:"summary"`
}

func TestAlertsWorkWithoutABaseline(t *testing.T) {
	s := openFixture(t)
	result := call[alertsShape](t, s, "alerts", nil)

	// No baseline yet, so the delta checks have nothing to compare — but the
	// checks that read the issue list still run. That is the whole reason bv
	// compares the current stats against themselves rather than bailing out.
	if result.HasBaseline {
		t.Error("reported a baseline in a fresh workspace")
	}
	if result.Summary.Total != len(result.Alerts) {
		t.Errorf("summary total %d but %d alerts", result.Summary.Total, len(result.Alerts))
	}
	if result.Summary.Critical+result.Summary.Warning+result.Summary.Info != result.Summary.Total {
		t.Error("severity counts do not add up to the total")
	}
}

func TestBaselineRoundTrip(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	before := call[baselineShape](t, s, "baseline_info", nil)
	if before.Exists {
		t.Fatal("a fresh workspace already has a baseline")
	}
	// Having no baseline is the normal starting state, not an error.
	if before.Path == "" {
		t.Error("no baseline path was reported")
	}

	saved := call[baselineShape](t, s, "baseline_save",
		map[string]any{"description": "before the refactor"})
	if saved.Path == "" {
		t.Fatal("save reported no path")
	}
	if _, err := os.Stat(saved.Path); err != nil {
		t.Fatalf("baseline was not written: %v", err)
	}
	if filepath.Base(saved.Path) != "baseline.json" {
		t.Errorf("baseline written to %s", saved.Path)
	}
	// The fixture's five beads, four of which are open or in progress.
	if saved.Stats.NodeCount != 5 {
		t.Errorf("baseline records %d nodes, want 5", saved.Stats.NodeCount)
	}
	if saved.Stats.ActionableCount == 0 {
		t.Error("baseline records no actionable beads")
	}

	after := call[baselineShape](t, s, "baseline_info", nil)
	if !after.Exists {
		t.Fatal("the saved baseline is not visible")
	}
	if after.Description != "before the refactor" {
		t.Errorf("description came back as %q", after.Description)
	}
}

func TestDriftAgainstAnUnchangedBaselineIsClean(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	call[baselineShape](t, s, "baseline_save", map[string]any{"description": "now"})
	alerts := call[alertsShape](t, s, "alerts", nil)
	if !alerts.HasBaseline {
		t.Fatal("the saved baseline is not being compared against")
	}

	// Nothing changed between saving and checking, so no *delta* alert can
	// fire — those are the ones that compare the two baselines.
	deltaTypes := map[string]bool{
		"new_cycle": true, "pagerank_change": true, "density_growth": true,
		"node_count_change": true, "edge_count_change": true,
		"blocked_increase": true, "actionable_change": true,
	}
	for _, alert := range alerts.Alerts {
		if deltaTypes[alert.Type] {
			t.Errorf("delta alert %q fired against an identical baseline: %s",
				alert.Type, alert.Message)
		}
	}

	// Issue-derived checks do still run, which is the point of comparing the
	// current stats against themselves rather than bailing out. This fixture's
	// beads are dated January, so staleness fires and is entirely correct.
	sawIssueDerived := false
	for _, alert := range alerts.Alerts {
		if alert.Type == "stale_issue" {
			sawIssueDerived = true
			if alert.IssueID == "" {
				t.Error("a stale-issue alert names no bead")
			}
		}
	}
	if !sawIssueDerived {
		t.Error("no issue-derived alert fired for beads months out of date")
	}

	// The exit code is bv's: critical -> 1, warning -> 2, otherwise 0.
	result := call[driftShape](t, s, "drift", nil)
	switch {
	case result.Summary.Critical > 0 && result.ExitCode != 1:
		t.Errorf("critical drift reported exit code %d, want 1", result.ExitCode)
	case result.Summary.Critical == 0 && result.Summary.Warning > 0 && result.ExitCode != 2:
		t.Errorf("warning drift reported exit code %d, want 2", result.ExitCode)
	case result.Summary.Critical == 0 && result.Summary.Warning == 0 && result.ExitCode != 0:
		t.Errorf("clean drift reported exit code %d, want 0", result.ExitCode)
	}
}

func TestDriftWithoutABaselineIsAnError(t *testing.T) {
	s := openFixture(t)
	// Alerts degrade gracefully without a baseline; an explicit drift *check*
	// cannot, because there is nothing to check against.
	if _, err := s.Call("drift", nil); err == nil {
		t.Error("expected an error when no baseline is saved")
	}
}

func TestAlertFiltersNarrowTheList(t *testing.T) {
	s := openFixture(t)
	all := call[alertsShape](t, s, "alerts", nil)
	if len(all.Alerts) == 0 {
		t.Skip("this fixture produces no alerts to filter")
	}

	severity := all.Alerts[0].Severity
	filtered := call[alertsShape](t, s, "alerts", map[string]any{"severity": severity})
	for _, alert := range filtered.Alerts {
		if alert.Severity != severity {
			t.Errorf("severity filter %q let through %q", severity, alert.Severity)
		}
	}
	if len(filtered.Alerts) > len(all.Alerts) {
		t.Error("filtering produced more alerts than it started with")
	}

	// A severity nothing carries filters everything out.
	none := call[alertsShape](t, s, "alerts", map[string]any{"severity": "nonexistent"})
	if len(none.Alerts) != 0 {
		t.Errorf("an unmatched severity still returned %d alerts", len(none.Alerts))
	}
	if none.Summary.Total != 0 {
		t.Error("the summary was not recounted after filtering")
	}
}

func TestTopMetricItemsAreDeterministic(t *testing.T) {
	// Equal values must break on id, or two baselines over identical data
	// differ purely because Go randomises map order.
	values := map[string]float64{"c": 1, "a": 1, "b": 1, "d": 2}
	first := topMetricItems(values, 10)
	for i := 0; i < 20; i++ {
		again := topMetricItems(values, 10)
		for j := range first {
			if first[j] != again[j] {
				t.Fatalf("ordering is unstable: %+v vs %+v", first, again)
			}
		}
	}
	if first[0].ID != "d" {
		t.Errorf("highest value did not sort first: %+v", first)
	}
	if first[1].ID != "a" || first[2].ID != "b" || first[3].ID != "c" {
		t.Errorf("ties did not break on id: %+v", first)
	}
}

func TestTopMetricItemsRespectsTheLimit(t *testing.T) {
	values := map[string]float64{}
	for i := 0; i < 50; i++ {
		values[string(rune('a'+i%26))+string(rune('a'+i/26))] = float64(i)
	}
	if got := len(topMetricItems(values, 10)); got != 10 {
		t.Errorf("limit of 10 returned %d items", got)
	}
	if topMetricItems(map[string]float64{}, 10) != nil {
		t.Error("an empty map should produce no items at all")
	}
}
