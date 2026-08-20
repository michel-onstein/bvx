// Package engine wraps bv's analysis engine in a session model with a
// JSON request/response vocabulary.
//
// The vocabulary deliberately mirrors bv's robot protocol method names, so a
// new bv capability becomes reachable from bvx without changing the C ABI.
// Everything here is plain Go with no cgo, so it is unit-testable directly;
// the cgo layer in ../cbridge is a thin marshalling shim over Call.
package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/correlation"
	"github.com/Dicklesworthstone/beads_viewer/pkg/export"
	"github.com/Dicklesworthstone/beads_viewer/pkg/loader"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

// OpenConfig is the payload accepted by Open.
type OpenConfig struct {
	// Path is a workspace directory, a .beads directory, or a file
	// (.jsonl or .db). Empty means the current working directory.
	Path string `json:"path"`
	// SkipPhase2 disables the expensive centrality metrics entirely.
	SkipPhase2 bool `json:"skip_phase2"`
}

// Session holds one loaded workspace and its analysis state.
type Session struct {
	mu sync.RWMutex

	config   OpenConfig
	source   string // resolved file actually read
	kind     string // "jsonl" | "sqlite"
	issues   []model.Issue
	warnings []string

	analyzer *analysis.Analyzer
	stats    *analysis.GraphStats

	loadedAt time.Time

	// Correlation state, guarded separately: walking the object store is slow
	// enough that it must not hold the analysis lock, and it is only built on
	// demand because most sessions never ask for history at all.
	historyMu    sync.Mutex
	history      *historyResult
	historyLimit int
}

// Open resolves a data source, loads it, and starts analysis.
//
// Phase 1 metrics are complete when Open returns; Phase 2 continues in the
// background and is observable through the "metrics" method's phase2_ready
// flag, matching bv's two-phase contract.
func Open(cfg OpenConfig) (*Session, error) {
	s := &Session{config: cfg}
	if err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// resolveSource applies bv's discovery rules: an explicit file wins, then a
// .beads directory is searched for issues.jsonl -> beads.jsonl ->
// beads.base.jsonl, and beads.db is the fallback when no JSONL has content.
func resolveSource(path string) (src string, kind string, warnings []string, err error) {
	if path == "" {
		path, err = os.Getwd()
		if err != nil {
			return "", "", nil, err
		}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", "", nil, err
	}

	info, err := os.Stat(abs)
	if err != nil {
		return "", "", nil, fmt.Errorf("cannot read %s: %w", abs, err)
	}

	if !info.IsDir() {
		switch strings.ToLower(filepath.Ext(abs)) {
		case ".db", ".sqlite", ".sqlite3":
			return abs, "sqlite", nil, nil
		default:
			return abs, "jsonl", nil, nil
		}
	}

	beadsDir := abs
	if filepath.Base(abs) != ".beads" {
		if d, derr := loader.GetBeadsDir(abs); derr == nil && d != "" {
			beadsDir = d
		} else if _, serr := os.Stat(filepath.Join(abs, ".beads")); serr == nil {
			beadsDir = filepath.Join(abs, ".beads")
		} else {
			return "", "", nil, fmt.Errorf("no .beads directory found under %s", abs)
		}
	}

	// Prefer a JSONL with actual content; bv's own discovery returns the
	// first match by name, but an empty issues.jsonl next to a populated
	// beads.db is common in bd-managed repos and must not read as "no data".
	jsonlPath, jerr := loader.FindJSONLPathWithWarnings(beadsDir, func(msg string) {
		warnings = append(warnings, msg)
	})
	if jerr == nil && jsonlPath != "" {
		if st, serr := os.Stat(jsonlPath); serr == nil && st.Size() > 0 {
			return jsonlPath, "jsonl", warnings, nil
		}
		warnings = append(warnings,
			fmt.Sprintf("%s is empty; falling back to SQLite", filepath.Base(jsonlPath)))
	}

	db := filepath.Join(beadsDir, "beads.db")
	if _, serr := os.Stat(db); serr == nil {
		return db, "sqlite", warnings, nil
	}
	if jsonlPath != "" {
		return jsonlPath, "jsonl", warnings, nil
	}
	return "", "", warnings, fmt.Errorf("no bead data found in %s", beadsDir)
}

// phase1OnlyConfig disables every metric in bv's expensive tier, leaving
// degree, topological order and density — the values Open must return
// immediately.
func phase1OnlyConfig() analysis.AnalysisConfig {
	cfg := analysis.DefaultConfig()
	cfg.ComputePageRank = false
	cfg.ComputeBetweenness = false
	cfg.ComputeHITS = false
	cfg.ComputeEigenvector = false
	cfg.ComputeCriticalPath = false
	cfg.ComputeCycles = false
	cfg.ComputeKCore = false
	cfg.ComputeArticulation = false
	cfg.ComputeSlack = false
	return cfg
}

func (s *Session) load() error {
	src, kind, warnings, err := resolveSource(s.config.Path)
	if err != nil {
		return err
	}

	var issues []model.Issue
	switch kind {
	case "sqlite":
		issues, err = LoadSQLite(src)
	default:
		opts := loader.ParseOptions{
			WarningHandler: func(msg string) { warnings = append(warnings, msg) },
		}
		issues, err = loader.LoadIssuesFromFileWithOptions(src, opts)
	}
	if err != nil {
		return fmt.Errorf("loading %s: %w", src, err)
	}

	an := analysis.NewAnalyzer(issues)
	var stats *analysis.GraphStats
	if s.config.SkipPhase2 {
		// Every Phase-2 metric off. Analyze() runs them synchronously, so
		// skipping has to be expressed through the config rather than by
		// choosing the sync entry point. The resulting status entries read
		// "skipped", which is what the UI renders instead of a fake zero.
		st := an.AnalyzeWithConfig(phase1OnlyConfig())
		stats = &st
	} else {
		stats = an.AnalyzeAsync(context.Background())
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.source, s.kind, s.warnings = src, kind, warnings
	s.issues, s.analyzer, s.stats = issues, an, stats
	s.loadedAt = time.Now()
	return nil
}

// Close releases session state.
func (s *Session) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.issues, s.analyzer, s.stats = nil, nil, nil
}

// Call dispatches one method by name. req may be nil or empty.
func (s *Session) Call(method string, req []byte) ([]byte, error) {
	switch method {
	case "info":
		return s.info()
	case "issues":
		return s.issuesPayload()
	case "metrics":
		return s.metrics()
	case "wait_phase2":
		s.mu.RLock()
		st := s.stats
		s.mu.RUnlock()
		if st != nil {
			st.WaitForPhase2()
		}
		return s.metrics()
	case "compute_phase2":
		return s.computePhase2()
	case "reload":
		return s.reload()
	case "triage":
		return s.triage()
	case "plan":
		return s.plan()
	case "impact":
		return s.impact()
	case "recommendations":
		return s.recommendations()
	case "actionable":
		return s.actionable()
	case "blocker_chain":
		return s.blockerChain(req)
	case "unblocks":
		return s.unblocks(req)
	case "label_health":
		return s.labelHealth()
	case "label_flow":
		return s.labelFlow()
	case "label_attention":
		return s.labelAttention()
	case "eta":
		return s.eta(req)
	case "graph":
		return s.graph()
	case "export_markdown":
		return s.exportMarkdown(req)
	case "history":
		return s.historyPayload(req)
	case "causality":
		return s.causality(req)
	case "related":
		return s.relatedWork(req)
	case "impact_network":
		return s.impactNetwork(req)
	case "file_beads":
		return s.fileBeads(req)
	case "file_hotspots":
		return s.fileHotspots(req)
	case "file_relations":
		return s.fileRelations(req)
	case "orphans":
		return s.orphans(req)
	case "commit_patch":
		return s.commitPatch(req)
	case "correlation_feedback":
		return s.correlationFeedback()
	case "correlation_confirm":
		return s.recordFeedback(req, correlation.FeedbackConfirm)
	case "correlation_reject":
		return s.recordFeedback(req, correlation.FeedbackReject)
	default:
		return nil, fmt.Errorf("unknown method %q", method)
	}
}

func (s *Session) snapshot() ([]model.Issue, *analysis.Analyzer, *analysis.GraphStats) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.issues, s.analyzer, s.stats
}

// ---- method implementations -------------------------------------------------

type infoPayload struct {
	Source    string   `json:"source"`
	Kind      string   `json:"kind"`
	IssueCoun int      `json:"issue_count"`
	DataHash  string   `json:"data_hash"`
	Warnings  []string `json:"warnings"`
	LoadedAt  string   `json:"loaded_at"`
}

func (s *Session) info() ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	hash := ""
	if s.analyzer != nil {
		hash = s.analyzer.DataHash()
	}
	w := s.warnings
	if w == nil {
		w = []string{}
	}
	return json.Marshal(infoPayload{
		Source:    s.source,
		Kind:      s.kind,
		IssueCoun: len(s.issues),
		DataHash:  hash,
		Warnings:  w,
		LoadedAt:  s.loadedAt.Format(time.RFC3339),
	})
}

func (s *Session) issuesPayload() ([]byte, error) {
	issues, _, _ := s.snapshot()
	if issues == nil {
		issues = []model.Issue{}
	}
	return json.Marshal(map[string]any{"issues": issues})
}

// metricsPayload is the wire shape for GraphStats. Phase-2 maps are omitted
// entirely (not zeroed) until ready, so the client can distinguish "not
// computed yet" from "computed as zero" — the distinction bv's status flags
// exist to preserve.
type metricsPayload struct {
	NodeCount        int             `json:"node_count"`
	EdgeCount        int             `json:"edge_count"`
	Density          float64         `json:"density"`
	InDegree         map[string]int  `json:"in_degree"`
	OutDegree        map[string]int  `json:"out_degree"`
	TopologicalOrder []string        `json:"topological_order"`
	Phase2Ready      bool            `json:"phase2_ready"`
	Status           json.RawMessage `json:"status,omitempty"`

	PageRank     map[string]float64 `json:"pagerank,omitempty"`
	Betweenness  map[string]float64 `json:"betweenness,omitempty"`
	Eigenvector  map[string]float64 `json:"eigenvector,omitempty"`
	Hubs         map[string]float64 `json:"hubs,omitempty"`
	Authorities  map[string]float64 `json:"authorities,omitempty"`
	CriticalPath map[string]float64 `json:"critical_path,omitempty"`
	Slack        map[string]float64 `json:"slack,omitempty"`
	CoreNumber   map[string]int     `json:"core_number,omitempty"`
	Articulation []string           `json:"articulation,omitempty"`
	Cycles       [][]string         `json:"cycles,omitempty"`

	PageRankRank    map[string]int `json:"pagerank_rank,omitempty"`
	BetweennessRank map[string]int `json:"betweenness_rank,omitempty"`
}

func (s *Session) metrics() ([]byte, error) {
	_, _, st := s.snapshot()
	if st == nil {
		return nil, fmt.Errorf("session has no analysis")
	}

	p := metricsPayload{
		NodeCount:        st.NodeCount,
		EdgeCount:        st.EdgeCount,
		Density:          st.Density,
		InDegree:         st.InDegree,
		OutDegree:        st.OutDegree,
		TopologicalOrder: st.TopologicalOrder,
		Phase2Ready:      st.IsPhase2Ready(),
	}
	if p.InDegree == nil {
		p.InDegree = map[string]int{}
	}
	if p.OutDegree == nil {
		p.OutDegree = map[string]int{}
	}
	if p.TopologicalOrder == nil {
		p.TopologicalOrder = []string{}
	}

	if raw, err := json.Marshal(st.Status()); err == nil {
		p.Status = raw
	}

	if p.Phase2Ready {
		p.PageRank = st.PageRank()
		p.Betweenness = st.Betweenness()
		p.Eigenvector = st.Eigenvector()
		p.Hubs = st.Hubs()
		p.Authorities = st.Authorities()
		p.CriticalPath = st.CriticalPathScore()
		p.Slack = st.Slack()
		p.CoreNumber = st.CoreNumber()
		p.Articulation = st.ArticulationPoints()
		p.Cycles = st.Cycles()
		p.PageRankRank = st.PageRankRank()
		p.BetweennessRank = st.BetweennessRank()
	}
	return json.Marshal(p)
}

// reload re-reads the source and re-analyses only when the data actually
// changed.
//
// The gate is bv's own content hash over the sorted issue set, so an
// incidental touch — a `git status`, an editor's atomic save of an unrelated
// file in the same directory — costs one parse and no analysis at all. The
// response carries `changed` so the UI can skip republishing too.
func (s *Session) reload() ([]byte, error) {
	src, kind, warnings, err := resolveSource(s.config.Path)
	if err != nil {
		return nil, err
	}

	var issues []model.Issue
	switch kind {
	case "sqlite":
		issues, err = LoadSQLite(src)
	default:
		opts := loader.ParseOptions{
			WarningHandler: func(msg string) { warnings = append(warnings, msg) },
		}
		issues, err = loader.LoadIssuesFromFileWithOptions(src, opts)
	}
	if err != nil {
		return nil, fmt.Errorf("reloading %s: %w", src, err)
	}

	newHash := analysis.ComputeDataHash(issues)

	s.mu.RLock()
	var oldHash string
	if s.analyzer != nil {
		oldHash = s.analyzer.DataHash()
	}
	s.mu.RUnlock()

	if newHash == oldHash && oldHash != "" {
		payload, err := s.info()
		if err != nil {
			return nil, err
		}
		return withChangedFlag(payload, false)
	}

	an := analysis.NewAnalyzer(issues)
	an.SeedDataHash(newHash)
	var stats *analysis.GraphStats
	if s.config.SkipPhase2 {
		st := an.AnalyzeWithConfig(phase1OnlyConfig())
		stats = &st
	} else {
		stats = an.AnalyzeAsync(context.Background())
	}

	s.mu.Lock()
	s.source, s.kind, s.warnings = src, kind, warnings
	s.issues, s.analyzer, s.stats = issues, an, stats
	s.loadedAt = time.Now()
	s.mu.Unlock()

	// Every correlation attribution is computed against the bead set, so a
	// changed set invalidates the whole report rather than part of it.
	s.invalidateHistory()

	payload, err := s.info()
	if err != nil {
		return nil, err
	}
	return withChangedFlag(payload, true)
}

// withChangedFlag splices a "changed" boolean into an info payload.
func withChangedFlag(payload []byte, changed bool) ([]byte, error) {
	var obj map[string]any
	if err := json.Unmarshal(payload, &obj); err != nil {
		return nil, err
	}
	obj["changed"] = changed
	return json.Marshal(obj)
}

// computePhase2 re-runs the full analysis with every metric enabled and
// blocks until it finishes.
//
// This is the escape hatch for a session opened with SkipPhase2 (or one whose
// metrics timed out): those runs leave the stats marked ready-but-skipped, so
// simply waiting again would return the same empty result forever. Callers get
// real values or a real timeout, never a silent no-op.
func (s *Session) computePhase2() ([]byte, error) {
	s.mu.RLock()
	an := s.analyzer
	s.mu.RUnlock()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}

	stats := an.AnalyzeAsync(context.Background())
	stats.WaitForPhase2()

	s.mu.Lock()
	s.stats = stats
	s.mu.Unlock()

	return s.metrics()
}

func (s *Session) triage() ([]byte, error) {
	issues, _, _ := s.snapshot()
	return json.Marshal(analysis.ComputeTriage(issues))
}

func (s *Session) plan() ([]byte, error) {
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	return json.Marshal(an.GetExecutionPlan())
}

func (s *Session) impact() ([]byte, error) {
	_, an, st := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	scores := an.ComputeImpactScoresFromStats(st, time.Now())
	return json.Marshal(map[string]any{"scores": scores})
}

func (s *Session) recommendations() ([]byte, error) {
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	return json.Marshal(map[string]any{"recommendations": an.GenerateRecommendations()})
}

func (s *Session) actionable() ([]byte, error) {
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	items := an.GetActionableIssues()
	ids := make([]string, 0, len(items))
	for _, it := range items {
		ids = append(ids, it.ID)
	}
	return json.Marshal(map[string]any{"issues": items, "ids": ids})
}

type idRequest struct {
	ID     string `json:"id"`
	Agents int    `json:"agents"`
}

func decodeID(req []byte) (idRequest, error) {
	var r idRequest
	if len(req) == 0 {
		return r, fmt.Errorf("request requires an \"id\"")
	}
	if err := json.Unmarshal(req, &r); err != nil {
		return r, err
	}
	if r.ID == "" {
		return r, fmt.Errorf("request requires a non-empty \"id\"")
	}
	return r, nil
}

func (s *Session) blockerChain(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	return json.Marshal(an.GetBlockerChain(r.ID))
}

func (s *Session) unblocks(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	_, an, _ := s.snapshot()
	if an == nil {
		return nil, fmt.Errorf("session has no analyzer")
	}
	ids := an.ComputeUnblocks(r.ID)
	if ids == nil {
		ids = []string{}
	}
	return json.Marshal(map[string]any{"id": r.ID, "unblocks": ids})
}

func (s *Session) labelHealth() ([]byte, error) {
	issues, _, st := s.snapshot()
	cfg := analysis.DefaultLabelHealthConfig()
	return json.Marshal(analysis.ComputeAllLabelHealth(issues, cfg, time.Now(), st))
}

func (s *Session) labelFlow() ([]byte, error) {
	issues, _, _ := s.snapshot()
	cfg := analysis.DefaultLabelHealthConfig()
	return json.Marshal(analysis.ComputeCrossLabelFlow(issues, cfg))
}

// labelAttention ranks labels by how much attention they need.
//
// The score is a product of centrality, staleness and blocking impact divided
// by velocity, and bv returns each factor alongside the total. All four are
// passed through: a ranking without its decomposition says a label is in
// trouble without saying why, which is the part that tells you what to do.
func (s *Session) labelAttention() ([]byte, error) {
	issues, _, _ := s.snapshot()
	cfg := analysis.DefaultLabelHealthConfig()
	return json.Marshal(analysis.ComputeLabelAttentionScores(issues, cfg, time.Now()))
}

func (s *Session) eta(req []byte) ([]byte, error) {
	r, err := decodeID(req)
	if err != nil {
		return nil, err
	}
	issues, _, st := s.snapshot()
	agents := r.Agents
	if agents <= 0 {
		agents = 1
	}
	est, err := analysis.EstimateETAForIssue(issues, st, r.ID, agents, time.Now())
	if err != nil {
		return nil, err
	}
	return json.Marshal(est)
}

type exportRequest struct {
	Title string `json:"title"`
	// Path, when set, writes the report to disk as well as returning it.
	Path string `json:"path"`
}

// exportMarkdown renders bv's Markdown report, Mermaid diagrams included.
//
// The content always comes back in the response so a sandboxed caller can
// write it wherever it has permission; Path is a convenience for the CLI.
func (s *Session) exportMarkdown(req []byte) ([]byte, error) {
	var r exportRequest
	if len(req) > 0 {
		if err := json.Unmarshal(req, &r); err != nil {
			return nil, err
		}
	}
	if r.Title == "" {
		r.Title = "Bead Report"
	}

	issues, _, _ := s.snapshot()
	content, err := export.GenerateMarkdown(issues, r.Title)
	if err != nil {
		return nil, fmt.Errorf("generating markdown: %w", err)
	}

	written := ""
	if r.Path != "" {
		if err := os.WriteFile(r.Path, []byte(content), 0o644); err != nil {
			return nil, fmt.Errorf("writing %s: %w", r.Path, err)
		}
		written = r.Path
	}

	return json.Marshal(map[string]any{
		"markdown": content,
		"bytes":    len(content),
		"path":     written,
	})
}

// graphEdge is a blocking dependency edge, the only edge type that
// participates in bv's graph metrics.
type graphEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
	Type string `json:"type"`
}

func (s *Session) graph() ([]byte, error) {
	issues, _, _ := s.snapshot()
	edges := make([]graphEdge, 0)
	known := make(map[string]bool, len(issues))
	for _, it := range issues {
		known[it.ID] = true
	}
	for _, it := range issues {
		for _, d := range it.Dependencies {
			if d == nil || !known[d.DependsOnID] {
				continue
			}
			edges = append(edges, graphEdge{
				From: it.ID, To: d.DependsOnID, Type: string(d.Type),
			})
		}
	}
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].From != edges[j].From {
			return edges[i].From < edges[j].From
		}
		return edges[i].To < edges[j].To
	})
	return json.Marshal(map[string]any{"edges": edges})
}
