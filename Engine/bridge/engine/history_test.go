package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// The correlation tests run against a real repository built here rather than
// a fixture, because the whole point of the object-store path is that it reads
// git's own storage. A fixture would test the parser and nothing else.

type repoBuilder struct {
	t    *testing.T
	dir  string
	repo *git.Repository
	tree *git.Worktree
	when time.Time
}

func newRepo(t *testing.T) *repoBuilder {
	t.Helper()
	dir := t.TempDir()
	repo, err := git.PlainInit(dir, false)
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	tree, err := repo.Worktree()
	if err != nil {
		t.Fatalf("worktree: %v", err)
	}
	return &repoBuilder{
		t:    t,
		dir:  dir,
		repo: repo,
		tree: tree,
		when: time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC),
	}
}

// write puts a file in the working tree, creating parents.
func (b *repoBuilder) write(rel, content string) {
	b.t.Helper()
	full := filepath.Join(b.dir, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		b.t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		b.t.Fatal(err)
	}
	if _, err := b.tree.Add(rel); err != nil {
		b.t.Fatalf("add %s: %v", rel, err)
	}
}

// commit records the staged files. Each commit advances the clock an hour, so
// the history has a real ordering to reason about.
func (b *repoBuilder) commit(message, author string) string {
	b.t.Helper()
	b.when = b.when.Add(time.Hour)
	hash, err := b.tree.Commit(message, &git.CommitOptions{
		Author: &object.Signature{
			Name:  author,
			Email: author + "@example.com",
			When:  b.when,
		},
	})
	if err != nil {
		b.t.Fatalf("commit %q: %v", message, err)
	}
	return hash.String()
}

// bead renders one JSONL record.
func bead(id, title, status string) string {
	return `{"id":"` + id + `","title":"` + title + `","status":"` + status +
		`","issue_type":"task","priority":1,"created_at":"2026-01-01T00:00:00Z",` +
		`"updated_at":"2026-01-02T00:00:00Z","labels":["core"]}`
}

// historyRepo builds a repository whose history exercises every attribution
// path: a created bead, a claimed one, an explicit "Closes" reference, a
// co-committed change, and a commit belonging to no bead at all.
func historyRepo(t *testing.T) string {
	t.Helper()
	b := newRepo(t)

	// 1. Two beads appear.
	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "open")+"\n"+
			bead("proj-2", "Polish the docs", "open")+"\n")
	b.commit("Add initial beads", "ada")

	// 2. proj-1 is claimed alongside real code — a co-commit.
	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "in_progress")+"\n"+
			bead("proj-2", "Polish the docs", "open")+"\n")
	b.write("src/loader.go", "package src\n\nfunc Load() {}\n")
	b.commit("Start the loader rewrite", "ada")

	// 3. A code-only commit naming the bead explicitly.
	b.write("src/loader.go", "package src\n\nfunc Load() error { return nil }\n")
	b.commit("Closes proj-1: loader returns an error", "ada")

	// 4. A code commit that mentions nothing and changes no bead: an orphan.
	b.write("src/unrelated.go", "package src\n\nvar X = 1\n")
	b.commit("Tweak an unrelated helper", "grace")

	// 5. proj-1 is finally marked closed.
	b.write(".beads/issues.jsonl",
		bead("proj-1", "Rewrite the loader", "closed")+"\n"+
			bead("proj-2", "Polish the docs", "open")+"\n")
	b.commit("Mark the loader rewrite done", "ada")

	return b.dir
}

func openHistorySession(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: historyRepo(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

type historyPayloadShape struct {
	GitRange    string              `json:"git_range"`
	DataHash    string              `json:"data_hash"`
	CommitIndex map[string][]string `json:"commit_index"`
	Stats       struct {
		TotalBeads         int            `json:"total_beads"`
		BeadsWithCommits   int            `json:"beads_with_commits"`
		TotalCommits       int            `json:"total_commits"`
		UniqueAuthors      int            `json:"unique_authors"`
		AvgCommitsPerBead  float64        `json:"avg_commits_per_bead"`
		MethodDistribution map[string]int `json:"method_distribution"`
	} `json:"stats"`
	Histories map[string]struct {
		BeadID string `json:"bead_id"`
		Title  string `json:"title"`
		Status string `json:"status"`
		Events []struct {
			EventType string `json:"event_type"`
			CommitSHA string `json:"commit_sha"`
			Author    string `json:"author"`
		} `json:"events"`
		Commits []struct {
			SHA        string  `json:"sha"`
			ShortSHA   string  `json:"short_sha"`
			Message    string  `json:"message"`
			Method     string  `json:"method"`
			Confidence float64 `json:"confidence"`
			Reason     string  `json:"reason"`
			Files      []struct {
				Path       string `json:"path"`
				Action     string `json:"action"`
				Insertions int    `json:"insertions"`
			} `json:"files"`
		} `json:"commits"`
		CycleTime *struct {
			CreateToClose *int64 `json:"create_to_close"`
		} `json:"cycle_time"`
	} `json:"histories"`
}

func TestHistoryReadsTheObjectStoreWithoutGit(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", nil)

	if report.Stats.TotalCommits != 5 {
		t.Errorf("walked %d commits, want 5", report.Stats.TotalCommits)
	}
	if report.Stats.UniqueAuthors != 2 {
		t.Errorf("found %d authors, want 2", report.Stats.UniqueAuthors)
	}
	if report.DataHash == "" {
		t.Error("report carries no data hash")
	}

	one, ok := report.Histories["proj-1"]
	if !ok {
		t.Fatalf("no history for proj-1, got %v", keysOf(report.Histories))
	}

	// The lifecycle is read out of the JSONL blob at each commit: created,
	// claimed, closed — in that order.
	var events []string
	for _, e := range one.Events {
		events = append(events, e.EventType)
	}
	want := []string{"created", "claimed", "closed"}
	if len(events) != len(want) {
		t.Fatalf("events %v, want %v", events, want)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event %d is %q, want %q", i, events[i], want[i])
		}
	}

	// A bead that was created and closed has a cycle time.
	if one.CycleTime == nil || one.CycleTime.CreateToClose == nil {
		t.Error("proj-1 closed but reports no create-to-close cycle time")
	}

	// proj-2 never moved, so it has no events and no commits — but it is
	// still in the report, because "no history" is a fact worth stating.
	two, ok := report.Histories["proj-2"]
	if !ok {
		t.Fatal("proj-2 is missing from the report")
	}
	if len(two.Commits) != 0 {
		t.Errorf("proj-2 picked up %d commits", len(two.Commits))
	}
}

func TestHistoryAttributesCommitsWithConfidence(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", nil)
	one := report.Histories["proj-1"]

	if len(one.Commits) < 2 {
		t.Fatalf("proj-1 linked %d commits, want at least 2", len(one.Commits))
	}

	methods := map[string]float64{}
	for _, commit := range one.Commits {
		methods[commit.Method] = commit.Confidence
	}

	explicit, hasExplicit := methods["explicit_id"]
	if !hasExplicit {
		t.Fatalf("no explicit_id link; methods were %v", methods)
	}
	// "Closes proj-1" is bv's strongest intent signal: 0.90 base + 0.05.
	if explicit < 0.94 || explicit > 0.96 {
		t.Errorf("explicit confidence %v, want ~0.95", explicit)
	}

	co, hasCo := methods["co_committed"]
	if !hasCo {
		t.Fatalf("no co_committed link; methods were %v", methods)
	}
	if co < 0.85 {
		t.Errorf("co-commit confidence %v is below bv's floor of 0.85", co)
	}

	// Confidence is carried at full precision, never rounded to a bucket.
	for _, commit := range one.Commits {
		if commit.Confidence <= 0 || commit.Confidence > 1 {
			t.Errorf("commit %s has confidence %v", commit.ShortSHA, commit.Confidence)
		}
	}

	// Highest confidence first, so the inspector's first row is the best link.
	for i := 1; i < len(one.Commits); i++ {
		if one.Commits[i-1].Confidence < one.Commits[i].Confidence {
			t.Errorf("commits are not ordered by confidence: %v", one.Commits)
		}
	}
}

func TestHistoryExcludesBookkeepingFromCodeFiles(t *testing.T) {
	s := openHistorySession(t)
	report := call[historyPayloadShape](t, s, "history", nil)

	for _, commit := range report.Histories["proj-1"].Commits {
		for _, file := range commit.Files {
			if file.Path == ".beads/issues.jsonl" {
				t.Errorf("commit %s attributes the beads file as code", commit.ShortSHA)
			}
		}
	}

	// And the code files it does report carry real line counts, not zeros.
	sawInsertions := false
	for _, commit := range report.Histories["proj-1"].Commits {
		for _, file := range commit.Files {
			if file.Insertions > 0 {
				sawInsertions = true
			}
		}
	}
	if !sawInsertions {
		t.Error("no line counts were computed for any changed file")
	}
}

func TestHistoryForOneBead(t *testing.T) {
	s := openHistorySession(t)

	var scoped struct {
		GitRange string `json:"git_range"`
		History  struct {
			BeadID string `json:"bead_id"`
			Title  string `json:"title"`
		} `json:"history"`
	}
	scoped = call[struct {
		GitRange string `json:"git_range"`
		History  struct {
			BeadID string `json:"bead_id"`
			Title  string `json:"title"`
		} `json:"history"`
	}](t, s, "history", map[string]any{"id": "proj-1"})

	if scoped.History.BeadID != "proj-1" {
		t.Errorf("scoped history returned %q", scoped.History.BeadID)
	}
	if scoped.History.Title != "Rewrite the loader" {
		t.Errorf("scoped history title %q", scoped.History.Title)
	}
}

type causalityShape struct {
	Chain struct {
		BeadID     string `json:"bead_id"`
		IsComplete bool   `json:"is_complete"`
		Events     []struct {
			Type        string `json:"type"`
			Description string `json:"description"`
		} `json:"events"`
	} `json:"chain"`
	Insights struct {
		CommitCount int    `json:"commit_count"`
		Summary     string `json:"summary"`
	} `json:"insights"`
}

func TestCausalityChain(t *testing.T) {
	s := openHistorySession(t)
	result := call[causalityShape](t, s, "causality", map[string]any{"id": "proj-1"})

	if result.Chain.BeadID != "proj-1" {
		t.Errorf("chain is for %q", result.Chain.BeadID)
	}
	if len(result.Chain.Events) == 0 {
		t.Error("chain has no events")
	}
	// The bead was created and closed, so its chain is complete.
	if !result.Chain.IsComplete {
		t.Error("a created-and-closed bead reports an incomplete chain")
	}
}

func TestCausalityRequiresAKnownBead(t *testing.T) {
	s := openHistorySession(t)
	if _, err := s.Call("causality", []byte(`{"id":"nope-9"}`)); err == nil {
		t.Error("expected an error for an unknown bead")
	}
	if _, err := s.Call("causality", nil); err == nil {
		t.Error("expected an error when no id is given")
	}
}

func TestFileBeadsAndHotspots(t *testing.T) {
	s := openHistorySession(t)

	var lookup struct {
		FilePath   string `json:"file_path"`
		TotalBeads int    `json:"total_beads"`
		OpenBeads  []struct {
			BeadID string `json:"bead_id"`
		} `json:"open_beads"`
		ClosedBeads []struct {
			BeadID string `json:"bead_id"`
		} `json:"closed_beads"`
	}
	lookup = call[struct {
		FilePath   string `json:"file_path"`
		TotalBeads int    `json:"total_beads"`
		OpenBeads  []struct {
			BeadID string `json:"bead_id"`
		} `json:"open_beads"`
		ClosedBeads []struct {
			BeadID string `json:"bead_id"`
		} `json:"closed_beads"`
	}](t, s, "file_beads", map[string]any{"path": "src/loader.go"})

	if lookup.TotalBeads == 0 {
		t.Errorf("src/loader.go maps to no beads: %+v", lookup)
	}

	var hotspots struct {
		Hotspots []struct {
			FilePath   string `json:"file_path"`
			TotalBeads int    `json:"total_beads"`
		} `json:"hotspots"`
		Stats struct {
			TotalFiles int `json:"total_files"`
		} `json:"stats"`
	}
	hotspots = call[struct {
		Hotspots []struct {
			FilePath   string `json:"file_path"`
			TotalBeads int    `json:"total_beads"`
		} `json:"hotspots"`
		Stats struct {
			TotalFiles int `json:"total_files"`
		} `json:"stats"`
	}](t, s, "file_hotspots", nil)

	if hotspots.Stats.TotalFiles == 0 {
		t.Error("the file index is empty")
	}
	found := false
	for _, h := range hotspots.Hotspots {
		if h.FilePath == "src/loader.go" {
			found = true
		}
	}
	if !found {
		t.Errorf("src/loader.go is not a hotspot: %+v", hotspots.Hotspots)
	}
}

type orphanShape struct {
	Stats struct {
		TotalCommits    int     `json:"total_commits"`
		CorrelatedCount int     `json:"correlated_count"`
		OrphanCount     int     `json:"orphan_count"`
		OrphanRatio     float64 `json:"orphan_ratio"`
	} `json:"stats"`
	Candidates []struct {
		ShortSHA       string   `json:"short_sha"`
		Message        string   `json:"message"`
		Author         string   `json:"author"`
		Files          []string `json:"files"`
		SuspicionScore int      `json:"suspicion_score"`
		ProbableBeads  []struct {
			BeadID     string   `json:"bead_id"`
			Confidence int      `json:"confidence"`
			Reasons    []string `json:"reasons"`
		} `json:"probable_beads"`
		Signals []struct {
			Signal string `json:"signal"`
			Weight int    `json:"weight"`
		} `json:"signals"`
	} `json:"candidates"`
}

func TestOrphanDetection(t *testing.T) {
	s := openHistorySession(t)
	report := call[orphanShape](t, s, "orphans", nil)

	// The unrelated helper commit belongs to no bead and changed code, so it
	// is exactly one orphan.
	if report.Stats.OrphanCount != 1 {
		t.Fatalf("found %d orphans, want 1: %+v", report.Stats.OrphanCount, report.Candidates)
	}
	candidate := report.Candidates[0]
	if candidate.Author != "grace" {
		t.Errorf("orphan author is %q, want grace", candidate.Author)
	}
	if len(candidate.Files) == 0 {
		t.Error("orphan reports no files")
	}

	// A commit that only rewrites the JSONL is bookkeeping, not lost work,
	// and must not be reported as an orphan.
	for _, c := range report.Candidates {
		if c.Message == "Mark the loader rewrite done" {
			t.Error("a bookkeeping-only commit was reported as an orphan")
		}
	}
}

func TestImpactNetworkAndRelatedWork(t *testing.T) {
	s := openHistorySession(t)

	var network struct {
		Stats struct {
			TotalNodes int `json:"total_nodes"`
		} `json:"stats"`
	}
	network = call[struct {
		Stats struct {
			TotalNodes int `json:"total_nodes"`
		} `json:"stats"`
	}](t, s, "impact_network", nil)

	if network.Stats.TotalNodes == 0 {
		t.Error("the impact network has no nodes")
	}

	var related struct {
		TargetBeadID string `json:"target_bead_id"`
		TotalRelated int    `json:"total_related"`
	}
	related = call[struct {
		TargetBeadID string `json:"target_bead_id"`
		TotalRelated int    `json:"total_related"`
	}](t, s, "related", map[string]any{"id": "proj-1"})

	if related.TargetBeadID != "proj-1" {
		t.Errorf("related work targeted %q", related.TargetBeadID)
	}
}

func TestHistoryIsCachedAndInvalidatedWhenBeadsChange(t *testing.T) {
	dir := historyRepo(t)
	s, err := Open(OpenConfig{Path: dir, SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	first := call[historyPayloadShape](t, s, "history", nil)
	second := call[historyPayloadShape](t, s, "history", nil)
	if first.GitRange != second.GitRange {
		t.Errorf("cached report changed between calls: %q vs %q", first.GitRange, second.GitRange)
	}

	// A reload that changes nothing must *keep* the cache. Walking the object
	// store is the expensive part of this whole subsystem, and re-walking it
	// on every filesystem event is what makes live watching unaffordable.
	if _, err := s.Call("reload", nil); err != nil {
		t.Fatalf("reload: %v", err)
	}
	s.historyMu.Lock()
	cached := s.history
	s.historyMu.Unlock()
	if cached == nil {
		t.Error("an unchanged reload threw away the cached report")
	}

	// A reload that really changes the bead set must drop it: every
	// attribution was computed against the old set.
	path := filepath.Join(dir, ".beads", "issues.jsonl")
	existing, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	added := string(existing) + bead("proj-3", "Something new", "open") + "\n"
	if err := os.WriteFile(path, []byte(added), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := s.Call("reload", nil); err != nil {
		t.Fatalf("reload after change: %v", err)
	}
	s.historyMu.Lock()
	cached = s.history
	s.historyMu.Unlock()
	if cached != nil {
		t.Error("a changed reload left a stale correlation report in place")
	}

	// And the fresh report knows about the new bead.
	refreshed := call[historyPayloadShape](t, s, "history", nil)
	if _, ok := refreshed.Histories["proj-3"]; !ok {
		t.Error("the rebuilt report does not mention the newly added bead")
	}
}

type feedbackShape struct {
	SHA          string  `json:"sha"`
	BeadID       string  `json:"bead_id"`
	Type         string  `json:"type"`
	OriginalConf float64 `json:"original_conf"`
	Stats        struct {
		TotalFeedback int     `json:"total_feedback"`
		Confirmed     int     `json:"confirmed"`
		Rejected      int     `json:"rejected"`
		AccuracyRate  float64 `json:"accuracy_rate"`
	} `json:"stats"`
}

func TestRejectingALinkRemovesItAndFreesTheCommit(t *testing.T) {
	s := openHistorySession(t)

	before := call[historyPayloadShape](t, s, "history", nil)
	linked := before.Histories["proj-1"].Commits
	if len(linked) == 0 {
		t.Fatal("nothing to reject")
	}
	target := linked[0]

	result := call[feedbackShape](t, s, "correlation_reject",
		map[string]any{"sha": target.SHA, "bead_id": "proj-1", "reason": "wrong bead"})
	if result.Type != "reject" {
		t.Errorf("verdict recorded as %q", result.Type)
	}
	// The verdict records what the engine believed at the time.
	if result.OriginalConf != target.Confidence {
		t.Errorf("recorded confidence %v, engine said %v", result.OriginalConf, target.Confidence)
	}
	if result.Stats.Rejected != 1 {
		t.Errorf("stats report %d rejections", result.Stats.Rejected)
	}

	after := call[historyPayloadShape](t, s, "history", nil)
	for _, commit := range after.Histories["proj-1"].Commits {
		if commit.SHA == target.SHA {
			t.Error("a rejected link is still attributed to the bead")
		}
	}

	// The commit index is derived, so it has to be rebuilt: a rejected link
	// left in the index would keep the commit out of the orphan list while
	// belonging to no bead at all.
	if ids := after.CommitIndex[target.SHA]; len(ids) > 0 {
		for _, id := range ids {
			if id == "proj-1" {
				t.Error("the commit index still points the rejected commit at proj-1")
			}
		}
	}
}

func TestConfirmingALinkRaisesItToItsMethodCeiling(t *testing.T) {
	s := openHistorySession(t)

	before := call[historyPayloadShape](t, s, "history", nil)
	var target struct {
		SHA        string
		Method     string
		Confidence float64
	}
	for _, commit := range before.Histories["proj-1"].Commits {
		if commit.Method == "co_committed" {
			target.SHA, target.Method, target.Confidence =
				commit.SHA, commit.Method, commit.Confidence
		}
	}
	if target.SHA == "" {
		t.Fatal("no co-committed link to confirm")
	}

	call[feedbackShape](t, s, "correlation_confirm",
		map[string]any{"sha": target.SHA, "bead_id": "proj-1", "reason": "correct"})

	after := call[historyPayloadShape](t, s, "history", nil)
	found := false
	for _, commit := range after.Histories["proj-1"].Commits {
		if commit.SHA != target.SHA {
			continue
		}
		found = true
		// bv's ceiling for co_committed is 0.99. Confirming raises the link to
		// the top of its method's band, not past it: the band is what the
		// method's confidence means.
		if commit.Confidence != 0.99 {
			t.Errorf("confirmed link sits at %v, want 0.99", commit.Confidence)
		}
		if commit.Confidence <= target.Confidence {
			t.Errorf("confirming did not raise confidence (%v -> %v)",
				target.Confidence, commit.Confidence)
		}
	}
	if !found {
		t.Error("the confirmed link disappeared")
	}
}

func TestFeedbackRequiresBothIdentifiers(t *testing.T) {
	s := openHistorySession(t)
	for _, req := range []string{``, `{}`, `{"sha":"abc"}`, `{"bead_id":"proj-1"}`} {
		if _, err := s.Call("correlation_confirm", []byte(req)); err == nil {
			t.Errorf("expected an error for request %q", req)
		}
	}
}

func TestHistoryOutsideARepositoryIsAnError(t *testing.T) {
	// The fixture workspace is a bare temp directory with no .git.
	s := openFixture(t)
	if _, err := s.Call("history", nil); err == nil {
		t.Error("expected an error when the workspace is not in a git repository")
	}
}

func keysOf[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
