# Bug Log

Found-and-fixed issues, with the regression test that locks each fix in.

---

## 2026-08-22 — The signing config had been dead since the rename, and said nothing

**Symptom:** `./scripts/package-app.sh --check` reported *"no distribution
channel is configured. Copy scripts/signing.env.example to scripts/signing.env,
or export the settings."* — with a complete, filled-in `scripts/signing.env`
sitting right there, all seven keys set.

**Cause:** the project was renamed from bvx to vbx in #13. The scripts were
renamed with it; the local config file was not. Every key in it was still
`BVX_TEAM_ID`, `BVX_DEVELOPER_ID_APP` and so on, and nothing reads those. The
file is `source`d, so the assignments succeeded — they just landed on variables
no one looks at.

What made it survive so long is the *wording of the failure*. "No distribution
channel is configured" reads as "you have not set this up yet", so the natural
response is to go and set it up, find the file already correct, and conclude the
check is about something else. A message can be accurate and still point away
from the cause.

It also made a real capability look absent: with the prefix fixed, `--check`
reports **"Developer ID cert — in the keychain"**. The certificate had been
there the whole time.

**Fix:** the config loader greps for `^BVX_` and refuses with the actual
diagnosis and the one-line `sed` that repairs it, rather than falling through to
the generic "unconfigured" path. The local `signing.env` was repaired with that
exact command (original kept as `signing.env.bvx-backup`).

**Prevention:** `test-packaging.py` drives `--check` with a fabricated `BVX_`
config and asserts it is rejected *by name* — and with a `VBX_` one, asserting
it is not flagged, so the guard cannot start firing on a correct file.

---

## 2026-08-22 — The first host build after a universal one refused to run

**Symptom:** `./scripts/build-engine.sh` failed with

```
build output ".../Engine/build/libvbxengine.a" already exists and is not an object file
```

Found while running the verify block immediately after a `--universal` build,
which is exactly when a person would hit it: the flag is new, so the state it
leaves behind is new too.

**Cause:** `go build -o` will overwrite an object file it produced, and refuses
anything else. A universal archive is a *fat* file rather than an object file,
so once `--universal` had written one, every subsequent host-only build stopped
on it. The error names the archive, not the flag that produced it, so the
obvious reading — a corrupt build directory — is wrong.

Latent before today in that `--universal` existed; unreachable in practice
because nothing called it. Wiring it into every distribution build is what made
it a normal thing to hit.

**Fix:** `build_slice` removes its target first. The universal path already
overwrote through `lipo -create`, which has no such restriction, so only the
host path needed it — but it is done in `build_slice` so both are covered.

**Prevention:** `test-packaging.py` asserts the archive is cleared before the
slice is built.

---

## 2026-08-22 — Every launch from the Dock opened onto an error

**Symptom:** launching vbx from the Dock or Finder showed **"Could not open
workspace"** with an error triangle, every time, before the user had asked for
anything. Launching it from a terminal that happened to be sitting in a
workspace worked, which is how it had been tested and why it was not caught.

**Cause:** `openInitialWorkspace()` tried a path argument, then `VBX_WORKSPACE`,
then `FileManager.default.currentDirectoryPath` — and *opened* each rather than
asking whether it could be opened. A GUI app launched from Finder or the Dock
has a current directory of `/`, which holds no `.beads`, so the third candidate
always failed, set `loadError`, and the error state won over the neutral "No
workspace open" state sitting a few lines below it in `ContentView`. It also
never consulted the recents list, although `RecentWorkspaces.shared` already
held exactly "the last workspace opened".

The distinction that had been lost: **"nothing to open yet" is not "what you
asked for failed."** `loadError` should mean the user pointed at something and
it did not work.

**Fix:** candidates are *probed* — `BeadsEngine.probe`, the same discovery code
the Open panel greys rows with — rather than opened, so a dead candidate is
skipped instead of producing an error. The order gained the recents list: a path
argument, `VBX_WORKSPACE`, the recent workspaces, then the current directory.
When none probes openable, nothing opens and `loadError` stays nil, so the
existing empty state appears on its own with its Choose Workspace… button. No
new UI was needed.

Two neighbours moved with it. A restored window goes through
`openRestoredWorkspace(path:)`, which probes for the same reason — being told a
folder you did not choose this session has vanished is the same unhelpful error,
one launch later. And a path the user *named* on the command line or in
`VBX_WORKSPACE` still reports why it failed, provided it exists: a stray launch
argument (`YES`, left behind by `-NSDocumentRevisionsDebugMode`) names nothing
and must stay silent.

**Prevention:** `LaunchDiscoveryTests` — ten cases, including the guard against
over-correcting: `open(path:)` on a folder holding no beads must still set
`loadError`, or a fix here could quietly make every failure silent.

---

## 2026-08-22 — Scrolling the bead list crashed the app

**Symptom:** open a workspace with more beads than fit in the window, scroll the
list, and vbx dies with `EXC_BREAKPOINT` on the main thread. The crash report
names `PriorityCell.body` and
`SwiftUICore/EnvironmentObject.swift:93: Fatal error: No ObservableObject of
type ProjectStore found`. It reproduced on a 327-bead workspace and never on
vbx's own 38, which made it look workspace-specific — a bad data row, or the
engine — rather than a property of how many rows were on screen.

**Cause:** `PriorityCell` read the store with `@EnvironmentObject`. It is the
only table cell that is its own `View`; every other column's cell closure
captures `IssueListView`'s store directly, so only this one depended on what the
cell's environment contains. macOS `Table` bridges to `NSTableView` and builds a
cell's subgraph when its row scrolls into view, and that subgraph does not carry
the `environmentObject` injected around `ContentView` in `WorkspaceWindow`. So
the lookup resolved for the rows laid out on the first pass and trapped on the
first row created after it. A workspace small enough to fit on screen never
creates one, which is exactly why the repo's own beads never showed it.

The `SearchContentKey` frames in the report are incidental — that was merely the
preference being combined during the layout pass that built the new cell. The
search field is not involved.

**Fix:** the store is handed in — `@ObservedObject var store` and
`PriorityCell(store: store, issue:)` — which is what the other nine columns
already do, made explicit because this cell is a separate type. Observation is
unchanged; only the lookup is.

**Checked, not assumed:** every other surface was swept for the same shape — a
standalone `View` with `@EnvironmentObject` inside a container that builds
children lazily. Board, Plan, Labels, Tree, Insights, Attention, Sprint, Alerts,
History, Flow, Sidebar and Inspector were each hosted in a short window and
scrolled past their content; all survived. `LazyVStack` and `LazyVGrid` stay in
the same view graph and do inherit the environment. `Table` was the only
container that loses it, and `PriorityCell` was its only environment-reading
cell.

**Prevention:** `PriorityCellTests` does both halves.
`scrollingTheListCreatesCellsThatKeepTheirStore` hosts the real `IssueListView`
in a 220pt window — short on purpose, so the fixture's rows cannot all lay out
on the first pass — and scrolls past the content; it traps on the fixture's 18
beads if the `@EnvironmentObject` returns, verified by reverting the fix.
`rendersWithoutAnEnvironmentObjectAncestor` states the invariant directly by
rendering the cell with no `environmentObject` anywhere above it. Both fail by
trapping rather than by reporting, because `EnvironmentObject.error()` is a
`fatalError` — the regression takes the process down, which is itself the
signal.

The general lesson is the one the sweep encodes: a view that renders correctly
at full size proves nothing about the children a container builds later. The
existing snapshot tests all render at a size where everything fits, which is the
blind spot this slipped through.

---

## 2026-08-22 — Recipes never loaded, so the feature looked inert

**Symptom:** the sidebar's Recipes section offered "New recipe…" and nothing
else, in every workspace. The feature appeared to do nothing, and was reported
that way.

**Cause:** `loadRecipes()` guards on `isLoaded` and was called from exactly
three places — the sidebar section's `.task`, `saveRecipe` and `deleteRecipe`.
**Nothing called it when a workspace opened.** The sidebar renders immediately
at launch, before any workspace has loaded, so its `.task` fired while
`isLoaded` was still false, returned early, and never ran again: `.task` does
not re-run when the value it depended on changes. The one call that would have
populated the list ran at the only moment it could not work.

Measured by driving the store directly — after `open`, `recipes` was empty; an
explicit `loadRecipes()` immediately returned eleven. `vbx-cli --robot-recipes`
listed all eleven for the same workspace throughout, so nothing below the store
was ever wrong.

**Fix:** load them in `open(path:)` after `refreshAll()`, and in
`reload(force:)` on the changed path — recipes live in the workspace, so an edit
on disk can add or remove one. The `.task` is gone: two mechanisms for one job,
and the view-driven one was the half that could not be relied on.

**Prevention:** `openingLoadsRecipes` asserts the list is populated after
`open`, and reports `recipes → []` against the unfixed store.
`loadedRecipesAreUsable` guards the shape of the fix — loading a list that
cannot be applied would satisfy the first test while leaving the feature just as
inert. `noWorkspaceMeansNoRecipes` pins the legitimately-empty case, which is
what made this bug easy to mistake for "recipes do nothing".

---

## 2026-08-21 — The Open panel could not be navigated to a workspace

**Symptom:** folders without `.beads` could not be double-clicked to enter
them, so a workspace below one was unreachable — the panel was only usable if
it happened to open inside a workspace already. Meanwhile *every* file was
selectable, greyed out or not.

**Cause, part one:** `OpenPanelGuard.panel(_:shouldEnable:)` returned
`canOpen(url.path)` for directories as well as files, and the type's own
documentation asserted that was safe: *"AppKit still lets the user navigate
into a disabled directory, which is essential."* It does not. A disabled
directory cannot be entered, and since every folder on the way to a repository
is itself unopenable, each was a dead end.

**Cause, part two:** `resolveSource`'s non-directory branch returned
`(path, "jsonl")` for anything that was not `.db`/`.sqlite`/`.sqlite3`, without
checking extension or content. Measured: `README.md`, `Package.swift` and a
binary `vbx.icns` all probed `can_open=true`. So `shouldEnable` said yes to
every file and the failure arrived later, in the loader — the panel/loader
disagreement `Probe`'s header says it exists to design out.

**Fix:** directories are always enabled and `panel(_:validate:)` — which
already existed for exactly this, and refuses with a reason — is the gate.
Greying now applies to files only, and the engine accepts a file by extension
(`.jsonl`, `.db`, `.sqlite`, `.sqlite3`). Content is deliberately not sniffed:
an empty or mid-write `issues.jsonl` is still the file the user means, and
refusing it here would break the documented fallback to `beads.db`.

**Also corrected:** `Probe`'s header claimed discovery "does *not* walk
upwards". A folder inside a git checkout does resolve to the repository root's
`.beads` — `Sources/deep` is openable — while the same layout *outside* git is
refused. Git is what decides it, and the two cases look identical on disk, so
both are now asserted: `TestProbeAcceptsAFolderInsideAGitRepository` alongside
the existing `TestProbeRefusesAFolderBelowOneWithBeads`.

**Prevention:** `unopenableFolderStaysNavigable` asserts an unopenable folder
stays *enabled*, paired with `unopenableFolderIsRefusedOnValidate` so a fix for
one cannot silently undo the other. `nonBeadFileIsDisabled` and
`beadDataFileStaysEnabled` pin both directions of the file rule — refusing
every file would "fix" the greying by switching the panel's file support off.
The existing `refusesEmptyFolder` was rewritten rather than deleted: it no
longer asserts the row is greyed, and says why.

---

## 2026-08-21 — A second workspace opened behind the first one's filters

**Symptom:** open one workspace, filter it, open another — and the list comes up
empty with no visible cause. The sidebar shows a filter nobody chose for this
workspace, and an empty table reads as "this workspace has no beads".

**Cause:** `open(path:)` swapped the workspace but left `query` (filter, search
text, labels, assignees, sort), `repoFilter`, the active recipe with its ids,
and the two alert filters exactly as the previous workspace left them. Labels,
assignees, repository names and a recipe's ids are all workspace-specific
strings, so after a switch they typically match nothing. Observed in the
failing test: `recipeIDs` still held `["vbx-12", "vbx-3", "vbx-14"]` — beads of
the workspace that had just been closed.

The rule was already stated twice in that same function and simply never
carried to filters: `resetNavigationHistory()` ("the previous workspace's beads
do not exist in this one"), and `refreshAll` keeping only selected ids the
fresh set still holds.

**Fix:** `resetWorkspaceFilters()` returns all of it to initialiser defaults,
called from `open(path:)` before `refreshAll()` so the first render is already
unfiltered. Gated on the resolved `info.source` actually changing, so reopening
the workspace already open leaves it alone. `surface` is deliberately *not*
reset: which view you are on is not a filter, it names nothing inside the
workspace, and someone comparing two workspaces in one view wants to stay in it.

**Prevention:** `openingAnotherWorkspaceResetsFilters` sets every listed filter,
opens a copy of the fixture at its own path, and asserts each default plus a
non-empty list; it fails nine assertions against the unfixed store.
`reloadPreservesFilters` is the half that matters just as much — resetting
inside `refreshAll` would satisfy the first test while wiping the filter on
every watcher tick, and `reload` exists precisely to keep the view stable while
the file changes underneath. `surfaceIsNotAFilter` pins the exclusion so it
cannot be "tidied up" later.

---

## 2026-08-21 — Triage staleness counted commits bv does not see

**Symptom:** `stale_count` disagreed with `bv --robot-triage` on the same
workspace. Reproduced against bv v0.20.0 in a repository holding three months-
old open beads plus one recent commit naming a bead in its message while
touching no bead record: bv reported 3 stale, vbx reported 2.

Invisible on the demo fixture — every bead there is recently active, so
staleness is `null` in both tools and the parity harness reported a match. It
takes a bead old enough to cross the 14-day threshold before the two disagree.

**Cause:** vbx correlates a commit to a bead two ways — the commit edited the
bead's record beside code (co-committed), or the commit *message* names the
bead (explicit). bv's triage path only ever has the first: it derives its
commits from the beads-file events, and its `ExplicitMatcher` is never
constructed anywhere in bv's own `pkg/` or `cmd/`. `ComputeStaleness` takes the
latest of a bead's events and commits, so an explicit-only commit made a bead
look freshly worked to vbx and stale to bv. Staleness is 10 % of the triage
score, so this moved the whole ranking, not one field.

**Fix:** `historyForTriage` hands triage a narrowed copy keeping only commits
whose SHA also appears among that bead's own events — exactly the set bv
derives. Narrowing by *method label* would have been wrong: a commit that both
names a bead and edits its record is recorded as explicit here but is a
co-commit to bv, so dropping it by label swaps one divergence for another.
Explicit correlation is untouched everywhere else — it is the History view's
whole point, and it is genuinely better, since bv's own patterns require a
numeric suffix and miss every `br`-minted id like `vbx-8ou`.

**Prevention:** `TestTriageStalenessIgnoresExplicitOnlyCommits` builds that
repository and asserts `stale_count`; it reports 1 against the unfixed engine.
`TestTriageNarrowingLeavesTheCachedReportIntact` guards the other direction —
the report is cached and shared with the History view, so narrowing a copy
rather than the original is load-bearing. `TestHistoryForTriageKeepsOnlyEvent`
`Commits` pins the SHA-based rule against a hand-built report.

---

## 2026-08-20 — The leak scan flagged nine files that held no secret

**Symptom:** the first run against a real `scripts/signing.env` reported
`FileWatchService.swift`, `Keychain.swift`, `build-app.sh`, `package-app.sh`,
`test-packaging.py` and the template itself as carrying "a configured signing
value". None of them did.

**Cause:** the scan took every value in the config file longer than eight
characters. `VBX_BUNDLE_ID=com.qjam.vbx` is one of them — and it is committed
in `Info.plist`, the scripts and the Swift sources, deliberately. A partly
filled config also still holds the template's placeholders, which by definition
match the template.

**Fix:** scan only the settings that are actually secret — Team ID, the three
certificate names, the provisioning profile path. The bundle identifier is
public by design, and the notary *profile name* is local rather than secret
(the credential it names stays in the keychain). Values still equal to a
placeholder are skipped.

**Prevention:** `test_the_leak_scan_still_detects` asserts both directions
against a planted config: a real Team ID and a real certificate name *are*
scanned for, the bundle id and notary profile are *not*, and an untouched
template yields nothing. Narrowing a detector risks switching it off, and a
detector that fires on everything gets ignored — which is the same outcome by a
longer route.

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

**Symptom:** `vbx-3` showed Blocks 7, Unblocks 0.

**Cause:** the count was fetched in a `.task`, which never runs in a static
render and flashes 0 in the live app before resolving.

**Fix:** the plan and triage payloads already carry unblocks lists, so they
populate a cache the inspector reads synchronously. Genuinely-unknown values
render "—", never 0.

**Prevention:** `UnblocksCacheTests`, including that nil and `[]` stay
distinguishable, and that unblocks (6) is not conflated with blocks (7) —
`vbx-6` also waits on `vbx-12`, so closing `vbx-3` alone would not free it.

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
treat `libvbxengine.a` as a build input, so rebuilding the engine alone does
*not* trigger a relink — `swift test` kept running the previous archive.
`build-engine.sh` now touches `Sources/VBXEngine/BeadsEngine.swift` after a
successful build to force it. Worth remembering whenever a Go-side change seems
to have no effect on the Swift side.

---

## 2026-08-20 — Two tests fought over the fixture's `.bv` directory

**Symptom:** the recipe save/delete test failed with `no project recipe named
"vbx-test-recipe"` — but only sometimes, and only when the whole suite ran. The
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
ld: warning: object file (libvbxengine.a[...]) was built for newer 'macOS'
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
