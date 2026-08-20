package engine

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type siteShape struct {
	OutputDir  string `json:"output_dir"`
	Title      string `json:"title"`
	IssueCount int    `json:"issue_count"`
	TotalBytes int64  `json:"total_bytes"`
	Files      []struct {
		Path  string `json:"path"`
		Bytes int64  `json:"bytes"`
	} `json:"files"`
	Warnings         []string `json:"warnings"`
	SuggestedRepo    string   `json:"suggested_repo"`
	SuggestedProject string   `json:"suggested_project"`
}

func TestExportSiteBuildsABundle(t *testing.T) {
	s := openFixture(t)
	out := filepath.Join(t.TempDir(), "site")

	result := call[siteShape](t, s, "export_site", map[string]any{
		"output_dir":            out,
		"title":                 "Demo beads",
		"include_robot_outputs": true,
	})

	if result.IssueCount != 5 {
		t.Errorf("exported %d beads, want 5", result.IssueCount)
	}
	if result.TotalBytes == 0 || len(result.Files) == 0 {
		t.Fatalf("the bundle is empty: %+v", result)
	}

	// A SQLite payload is the point of the export.
	sawDatabase := false
	for _, file := range result.Files {
		if filepath.Ext(file.Path) == ".db" || filepath.Ext(file.Path) == ".sqlite3" {
			sawDatabase = true
		}
	}
	if !sawDatabase {
		t.Errorf("no database in the bundle: %+v", result.Files)
	}

	// Largest first, because the file about to blow a host's size limit is
	// the one worth seeing.
	for i := 1; i < len(result.Files); i++ {
		if result.Files[i-1].Bytes < result.Files[i].Bytes {
			t.Errorf("files are not ordered by size: %+v", result.Files)
			break
		}
	}

	// The reported total matches what is actually on disk.
	var onDisk int64
	_ = filepath.Walk(out, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			onDisk += info.Size()
		}
		return nil
	})
	if onDisk != result.TotalBytes {
		t.Errorf("reported %d bytes, found %d on disk", result.TotalBytes, onDisk)
	}
}

func TestExportSiteRequiresAnOutputDirectory(t *testing.T) {
	s := openFixture(t)
	for _, req := range [][]byte{nil, []byte(`{}`), []byte(`{"output_dir":""}`)} {
		if _, err := s.Call("export_site", req); err == nil {
			t.Errorf("expected an error for %q", req)
		}
	}
}

func TestPreviewRejectsSomethingThatIsNotABundle(t *testing.T) {
	s := openFixture(t)
	// A directory with no index.html is not a built bundle, and serving it
	// would present an empty page as a working site.
	if _, err := s.Call("export_preview",
		[]byte(`{"bundle_path":"`+t.TempDir()+`"}`)); err == nil {
		t.Error("expected an error for a directory that is not a bundle")
	}
	if _, err := s.Call("export_preview", nil); err == nil {
		t.Error("expected an error when no path is given")
	}
}

func TestCloudflareReportsWhatItCannotDo(t *testing.T) {
	s := openFixture(t)

	var hint struct {
		Supported bool   `json:"supported"`
		Reason    string `json:"reason"`
		Command   string `json:"command"`
		Project   string `json:"project"`
	}
	hint = call[struct {
		Supported bool   `json:"supported"`
		Reason    string `json:"reason"`
		Command   string `json:"command"`
		Project   string `json:"project"`
	}](t, s, "export_cloudflare_hint", map[string]any{
		"bundle_path": "/tmp/my site", "project": "demo",
	})

	// Saying plainly that this path is unavailable, and how to do it by hand,
	// beats a half-working reimplementation of wrangler's upload protocol.
	if hint.Supported {
		t.Error("claimed Cloudflare deployment is supported in-process")
	}
	if hint.Reason == "" {
		t.Error("no reason given")
	}
	// A path with a space has to survive being pasted into a shell.
	if !strings.Contains(hint.Command, `'/tmp/my site'`) {
		t.Errorf("the command does not quote the path: %s", hint.Command)
	}
}

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"":             ".",
		"/tmp/site":    "/tmp/site",
		"/tmp/my site": `'/tmp/my site'`,
		`/tmp/it's`:    `'/tmp/it'\''s'`,
		"/tmp/a$b":     `'/tmp/a$b'`,
	}
	for input, want := range cases {
		if got := shellQuote(input); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestDeployRequiresItsInputs(t *testing.T) {
	s := openFixture(t)
	cases := map[string][]byte{
		"nothing":   nil,
		"no bundle": []byte(`{"repo":"me/site","token":"t"}`),
		"no repo":   []byte(`{"bundle_path":"/tmp","token":"t"}`),
		"no token":  []byte(`{"bundle_path":"/tmp","repo":"me/site"}`),
	}
	for name, req := range cases {
		if _, err := s.Call("export_deploy_github", req); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

// The GitHub client is exercised against a stub, so the request shaping is
// covered without touching the network.

func TestGitHubClientResolvesTheOwnerFromTheToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/user" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("token was not sent as a bearer: %q", r.Header.Get("Authorization"))
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"login": "octocat"})
	}))
	defer server.Close()

	client := &githubClient{token: "test-token", http: server.Client()}
	original := githubAPIBase
	githubAPIBase = server.URL
	defer func() { githubAPIBase = original }()

	owner, name, err := client.resolveRepo("dashboard")
	if err != nil {
		t.Fatalf("resolveRepo: %v", err)
	}
	if owner != "octocat" || name != "dashboard" {
		t.Errorf("resolved to %s/%s", owner, name)
	}

	// An explicit owner is taken as given, with no round trip at all.
	owner, name, err = client.resolveRepo("someone/else")
	if err != nil || owner != "someone" || name != "else" {
		t.Errorf("explicit owner resolved to %s/%s (%v)", owner, name, err)
	}
}

func TestGitHubClientSurfacesTheAPIMessage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "Bad credentials"})
	}))
	defer server.Close()

	client := &githubClient{token: "bad", http: server.Client()}
	original := githubAPIBase
	githubAPIBase = server.URL
	defer func() { githubAPIBase = original }()

	_, _, err := client.resolveRepo("dashboard")
	if err == nil {
		t.Fatal("expected an error")
	}
	// GitHub's own message is far more useful than the status alone.
	if !strings.Contains(err.Error(), "Bad credentials") {
		t.Errorf("error does not carry the API message: %v", err)
	}
}
