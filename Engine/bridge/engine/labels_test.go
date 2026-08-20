package engine

import (
	"testing"
)

// The fixture's edges by label: a(core)->b(core) stays inside one label, while
// b(core)->c(infra) and e(infra)->c(infra) leave it. Only b->c crosses a
// boundary in the blocking direction, so "core" waits on "infra".

type flowDependency struct {
	FromLabel  string   `json:"from_label"`
	ToLabel    string   `json:"to_label"`
	IssueCount int      `json:"issue_count"`
	IssueIDs   []string `json:"issue_ids"`
}

type flowPayload struct {
	Labels              []string         `json:"labels"`
	FlowMatrix          [][]int          `json:"flow_matrix"`
	Dependencies        []flowDependency `json:"dependencies"`
	BottleneckLabels    []string         `json:"bottleneck_labels"`
	TotalCrossLabelDeps int              `json:"total_cross_label_deps"`
}

type attentionScore struct {
	Label           string  `json:"label"`
	AttentionScore  float64 `json:"attention_score"`
	NormalizedScore float64 `json:"normalized_score"`
	Rank            int     `json:"rank"`
	PageRankSum     float64 `json:"pagerank_sum"`
	StalenessFactor float64 `json:"staleness_factor"`
	BlockImpact     float64 `json:"block_impact"`
	VelocityFactor  float64 `json:"velocity_factor"`
	OpenCount       int     `json:"open_count"`
}

type attentionPayload struct {
	Labels       []attentionScore `json:"labels"`
	TopAttention []string         `json:"top_attention"`
	TotalLabels  int              `json:"total_labels"`
}

func TestLabelFlowReportsCrossLabelEdges(t *testing.T) {
	s := openFixture(t)
	flow := call[flowPayload](t, s, "label_flow", nil)

	if len(flow.Labels) == 0 {
		t.Fatal("no labels in flow")
	}

	// The matrix must be square over the label list, because the UI indexes
	// it by that list's positions. A ragged matrix would read the wrong cell.
	if len(flow.FlowMatrix) != len(flow.Labels) {
		t.Fatalf("matrix is %d rows for %d labels", len(flow.FlowMatrix), len(flow.Labels))
	}
	for i, row := range flow.FlowMatrix {
		if len(row) != len(flow.Labels) {
			t.Fatalf("row %d is %d wide for %d labels", i, len(row), len(flow.Labels))
		}
	}

	// Direction matters and is easy to get backwards: bv orients an edge
	// blocker -> blocked. Bead b carries the label "core" and waits on c,
	// which carries "infra", so the edge is infra -> core. The heat map reads
	// a cell as "the row label blocks the column label" for the same reason.
	found := false
	for _, dep := range flow.Dependencies {
		if dep.FromLabel == "infra" && dep.ToLabel == "core" {
			found = true
			if dep.IssueCount < 1 {
				t.Errorf("infra->core reported %d dependencies", dep.IssueCount)
			}
		}
		if dep.FromLabel == "core" && dep.ToLabel == "infra" {
			t.Errorf("edge is oriented blocked->blocker: %+v", dep)
		}
	}
	if !found {
		t.Errorf("expected an infra->core dependency, got %+v", flow.Dependencies)
	}
}

func TestLabelAttentionRanksAndDecomposes(t *testing.T) {
	s := openFixture(t)
	attention := call[attentionPayload](t, s, "label_attention", nil)

	if attention.TotalLabels == 0 || len(attention.Labels) == 0 {
		t.Fatal("no attention scores returned")
	}

	// Ranks are 1-based and dense, and the list arrives already ordered by
	// descending score — the UI renders it in the order it is given.
	for i, label := range attention.Labels {
		if label.Rank != i+1 {
			t.Errorf("label %q has rank %d at position %d", label.Label, label.Rank, i)
		}
		if i > 0 && attention.Labels[i-1].AttentionScore < label.AttentionScore {
			t.Errorf("scores are not descending at position %d", i)
		}
		if label.NormalizedScore < 0 || label.NormalizedScore > 1 {
			t.Errorf("normalized score %f out of range for %q", label.NormalizedScore, label.Label)
		}
		if label.OpenCount == 0 {
			t.Errorf("label %q reports no open beads", label.Label)
		}
	}

	// The decomposition has to survive the round trip. A ranking without its
	// factors says a label is in trouble without saying which lever moved it.
	anyFactor := false
	for _, label := range attention.Labels {
		if label.PageRankSum != 0 || label.StalenessFactor != 0 ||
			label.BlockImpact != 0 || label.VelocityFactor != 0 {
			anyFactor = true
		}
	}
	if !anyFactor {
		t.Error("every attention factor came back zero; the decomposition was lost")
	}
}
