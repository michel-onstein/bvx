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

---

## ADR-006 — Correlation reads the git object store directly, not `git`

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** bv's `pkg/correlation` reaches git through exactly one choke
point — a hardcoded `exec.Command("git")` in `gitcmd.go`. It exposes no
interface, no func-typed field and no settable runner to supply that data
another way; the only levers from outside are `WithContext`, the repo path, and
`PATH`. The App Sandbox forbids spawning that binary, so `Correlator` and
everything built on it is unreachable from the app.

What *is* reachable is everything downstream of the report. `FileLookup`,
`BuildFileIndex`, `NetworkBuilder`, `HistoryReport.BuildCausalityChain` and
`HistoryReport.FindRelatedWork` are pure functions over a `*HistoryReport`
whose fields are all exported, and none of them touches git.

**Decision.** Build the `*HistoryReport` ourselves by walking the object store
with `go-git`, then hand it to bv's own analyses. Scoring stays bv's:
confidences come from `correlation.CalculateConfidence` and
`correlation.MethodRanges`, milestones from `correlation.GetBeadMilestones`,
cycle times from `correlation.CalculateCycleTime`, and the beads file at each
commit is parsed with `loader.ParseIssues`. This is not a second opinion about
the numbers — it is the same code, fed different input.

**Consequences.**

- One code path serves the app and the CLI, so there is no pair of correlation
  engines to keep in agreement.
- `go-git` joins the dependency set. It is pure Go, so the archive still links
  as a `c-archive` with no new system requirements; it costs about 6 MB.
- **Temporal-author correlation is not implemented.** It needs a repo-wide
  author/time query that only pays for itself as a `git log` subprocess, and bv
  rates it lowest of the three methods (0.20–0.85). Explicit-ID and co-commit
  attribution, which bv rates 0.70–0.99 and 0.85–0.99, are both present.
- **Explicit matching is membership-driven, not pattern-driven.** bv's built-in
  patterns require a numeric suffix (`[A-Za-z]+-\d+`) and would miss every id
  `br` mints — `bvx-8ou`, `whois-q1rfj`. Ids are matched against the loaded
  workspace first, so no id format is assumed and an id the workspace does not
  hold is never linked. bv's patterns still run, for the classic
  `PROJECT-123` style.
- **Orphan detection is ours.** bv's `OrphanDetector` re-queries git whatever
  report it is handed, so it cannot run sandboxed. The replacement scores the
  same four signals — files, timing, message, author — with weights summing to
  100 so each contribution stays legible beside the total.
- The walk computes a patch per commit for line counts, so it is capped at
  bv's own `DefaultHistoryLimit` of 500 and cached until the bead set changes.
  An unchanged reload deliberately keeps the cache; only a changed one drops it.

---

## ADR-007 — TOON is encoded in Go, not delegated to `tru`

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** bv contains no TOON encoder. It imports a Go wrapper that shells
out to the Rust `tru` binary, and when that binary is absent it prints a
warning to stderr and emits JSON instead. bv's own TOON tests skip when `tru`
is missing, and beads_viewer ships no TOON goldens — the only normative data is
toon_rust's fixture corpus.

That is a poor contract to inherit. `--format toon` would produce a different
format depending on what happened to be installed, the App Sandbox forbids
spawning the binary anyway, and a format that silently degrades is worse than
one that is unavailable.

**Decision.** A pure-Go implementation of TOON spec v3.0 in the engine. No
subprocess, no external dependency, identical output on every machine.

**Consequences.**

- `bvx-cli --format toon` always emits TOON, and works under the sandbox.
- Key order had to be preserved through the JSON parse. Go randomises map
  iteration, and TOON's whole point is a stable compact rendering, so the
  decoder builds an ordered value rather than a `map[string]any`.
- The spec's twelve encode fixtures are the test suite, copied verbatim. The
  quoting rules are where a naive implementation goes wrong in both
  directions: `05` and `-dash` must be quoted, `café` and `你好` must not.
- **Version drift is a live risk.** toon_rust implements v3.0, where an empty
  array is `key[0]:`. The published spec is now v4.1, which mandates `key: []`
  and only accepts the older form as legacy. v3.0 is implemented here because
  that is what today's `tru` — and therefore bv — produces.
