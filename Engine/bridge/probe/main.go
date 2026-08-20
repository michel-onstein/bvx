// Command probe verifies that bv's engine packages compile and run correctly
// from an external Go module. It is a build-time smoke test, not shipped code.
package main

import (
	"fmt"

	"github.com/Dicklesworthstone/beads_viewer/pkg/analysis"
	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
)

func main() {
	issues := []model.Issue{
		{
			ID: "a", Title: "A", Status: model.StatusOpen, IssueType: model.TypeTask,
			Dependencies: []*model.Dependency{
				{IssueID: "a", DependsOnID: "b", Type: model.DepBlocks},
			},
		},
		{ID: "b", Title: "B", Status: model.StatusOpen, IssueType: model.TypeTask},
	}

	an := analysis.NewAnalyzer(issues)
	st := an.Analyze()
	fmt.Println("nodes:", st.NodeCount, "edges:", st.EdgeCount)
	fmt.Println("actionable:", len(an.GetActionableIssues()))
	fmt.Println("plan tracks:", len(an.GetExecutionPlan().Tracks))
	fmt.Println("datahash:", an.DataHash()[:12])

	tri := analysis.ComputeTriage(issues)
	fmt.Println("triage recommendations:", len(tri.Recommendations))
}
