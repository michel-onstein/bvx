package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// fixture writes a small but structurally interesting bead graph:
//
//	a -> b -> c   (a blocked by b, b blocked by c)
//	d             (isolated, actionable)
//	e -> c        (shares blocker c)
//
// Only c and d are actionable; closing c unblocks b and e.
const fixture = `{"id":"a","title":"Alpha","status":"open","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["core"],"dependencies":[{"issue_id":"a","depends_on_id":"b","type":"blocks"}]}
{"id":"b","title":"Bravo","status":"open","issue_type":"bug","priority":0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["core"],"dependencies":[{"issue_id":"b","depends_on_id":"c","type":"blocks"}]}
{"id":"c","title":"Charlie","status":"open","issue_type":"task","priority":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["infra"]}
{"id":"d","title":"Delta","status":"open","issue_type":"chore","priority":3,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","labels":["docs"]}
{"id":"e","title":"Echo","status":"in_progress","issue_type":"feature","priority":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z","labels":["infra"],"dependencies":[{"issue_id":"e","depends_on_id":"c","type":"blocks"}]}
`

func newFixtureWorkspace(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func openFixture(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: newFixtureWorkspace(t)})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func call[T any](t *testing.T, s *Session, method string, req any) T {
	t.Helper()
	var raw []byte
	if req != nil {
		var err error
		raw, err = json.Marshal(req)
		if err != nil {
			t.Fatal(err)
		}
	}
	out, err := s.Call(method, raw)
	if err != nil {
		t.Fatalf("Call(%s): %v", method, err)
	}
	var v T
	if err := json.Unmarshal(out, &v); err != nil {
		t.Fatalf("decode %s: %v\npayload: %s", method, err, out)
	}
	return v
}

func TestOpenAndInfo(t *testing.T) {
	s := openFixture(t)
	info := call[infoPayload](t, s, "info", nil)

	if info.IssueCoun != 5 {
		t.Errorf("issue_count = %d, want 5", info.IssueCoun)
	}
	if info.Kind != "jsonl" {
		t.Errorf("kind = %q, want jsonl", info.Kind)
	}
	if len(info.DataHash) == 0 {
		t.Error("data_hash is empty; cache keying and parity checks depend on it")
	}
}

func TestPhase1MetricsAreImmediate(t *testing.T) {
	s := openFixture(t)
	m := call[metricsPayload](t, s, "metrics", nil)

	if m.NodeCount != 5 {
		t.Errorf("node_count = %d, want 5", m.NodeCount)
	}
	if m.EdgeCount != 3 {
		t.Errorf("edge_count = %d, want 3", m.EdgeCount)
	}
	// c is depended on by both b and e.
	if got := m.InDegree["c"]; got != 2 {
		t.Errorf("in_degree[c] = %d, want 2", got)
	}
	if got := m.OutDegree["d"]; got != 0 {
		t.Errorf("out_degree[d] = %d, want 0", got)
	}
	if len(m.TopologicalOrder) != 5 {
		t.Errorf("topological_order has %d entries, want 5", len(m.TopologicalOrder))
	}
}

func TestPhase2MetricsArriveAndAreLabelled(t *testing.T) {
	s := openFixture(t)
	m := call[metricsPayload](t, s, "wait_phase2", nil)

	if !m.Phase2Ready {
		t.Fatal("phase2_ready is false after wait_phase2")
	}
	if len(m.PageRank) != 5 {
		t.Errorf("pagerank has %d entries, want 5", len(m.PageRank))
	}
	// c is the deepest blocker, so it must carry the highest PageRank.
	for _, id := range []string{"a", "b", "d", "e"} {
		if m.PageRank["c"] <= m.PageRank[id] {
			t.Errorf("pagerank[c]=%v should exceed pagerank[%s]=%v",
				m.PageRank["c"], id, m.PageRank[id])
		}
	}
	if len(m.Status) == 0 {
		t.Error("status block missing; clients cannot distinguish timeout from zero")
	}
	if len(m.Cycles) != 0 {
		t.Errorf("unexpected cycles in an acyclic fixture: %v", m.Cycles)
	}
}

func TestPhase2MapsAbsentBeforeReady(t *testing.T) {
	// With Phase 2 skipped the maps must be absent rather than present-and-zero,
	// so the UI can render "not computed" instead of a misleading 0.0.
	s, err := Open(OpenConfig{Path: newFixtureWorkspace(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	out, err := s.Call("metrics", nil)
	if err != nil {
		t.Fatal(err)
	}
	var generic map[string]any
	if err := json.Unmarshal(out, &generic); err != nil {
		t.Fatal(err)
	}
	if _, present := generic["pagerank"]; present {
		t.Error("pagerank key present despite Phase 2 being skipped")
	}
}

func TestActionableAndPlan(t *testing.T) {
	s := openFixture(t)

	act := call[struct {
		IDs []string `json:"ids"`
	}](t, s, "actionable", nil)

	got := map[string]bool{}
	for _, id := range act.IDs {
		got[id] = true
	}
	// c has no blockers; d is isolated. a, b and e are all transitively blocked.
	if !got["c"] || !got["d"] {
		t.Errorf("actionable = %v, want to include c and d", act.IDs)
	}
	if got["a"] || got["b"] {
		t.Errorf("actionable = %v, must not include blocked issues a or b", act.IDs)
	}

	plan := call[struct {
		Tracks []struct {
			ID string `json:"id"`
		} `json:"tracks"`
	}](t, s, "plan", nil)
	if len(plan.Tracks) == 0 {
		t.Error("execution plan produced no parallel tracks")
	}
}

func TestUnblocksAndBlockerChain(t *testing.T) {
	s := openFixture(t)

	un := call[struct {
		Unblocks []string `json:"unblocks"`
	}](t, s, "unblocks", map[string]string{"id": "c"})

	got := map[string]bool{}
	for _, id := range un.Unblocks {
		got[id] = true
	}
	// Closing c makes b actionable (its only blocker) and e actionable too.
	if !got["b"] || !got["e"] {
		t.Errorf("unblocks(c) = %v, want b and e", un.Unblocks)
	}

	if _, err := s.Call("blocker_chain", []byte(`{"id":"a"}`)); err != nil {
		t.Errorf("blocker_chain(a): %v", err)
	}
}

func TestGraphEdgesAreBlockingOnly(t *testing.T) {
	s := openFixture(t)
	g := call[struct {
		Edges []graphEdge `json:"edges"`
	}](t, s, "graph", nil)

	if len(g.Edges) != 3 {
		t.Fatalf("got %d edges, want 3: %+v", len(g.Edges), g.Edges)
	}
	for _, e := range g.Edges {
		if e.From == "" || e.To == "" {
			t.Errorf("edge with empty endpoint: %+v", e)
		}
	}
}

func TestTriageAndIssuesRoundTrip(t *testing.T) {
	s := openFixture(t)

	if _, err := s.Call("triage", nil); err != nil {
		t.Errorf("triage: %v", err)
	}
	issues := call[struct {
		Issues []struct {
			ID     string   `json:"id"`
			Title  string   `json:"title"`
			Labels []string `json:"labels"`
		} `json:"issues"`
	}](t, s, "issues", nil)

	if len(issues.Issues) != 5 {
		t.Fatalf("got %d issues, want 5", len(issues.Issues))
	}
	for _, it := range issues.Issues {
		if it.ID == "" || it.Title == "" {
			t.Errorf("issue lost required fields crossing the wire: %+v", it)
		}
	}
}

func TestUnknownMethodIsAnError(t *testing.T) {
	s := openFixture(t)
	if _, err := s.Call("no_such_method", nil); err == nil {
		t.Error("expected an error for an unknown method")
	}
}

func TestMissingSourceIsAnError(t *testing.T) {
	if _, err := Open(OpenConfig{Path: t.TempDir()}); err == nil {
		t.Error("expected an error opening a directory with no .beads")
	}
}
