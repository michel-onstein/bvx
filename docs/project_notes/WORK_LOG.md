# Work Log

Entries are dated, newest first, and cite their bead where one exists. The
store was empty until 2026-08-21, so earlier entries carry no id.

---

## 2026-08-21 — Open panel navigation, and bead selection as navigation

`vbx-kjh`, `vbx-8ea`.

The panel fix is in BUGS.md. Worth repeating here: the guard's own doc comment
stated the AppKit behaviour it depended on, and that statement was wrong. Both
halves of the new rule are now asserted in pairs — enabled *and* refused on OK,
files greyed *and* bead data still offered — because each half alone reads as a
sensible thing to "simplify" later.

**Selecting a bead now records a position** (`vbx-8ea`), reversing the choice
made in `vbx-8lk` a few hours earlier. That choice — refresh the current
position in place, because `j`/`k` browsing is not navigation — left back
unable to return to the bead just read, which is the commonest thing to want
back for.

The objection behind it was still real: with a twenty-position cap, key repeat
would evict every surface position within a screenful. So a *run* of selections
inside `navigationCoalesceWindow` (0.5 s) collapses into the position it ends
on, and back leaves the whole run in one step. Both behaviours are tested, and
the clock is injectable so the run test is deterministic rather than racing a
real interval.

One robustness point found by that test: the window is a half-open range, not a
bare `<`. A negative interval means the clock moved backwards — an NTP step, or
a test installing its own clock — and treating that as "the same run" silently
merges positions. Recording is the harmless reading.

---

## 2026-08-21 — Filters reset on a workspace switch

`vbx-ozd`. See BUGS.md. Opening a second workspace inherited the first one's
filters, and because labels, assignees, repo names and a recipe's ids are
workspace-specific strings, the new workspace typically came up empty with
nothing on screen explaining why.

The reset is gated on the resolved source changing rather than run on every
`open`, and it sits before `refreshAll()` so the first render is already
unfiltered. `surface` is left alone on purpose — it is not a filter — and there
is a test pinning that, so the exclusion reads as a decision rather than an
oversight.

---

## 2026-08-21 — Five open beads: list columns, link affordances, view history

`bvx-iyc`, `bvx-4xw`, `vbx-tdk`, `vbx-8lk`, `bvx-hsv`. Four UI changes and one
parity bug, landed together.

**Priority column moved after ID** (`bvx-iyc`) and **labels drawn as pills**
(`bvx-4xw`). The pill fill is 0.18 rather than the 0.12 `StatusChip` uses,
because that chip's tint is *coloured* while a label's is grey: measured
against the window background, a neutral capsule at 0.12 scores the same ink as
bare text (0.049 vs 0.043) — it renders, it just cannot be seen. The test
compares pill against bare text instead of a fixed threshold, which is the only
form that catches this.

SwiftUI's `Table` exposes no list of its columns, so the column order is pinned
by reading `IssueListView.swift` in the test. Unusual, but the order is exactly
what an unrelated edit reshuffles unnoticed.

**Bead-link affordances** (`vbx-tdk`). Linked ids already drew in the accent
colour — SwiftUI does that for any `.link` — so the visible gap was narrower
than the bead assumed. Added an explicit tint (so the styling does not depend
on the rendering context), an underline, and a pointing-hand cursor.
`.pointerStyle(.link)` is macOS 15 and this package targets 14, so the cursor
rides as an `appKit.cursor` attribute on the linked range — precise, unlike an
`onHover` over the whole `Text`. Whether AppKit honours that attribute inside a
SwiftUI `Text` is not assertable headlessly; the tests pin that the attribute is
set on exactly the linked run, and the runtime behaviour wants a look in the
running app.

**Navigation history** (`vbx-8lk`). Twenty positions, back/forward at the
leading end of the toolbar. A position is surface *plus* focused bead: following
a bead link changes selection without changing surface, and that is the move
back exists to undo. Row browsing (`j`/`k`, a table click) updates the current
position in place instead of pushing one — pushing per row would evict all
twenty within a screenful — while `select(id:)`, the deliberate jump, pushes.
The cursor rules are what make forward work: back moves a cursor rather than
popping, a new move mid-history truncates the forward branch, and restoring
never re-records.

**Triage staleness parity** (`bvx-hsv`) — see BUGS.md. The bead carried only a
title, so the divergence was found by running vbx and bv side by side over
purpose-built repositories until they disagreed.

---

## 2026-08-21 — Licence: MIT with an AI training rider

The repo had no `LICENSE` at all, which defaults to all rights reserved and
leaves anyone reading the public source unsure whether they may build it. It now
carries the unmodified MIT grant plus a rider that reserves one use: feeding the
source to model training, fine-tuning, distillation, RAG indexing or corpus
construction. The rider is written as a narrowing condition on the MIT grant and
says so in its own text, so nobody mistakes the result for OSI-approved MIT —
the file's title is "MIT License with AI Training Rider" rather than "MIT
License".

Two carve-outs keep it from over-reaching: using an AI assistant while working
on or with vbx is explicitly permitted, as is a model reading the source
transiently at inference time without retaining it. The restriction is about
corpora, not tools.

A closing section states what the licence does *not* cover — the Go modules in
`Engine/bridge/go.mod`, and beads_viewer, whose engine vbx links unmodified.
Those keep their own terms. Copyright is held by Michel Onstein.

---

## 2026-08-20 — App icon

vbx had no `CFBundleIconFile` and no `.icns`, so it took the generic macOS
placeholder in the Dock. Nothing upstream was reusable: `bv` has no mark at all,
`br` has an AI-drawn robot illustration that will not scale to 32px, and beads
itself has only the teal "bd" tile Docusaurus scaffolds as a default favicon.
The beaded chain from `br`'s illustration was the one idea worth keeping.

The mark is four white beads on a curved strand with a teal X tucked into the
bottom-right corner, on a near-black slate body. Artwork is generated by
`scripts/make-icon.py` — bead centres are sampled at equal arc length along one
quadratic Bézier, so spacing stays even as the curve flattens — and
`scripts/build-icon.sh` rasterises the ten representations into
`Resources/vbx.icns`. Three palettes were rendered at 512/128/64/32/16px before
graphite was chosen; `--variants` regenerates them. ADR-008 records why the
`.icns` is committed when the engine archive is not.

The same run also emits `docs/images/vbx-icon.png`, the README's hero image, so
it cannot be left behind when the artwork changes — a test asserts it is
pixel-identical to the icon's 512px representation.

`AppIconTests.swift` measures edge density inside the icon body per
representation. Both failure modes were confirmed to fail the suite before the
thresholds were fixed: a gradient tile with no artwork on it, and artwork
bleeding into the transparent squircle margin that macOS clips. The first pass
missed the flat tile entirely — colour-diversity ink coverage counted the
transparent margin as ink — which is why the measure is local contrast instead.

Tests: 336 → 341 Swift.

---

## 2026-08-20 — Signed distribution: a notarized .dmg and an App Store .pkg

`scripts/package-app.sh` signs and packages the app for both channels;
`build-app.sh --release --dmg` and `--app-store` build the bundle and hand off
to it. `--check` reports what is configured and which channel is ready,
`--dry-run` prints the plan without running anything.

**The channels ship different apps** (ADR-010). Developer ID is unsandboxed,
hardened-runtime, keeps `vbx-cli` and the shell hooks. The App Store build is
sandboxed, embeds the provisioning profile, and *removes* `vbx-cli` — a
sandboxed app cannot symlink it into `/usr/local/bin`, so shipping it would put
an unusable binary in the bundle. Packaging always works on a staged copy, so an
`--app-store` run cannot quietly delete the CLI from the developer's own build.

**Nothing account-specific is in the repository** (ADR-009), which is the part
that needed care rather than typing. Configuration is a gitignored
`scripts/signing.env` or the environment; the App Store entitlements are a
template expanded into `.build/dist/` at mode 600, because
`com.apple.application-identifier` must contain the Team ID verbatim; and every
line the script prints goes through `redact`, since `codesign -dvvv` and
`security find-identity` echo the Team ID and build logs get pasted into public
issues.

`scripts/test-packaging.py` — 65 checks — drives the real script with fabricated
credentials and asserts they do not come back out. It found two bugs that
review would not have:

- **Masking order.** A certificate name contains the Team ID, so masking the
  Team ID first left a string that no longer matched the full name, and the
  developer's *name* survived into the log. Longest first.
- **Short values.** The ad-hoc identity is a single `-`; masking it replaced
  every hyphen in the output, turning flags and paths into
  `<DEVELOPER_ID_APP>`. Only values of six characters or more are masked.

It also scans every tracked file for the values configured locally, and says so
when there is no configuration to check against rather than passing silently.

Verified end to end with an ad-hoc signature (`VBX_DEVELOPER_ID_APP=-`): a real
26 MB `.dmg` that mounts, carries a valid signature inside and out, and an App
Store bundle that signs with the expanded entitlements and drops the CLI. Both
scripts were checked under `/bin/bash` 3.2, not just the Homebrew bash 5.

Still not built, and now said so in §17: the universal binary, the Sparkle
appcast, and the Homebrew cask.

---

## 2026-08-20 — List multi-selection, a row context menu, and an Open-panel guard

Three beads (`vbx-jpn`, `vbx-tlv`, `vbx-roq`).

**Multi-selection.** `ProjectStore.selectedID` became `selection: Set<Issue.ID>`
plus a derived `focusedID`. Everything that follows the cursor — the inspector,
the graph, history — binds to `focusedID`, so a multi-row selection does not
leave those surfaces guessing which of several beads they are describing. The
focus rule is "the row just added, or the first survivor when the focused one
leaves the selection", which keeps a filter change or a recipe from blanking the
inspector.

**Context menu.** Attached with `.contextMenu(forSelectionType:)`, which is what
makes "the selected beads, or the one right-clicked when it is not selected"
fall out of AppKit rather than being reconstructed from mouse position. The menu
is structured around none / one / several from the start. First item is Copy ID;
several ids join with `", "` **in screen order**, since a `Set` iterates in hash
order and the same action could otherwise put two different strings on the
clipboard.

**Open-panel guard.** `vbx_probe` — a new, session-less C entry point — answers
"could this path be opened?" without loading it, and `OpenPanelGuard` is an
`NSOpenSavePanelDelegate` over it. The answer comes from the same discovery code
`open` runs, so the panel and the loader cannot disagree.

The literal rule (a folder containing `.beads`) is not the rule implemented,
because it is wrong in both directions: it would refuse a multi-repository
workspace root, which holds `.bv/workspace.yaml` while its `.beads` directories
live in the repositories below it, and it would accept a folder below a project
root — discovery does *not* walk upwards, so opening that fails. Greying is
advisory; `panel(_:validate:)` is the actual gate, because a path typed into
Go-to-folder never passes through `shouldEnable`.

336 Swift tests, Go suite green, parity 9 matched / 0 differed.

---

## 2026-08-19 — Markdown in the bead detail view

The inspector renders a bead's description as Markdown when it contains any:
headings, paragraphs, bullet and numbered lists, fenced code with a language
label, blockquotes, rules, and inline emphasis / code / links.

Detection is deliberately conservative — bead prose is full of identifiers like
`data_hash`, so single underscores are not treated as emphasis and plain prose
renders verbatim. Parsing lives in `VBXCore` (pure, 24 tests); rendering is
`MarkdownText` in `VBXUI`.

Two bugs found by looking at the snapshots: a greedy blockquote rule, and
soft line breaks rendered as hard ones. Both logged in BUGS.md.

---

## 2026-08-19 — Conventions compliance pass

Brought the repo in line with the global conventions after re-reading them.

- Renamed `docs/vbx-design.md` → `docs/VBX_DESIGN.md` and
  `docs/feature-parity.md` → `docs/FEATURE_PARITY.md`, updating every reference
  (both docs' cross-links, `README.md`, `docs/README.md`,
  `scripts/build-docs.py` nav order) and regenerating `docs/html`.
- Converted the two remaining ASCII diagrams to Mermaid: the window-anatomy
  wireframe in the design doc, and the architecture chain in `README.md`. The
  directory listings stay as plain code blocks, which the rule allows.
- Added the project `CLAUDE.md` document index.
- Added `docs/project_notes/` (BUGS, DECISIONS, KEY_FACTS, WORK_LOG).
- Added the missing regression test for the inspector unblocks bug
  (`UnblocksCacheTests`, 5 tests).
- Updated `Status:` lines and the parity matrix to match what is actually built.

---

## 2026-08-19 — Offscreen view snapshot tests

12 tests rendering every view to PNG. Caught three real defects: scrolling views
rendering blank under `ImageRenderer`, dead gaps in the Insights grid from
`LazyVGrid` row alignment, and the inspector reporting Unblocks 0 for a bead
that unblocks six. Views moved to a `VBXUI` library so tests can import them.

## 2026-08-19 — Triage recommendations

Scored recommendations with the engine's reasoning, quick wins, and blockers to
clear, in the Insights dashboard. Gated on `hasPhase2Values`, since the score
derives from PageRank and betweenness.

## 2026-08-19 — Markdown report export

bv's `pkg/export` wired through the bridge, so the report is byte-identical to
`bv --export-md`. Available from the File menu, `vbx-cli export-md`, and the
engine's `export_markdown`. Archive grew 24 MB → 29 MB.

## 2026-08-19 — Live reload and label analytics

FSEvents watching the containing directory (atomic renames defeat a
descriptor-level watch), debounced at 200 ms, with a content-hash gate so an
incidental touch costs one parse and no analysis. Labels dashboard over the
engine's `label_health`.

## 2026-08-19 — vbx implemented

Native macOS app over bv's Go engine via `c-archive` and a C ABI. Seven views,
inspector, filters, sorting, fuzzy search, bv's single-key bindings alongside
native menu shortcuts, and a CLI with a `doctor` self-check. ~6,200 lines of
implementation.

## 2026-08-19 — Design document

`docs/VBX_DESIGN.md` and `docs/FEATURE_PARITY.md`, derived from a study of
upstream bv, plus a static HTML build with vendored Mermaid.

## 2026-08-20 — The remainder of vbx

Closed all sixteen open beads. Highlights, in the order they landed:

- **vbx-ee7** Markdown tables — parsed and rendered; the bug was that
  `joinSoftWrapped` collapsed rows onto one line.
- **vbx-8y4** Bead ids in prose link to their bead, membership-driven so no id
  format is hardcoded and a stale id stays plain text.
- **vbx-6qy** Column-header sorting, sharing one sort value with the toolbar
  and bv's `s` cycle so they cannot disagree.
- **vbx-8ou** Git correlation without a `git` subprocess (ADR-006), reading the
  object store with go-git and feeding bv's own pure analyses.
- **vbx-dpz** Flow matrix and attention views.
- **vbx-v49** History view: commits, timeline, causality, files, hotspots,
  orphans, and confirm/reject feedback.
- **vbx-hai** Time travel with per-bead diff badges.
- **vbx-k1s** Alerts, baselines and drift.
- **vbx-k51** Recipes, written to bv's own `.bv/recipes.yaml`.
- **vbx-k06** Sprint dashboard with burndown and capacity.
- **vbx-6w3** Hybrid search with live weights and score breakdowns.
- **vbx-e3y** Multi-repository workspaces.
- **vbx-1gn** App Intents, `vbx://`, Spotlight, CLI installer.
- **vbx-pk8** Static site export with in-process GitHub Pages deployment.
- **vbx-erx** Interactive tutorial.
- **vbx-fl1** Robot-protocol parity: a pure-Go TOON encoder (ADR-007) and a
  parity harness diffing `vbx-cli` against `bv`.

The parity harness earned its place immediately: it caught that vbx's triage
scores disagreed with bv's, because bv feeds a bounded git-history report into
the scorer and vbx did not. That is now fixed, and nine commands compare byte
for byte.

Tests: 104 → 304 Swift, plus a substantially expanded Go suite.
