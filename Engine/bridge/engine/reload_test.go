package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type reloadPayload struct {
	IssueCount int    `json:"issue_count"`
	DataHash   string `json:"data_hash"`
	Changed    bool   `json:"changed"`
}

func TestReloadIsHashGated(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	first := call[reloadPayload](t, s, "reload", nil)
	if first.Changed {
		t.Error("reload reported a change when nothing was written")
	}

	// Rewriting byte-identical content must still hash the same: the gate is
	// content-based, not mtime-based, which is what makes leaving the watcher
	// on affordable.
	path := filepath.Join(dir, ".beads", "issues.jsonl")
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}
	same := call[reloadPayload](t, s, "reload", nil)
	if same.Changed {
		t.Error("rewriting identical content reported a change")
	}
	if same.DataHash != first.DataHash {
		t.Errorf("hash moved without a content change: %s -> %s", first.DataHash, same.DataHash)
	}
}

func TestReloadDetectsRealChanges(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	before := call[reloadPayload](t, s, "reload", nil)

	extra := fixture +
		`{"id":"f","title":"Foxtrot","status":"open","issue_type":"task","priority":1,` +
		`"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z",` +
		`"dependencies":[{"issue_id":"f","depends_on_id":"c","type":"blocks"}]}` + "\n"

	path := filepath.Join(dir, ".beads", "issues.jsonl")
	if err := os.WriteFile(path, []byte(extra), 0o644); err != nil {
		t.Fatal(err)
	}

	after := call[reloadPayload](t, s, "reload", nil)
	if !after.Changed {
		t.Fatal("reload missed an added issue")
	}
	if after.IssueCount != 6 {
		t.Errorf("issue_count = %d, want 6", after.IssueCount)
	}
	if after.DataHash == before.DataHash {
		t.Error("data hash did not move after a real change")
	}

	// The graph must reflect the new edge, not just the count.
	m := call[metricsPayload](t, s, "metrics", nil)
	if m.NodeCount != 6 {
		t.Errorf("node_count = %d, want 6", m.NodeCount)
	}
	if got := m.InDegree["c"]; got != 3 {
		t.Errorf("in_degree[c] = %d, want 3 after the new dependency", got)
	}
}

func TestComputePhase2AfterSkip(t *testing.T) {
	// A session opened with metrics skipped must still be able to compute
	// them later; otherwise the UI's "compute metrics" action is a no-op.
	s, err := Open(OpenConfig{Path: newFixtureWorkspace(t), SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	raw, err := s.Call("metrics", nil)
	if err != nil {
		t.Fatal(err)
	}
	var skipped map[string]any
	if err := json.Unmarshal(raw, &skipped); err != nil {
		t.Fatal(err)
	}
	if _, present := skipped["pagerank"]; present {
		t.Fatal("pagerank present despite skip")
	}

	full := call[metricsPayload](t, s, "compute_phase2", nil)
	if !full.Phase2Ready {
		t.Error("phase2 not ready after compute_phase2")
	}
	if len(full.PageRank) != 5 {
		t.Errorf("pagerank has %d entries after compute_phase2, want 5", len(full.PageRank))
	}
}
