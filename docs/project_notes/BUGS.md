# Bug Log

Found-and-fixed issues, with the regression test that locks each fix in.

---

## 2026-08-20 — An editor's swap file beside `signing.env` was committable

**Symptom:** with `scripts/signing.env` created and correctly ignored,
`git status` showed `?? scripts/.signing.env.swp` — vim's swap file, holding
the same buffer contents, Team ID included, and stageable.

**Cause:** the `.gitignore` rule was the exact filename. It covered the file
being protected and nothing an editor leaves beside it: `.signing.env.swp`,
`signing.env~`, `signing.env.bak`. The one file everybody thinks of was
covered; the copies made automatically were not.

**Fix:** glob the family — `scripts/signing.env`, `scripts/signing.env.*`,
`scripts/signing.env~`, `scripts/.signing.env*` — with an explicit
`!scripts/signing.env.example` negation, because the broadened glob would
otherwise swallow the committed template.

**Prevention:** `scripts/test-packaging.py` asserts six editor leftovers are
ignored *and* that the example template is not, so the negation cannot be lost
while widening the glob later. Found by watching real `git status` output
rather than by reasoning about the rule — the original rule looked right.

---

## 2026-08-19 — Blockquote rule stretched down the whole pane

**Symptom:** a one-line quote in a bead description drew a grey vertical bar
hundreds of points tall, down the rest of the description.

**Cause:** the rule was a `RoundedRectangle` sibling in an `HStack`. A bare
shape is greedy and expanded to whatever vertical space the container had left.

**Fix:** the rule is an `.overlay(alignment: .leading)` on the quote text, so it
inherits the text's height.

**Prevention:** covered by the `markdown-blocks` snapshot — this was invisible
to every non-visual test and was found by looking at the rendered PNG.

---

## 2026-08-19 — Wrapped sentences broke mid-clause in rendered Markdown

**Symptom:** a description wrapped in the source rendered with a hard line
break where the author had simply wrapped, e.g. "…while the real" / newline /
"concurrency stays inside Go."

**Cause:** the parser joined paragraph lines with a literal newline, and the
renderer preserves whitespace. In Markdown a lone newline inside a paragraph is
a *soft* break and means a space.

**Fix:** `MarkdownParser.joinSoftWrapped` joins with a space, keeping genuine
hard breaks (two trailing spaces, or a trailing backslash).

**Prevention:** `MarkdownTests.lineBreaks` and `wrappedSentenceJoins`, the
latter using the exact sentence that exhibited the bug.

---

## 2026-08-19 — `parent-child` and `waits-for` wrongly treated as blocking

**Symptom:** none visible; every graph metric would have been subtly wrong.

**Cause:** the initial Swift `DependencyType` declared
`{blocks, parentChild, conditionalBlocks, waitsFor}` as blocking. bv's rule is
narrower: `IsBlocking()` is `type == "" || type == "blocks"`.

**Fix:** `DependencyType.isBlocking` now matches bv exactly, including the
legacy quirk that an *empty* type blocks.

**Prevention:** `ModelTests.blockingSemantics` asserts each type individually.
Any Swift-side notion of blocking must be checked against bv's source, not
inferred from the name — this is the failure mode the "no metric is computed in
Swift" rule exists to prevent.

---

## 2026-08-19 — Graph layout ranked dependents above their blockers

**Symptom:** the dependency graph drew upside down — the bead that depends on
everything sat at the top, its blockers beneath it.

**Cause:** `GraphLayoutEngine` computed longest-path rank correctly, then
inverted it with `maxRank - rank`.

**Fix:** use the computed rank directly, so rank 0 is unblocked and each row
below waits on the row above.

**Prevention:** `QueryAndLayoutTests.layoutRanking` pins the ranks of a
three-node chain. Confirmed visually in the `graph-canvas` snapshot.

---

## 2026-08-19 — Execution plan decoded to silently empty tracks

**Symptom:** the Plan view showed track headers with no cards.

**Cause:** the Swift model expected `{id, issues: [String]}`; bv emits
`{track_id, items: [PlanItem]}`. Lenient decoding turned the mismatch into
empty arrays rather than an error.

**Fix:** model the real shape, including `PlanItem` and the plan summary.

**Prevention:** `EngineTests.executionPlan` asserts every track is non-empty
*and* that the planned set equals the actionable set. Lenient decoding needs a
positive assertion on content, since it cannot fail loudly by design.

---

## 2026-08-19 — "Compute metrics" was a no-op after opening with Phase 2 skipped

**Symptom:** opening with metrics skipped left the UI permanently unable to
compute them; the button did nothing.

**Cause:** the session was analysed once with every Phase-2 metric disabled.
That leaves `phase2Ready == true` with no values, so `wait_phase2` returned the
same empty result forever.

**Fix:** added the engine's `compute_phase2`, which re-runs a full analysis. The
UI gates on `hasPhase2Values` rather than `phase2Ready`.

**Prevention:** `engine.TestComputePhase2AfterSkip` and
`ProjectStoreTests.storeComputesPhase2`. Note the distinction the two flags
carry: "ready" and "has values" are not the same thing, and conflating them is
what produced the dead button.

---

## 2026-08-19 — Scrolling views rendered completely blank in snapshots

**Symptom:** Board, Insights, Labels and Inspector snapshots were empty —
0 % ink, one colour — while Graph, Tree and Sidebar rendered fine.

**Cause:** `ImageRenderer` does not lay out `ScrollView` content.

**Fix:** snapshots render through `NSHostingView` in an offscreen window, which
performs a real AppKit layout pass.

**Prevention:** the snapshot suite asserts ink coverage and colour variety, not
file size — a view that lays out but paints nothing still produces a valid PNG,
so "a file appeared" would have passed throughout.

---

## 2026-08-19 — Inspector reported "Unblocks 0" for a bead that unblocks six

**Symptom:** `bvx-3` showed Blocks 7, Unblocks 0.

**Cause:** the count was fetched in a `.task`, which never runs in a static
render and flashes 0 in the live app before resolving.

**Fix:** the plan and triage payloads already carry unblocks lists, so they
populate a cache the inspector reads synchronously. Genuinely-unknown values
render "—", never 0.

**Prevention:** `UnblocksCacheTests`, including that nil and `[]` stay
distinguishable, and that unblocks (6) is not conflated with blocks (7) —
`bvx-6` also waits on `bvx-12`, so closing `bvx-3` alone would not free it.

---

## 2026-08-20 — Markdown tables were collapsed onto a single line

**Symptom:** a pipe table in a bead description rendered two different wrong
ways depending on what surrounded it. Alone, `looksLikeMarkdown` returned
`false` and the rows showed as literal pipes in body font. Beside any other
Markdown, detection fired, the rows fell through to the paragraph branch, and
every row was joined into one line.

**Cause:** `MarkdownParser` had no table block. The second symptom was a side
effect of the soft-break fix: `joinSoftWrapped` is correct for prose and
destructive for a table, and nothing stopped table rows reaching it.

**Fix:** `MarkdownBlock.table(headers:rows:alignments:)`, parsed from a header
row followed by a delimiter row and rendered with SwiftUI `Grid` inside a
horizontal `ScrollView`. Detection treats `|` as a signal only when a delimiter
row follows.

**Prevention:** parser tests for alignment, ragged rows, escaped pipes in cells
and table termination, a false-positive suite covering prose like
`use a | b to pipe`, and a render snapshot. The false-positive guard is the load
bearing one — the delimiter row must have exactly as many cells as the header,
which is what stops a `---` rule under a pipe-containing sentence from reading
as a one-column table.

---

## 2026-08-20 — History was empty in a git worktree

**Symptom:** the History view reported "no history available" and the engine
returned `resolving HEAD: reference not found`, in a checkout that plainly had
commits.

**Cause:** the checkout was a *linked worktree*. There `.git` is a file
pointing at `<main>/.git/worktrees/<name>`, and the refs — HEAD included — live
in the common directory rather than beside the worktree. go-git opens such a
repository happily with `DetectDotGit` alone and only fails later, at HEAD
resolution, which reads like an empty repository rather than a misconfigured
one.

**Fix:** `PlainOpenOptions.EnableDotGitCommonDir`, which is exactly the option
for this layout.

**Prevention:** `EngineTests.historyReachable` walks the fixture workspace,
which lives inside this repository — so it exercises whatever checkout layout
the tests are run from, worktree or not.

**A second bug hid the first.** The fix appeared not to work: the Go tests
passed and the Swift ones kept failing with the old message. SwiftPM does not
treat `libbvxengine.a` as a build input, so rebuilding the engine alone does
*not* trigger a relink — `swift test` kept running the previous archive.
`build-engine.sh` now touches `Sources/BVXEngine/BeadsEngine.swift` after a
successful build to force it. Worth remembering whenever a Go-side change seems
to have no effect on the Swift side.

---

## 2026-08-20 — Two tests fought over the fixture's `.bv` directory

**Symptom:** the recipe save/delete test failed with `no project recipe named
"bvx-test-recipe"` — but only sometimes, and only when the whole suite ran. The
recipe was demonstrably saved a moment earlier, and the listing still showed it.

**Cause:** Swift Testing runs tests in parallel. The alerts test wrote a
baseline to `<fixture>/.bv/baseline.json` and cleaned up by removing the file
*and its parent directory*. `removeItem` on a directory is recursive, so it took
`<fixture>/.bv/recipes.yaml` with it — a file a different test, running at the
same moment, had just written. Whichever test lost the race reported the
failure, which is why it looked like a bug in the recipe code.

**Fix:** `Fixture.writableStore()` copies the fixture to a private temporary
directory. Any test that writes into the workspace uses it, so no two tests
share a filesystem.

**Prevention:** the two tests that write — the baseline round trip and the
recipe round trip — both go through the helper, and both assert against a
directory they own. As a side effect the checkout is no longer mutated by a
test run at all, which is worth having on its own.

---

## 2026-08-20 — The engine archive ignored the declared deployment target

**Symptom:** every Swift link printed, once per object file:

```
ld: warning: object file (libbvxengine.a[...]) was built for newer 'macOS'
    version (26.0) than being linked (14.0)
```

**Cause:** `Package.swift` declares `platforms: [.macOS(.v14)]`, but
`build-engine.sh` built the Go archive with no deployment target at all, so
every object carried the host SDK's minimum — 26.0. Not cosmetic: the app
claimed to support macOS 14 while linking objects that require 26. It runs on
the build machine and fails on the machine the deployment target promised.

**Fix:** `-mmacosx-version-min` via `CGO_CFLAGS` and `CGO_LDFLAGS`.

**The part worth remembering:** `MACOSX_DEPLOYMENT_TARGET` alone does **not**
work with this toolchain. Setting it changed nothing — the Go-linked `go.o` and
the cgo-compiled objects alike stayed at 26.0. Only the explicit
`-mmacosx-version-min` flag reaches both. The variable is still set because it
is the conventional knob and costs nothing, but it is not what fixes this.

**Prevention:** two assertions in `build-engine.sh`, because setting a flag and
assuming it worked is how this went unnoticed for so long:

- `assert_package_target` reads the platform out of `Package.swift` and refuses
  to build when the script and the manifest disagree. Nothing else would notice
  them drifting apart.
- `assert_archive_target` runs `otool -l` on the built archive and requires
  *every* object to report the expected `minos`. Checking only the first would
  have passed while the rest were wrong — the archive holds objects from two
  different tools, and a flag reaching one need not reach the others.
