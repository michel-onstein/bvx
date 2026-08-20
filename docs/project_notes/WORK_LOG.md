# Work Log

No ticket IDs: this repo's beads store is empty, so entries are dated and
described. Newest first.

---

## 2026-08-19 — Conventions compliance pass

Brought the repo in line with the global conventions after re-reading them.

- Renamed `docs/bvx-design.md` → `docs/BVX_DESIGN.md` and
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
that unblocks six. Views moved to a `BVXUI` library so tests can import them.

## 2026-08-19 — Triage recommendations

Scored recommendations with the engine's reasoning, quick wins, and blockers to
clear, in the Insights dashboard. Gated on `hasPhase2Values`, since the score
derives from PageRank and betweenness.

## 2026-08-19 — Markdown report export

bv's `pkg/export` wired through the bridge, so the report is byte-identical to
`bv --export-md`. Available from the File menu, `bvx-cli export-md`, and the
engine's `export_markdown`. Archive grew 24 MB → 29 MB.

## 2026-08-19 — Live reload and label analytics

FSEvents watching the containing directory (atomic renames defeat a
descriptor-level watch), debounced at 200 ms, with a content-hash gate so an
incidental touch costs one parse and no analysis. Labels dashboard over the
engine's `label_health`.

## 2026-08-19 — bvx implemented

Native macOS app over bv's Go engine via `c-archive` and a C ABI. Seven views,
inspector, filters, sorting, fuzzy search, bv's single-key bindings alongside
native menu shortcuts, and a CLI with a `doctor` self-check. ~6,200 lines of
implementation.

## 2026-08-19 — Design document

`docs/BVX_DESIGN.md` and `docs/FEATURE_PARITY.md`, derived from a study of
upstream bv, plus a static HTML build with vendored Mermaid.
