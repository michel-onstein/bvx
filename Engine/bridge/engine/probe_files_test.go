package engine

import (
	"os"
	"path/filepath"
	"testing"

	git "github.com/go-git/go-git/v5"
)

// A file is offered only when it is bead data.
//
// The regression: `resolveSource` treated every non-`.db` file as JSONL, so
// Probe answered yes for a README, a .swift file, even a binary .icns. The Open
// panel greys out what Probe refuses, so nothing among files was ever greyed
// and the choice failed later in the loader — the panel/loader disagreement
// this file exists to prevent.
func TestProbeRefusesFilesThatAreNotBeadData(t *testing.T) {
	dir := t.TempDir()

	refused := map[string]string{
		"README.md":     "# notes\n",
		"main.swift":    "print(\"hi\")\n",
		"icon.icns":     "\x00\x00\x00\x00binary",
		"CHANGELOG":     "no extension at all\n",
		"issues.json":   "{\"id\":\"a-1\"}\n",
		"issues.jsonl2": "{\"id\":\"a-1\"}\n",
	}
	for name, body := range refused {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		result := Probe(path)
		if result.CanOpen {
			t.Errorf("Probe(%s) reports openable; the panel would offer it", name)
		}
		if result.Reason == "" {
			t.Errorf("Probe(%s) refused without a reason to show", name)
		}
	}
}

// The files that genuinely are bead data must stay openable, or the fix above
// has simply switched the panel off for files.
func TestProbeStillAcceptsBeadDataFiles(t *testing.T) {
	dir := t.TempDir()

	for _, name := range []string{"issues.jsonl", "beads.db", "beads.sqlite", "beads.sqlite3"} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
			t.Fatal(err)
		}
		if result := Probe(path); !result.CanOpen {
			t.Errorf("Probe(%s) refused bead data: %s", name, result.Reason)
		}
	}
}

// An empty issues.jsonl is still the file the user means.
//
// Pins the decision not to sniff content: the workspace path documents a
// fallback from an empty JSONL to beads.db, and a content check here would
// refuse the file before that fallback could run.
func TestProbeAcceptsAnEmptyJSONLByExtension(t *testing.T) {
	path := filepath.Join(t.TempDir(), "issues.jsonl")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if result := Probe(path); !result.CanOpen {
		t.Errorf("an empty issues.jsonl was refused: %s", result.Reason)
	}
}

// Inside a *git* repository, a folder below the root resolves to the
// repository's own .beads.
//
// This is the rule that was mis-documented. Discovery does not walk arbitrary
// parents — `TestProbeRefusesAFolderBelowOneWithBeads` covers the plain
// directory case and still refuses — but it does resolve a git repository to
// its root, so `Sources/deep` in a checkout is openable while the same layout
// outside git is not. The pair of tests is the documentation: neither one alone
// says which factor decides it.
func TestProbeAcceptsAFolderInsideAGitRepository(t *testing.T) {
	root := newFixtureWorkspace(t)
	if _, err := git.PlainInit(root, false); err != nil {
		t.Fatalf("init: %v", err)
	}
	nested := filepath.Join(root, "Sources", "deep")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	result := Probe(nested)
	if !result.CanOpen {
		t.Fatalf("a folder inside the checkout was refused: %s", result.Reason)
	}
	// Both sides resolved before comparing: on macOS a temp directory is
	// behind a /private symlink, and discovery reports the resolved path.
	want, err := filepath.EvalSymlinks(filepath.Join(root, ".beads", "issues.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := filepath.EvalSymlinks(result.Source)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("resolved to %s, want the repository's own data at %s", got, want)
	}
}
