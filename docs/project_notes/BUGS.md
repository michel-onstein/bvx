# Bug Log

Found-and-fixed issues, with the regression test that locks each fix in.

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
