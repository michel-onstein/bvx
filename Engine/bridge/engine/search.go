package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/search"
)

// Search.
//
// bv has exactly two modes, and the naming is worth stating plainly because it
// is easy to get wrong: there is no separate "fuzzy" and "semantic" mode. The
// vector index is *always* used to find candidates; the mode selects what
// re-ranks them. `text` takes the index's own similarity; `hybrid` re-scores
// with graph metrics — centrality, actionability, impact, priority, recency —
// through bv's own scorer.
//
// The default embedder is `hash`, which is deterministic and needs no model.
// That is what keeps bvx's default ranking identical to the CLI's: a better
// embedder would give better results and *different* ones, so choosing it is
// the caller's decision, never a default.

// issueIDPattern matches a bare bead id, which bv promotes to the top of the
// results when the query looks like one.
var issueIDPattern = regexp.MustCompile(`^[A-Za-z]+-[A-Za-z0-9]+$`)

type searchRequest struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
	// Mode is "text" or "hybrid". Empty means text.
	Mode string `json:"mode"`
	// Preset names a weight set: default, bug-hunting, sprint-planning,
	// impact-first, text-only.
	Preset string `json:"preset"`
	// Weights overrides the preset entirely. All six keys are required.
	Weights *search.Weights `json:"weights"`
	// Embedder selects the vector provider. Empty means the environment's,
	// which defaults to the deterministic hash embedder.
	Embedder string `json:"embedder"`
}

// searchIssues runs one query.
func (s *Session) searchIssues(req []byte) ([]byte, error) {
	var r searchRequest
	if len(req) == 0 {
		return nil, fmt.Errorf("search requires a \"query\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return nil, err
	}
	if strings.TrimSpace(r.Query) == "" {
		return nil, fmt.Errorf("search requires a non-empty \"query\"")
	}

	limit := r.Limit
	if limit <= 0 {
		limit = 10
	}
	mode := strings.ToLower(strings.TrimSpace(r.Mode))
	if mode == "" {
		mode = "text"
	}
	if mode != "text" && mode != "hybrid" {
		return nil, fmt.Errorf("invalid search mode %q (expected text or hybrid)", mode)
	}

	issues, _, _ := s.snapshot()
	if len(issues) == 0 {
		return json.Marshal(map[string]any{
			"query": r.Query, "mode": mode, "results": []any{},
		})
	}

	embedConfig := search.EmbeddingConfigFromEnv()
	if r.Embedder != "" {
		embedConfig.Provider = search.Provider(r.Embedder)
		embedConfig = embedConfig.Normalized()
	}
	embedder, err := search.NewEmbedderFromConfig(embedConfig)
	if err != nil {
		return nil, fmt.Errorf("creating embedder: %w", err)
	}

	docs := search.DocumentsFromIssues(issues)
	index, err := s.vectorIndex(embedder, docs, embedConfig)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	vectors, err := embedder.Embed(ctx, []string{r.Query})
	if err != nil || len(vectors) == 0 {
		return nil, fmt.Errorf("embedding the query: %w", err)
	}

	// Hybrid re-ranks, so it needs more candidates than it will return —
	// otherwise re-scoring can only reorder what text similarity already
	// chose, and a bead the metrics would have promoted is never seen.
	fetch := limit
	if mode == "hybrid" {
		fetch = search.HybridCandidateLimit(limit, len(issues), r.Query)
	}

	results, err := index.SearchTopK(vectors[0], fetch)
	if err != nil {
		return nil, fmt.Errorf("searching: %w", err)
	}
	results = search.ApplyShortQueryLexicalBoost(results, r.Query, docs)
	results = promoteExactID(results, r.Query)

	payload := map[string]any{
		"query":       r.Query,
		"mode":        mode,
		"provider":    string(embedder.Provider()),
		"dim":         embedder.Dim(),
		"index_size":  index.Size(),
		"limit":       limit,
		"total_beads": len(issues),
	}

	if mode == "text" {
		payload["results"] = textResults(results, limit)
		return json.Marshal(payload)
	}

	weights, preset, err := resolveWeights(r)
	if err != nil {
		return nil, err
	}
	scored, err := hybridResults(results, issues, weights, r.Query, limit)
	if err != nil {
		return nil, err
	}
	payload["results"] = scored
	payload["preset"] = preset
	payload["weights"] = weights
	return json.Marshal(payload)
}

// vectorIndex loads or builds the workspace's vector index.
func (s *Session) vectorIndex(
	embedder search.Embedder, docs map[string]string, cfg search.EmbeddingConfig,
) (*search.VectorIndex, error) {
	dir := s.projectDir()
	if dir == "" {
		return nil, fmt.Errorf("session has no source")
	}
	path := search.DefaultIndexPath(dir, cfg)

	index, loaded, err := search.LoadOrNewVectorIndex(path, embedder.Dim())
	if err != nil {
		return nil, fmt.Errorf("opening the search index: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	stats, err := search.SyncVectorIndex(ctx, index, embedder, docs, 64)
	if err != nil {
		return nil, fmt.Errorf("indexing: %w", err)
	}
	if !loaded || stats.Changed() {
		// A save failure costs the next query its warm start, not this
		// query's answer, so it is not fatal.
		_ = index.Save(path)
	}
	return index, nil
}

// resolveWeights turns a preset name or an explicit set into weights.
func resolveWeights(r searchRequest) (search.Weights, string, error) {
	if r.Weights != nil {
		weights := r.Weights.Normalize()
		if err := weights.Validate(); err != nil {
			return search.Weights{}, "", fmt.Errorf("invalid weights: %w", err)
		}
		// bv labels an explicit set "custom" rather than naming a preset it
		// no longer matches.
		return search.AdjustWeightsForQuery(weights, r.Query), "custom", nil
	}

	name := r.Preset
	if name == "" {
		name = "default"
	}
	weights, err := search.GetPreset(search.PresetName(strings.ToLower(name)))
	if err != nil {
		return search.Weights{}, "", fmt.Errorf("unknown search preset %q", name)
	}
	return search.AdjustWeightsForQuery(weights.Normalize(), r.Query), name, nil
}

// textResults trims to the limit and shapes the payload.
func textResults(results []search.SearchResult, limit int) []map[string]any {
	if len(results) > limit {
		results = results[:limit]
	}
	out := make([]map[string]any, 0, len(results))
	for _, result := range results {
		out = append(out, map[string]any{
			"issue_id": result.IssueID,
			"score":    result.Score,
		})
	}
	return out
}

// hybridResults re-scores candidates with graph metrics.
func hybridResults(
	candidates []search.SearchResult, issues []model.Issue,
	weights search.Weights, query string, limit int,
) ([]map[string]any, error) {
	cache := search.NewMetricsCache(search.NewAnalyzerMetricsLoader(issues))
	if err := cache.Refresh(); err != nil {
		return nil, fmt.Errorf("loading metrics for hybrid ranking: %w", err)
	}
	scorer := search.NewHybridScorer(weights, cache)

	scored := make([]search.HybridScore, 0, len(candidates))
	for _, candidate := range candidates {
		score, err := scorer.Score(candidate.IssueID, candidate.Score)
		if err != nil {
			continue
		}
		scored = append(scored, score)
	}

	sort.SliceStable(scored, func(i, j int) bool {
		if scored[i].FinalScore != scored[j].FinalScore {
			return scored[i].FinalScore > scored[j].FinalScore
		}
		// Ties break on id, so the same query twice gives the same order.
		return scored[i].IssueID < scored[j].IssueID
	})

	if exact := exactIDIndex(scored, query); exact > 0 {
		// Re-ranking can bury the bead whose id was literally typed. Rotating
		// it back to the front preserves the relative order of the rest.
		match := scored[exact]
		copy(scored[1:exact+1], scored[:exact])
		scored[0] = match
	}

	if len(scored) > limit {
		scored = scored[:limit]
	}

	out := make([]map[string]any, 0, len(scored))
	for _, score := range scored {
		entry := map[string]any{
			"issue_id":   score.IssueID,
			"score":      score.FinalScore,
			"text_score": score.TextScore,
		}
		if len(score.ComponentScores) > 0 {
			// The breakdown is what makes a hybrid ranking auditable rather
			// than a number to take on trust.
			entry["component_scores"] = score.ComponentScores
		}
		out = append(out, entry)
	}
	return out, nil
}

// promoteExactID moves a bead whose id was typed verbatim to the front.
func promoteExactID(results []search.SearchResult, query string) []search.SearchResult {
	if !issueIDPattern.MatchString(strings.TrimSpace(query)) {
		return results
	}
	target := strings.TrimSpace(query)
	for i, result := range results {
		if strings.EqualFold(result.IssueID, target) {
			if i == 0 {
				return results
			}
			match := results[i]
			copy(results[1:i+1], results[:i])
			results[0] = match
			return results
		}
	}
	return results
}

// exactIDIndex finds a verbatim id match among scored results, or -1.
func exactIDIndex(scored []search.HybridScore, query string) int {
	if !issueIDPattern.MatchString(strings.TrimSpace(query)) {
		return -1
	}
	target := strings.TrimSpace(query)
	for i, score := range scored {
		if strings.EqualFold(score.IssueID, target) {
			return i
		}
	}
	return -1
}

// searchPresets lists the weight sets available, with their values.
func (s *Session) searchPresets() ([]byte, error) {
	names := []string{"default", "bug-hunting", "sprint-planning", "impact-first", "text-only"}
	entries := make([]map[string]any, 0, len(names))
	for _, name := range names {
		weights, err := search.GetPreset(search.PresetName(name))
		if err != nil {
			continue
		}
		entries = append(entries, map[string]any{"name": name, "weights": weights})
	}
	return json.Marshal(map[string]any{
		"presets": entries,
		"modes":   []string{"text", "hybrid"},
	})
}
