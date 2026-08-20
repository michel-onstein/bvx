package engine

import (
	"testing"
)

type revisionsShape struct {
	Count     int `json:"count"`
	Revisions []struct {
		SHA      string `json:"sha"`
		ShortSHA string `json:"short_sha"`
		Subject  string `json:"subject"`
		Author   string `json:"author"`
	} `json:"revisions"`
}

type snapshotShape struct {
	RequestedRevision string `json:"requested_revision"`
	ResolvedRevision  string `json:"resolved_revision"`
	ShortRevision     string `json:"short_revision"`
	IssueCount        int    `json:"issue_count"`
	DataHash          string `json:"data_hash"`
	Issues            []struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	} `json:"issues"`
}

type diffShape struct {
	RequestedRevision string            `json:"requested_revision"`
	ResolvedRevision  string            `json:"resolved_revision"`
	FromDataHash      string            `json:"from_data_hash"`
	ToDataHash        string            `json:"to_data_hash"`
	Badges            map[string]string `json:"badges"`
	Diff              struct {
		FromRevision string `json:"from_revision"`
		NewIssues    []struct {
			ID string `json:"id"`
		} `json:"new_issues"`
		ClosedIssues []struct {
			ID string `json:"id"`
		} `json:"closed_issues"`
		Summary struct {
			TotalChanges   int    `json:"total_changes"`
			IssuesAdded    int    `json:"issues_added"`
			IssuesClosed   int    `json:"issues_closed"`
			IssuesModified int    `json:"issues_modified"`
			HealthTrend    string `json:"health_trend"`
		} `json:"summary"`
	} `json:"diff"`
}

func TestRevisionsListOnlyBeadChangingCommits(t *testing.T) {
	s := openHistorySession(t)
	list := call[revisionsShape](t, s, "revisions", nil)

	// The fixture repo has five commits, three of which touch the beads file.
	// A scrubber over every commit would be mostly no-op steps, so only those
	// three are offered.
	if list.Count != 3 {
		t.Errorf("listed %d revisions, want 3: %+v", list.Count, list.Revisions)
	}
	for _, rev := range list.Revisions {
		if len(rev.ShortSHA) != 7 {
			t.Errorf("short sha %q is not 7 characters", rev.ShortSHA)
		}
		if rev.Subject == "" {
			t.Error("a revision has no subject")
		}
		// The subject is the first line only; a body must not leak into it.
		if len(rev.Subject) > 0 && rev.Subject[len(rev.Subject)-1] == '\n' {
			t.Errorf("subject %q carries a newline", rev.Subject)
		}
	}
}

func TestSnapshotAtEarlierRevision(t *testing.T) {
	s := openHistorySession(t)

	// At HEAD, proj-1 is closed.
	current := call[snapshotShape](t, s, "snapshot_at", map[string]any{"revision": "HEAD"})
	if statusOf(current.Issues, "proj-1") != "closed" {
		t.Fatalf("proj-1 is %q at HEAD", statusOf(current.Issues, "proj-1"))
	}

	// Four commits back it had only just been created.
	earlier := call[snapshotShape](t, s, "snapshot_at", map[string]any{"revision": "HEAD~4"})
	if got := statusOf(earlier.Issues, "proj-1"); got != "open" {
		t.Errorf("proj-1 is %q at HEAD~4, want open", got)
	}
	if earlier.IssueCount != 2 {
		t.Errorf("HEAD~4 has %d beads, want 2", earlier.IssueCount)
	}

	// The response echoes the resolved commit, not the expression. `HEAD~4`
	// means something different tomorrow, and a UI showing the raw input would
	// keep claiming to show a snapshot it is no longer showing.
	if earlier.RequestedRevision != "HEAD~4" {
		t.Errorf("requested revision echoed as %q", earlier.RequestedRevision)
	}
	if len(earlier.ResolvedRevision) != 40 {
		t.Errorf("resolved revision %q is not a full sha", earlier.ResolvedRevision)
	}
	if earlier.ResolvedRevision == current.ResolvedRevision {
		t.Error("HEAD~4 resolved to the same commit as HEAD")
	}
	if earlier.DataHash == current.DataHash {
		t.Error("two different bead sets produced the same data hash")
	}
}

func TestSnapshotDefaultsToHead(t *testing.T) {
	s := openHistorySession(t)
	explicit := call[snapshotShape](t, s, "snapshot_at", map[string]any{"revision": "HEAD"})
	implicit := call[snapshotShape](t, s, "snapshot_at", nil)
	if explicit.ResolvedRevision != implicit.ResolvedRevision {
		t.Error("an empty revision did not default to HEAD")
	}
}

func TestSnapshotRejectsAnUnknownRevision(t *testing.T) {
	s := openHistorySession(t)
	if _, err := s.Call("snapshot_at", []byte(`{"revision":"no-such-ref"}`)); err == nil {
		t.Error("expected an error for an unresolvable revision")
	}
}

func TestDiffSinceReportsBadgesPerBead(t *testing.T) {
	s := openHistorySession(t)
	diff := call[diffShape](t, s, "diff", map[string]any{"revision": "HEAD~4"})

	if diff.ResolvedRevision == "" || len(diff.ResolvedRevision) != 40 {
		t.Errorf("diff resolved revision is %q", diff.ResolvedRevision)
	}
	if diff.FromDataHash == diff.ToDataHash {
		t.Error("the two ends of the diff have the same data hash")
	}

	// proj-1 went open -> closed across that span.
	if badge := diff.Badges["proj-1"]; badge != "closed" {
		t.Errorf("proj-1 is badged %q, want closed", badge)
	}
	// proj-2 never moved, so it earns no badge at all.
	if badge, ok := diff.Badges["proj-2"]; ok {
		t.Errorf("proj-2 is badged %q but never changed", badge)
	}
	if diff.Diff.Summary.TotalChanges == 0 {
		t.Error("the summary reports no changes across a span that closed a bead")
	}
}

func TestDiffRequiresARevision(t *testing.T) {
	s := openHistorySession(t)
	if _, err := s.Call("diff", nil); err == nil {
		t.Error("expected an error when no revision is given")
	}
	if _, err := s.Call("diff", []byte(`{}`)); err == nil {
		t.Error("expected an error for an empty revision")
	}
}

func TestTimeTravelOutsideARepositoryIsAnError(t *testing.T) {
	s := openFixture(t)
	for _, method := range []string{"revisions", "snapshot_at", "diff"} {
		if _, err := s.Call(method, []byte(`{"revision":"HEAD"}`)); err == nil {
			t.Errorf("%s succeeded outside a git repository", method)
		}
	}
}

func statusOf(issues []struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}, id string) string {
	for _, issue := range issues {
		if issue.ID == id {
			return issue.Status
		}
	}
	return ""
}
