package engine

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Probing a path without opening it.
//
// The Open panel needs to know whether a folder can be opened *before* the
// user commits to it, and it asks about every directory the user browses past.
// Opening a session to find out would run a full analysis per folder.
//
// This exists so the panel and the loader answer from the same rules. A
// predicate written separately in Swift would be a second copy that drifts,
// and the symptom — a folder the panel refuses but the CLI opens happily — is
// confusing enough to be worth designing out.

// ProbeResult describes whether a path holds bead data.
type ProbeResult struct {
	Path    string `json:"path"`
	CanOpen bool   `json:"can_open"`
	// Kind is "workspace", "jsonl" or "sqlite" when openable.
	Kind string `json:"kind,omitempty"`
	// Source is the file that would actually be read.
	Source string `json:"source,omitempty"`
	// Reason explains a refusal, for a tooltip or an error.
	Reason string `json:"reason,omitempty"`
}

// Probe reports whether `path` could be opened, without loading it.
//
// Deliberately accepts everything `load` does, which is more than "a folder
// containing .beads":
//
//   - a folder containing `.beads`
//   - a `.beads` directory chosen directly
//   - a `.jsonl` or `.db` file chosen directly
//   - a multi-repository workspace root, which holds `.bv/workspace.yaml` while
//     its `.beads` directories live in the repositories below it
//   - a git worktree whose `.beads` lives in the main repository, not in it
//
// The workspace case is the one a naive check breaks: requiring `.beads` at the
// chosen level makes every workspace root unselectable.
//
// Note discovery does *not* walk upwards — bv checks `<path>/.beads` and the
// main repository of a worktree, and nothing else. A folder below a workspace
// root is therefore refused, and refusing it is correct: opening it would fail.
func Probe(path string) ProbeResult {
	result := ProbeResult{Path: path}

	if path == "" {
		result.Reason = "no path given"
		return result
	}
	if _, err := os.Stat(path); err != nil {
		result.Reason = "does not exist"
		return result
	}

	// A workspace configuration wins, exactly as it does when loading.
	if configPath := findWorkspaceConfig(path); configPath != "" {
		result.CanOpen = true
		result.Kind = "workspace"
		result.Source = configPath
		return result
	}

	source, kind, _, err := resolveSource(path)
	if err != nil {
		result.Reason = friendlyProbeReason(path, err)
		return result
	}

	result.CanOpen = true
	result.Kind = kind
	result.Source = source
	return result
}

// friendlyProbeReason turns a loader error into something worth showing.
func friendlyProbeReason(path string, err error) string {
	info, statErr := os.Stat(path)
	if statErr == nil && info.IsDir() {
		return fmt.Sprintf("no .beads directory in or above %s", filepath.Base(path))
	}
	return err.Error()
}

// probePayload is the session-level method, for callers that already hold one.
func probePayload(req []byte) ([]byte, error) {
	var r struct {
		Path string `json:"path"`
	}
	if len(req) == 0 {
		return nil, fmt.Errorf("probe requires a \"path\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	return json.Marshal(Probe(r.Path))
}
