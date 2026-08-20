package engine

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProbeAcceptsAFolderContainingBeads(t *testing.T) {
	dir := newFixtureWorkspace(t)
	result := Probe(dir)

	if !result.CanOpen {
		t.Fatalf("refused a workspace folder: %+v", result)
	}
	if result.Kind != "jsonl" {
		t.Errorf("kind is %q", result.Kind)
	}
	if filepath.Base(result.Source) != "issues.jsonl" {
		t.Errorf("source is %q", result.Source)
	}
}

func TestProbeAcceptsTheBeadsDirectoryItself(t *testing.T) {
	dir := newFixtureWorkspace(t)
	result := Probe(filepath.Join(dir, ".beads"))

	// `resolveSource` accepts a .beads directory chosen directly, so the panel
	// must offer it too.
	if !result.CanOpen {
		t.Errorf("refused a .beads directory: %+v", result)
	}
}

func TestProbeAcceptsADataFile(t *testing.T) {
	dir := newFixtureWorkspace(t)
	result := Probe(filepath.Join(dir, ".beads", "issues.jsonl"))

	if !result.CanOpen {
		t.Errorf("refused a JSONL file: %+v", result)
	}
	if result.Kind != "jsonl" {
		t.Errorf("kind is %q", result.Kind)
	}
}

func TestProbeRefusesAFolderBelowOneWithBeads(t *testing.T) {
	dir := newFixtureWorkspace(t)
	nested := filepath.Join(dir, "src", "deep")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	// Discovery does not walk upwards: bv checks `<path>/.beads` and, for a
	// linked checkout, the main repository — nothing else. So a folder below
	// the workspace root cannot be opened, and the panel must refuse it. The
	// alternative is offering a folder that then fails to load.
	result := Probe(nested)
	if result.CanOpen {
		t.Fatalf("accepted a folder below the workspace root: %+v", result)
	}

	session, err := Open(OpenConfig{Path: nested, SkipPhase2: true})
	if session != nil {
		session.Close()
	}
	if err == nil {
		t.Error("Open accepted what Probe refused")
	}
}

func TestProbeAcceptsAMultiRepoWorkspaceRoot(t *testing.T) {
	root := multiRepoWorkspace(t)
	result := Probe(root)

	// The case a naive "contains .beads" check breaks: a workspace root holds
	// .bv/workspace.yaml, and its .beads directories live in the repositories
	// below it. Requiring .beads at the chosen level makes every workspace
	// root unselectable.
	if !result.CanOpen {
		t.Fatalf("refused a multi-repository workspace root: %+v", result)
	}
	if result.Kind != "workspace" {
		t.Errorf("kind is %q, want workspace", result.Kind)
	}
	if filepath.Base(result.Source) != "workspace.yaml" {
		t.Errorf("source is %q", result.Source)
	}
}

func TestProbeRefusesAFolderWithNoBeadData(t *testing.T) {
	// A bare temp directory with nothing above it either.
	result := Probe(t.TempDir())

	if result.CanOpen {
		t.Errorf("accepted a folder with no bead data: %+v", result)
	}
	if result.Reason == "" {
		t.Error("refused without saying why")
	}
}

func TestProbeRefusesWhatDoesNotExist(t *testing.T) {
	result := Probe(filepath.Join(t.TempDir(), "nowhere"))
	if result.CanOpen {
		t.Error("accepted a path that does not exist")
	}
	if result.Reason != "does not exist" {
		t.Errorf("reason is %q", result.Reason)
	}

	if empty := Probe(""); empty.CanOpen {
		t.Error("accepted an empty path")
	}
}

func TestProbeAgreesWithOpen(t *testing.T) {
	// The whole point of routing the panel through the engine: whatever Probe
	// accepts, Open must accept, and whatever it refuses, Open must refuse.
	cases := []struct {
		name string
		path string
	}{
		{"workspace folder", newFixtureWorkspace(t)},
		{"multi-repo root", multiRepoWorkspace(t)},
		{"empty folder", t.TempDir()},
	}

	for _, c := range cases {
		probe := Probe(c.path)
		session, err := Open(OpenConfig{Path: c.path, SkipPhase2: true})
		if session != nil {
			session.Close()
		}
		opened := err == nil

		if probe.CanOpen != opened {
			t.Errorf("%s: probe says %v, Open says %v (%v)",
				c.name, probe.CanOpen, opened, err)
		}
	}
}

func TestProbeMethodOverTheSession(t *testing.T) {
	s := openFixture(t)

	var result struct {
		CanOpen bool   `json:"can_open"`
		Kind    string `json:"kind"`
	}
	result = call[struct {
		CanOpen bool   `json:"can_open"`
		Kind    string `json:"kind"`
	}](t, s, "probe", map[string]any{"path": newFixtureWorkspace(t)})

	if !result.CanOpen {
		t.Error("the session method refused a valid workspace")
	}

	if _, err := s.Call("probe", nil); err == nil {
		t.Error("expected an error when no path is given")
	}
}
