package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

type reposShape struct {
	IsWorkspace bool   `json:"is_workspace"`
	ConfigPath  string `json:"config_path"`
	Repos       []struct {
		Name       string `json:"name"`
		Prefix     string `json:"prefix"`
		IssueCount int    `json:"issue_count"`
		Error      string `json:"error"`
	} `json:"repos"`
	CrossRepoEdges []struct {
		From     string `json:"from"`
		To       string `json:"to"`
		FromRepo string `json:"from_repo"`
		ToRepo   string `json:"to_repo"`
	} `json:"cross_repo_edges"`
}

// multiRepoWorkspace builds two repositories under one workspace, with a
// dependency crossing between them.
func multiRepoWorkspace(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	write := func(repo, content string) {
		dir := filepath.Join(root, repo, ".beads")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "issues.jsonl"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Both repositories hold an issue numbered 1. Without namespacing one
	// would silently overwrite the other in every id-keyed map.
	write("api", `{"id":"1","title":"API endpoint","status":"open","issue_type":"task","priority":1,"dependencies":[{"issue_id":"1","depends_on_id":"web-1","type":"blocks"}]}
{"id":"2","title":"API docs","status":"open","issue_type":"docs","priority":2}
`)
	write("web", `{"id":"1","title":"Web form","status":"open","issue_type":"task","priority":0}
`)

	config := `name: Demo workspace
repos:
  - name: api
    path: api
    prefix: "api-"
  - name: web
    path: web
    prefix: "web-"
`
	configDir := filepath.Join(root, ".bv")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "workspace.yaml"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func openWorkspace(t *testing.T) *Session {
	t.Helper()
	s, err := Open(OpenConfig{Path: multiRepoWorkspace(t), SkipPhase2: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func TestWorkspaceAggregatesEveryRepository(t *testing.T) {
	s := openWorkspace(t)

	var info struct {
		Kind       string `json:"kind"`
		IssueCount int    `json:"issue_count"`
		Source     string `json:"source"`
	}
	info = call[struct {
		Kind       string `json:"kind"`
		IssueCount int    `json:"issue_count"`
		Source     string `json:"source"`
	}](t, s, "info", nil)

	if info.Kind != "workspace" {
		t.Errorf("kind is %q, want workspace", info.Kind)
	}
	if info.IssueCount != 3 {
		t.Errorf("loaded %d beads, want 3 across two repos", info.IssueCount)
	}
	// The configuration file stands in for the source, because it is what was
	// read and what the watcher should follow.
	if filepath.Base(info.Source) != "workspace.yaml" {
		t.Errorf("source is %q", info.Source)
	}
}

func TestWorkspaceNamespacesIDs(t *testing.T) {
	s := openWorkspace(t)

	var payload struct {
		Issues []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"issues"`
	}
	payload = call[struct {
		Issues []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"issues"`
	}](t, s, "issues", nil)

	byID := map[string]string{}
	for _, issue := range payload.Issues {
		byID[issue.ID] = issue.Title
	}

	// Both repos hold an issue "1"; the prefixes keep them apart.
	if byID["api-1"] != "API endpoint" {
		t.Errorf("api-1 is %q", byID["api-1"])
	}
	if byID["web-1"] != "Web form" {
		t.Errorf("web-1 is %q", byID["web-1"])
	}
	if _, collided := byID["1"]; collided {
		t.Error("an unqualified id survived, so the two repos can collide")
	}
	if len(byID) != 3 {
		t.Errorf("expected 3 distinct ids, got %v", byID)
	}
}

func TestWorkspaceReportsItsRepositories(t *testing.T) {
	s := openWorkspace(t)
	repos := call[reposShape](t, s, "repos", nil)

	if !repos.IsWorkspace {
		t.Fatal("a workspace did not report itself as one")
	}
	if len(repos.Repos) != 2 {
		t.Fatalf("reported %d repos: %+v", len(repos.Repos), repos.Repos)
	}
	// Sorted by name, so the picker is stable between runs.
	if repos.Repos[0].Name != "api" || repos.Repos[1].Name != "web" {
		t.Errorf("repos are not sorted: %+v", repos.Repos)
	}
	if repos.Repos[0].IssueCount != 2 || repos.Repos[1].IssueCount != 1 {
		t.Errorf("issue counts are %d and %d",
			repos.Repos[0].IssueCount, repos.Repos[1].IssueCount)
	}
	for _, repo := range repos.Repos {
		if repo.Error != "" {
			t.Errorf("repo %q failed to load: %s", repo.Name, repo.Error)
		}
	}
}

func TestWorkspaceFindsCrossRepositoryEdges(t *testing.T) {
	s := openWorkspace(t)
	repos := call[reposShape](t, s, "repos", nil)

	// api-1 waits on web-1. That edge is invisible from inside either
	// repository, which is the whole reason to aggregate them.
	if len(repos.CrossRepoEdges) != 1 {
		t.Fatalf("found %d cross-repo edges: %+v",
			len(repos.CrossRepoEdges), repos.CrossRepoEdges)
	}
	edge := repos.CrossRepoEdges[0]
	if edge.From != "api-1" || edge.To != "web-1" {
		t.Errorf("edge is %s -> %s", edge.From, edge.To)
	}
	if edge.FromRepo != "api" || edge.ToRepo != "web" {
		t.Errorf("edge repos are %s -> %s", edge.FromRepo, edge.ToRepo)
	}
}

func TestSingleRepoReportsItselfAsNotAWorkspace(t *testing.T) {
	s := openFixture(t)
	repos := call[reposShape](t, s, "repos", nil)

	// Not an error — it simply has one repo, and saying so beats an empty
	// list the caller has to interpret.
	if repos.IsWorkspace {
		t.Error("a single repository reported itself as a workspace")
	}
	if repos.Repos == nil || repos.CrossRepoEdges == nil {
		t.Error("lists came back null rather than empty")
	}
}

func TestWorkspaceReloadIsHashGated(t *testing.T) {
	root := multiRepoWorkspace(t)
	s, err := Open(OpenConfig{Path: root, SkipPhase2: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	var first struct {
		Changed bool `json:"changed"`
	}
	first = call[struct {
		Changed bool `json:"changed"`
	}](t, s, "reload", nil)
	if first.Changed {
		t.Error("an unchanged workspace reported a change")
	}

	// Add a bead to one repo and reload again.
	path := filepath.Join(root, "web", ".beads", "issues.jsonl")
	existing, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	added := string(existing) +
		`{"id":"2","title":"Web tests","status":"open","issue_type":"task","priority":2}` + "\n"
	if err := os.WriteFile(path, []byte(added), 0o644); err != nil {
		t.Fatal(err)
	}

	var second struct {
		Changed    bool `json:"changed"`
		IssueCount int  `json:"issue_count"`
	}
	second = call[struct {
		Changed    bool `json:"changed"`
		IssueCount int  `json:"issue_count"`
	}](t, s, "reload", nil)

	if !second.Changed {
		t.Error("a changed workspace reported no change")
	}
	if second.IssueCount != 4 {
		t.Errorf("reloaded %d beads, want 4", second.IssueCount)
	}
}

func TestCrossRepoEdgesPreferTheLongestPrefix(t *testing.T) {
	// `api-v2-3` belongs to api-v2, not to api, and matching the shorter
	// prefix first would attribute it to the wrong repository.
	loads := []repoLoad{
		{Name: "api", Prefix: "api-"},
		{Name: "api-v2", Prefix: "api-v2-"},
		{Name: "web", Prefix: "web-"},
	}
	// `issue_type` is required: bv's loader skips a record without one, with
	// only a warning, and the edge would then vanish for the wrong reason.
	issues := parseIssuesForTest(t, `{"id":"api-v2-3","title":"v2","status":"open","issue_type":"task","dependencies":[{"issue_id":"api-v2-3","depends_on_id":"web-1","type":"blocks"}]}
{"id":"web-1","title":"web","status":"open","issue_type":"task"}
`)
	if len(issues) != 2 {
		t.Fatalf("the fixture parsed to %d issues, want 2", len(issues))
	}

	edges := crossRepoEdges(issues, loads)
	if len(edges) != 1 {
		t.Fatalf("found %d edges: %+v", len(edges), edges)
	}
	if edges[0].FromRepo != "api-v2" {
		t.Errorf("attributed api-v2-3 to %q", edges[0].FromRepo)
	}
}

// parseIssuesForTest parses JSONL into issues using bv's own parser.
func parseIssuesForTest(t *testing.T, content string) []model.Issue {
	t.Helper()
	issues, err := loader.ParseIssues(strings.NewReader(content))
	if err != nil {
		t.Fatalf("parsing test issues: %v", err)
	}
	return issues
}
