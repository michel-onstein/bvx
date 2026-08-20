// Package engine — building a correlation report without a git subprocess.
//
// bv's correlation package reaches git through exactly one choke point, a
// hardcoded exec.Command("git") in gitcmd.go, and offers no interface or
// injection point to supply the data another way. The App Sandbox forbids
// spawning that binary, so the app cannot use bv's Correlator at all.
//
// What it *can* use is everything downstream of the report: FileLookup,
// BuildFileIndex, NetworkBuilder, HistoryReport.BuildCausalityChain and
// HistoryReport.FindRelatedWork are pure functions over a *HistoryReport whose
// fields are all exported. So this file builds that report by reading the
// object store directly, and every analysis after it is bv's own code.
//
// The scoring is bv's too: confidences come from correlation.CalculateConfidence
// and milestones from correlation.GetBeadMilestones, so the numbers here are
// not a second opinion — they are the same numbers, fed different input.
package engine

import (
	"context"
	"fmt"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
	"github.com/go-git/go-git/v5/utils/merkletrie"
)

// defaultHistoryLimit caps how many commits are walked, matching bv's own
// DefaultHistoryLimit. The walk computes a patch per commit to get line
// counts, so an uncapped walk over a large repository would be slow enough to
// feel like a hang.
const defaultHistoryLimit = correlation.DefaultHistoryLimit

// commitRecord is one walked commit, before it is attributed to any bead.
type commitRecord struct {
	sha      string
	shortSHA string
	message  string
	author   string
	email    string
	when     time.Time
	files    []correlation.FileChange
	// beadEvents are lifecycle transitions this commit made to the beads
	// file, keyed by bead id.
	beadEvents map[string]correlation.EventType
	// codeFiles are the changed files outside the beads directory.
	codeFiles []correlation.FileChange
}

// historyResult carries the report plus the raw commit list, because orphan
// detection needs commits the report deliberately does not mention.
type historyResult struct {
	report  *correlation.HistoryReport
	commits []commitRecord
}

// objectStoreExtractor reads one repository's object store.
type objectStoreExtractor struct {
	repo *git.Repository
	// beadsPath is the beads JSONL's path relative to the repository root,
	// slash-separated as git stores it.
	beadsPath string
	// beadsDir is the directory prefix that marks a path as bookkeeping
	// rather than code.
	beadsDir string
	issues   []model.Issue
	byID     map[string]model.Issue
	patterns []*regexp.Regexp
	// blobCache memoises parsed bead sets by blob hash. A merge-heavy history
	// revisits the same blob repeatedly, and parsing is the expensive part.
	blobCache map[plumbing.Hash]map[string]model.Issue
}

// openObjectStore locates the repository containing sourcePath.
func openObjectStore(sourcePath string, issues []model.Issue) (*objectStoreExtractor, error) {
	dir := filepath.Dir(sourcePath)
	repo, err := git.PlainOpenWithOptions(dir, &git.PlainOpenOptions{DetectDotGit: true})
	if err != nil {
		return nil, fmt.Errorf("opening git repository near %s: %w", dir, err)
	}

	root, err := repositoryRoot(repo)
	if err != nil {
		return nil, err
	}

	// Both sides are resolved before comparing. On macOS a temporary
	// directory — and /tmp itself — is a symlink, and go-git reports the
	// resolved worktree root while the caller passes the unresolved path.
	// Subtracting one from the other then yields a "../../.." path that
	// matches no tree entry, which shows up as a repository whose beads file
	// is apparently never touched.
	rel, err := filepath.Rel(resolvePath(root), resolvePath(sourcePath))
	if err != nil || strings.HasPrefix(rel, "..") {
		return nil, fmt.Errorf("%s is not inside the repository at %s", sourcePath, root)
	}
	beadsPath := filepath.ToSlash(rel)

	byID := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		byID[issue.ID] = issue
	}

	return &objectStoreExtractor{
		repo:      repo,
		beadsPath: beadsPath,
		beadsDir:  path.Dir(beadsPath),
		issues:    issues,
		byID:      byID,
		patterns:  correlation.DefaultPatterns(),
		blobCache: map[plumbing.Hash]map[string]model.Issue{},
	}, nil
}

// resolvePath follows symlinks, falling back to the input when it cannot.
//
// The fallback matters: the path may not exist yet, or may sit behind a
// directory the process cannot stat, and neither is a reason to fail outright.
func resolvePath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// repositoryRoot resolves the working tree's root directory.
func repositoryRoot(repo *git.Repository) (string, error) {
	tree, err := repo.Worktree()
	if err != nil {
		return "", fmt.Errorf("resolving worktree: %w", err)
	}
	return tree.Filesystem.Root(), nil
}

// extract walks the history and assembles the report.
func (e *objectStoreExtractor) extract(
	ctx context.Context, opts correlation.CorrelatorOptions,
) (*historyResult, error) {
	head, err := e.repo.Head()
	if err != nil {
		return nil, fmt.Errorf("resolving HEAD: %w", err)
	}

	limit := opts.Limit
	if limit <= 0 {
		limit = defaultHistoryLimit
	}

	iter, err := e.repo.Log(&git.LogOptions{From: head.Hash(), Order: git.LogOrderCommitterTime})
	if err != nil {
		return nil, fmt.Errorf("walking history: %w", err)
	}
	defer iter.Close()

	var records []commitRecord
	err = iter.ForEach(func(commit *object.Commit) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		when := commit.Author.When
		if opts.Since != nil && when.Before(*opts.Since) {
			// The walk is newest-first, so anything older is out of range
			// too — stopping is both correct and much cheaper than filtering.
			return storer.ErrStop
		}
		if opts.Until != nil && when.After(*opts.Until) {
			return nil
		}

		record, err := e.record(ctx, commit)
		if err != nil {
			return err
		}
		records = append(records, record)
		if len(records) >= limit {
			return storer.ErrStop
		}
		return nil
	})
	if err != nil && err != storer.ErrStop {
		return nil, err
	}

	report := e.assemble(records, head.Hash().String(), opts)
	return &historyResult{report: report, commits: records}, nil
}

// record turns one commit into a commitRecord, including the bead lifecycle
// transitions it made.
func (e *objectStoreExtractor) record(
	ctx context.Context, commit *object.Commit,
) (commitRecord, error) {
	rec := commitRecord{
		sha:        commit.Hash.String(),
		shortSHA:   shortHash(commit.Hash.String()),
		message:    strings.TrimSpace(commit.Message),
		author:     commit.Author.Name,
		email:      commit.Author.Email,
		when:       commit.Author.When,
		beadEvents: map[string]correlation.EventType{},
	}

	tree, err := commit.Tree()
	if err != nil {
		return rec, fmt.Errorf("reading tree of %s: %w", rec.shortSHA, err)
	}

	var parentTree *object.Tree
	if commit.NumParents() > 0 {
		// First parent only: a merge's second parent would re-report every
		// change already attributed on the branch it merged.
		parent, err := commit.Parent(0)
		if err == nil {
			parentTree, _ = parent.Tree()
		}
	}

	changes, err := object.DiffTreeWithOptions(
		ctx, parentTree, tree, &object.DiffTreeOptions{DetectRenames: true})
	if err != nil {
		return rec, fmt.Errorf("diffing %s: %w", rec.shortSHA, err)
	}

	stats := e.lineStats(ctx, changes)
	touchedBeadsFile := false

	for _, change := range changes {
		name := change.To.Name
		if name == "" {
			name = change.From.Name
		}
		action, err := change.Action()
		if err != nil {
			continue
		}
		file := correlation.FileChange{
			Path:       name,
			Action:     actionCode(action),
			Insertions: stats[name].added,
			Deletions:  stats[name].deleted,
		}
		rec.files = append(rec.files, file)

		if name == e.beadsPath {
			touchedBeadsFile = true
		} else if !e.isBookkeeping(name) {
			rec.codeFiles = append(rec.codeFiles, file)
		}
	}

	if touchedBeadsFile {
		rec.beadEvents = e.beadTransitions(commit, tree, parentTree)
	}
	return rec, nil
}

// isBookkeeping reports whether a path is bead bookkeeping rather than code.
//
// Everything under the beads directory counts: the JSONL, its sync base, the
// config. Attributing those to a bead as "code changed" would make every bead
// look like it touched the same file.
func (e *objectStoreExtractor) isBookkeeping(name string) bool {
	if e.beadsDir == "." || e.beadsDir == "" {
		return name == e.beadsPath
	}
	return name == e.beadsPath || strings.HasPrefix(name, e.beadsDir+"/")
}

type lineStat struct {
	added   int
	deleted int
}

// lineStats computes per-file insertions and deletions for one commit.
//
// This is the expensive part of the walk — it decodes and diffs blob content —
// which is why the walk is capped. The numbers are reported rather than
// omitted because a file change with no line counts reads as an empty change.
func (e *objectStoreExtractor) lineStats(
	ctx context.Context, changes object.Changes,
) map[string]lineStat {
	out := map[string]lineStat{}
	patch, err := changes.PatchContext(ctx)
	if err != nil {
		// A binary file or an unreadable blob costs the line counts for the
		// whole commit, not the commit itself.
		return out
	}
	for _, stat := range patch.Stats() {
		out[stat.Name] = lineStat{added: stat.Addition, deleted: stat.Deletion}
	}
	return out
}

// beadTransitions diffs the beads file across one commit and classifies what
// changed as bv's lifecycle events.
func (e *objectStoreExtractor) beadTransitions(
	commit *object.Commit, tree, parentTree *object.Tree,
) map[string]correlation.EventType {
	current := e.beadsAt(tree)
	previous := map[string]model.Issue{}
	if parentTree != nil {
		previous = e.beadsAt(parentTree)
	}

	events := map[string]correlation.EventType{}
	for id, issue := range current {
		before, existed := previous[id]
		if !existed {
			events[id] = correlation.EventCreated
			continue
		}
		if before.Status == issue.Status {
			// A description or label edit is still activity on the bead, and
			// bv models it as a modification rather than dropping it.
			if !sameIssueShape(before, issue) {
				events[id] = correlation.EventModified
			}
			continue
		}
		events[id] = transitionEvent(string(before.Status), string(issue.Status))
	}
	return events
}

// transitionEvent maps a status change onto bv's event vocabulary.
func transitionEvent(from, to string) correlation.EventType {
	switch {
	case isClosedStatus(to):
		return correlation.EventClosed
	case isClosedStatus(from):
		// Leaving a closed state is a reopen regardless of where it lands.
		return correlation.EventReopened
	case to == "in_progress":
		return correlation.EventClaimed
	default:
		return correlation.EventModified
	}
}

func isClosedStatus(status string) bool {
	return status == "closed" || status == "tombstone"
}

// sameIssueShape reports whether two revisions of a bead are equivalent for
// history purposes.
func sameIssueShape(a, b model.Issue) bool {
	return a.Title == b.Title &&
		a.Priority == b.Priority &&
		a.Assignee == b.Assignee &&
		a.Description == b.Description &&
		strings.Join(a.Labels, ",") == strings.Join(b.Labels, ",") &&
		len(a.Dependencies) == len(b.Dependencies)
}

// beadsAt parses the beads file as of one tree, memoised by blob hash.
func (e *objectStoreExtractor) beadsAt(tree *object.Tree) map[string]model.Issue {
	if tree == nil {
		return map[string]model.Issue{}
	}
	entry, err := tree.File(e.beadsPath)
	if err != nil {
		return map[string]model.Issue{}
	}
	if cached, ok := e.blobCache[entry.Hash]; ok {
		return cached
	}

	reader, err := entry.Reader()
	if err != nil {
		return map[string]model.Issue{}
	}
	defer reader.Close()

	// bv's own parser, so a record it accepts today is accepted here too.
	issues, err := loader.ParseIssues(reader)
	if err != nil {
		return map[string]model.Issue{}
	}
	parsed := make(map[string]model.Issue, len(issues))
	for _, issue := range issues {
		parsed[issue.ID] = issue
	}
	e.blobCache[entry.Hash] = parsed
	return parsed
}

// assemble turns walked commits into bv's report shape.
func (e *objectStoreExtractor) assemble(
	records []commitRecord, headSHA string, opts correlation.CorrelatorOptions,
) *correlation.HistoryReport {
	histories := make(map[string]correlation.BeadHistory, len(e.issues))
	for _, issue := range e.issues {
		if opts.BeadID != "" && issue.ID != opts.BeadID {
			continue
		}
		histories[issue.ID] = correlation.BeadHistory{
			BeadID: issue.ID,
			Title:  issue.Title,
			Status: string(issue.Status),
			Events: []correlation.BeadEvent{},
			// A nil slice would marshal as null; the UI reads an empty list.
			Commits: []correlation.CorrelatedCommit{},
		}
	}

	commitIndex := correlation.CommitIndex{}
	authors := map[string]struct{}{}

	// Oldest first, so each bead's events read in the order they happened.
	for i := len(records) - 1; i >= 0; i-- {
		rec := records[i]
		authors[rec.email] = struct{}{}
		attributed := e.attribute(rec)

		for id, links := range attributed {
			history, ok := histories[id]
			if !ok {
				continue
			}
			if event, changed := rec.beadEvents[id]; changed {
				history.Events = append(history.Events, correlation.BeadEvent{
					BeadID:      id,
					EventType:   event,
					Timestamp:   rec.when,
					CommitSHA:   rec.sha,
					CommitMsg:   rec.message,
					Author:      rec.author,
					AuthorEmail: rec.email,
				})
			}
			history.Commits = append(history.Commits, links...)
			history.LastAuthor = rec.author
			histories[id] = history
			commitIndex[rec.sha] = appendUnique(commitIndex[rec.sha], id)
		}
	}

	methodCounts := map[string]int{}
	beadsWithCommits := 0
	totalLinked := 0

	for id, history := range histories {
		history.Milestones = correlation.GetBeadMilestones(history.Events)
		history.CycleTime = correlation.CalculateCycleTime(history.Milestones)
		// Highest confidence first: the inspector shows the strongest link,
		// and a caller taking the head of the list should get the best one.
		sort.SliceStable(history.Commits, func(a, b int) bool {
			return history.Commits[a].Confidence > history.Commits[b].Confidence
		})
		for _, commit := range history.Commits {
			methodCounts[string(commit.Method)]++
		}
		if len(history.Commits) > 0 {
			beadsWithCommits++
			totalLinked += len(history.Commits)
		}
		histories[id] = history
	}

	avg := 0.0
	if beadsWithCommits > 0 {
		avg = float64(totalLinked) / float64(beadsWithCommits)
	}

	gitRange := "HEAD"
	if len(records) > 0 {
		gitRange = fmt.Sprintf("%s..%s", records[len(records)-1].shortSHA, records[0].shortSHA)
	}

	return &correlation.HistoryReport{
		GeneratedAt:     time.Now(),
		DataHash:        analysis.ComputeDataHash(e.issues),
		GitRange:        gitRange,
		LatestCommitSHA: headSHA,
		Stats: correlation.HistoryStats{
			TotalBeads:         len(histories),
			BeadsWithCommits:   beadsWithCommits,
			TotalCommits:       len(records),
			UniqueAuthors:      len(authors),
			AvgCommitsPerBead:  avg,
			MethodDistribution: methodCounts,
		},
		Histories:   histories,
		CommitIndex: commitIndex,
	}
}

// attribute decides which beads a commit belongs to, and how confidently.
//
// Two methods are applied, both of which bv rates highly:
//
//   - explicit: the message names a bead. Ids are matched against the loaded
//     workspace as well as bv's patterns, because bv's built-in patterns
//     require a numeric suffix (`[A-Za-z]+-\d+`) and `br` mints alphanumeric
//     tokens like `bvx-8ou`, which those patterns miss entirely.
//   - co-committed: the same commit edited the bead's record and some code.
//
// Temporal-author correlation is deliberately absent: it needs a repo-wide
// author/time query that only pays for itself as a git subprocess, and bv
// rates it lowest (0.20–0.85) of the three.
func (e *objectStoreExtractor) attribute(rec commitRecord) map[string][]correlation.CorrelatedCommit {
	out := map[string][]correlation.CorrelatedCommit{}

	explicit := e.explicitMatches(rec.message)
	for id, matchType := range explicit {
		confidence := correlation.CalculateConfidence(matchType, len(explicit))
		out[id] = append(out[id], correlation.CorrelatedCommit{
			SHA:         rec.sha,
			ShortSHA:    rec.shortSHA,
			Message:     rec.message,
			Author:      rec.author,
			AuthorEmail: rec.email,
			Timestamp:   rec.when,
			Files:       rec.codeFiles,
			Method:      correlation.MethodExplicitID,
			Confidence:  confidence,
			Reason:      fmt.Sprintf("commit message references %s (%s)", id, matchType),
		})
	}

	// Co-commit only counts when there is code beside the bookkeeping;
	// a commit that only rewrites the JSONL has no code to attribute.
	if len(rec.codeFiles) > 0 {
		for id := range rec.beadEvents {
			if _, already := explicit[id]; already {
				continue
			}
			out[id] = append(out[id], correlation.CorrelatedCommit{
				SHA:         rec.sha,
				ShortSHA:    rec.shortSHA,
				Message:     rec.message,
				Author:      rec.author,
				AuthorEmail: rec.email,
				Timestamp:   rec.when,
				Files:       rec.codeFiles,
				Method:      correlation.MethodCoCommitted,
				Confidence:  correlation.MethodRanges[correlation.MethodCoCommitted].Min,
				Reason:      "bead record and code changed in the same commit",
			})
		}
	}

	// A bead whose record changed with no code and no mention still gets its
	// lifecycle event recorded; assemble reads rec.beadEvents for that.
	for id := range rec.beadEvents {
		if _, ok := out[id]; !ok {
			out[id] = nil
		}
	}
	return out
}

// explicitMatches finds bead ids named in a commit message, keyed to the match
// type bv's confidence function expects.
func (e *objectStoreExtractor) explicitMatches(message string) map[string]string {
	found := map[string]string{}

	// Known ids first. This is exact — no pattern can produce a false
	// positive against a bead the workspace does not hold.
	for id := range e.byID {
		if containsToken(message, id) {
			found[id] = classifyMatch(message, id)
		}
	}

	// Then bv's own patterns, for the classic PROJECT-123 style. A match is
	// still only kept when the workspace holds that bead.
	for _, pattern := range e.patterns {
		for _, match := range pattern.FindAllStringSubmatch(message, -1) {
			candidate := match[len(match)-1]
			if _, known := e.byID[candidate]; !known {
				continue
			}
			if _, already := found[candidate]; already {
				continue
			}
			found[candidate] = classifyMatch(message, candidate)
		}
	}
	return found
}

// classifyMatch names the strongest intent signal around an id, using the
// vocabulary correlation.CalculateConfidence scores.
func classifyMatch(message, id string) string {
	lower := strings.ToLower(message)
	target := strings.ToLower(id)
	index := strings.Index(lower, target)
	if index < 0 {
		return "generic"
	}

	if index > 0 && lower[index-1] == '[' {
		return "bracket"
	}

	// Look back a short way for a keyword; far enough for "closes: " and
	// "fixed #", not so far that an unrelated verb earlier in the line counts.
	start := index - 24
	if start < 0 {
		start = 0
	}
	prefix := lower[start:index]
	switch {
	case strings.Contains(prefix, "close"):
		return "closes"
	case strings.Contains(prefix, "fix"):
		return "fixes"
	case strings.Contains(prefix, "resolve"):
		return "resolves"
	case strings.Contains(prefix, "ref"):
		return "refs"
	default:
		return "generic"
	}
}

// containsToken reports whether `id` appears in `text` as a whole token.
//
// Substring matching would link `bvx-8` to a message naming `bvx-80`.
func containsToken(text, id string) bool {
	lower := strings.ToLower(text)
	target := strings.ToLower(id)
	from := 0
	for {
		index := strings.Index(lower[from:], target)
		if index < 0 {
			return false
		}
		index += from
		before := index == 0 || !isIDRune(rune(lower[index-1]))
		end := index + len(target)
		after := end >= len(lower) || !isIDRune(rune(lower[end]))
		if before && after {
			return true
		}
		from = index + 1
	}
}

func isIDRune(r rune) bool {
	return r == '-' || r == '_' ||
		(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

func appendUnique(list []string, value string) []string {
	for _, existing := range list {
		if existing == value {
			return list
		}
	}
	return append(list, value)
}

func shortHash(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

// actionCode maps go-git's change action onto the single letters bv's
// FileChange.Action carries.
func actionCode(action merkletrie.Action) string {
	switch action {
	case merkletrie.Insert:
		return "A"
	case merkletrie.Delete:
		return "D"
	default:
		return "M"
	}
}
