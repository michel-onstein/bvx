package engine

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// makeBeadsDB builds a store with the column shape a current beads.db has,
// including the columns bvx does not read, so the projection logic is
// exercised against a realistic schema rather than a minimal one.
func makeBeadsDB(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "beads.db")

	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	stmts := []string{
		`CREATE TABLE issues (
			id TEXT PRIMARY KEY, content_hash TEXT, title TEXT, description TEXT,
			design TEXT, acceptance_criteria TEXT, notes TEXT, status TEXT,
			priority INTEGER, issue_type TEXT, assignee TEXT, owner TEXT,
			estimated_minutes INTEGER, created_at DATETIME, created_by TEXT,
			updated_at DATETIME, closed_at DATETIME, due_at DATETIME,
			external_ref TEXT, source_repo TEXT, deleted_at DATETIME,
			compaction_level INTEGER, original_size INTEGER)`,
		`CREATE TABLE dependencies (
			issue_id TEXT, depends_on_id TEXT, type TEXT,
			created_at DATETIME, created_by TEXT)`,
		`CREATE TABLE labels (issue_id TEXT, label TEXT)`,
		`CREATE TABLE comments (
			id TEXT, issue_id TEXT, author TEXT, text TEXT, created_at DATETIME)`,

		`INSERT INTO issues (id,title,description,status,priority,issue_type,assignee,
			estimated_minutes,created_at,updated_at)
		 VALUES ('s-1','First','desc one','open',1,'task','michel',60,
			'2026-01-01T00:00:00Z','2026-02-01T00:00:00Z')`,
		`INSERT INTO issues (id,title,status,priority,issue_type,created_at,updated_at)
		 VALUES ('s-2','Second','closed',0,'bug',
			'2026-01-02T00:00:00Z','2026-02-02T00:00:00Z')`,
		// A soft-deleted row that must not load.
		`INSERT INTO issues (id,title,status,issue_type,deleted_at)
		 VALUES ('s-gone','Deleted','open','task','2026-03-01T00:00:00Z')`,

		`INSERT INTO dependencies (issue_id,depends_on_id,type)
		 VALUES ('s-1','s-2','blocks')`,
		// A legacy row with no type: must still count as blocking.
		`INSERT INTO dependencies (issue_id,depends_on_id,type) VALUES ('s-1','s-2','')`,
		// A dangling target must not crash the load.
		`INSERT INTO dependencies (issue_id,depends_on_id,type)
		 VALUES ('s-1','s-missing','blocks')`,

		`INSERT INTO labels (issue_id,label) VALUES ('s-1','core')`,
		`INSERT INTO labels (issue_id,label) VALUES ('s-1','infra')`,
		`INSERT INTO comments (id,issue_id,author,text,created_at)
		 VALUES ('c1','s-1','michel','a comment','2026-01-05T00:00:00Z')`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("exec %q: %v", s, err)
		}
	}
	return path
}

func TestLoadSQLite(t *testing.T) {
	path := makeBeadsDB(t, t.TempDir())

	issues, err := LoadSQLite(path)
	if err != nil {
		t.Fatalf("LoadSQLite: %v", err)
	}

	if len(issues) != 2 {
		t.Fatalf("got %d issues, want 2 (the deleted row must be excluded)", len(issues))
	}

	byID := map[string]int{}
	for i, it := range issues {
		byID[it.ID] = i
	}
	if _, gone := byID["s-gone"]; gone {
		t.Error("soft-deleted issue was loaded")
	}

	first := issues[byID["s-1"]]
	if first.Title != "First" || first.Description != "desc one" {
		t.Errorf("text fields wrong: %+v", first)
	}
	if first.Assignee != "michel" {
		t.Errorf("assignee = %q", first.Assignee)
	}
	if first.Priority != 1 {
		t.Errorf("priority = %d, want 1", first.Priority)
	}
	if first.EstimatedMinutes == nil || *first.EstimatedMinutes != 60 {
		t.Errorf("estimated_minutes not read")
	}
	if first.CreatedAt.IsZero() || first.UpdatedAt.IsZero() {
		t.Errorf("timestamps not parsed: %v / %v", first.CreatedAt, first.UpdatedAt)
	}
	if len(first.Labels) != 2 {
		t.Errorf("labels = %v, want 2", first.Labels)
	}
	if len(first.Comments) != 1 || first.Comments[0].Text != "a comment" {
		t.Errorf("comments not loaded: %+v", first.Comments)
	}
	if len(first.Dependencies) != 3 {
		t.Errorf("dependencies = %d, want 3 (including the dangling one)", len(first.Dependencies))
	}

	// The empty-typed dependency must still block, matching bv's rule.
	blocking := 0
	for _, d := range first.Dependencies {
		if d.Type.IsBlocking() {
			blocking++
		}
	}
	if blocking != 3 {
		t.Errorf("%d blocking deps, want 3 (empty type blocks)", blocking)
	}
}

func TestLoadSQLiteMissingFile(t *testing.T) {
	if _, err := LoadSQLite(filepath.Join(t.TempDir(), "nope.db")); err == nil {
		t.Error("expected an error for a missing database")
	}
}

func TestSessionOpensSQLiteWorkspace(t *testing.T) {
	// An empty issues.jsonl next to a populated beads.db is the normal shape
	// in bd-managed repos; discovery must not stop at the empty JSONL.
	dir := t.TempDir()
	beads := filepath.Join(dir, ".beads")
	if err := os.MkdirAll(beads, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(beads, "issues.jsonl"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	makeBeadsDB(t, beads)

	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()

	raw, err := s.Call("info", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(raw); !contains(got, `"kind":"sqlite"`) {
		t.Errorf("expected the sqlite source to be chosen, got %s", got)
	}
	if got := string(raw); !contains(got, `"issue_count":2`) {
		t.Errorf("expected 2 issues, got %s", got)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) &&
		(haystack == needle || len(needle) == 0 || indexOf(haystack, needle) >= 0)
}

func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}
