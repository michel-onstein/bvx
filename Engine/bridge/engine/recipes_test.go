package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Dicklesworthstone/beads_viewer/pkg/model"
	"github.com/Dicklesworthstone/beads_viewer/pkg/recipe"
)

type recipeListShape struct {
	Path    string `json:"path"`
	Recipes []struct {
		Recipe struct {
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"recipe"`
		IsBuiltin bool `json:"is_builtin"`
	} `json:"recipes"`
}

type recipeApplyShape struct {
	Recipe struct {
		Name string `json:"name"`
	} `json:"recipe"`
	IssueIDs  []string `json:"issue_ids"`
	Matched   int      `json:"matched"`
	Truncated bool     `json:"truncated"`
}

func TestRecipesIncludeTheBuiltIns(t *testing.T) {
	s := openFixture(t)
	list := call[recipeListShape](t, s, "recipes", nil)

	names := map[string]bool{}
	for _, entry := range list.Recipes {
		names[entry.Recipe.Name] = true
	}
	// The two the bead calls out as worth having on day one.
	for _, want := range []string{"actionable", "high-impact"} {
		if !names[want] {
			t.Errorf("built-in recipe %q is missing; got %v", want, keysOfBool(names))
		}
	}
	if list.Path == "" {
		t.Error("no recipe file path was reported")
	}
}

func TestApplyingActionableSelectsUnblockedBeads(t *testing.T) {
	s := openFixture(t)
	result := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "actionable"})

	if result.Recipe.Name != "actionable" {
		t.Errorf("applied %q", result.Recipe.Name)
	}
	// In the fixture only c and d have no unresolved blocking dependency.
	got := map[string]bool{}
	for _, id := range result.IssueIDs {
		got[id] = true
	}
	for _, want := range []string{"c", "d"} {
		if !got[want] {
			t.Errorf("actionable did not select %q; got %v", want, result.IssueIDs)
		}
	}
	for _, unwanted := range []string{"a", "b"} {
		if got[unwanted] {
			t.Errorf("actionable selected the blocked bead %q", unwanted)
		}
	}
}

func TestApplyingAnUnknownRecipeIsAnError(t *testing.T) {
	s := openFixture(t)
	if _, err := s.Call("recipe_apply", []byte(`{"name":"nope"}`)); err == nil {
		t.Error("expected an error for an unknown recipe")
	}
	if _, err := s.Call("recipe_apply", nil); err == nil {
		t.Error("expected an error when no name is given")
	}
}

func TestUserRecipeRoundTrip(t *testing.T) {
	dir := newFixtureWorkspace(t)
	s, err := Open(OpenConfig{Path: dir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)

	var saved struct {
		Path string `json:"path"`
		Name string `json:"name"`
	}
	saved = call[struct {
		Path string `json:"path"`
		Name string `json:"name"`
	}](t, s, "recipe_save", map[string]any{
		"recipe": map[string]any{
			"name":        "infra-only",
			"description": "Just the infra beads",
			"filters":     map[string]any{"tags": []string{"infra"}},
			"sort":        map[string]any{"field": "id", "direction": "asc"},
		},
	})

	// bv's own location, so a recipe written here is one `bv --recipe` can
	// use rather than one only vbx can see.
	if filepath.Base(saved.Path) != "recipes.yaml" ||
		filepath.Base(filepath.Dir(saved.Path)) != ".bv" {
		t.Errorf("recipe written to %s, want <project>/.bv/recipes.yaml", saved.Path)
	}
	if _, err := os.Stat(saved.Path); err != nil {
		t.Fatalf("recipe file missing: %v", err)
	}

	// It is visible to the loader immediately, and applying it selects the
	// beads carrying that label.
	applied := call[recipeApplyShape](t, s, "recipe_apply", map[string]any{"name": "infra-only"})
	if len(applied.IssueIDs) != 2 {
		t.Errorf("infra-only selected %v, want c and e", applied.IssueIDs)
	}
	if applied.IssueIDs[0] != "c" || applied.IssueIDs[1] != "e" {
		t.Errorf("sort by id ascending produced %v", applied.IssueIDs)
	}

	call[struct{}](t, s, "recipe_delete", map[string]any{"name": "infra-only"})
	if _, err := s.Call("recipe_apply", []byte(`{"name":"infra-only"}`)); err == nil {
		t.Error("the deleted recipe is still applicable")
	}
	// Deleting one recipe must not remove the file, which holds the rest.
	if _, err := os.Stat(saved.Path); err != nil {
		t.Errorf("the recipe file was removed along with the recipe: %v", err)
	}
}

func TestRecipeNamesCannotEscapeTheDirectory(t *testing.T) {
	s := openFixture(t)
	// A silently sanitised name is a recipe the user cannot find again, so a
	// path-bearing name is refused outright.
	for _, name := range []string{"../escape", "nested/name", `back\slash`, "."} {
		req := []byte(`{"recipe":{"name":"` + name + `"}}`)
		if _, err := s.Call("recipe_save", req); err == nil {
			t.Errorf("accepted the recipe name %q", name)
		}
	}
}

// ---- filter and sort semantics --------------------------------------------

func recipeFixtureIssues() []model.Issue {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return []model.Issue{
		{
			ID: "a", Title: "Alpha", Status: model.StatusOpen, Priority: 1,
			Labels:    []string{"core", "infra"},
			CreatedAt: base, UpdatedAt: base.AddDate(0, 0, 10),
		},
		{
			ID: "b", Title: "bravo", Status: model.StatusClosed, Priority: 0,
			Labels:    []string{"core"},
			CreatedAt: base.AddDate(0, 0, 5), UpdatedAt: base.AddDate(0, 0, 20),
		},
		{
			ID: "c", Title: "Charlie", Status: model.StatusOpen, Priority: 3,
			Labels: []string{"docs"},
		},
	}
}

func TestRecipeTagsRequireAllOfThem(t *testing.T) {
	issues := recipeFixtureIssues()

	// Both tags: only `a` carries them.
	both := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Tags: []string{"core", "infra"}},
	}, time.Now())
	if len(both) != 1 || both[0].ID != "a" {
		t.Errorf("tags should require all of them, got %v", idsOf(both))
	}

	// One tag: `a` and `b`.
	one := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Tags: []string{"core"}},
	}, time.Now())
	if len(one) != 2 {
		t.Errorf("single tag selected %v", idsOf(one))
	}
}

func TestRecipeExcludeTagsTakeAny(t *testing.T) {
	issues := recipeFixtureIssues()
	out := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{ExcludeTags: []string{"docs", "infra"}},
	}, time.Now())
	// Excluding is the mirror of including: carrying *any* forbidden tag is
	// enough to be dropped.
	if len(out) != 1 || out[0].ID != "b" {
		t.Errorf("exclude-tags kept %v", idsOf(out))
	}
}

func TestRecipeMatchingIsCaseInsensitive(t *testing.T) {
	issues := recipeFixtureIssues()
	out := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{Status: []string{"OPEN"}, Tags: []string{"CORE"}},
	}, time.Now())
	if len(out) != 1 || out[0].ID != "a" {
		t.Errorf("case-insensitive matching selected %v", idsOf(out))
	}
}

func TestRecipeDateFiltersSkipUndatedBeads(t *testing.T) {
	issues := recipeFixtureIssues()
	now := time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)

	out := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{UpdatedAfter: "20d"},
	}, now)
	// `c` has no timestamps at all. An unset date is unknown, not "the
	// beginning of time", so it is skipped rather than failing the comparison.
	for _, issue := range out {
		if issue.ID == "c" {
			t.Error("an undated bead passed a date filter")
		}
	}
}

func TestRecipeUnparseableDateIsIgnored(t *testing.T) {
	issues := recipeFixtureIssues()
	out := filterByRecipe(issues, &recipe.Recipe{
		Filters: recipe.FilterConfig{CreatedAfter: "not-a-date"},
	}, time.Now())
	// Dropping the filter is right; treating the failure as the zero time
	// would silently select everything, and as "now" would select nothing.
	if len(out) != len(issues) {
		t.Errorf("an unparseable date filtered the list down to %v", idsOf(out))
	}
}

func TestRecipeSortUsesSecondaryThenID(t *testing.T) {
	issues := []model.Issue{
		{ID: "c", Title: "same", Priority: 1},
		{ID: "a", Title: "same", Priority: 1},
		{ID: "b", Title: "same", Priority: 0},
	}
	sortByRecipe(issues, &recipe.Recipe{
		Sort: recipe.SortConfig{
			Field:     "priority",
			Direction: "asc",
			Secondary: &recipe.SortConfig{Field: "title", Direction: "asc"},
		},
	}, nil)

	// b first on priority; a before c because the titles tie and ids break it.
	if got := idsOf(issues); got[0] != "b" || got[1] != "a" || got[2] != "c" {
		t.Errorf("sorted to %v", got)
	}
}

func TestRecipeSortDescending(t *testing.T) {
	issues := []model.Issue{
		{ID: "a", Priority: 0}, {ID: "b", Priority: 2}, {ID: "c", Priority: 1},
	}
	sortByRecipe(issues, &recipe.Recipe{
		Sort: recipe.SortConfig{Field: "priority", Direction: "desc"},
	}, nil)
	if got := idsOf(issues); got[0] != "b" || got[1] != "c" || got[2] != "a" {
		t.Errorf("descending sort produced %v", got)
	}
}

func idsOf(issues []model.Issue) []string {
	out := make([]string, 0, len(issues))
	for _, issue := range issues {
		out = append(out, issue.ID)
	}
	return out
}

func keysOfBool(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
