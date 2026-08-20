# Architectural Decision Records

---

## ADR-001 — Reuse bv's Go engine rather than reimplement it in Swift

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** bv is ~85k lines of Go: roughly 34k of Bubble Tea terminal UI and
~50k of platform-neutral engine — tolerant loading, a two-phase analyser
computing nine graph metrics with per-metric deadlines, git correlation, search
and export. bvx needs the same numbers with a native UI.

**Decision.** Compile bv's non-UI packages with `go build -buildmode=c-archive`,
expose them through a small C ABI, and replace only the UI with Swift.

**Alternatives.**

- *Full Swift rewrite.* Rejected: ~50k lines whose behaviour is subtle
  (approximation thresholds, timeout semantics, confidence blending). Its bugs
  would surface as plausible-but-wrong numbers, the worst failure mode for a
  decision-support tool, and upstream tracking becomes manual forever.
- *Sidecar `bv` binary over robot JSON.* Kept only as the Phase-0 scaffold. No
  shared warm state, a process spawn per query, and an embedded binary to
  notarize.

**Consequences.**

- Metrics match upstream by construction; tracking a bv release is a version
  bump. Verified end-to-end: `bvx-cli` reports PageRank 0.2013 for the bead that
  blocks seven others, computed by bv's own code.
- cgo is required, and the archive is ~29 MB (24 MB before `pkg/export`).
- `internal/datasource` is not importable across modules, so bvx carries its own
  SQLite reader — the one piece deliberately duplicated.

**Rule this imposes:** *no metric is ever computed in Swift.* Layout and
formatting only. Graph layout is Swift because it is presentation, not analysis.

---

## ADR-002 — An unavailable metric is absent, never zero

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** bv's Phase-2 metrics can be `computed`, `approx`, `timeout` or
`skipped`. A timed-out betweenness rendered as `0.000` reads as "this is not a
bottleneck" — a confident falsehood.

**Decision.** Phase-2 dictionaries are omitted from the wire format rather than
zero-filled. The UI renders the metric's status instead of a value, and
disables sorting by a metric that has not been computed.

**Consequences.** `phase2Ready` and `hasPhase2Values` are distinct and both
needed — everything-skipped is "ready" with nothing in it. Conflating them
produced the dead "compute metrics" button (see BUGS.md).

---

## ADR-003 — Decoding must never drop a record

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** beads is an evolving ecosystem; bv accepts Gastown statuses
(`role`, `agent`, `molecule`) it does not enumerate, three spellings of a
dependency target, and comment ids as UUID or integer.

**Decision.** `IssueStatus`, `IssueType` and `DependencyType` are open enums
with a catch-all case. Unknown values render; they never throw.

**Consequences.** A dropped issue silently changes every downstream metric, so
this is a correctness rule rather than a robustness nicety. Each tolerance has
a test pinning it.

---

## ADR-004 — Views live in a library, not the executable

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** A Swift test target cannot import an executable target, so neither
`ProjectStore` nor any view was testable while they lived in `Sources/bvx`.

**Decision.** `BVXAppCore` holds application state, `BVXUI` holds views. The
executable is a thin `@main` shell.

**Consequences.** The state layer and every view are verifiable headlessly.
This mattered more than expected: GUI verification via screenshot, the
accessibility API and `CGWindowList` are all permission-gated, and offscreen
rendering was the only route available.

---

## ADR-005 — Snapshot rendering uses NSHostingView, not ImageRenderer

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** `ImageRenderer` is the obvious choice and needs no permissions, but
it does not lay out `ScrollView` content — four views rendered entirely blank
through it.

**Decision.** Render through `NSHostingView` in an offscreen window, and assert
on ink coverage and colour variety rather than file size.

**Consequences.** `.task` and `.onAppear` still do not run, so views should
prefer data the store already holds — which is what motivated the unblocks
cache. Snapshots are closer to what the app actually draws.
