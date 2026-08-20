package engine

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/export"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing/object"
	githttp "github.com/go-git/go-git/v5/plumbing/transport/http"
)

// GitHub Pages deployment, entirely in-process.
//
// bv drives this through the `gh` CLI. The App Sandbox forbids spawning it,
// so the repository is created through GitHub's REST API, the bundle is
// committed and pushed with go-git, and Pages is enabled through the API
// again. Nothing here shells out.
//
// The token is passed in by the caller rather than read from the environment,
// because the caller keeps it in the Keychain — which is the point of the
// exercise: a deploy credential in an environment variable is a deploy
// credential in every child process and every crash log.

// githubAPIBase is a variable rather than a constant so tests can point the
// client at a stub and cover the request shaping without touching the network.
var githubAPIBase = "https://api.github.com"

type deployRequest struct {
	BundlePath string `json:"bundle_path"`
	// Repo is `owner/name`, or just `name` to create it under the token's user.
	Repo    string `json:"repo"`
	Token   string `json:"token"`
	Private bool   `json:"private"`
	// Branch is the branch Pages serves from.
	Branch string `json:"branch"`
	// Message is the commit message.
	Message string `json:"message"`
}

// deployGitHub pushes a bundle to GitHub Pages.
func (s *Session) deployGitHub(req []byte) ([]byte, error) {
	var r deployRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("export_deploy requires a request")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	switch {
	case r.BundlePath == "":
		return nil, fmt.Errorf("export_deploy requires a \"bundle_path\"")
	case r.Repo == "":
		return nil, fmt.Errorf("export_deploy requires a \"repo\"")
	case r.Token == "":
		return nil, fmt.Errorf("export_deploy requires a \"token\"")
	}
	if r.Branch == "" {
		r.Branch = "gh-pages"
	}
	if r.Message == "" {
		r.Message = "Publish bead dashboard"
	}

	client := &githubClient{token: r.Token, http: &http.Client{Timeout: 30 * time.Second}}

	owner, name, err := client.resolveRepo(r.Repo)
	if err != nil {
		return nil, err
	}
	full := owner + "/" + name

	created, err := client.ensureRepository(owner, name, r.Private)
	if err != nil {
		return nil, err
	}

	remote := fmt.Sprintf("https://github.com/%s.git", full)
	if err := pushBundle(r.BundlePath, remote, r.Branch, r.Message, r.Token); err != nil {
		return nil, err
	}

	pagesURL, pagesErr := client.enablePages(full, r.Branch)
	warnings := []string{}
	if pagesErr != nil {
		// The push succeeded, so the bundle is published even if Pages needs
		// turning on by hand. Reporting the deploy as a failure would be
		// wrong and would invite a pointless retry.
		warnings = append(warnings, "enabling Pages: "+pagesErr.Error())
	}

	return json.Marshal(map[string]any{
		"repo":         full,
		"branch":       r.Branch,
		"created_repo": created,
		"remote":       remote,
		"pages_url":    pagesURL,
		"warnings":     warnings,
		"verify_hint":  "Pages can take a minute to build after the first push.",
	})
}

// pushBundle commits the bundle and force-pushes it to `branch`.
//
// Force, deliberately: the branch holds a generated site, and its history is
// not something anyone wants to preserve or merge.
func pushBundle(dir, remote, branch, message, token string) error {
	repo, err := git.PlainInit(dir, false)
	if err != nil {
		// Re-publishing into the same directory is normal.
		repo, err = git.PlainOpen(dir)
		if err != nil {
			return fmt.Errorf("preparing %s as a repository: %w", dir, err)
		}
	}

	tree, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("opening the worktree: %w", err)
	}
	if err := tree.AddGlob("."); err != nil {
		return fmt.Errorf("staging the bundle: %w", err)
	}

	_, err = tree.Commit(message, &git.CommitOptions{
		// A generated site has no meaningful author; naming the tool is more
		// honest than borrowing the user's identity.
		Author: &object.Signature{
			Name:  "bvx",
			Email: "bvx@localhost",
			When:  time.Now(),
		},
		AllowEmptyCommits: true,
	})
	if err != nil {
		return fmt.Errorf("committing the bundle: %w", err)
	}

	head, err := repo.Head()
	if err != nil {
		return fmt.Errorf("resolving HEAD: %w", err)
	}

	_, _ = repo.CreateRemote(&config.RemoteConfig{
		Name: "bvx-deploy",
		URLs: []string{remote},
	})

	refspec := config.RefSpec(fmt.Sprintf(
		"+%s:refs/heads/%s", head.Name().String(), branch))
	err = repo.Push(&git.PushOptions{
		RemoteName: "bvx-deploy",
		RefSpecs:   []config.RefSpec{refspec},
		Force:      true,
		Auth: &githttp.BasicAuth{
			// GitHub accepts any username with a token as the password.
			Username: "x-access-token",
			Password: token,
		},
	})
	if err != nil && err != git.NoErrAlreadyUpToDate {
		return fmt.Errorf("pushing to %s: %w", remote, err)
	}
	return nil
}

// githubClient is a minimal REST client — enough for this one flow.
type githubClient struct {
	token string
	http  *http.Client
}

func (c *githubClient) do(method, path string, body any, out any) (int, error) {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		payload = bytes.NewReader(encoded)
	}

	request, err := http.NewRequest(method, githubAPIBase+path, payload)
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := c.http.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()

	data, _ := io.ReadAll(response.Body)
	if out != nil && len(data) > 0 {
		_ = json.Unmarshal(data, out)
	}
	if response.StatusCode >= 400 {
		// GitHub's message field is far more useful than the status alone.
		var apiError struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(data, &apiError)
		if apiError.Message != "" {
			return response.StatusCode, fmt.Errorf("github: %s", apiError.Message)
		}
		return response.StatusCode, fmt.Errorf("github returned %s", response.Status)
	}
	return response.StatusCode, nil
}

// resolveRepo splits `owner/name`, defaulting the owner to the token's user.
func (c *githubClient) resolveRepo(repo string) (owner, name string, err error) {
	if parts := strings.SplitN(repo, "/", 2); len(parts) == 2 {
		return parts[0], parts[1], nil
	}
	var user struct {
		Login string `json:"login"`
	}
	if _, err := c.do(http.MethodGet, "/user", nil, &user); err != nil {
		return "", "", fmt.Errorf("resolving the token's account: %w", err)
	}
	if user.Login == "" {
		return "", "", fmt.Errorf("the token does not identify an account")
	}
	return user.Login, repo, nil
}

// ensureRepository creates the repository if it does not exist.
func (c *githubClient) ensureRepository(owner, name string, private bool) (bool, error) {
	status, err := c.do(http.MethodGet, "/repos/"+owner+"/"+name, nil, nil)
	if err == nil {
		return false, nil
	}
	if status != http.StatusNotFound {
		return false, err
	}

	body := map[string]any{
		"name":        name,
		"private":     private,
		"description": "Bead dashboard published by bvx",
		"auto_init":   false,
	}
	if _, err := c.do(http.MethodPost, "/user/repos", body, nil); err != nil {
		return false, fmt.Errorf("creating %s/%s: %w", owner, name, err)
	}
	return true, nil
}

// enablePages points GitHub Pages at the deployed branch.
func (c *githubClient) enablePages(full, branch string) (string, error) {
	body := map[string]any{
		"source": map[string]string{"branch": branch, "path": "/"},
	}

	var result struct {
		HTMLURL string `json:"html_url"`
	}
	status, err := c.do(http.MethodPost, "/repos/"+full+"/pages", body, &result)
	if err != nil && status == http.StatusConflict {
		// Already enabled: update the source instead, then read it back.
		if _, uerr := c.do(http.MethodPut, "/repos/"+full+"/pages", body, nil); uerr != nil {
			return "", uerr
		}
		if _, gerr := c.do(http.MethodGet, "/repos/"+full+"/pages", nil, &result); gerr != nil {
			return "", gerr
		}
		return result.HTMLURL, nil
	}
	if err != nil {
		return "", err
	}
	return result.HTMLURL, nil
}

// cloudflareInstructions explains the one path that cannot run in-process.
//
// Cloudflare Pages deployment is `wrangler`'s direct-upload protocol. The
// honest answer is the command to run, rather than a half-working
// reimplementation of an undocumented upload flow.
func (s *Session) cloudflareInstructions(req []byte) ([]byte, error) {
	var r struct {
		BundlePath string `json:"bundle_path"`
		Project    string `json:"project"`
	}
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}
	if r.Project == "" && r.BundlePath != "" {
		r.Project = export.SuggestProjectName(r.BundlePath)
	}
	if r.Project == "" {
		r.Project = "beads"
	}

	return json.Marshal(map[string]any{
		"supported": false,
		"reason": "Cloudflare Pages deploys through the wrangler CLI, which a " +
			"sandboxed app cannot launch. Run this from a terminal instead.",
		"command": fmt.Sprintf(
			"npx wrangler pages deploy %s --project-name %s",
			shellQuote(r.BundlePath), shellQuote(r.Project)),
		"project": r.Project,
	})
}

// shellQuote makes a path safe to paste into a shell.
func shellQuote(value string) string {
	if value == "" {
		return "."
	}
	if !strings.ContainsAny(value, " \t\"'$`\\") {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
