# bvx — project instructions

A native macOS app for beads issue graphs: a SwiftUI front end over the Go
analysis engine of [`bv`](https://github.com/Dicklesworthstone/beads_viewer).

## Document index

| Document | ADR | Description | State |
|---|---|---|---|
| [BVX_DESIGN.md](docs/BVX_DESIGN.md) | ADR-001 | Architecture: engine reuse, C ABI bridge, data model, UI, distribution | Built |
| [FEATURE_PARITY.md](docs/FEATURE_PARITY.md) | — | Every bv capability mapped to a bvx surface and delivery phase | Living |
| [project_notes/BUGS.md](docs/project_notes/BUGS.md) | — | Bug log with the regression test locking each fix in | Living |
| [project_notes/DECISIONS.md](docs/project_notes/DECISIONS.md) | ADR-001…007 | Architectural decisions and their trade-offs | Living |
| [project_notes/KEY_FACTS.md](docs/project_notes/KEY_FACTS.md) | — | Toolchain, commands, layout, gotchas | Living |
| [project_notes/WORK_LOG.md](docs/project_notes/WORK_LOG.md) | — | Dated work log | Living |

`docs/html/` is generated from `docs/*.md` by `scripts/build-docs.py`; never
edit it by hand.

## Rules specific to this repo

These are not in `bv --help` or the global conventions, and nothing else records
them.

- **No metric is ever computed in Swift.** The engine owns every number; Swift
  does layout and formatting only. Graph *layout* is Swift because it is
  presentation, not analysis. Reimplementing a metric "just to avoid a round
  trip" reintroduces exactly the drift ADR-001 exists to prevent.
- **An unavailable metric is absent, never zero.** Phase-2 dictionaries are
  omitted rather than zero-filled, and the UI shows the metric's status. Note
  `phase2Ready` and `hasPhase2Values` are different: everything-skipped is
  "ready" with nothing in it.
- **Decoding never drops a record.** Status, type and dependency-type enums are
  open. A dropped issue silently changes every downstream metric.
- **An empty dependency type blocks**, matching bv's rule for rows written
  before the typed system. Only `""` and `blocks` block — not `parent-child`,
  not `waits-for`.
- **The engine archive is not committed.** Run `./scripts/build-engine.sh`
  before `swift build` in a fresh clone. The generated header *is* committed,
  because the Swift C target needs it to compile.
- **Snapshot tests must not use `ImageRenderer`** — it does not lay out
  `ScrollView` content, so scrolling views render blank and pass a naive
  file-exists check. Use `NSHostingView`, and assert on ink coverage.
- **`.task` and `.onAppear` do not run in a snapshot.** Prefer data the store
  already holds; that constraint is why the unblocks cache exists.
- **Swift Testing exports its own `Issue` type.** Test files alias the model:
  `private typealias Bead = BVXCore.Issue`.
- **Tests that write into a workspace use `Fixture.writableStore()`**, which
  copies the fixture to a temporary directory. Swift Testing runs tests in
  parallel, and two writing to the shared fixture interfere.
- **Triage includes a bounded git-history walk**, because bv's does and it
  moves the scores. It is capped at 200 commits with a 10 s timeout, and
  reports `history_status` so an absent staleness signal is distinguishable
  from a low one.

## Verify before committing

```bash
./scripts/build-engine.sh --check   # Go archive + C ABI smoke test
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
gofmt -l Engine/bridge              # must print nothing
python3 scripts/parity-check.py     # bvx-cli vs bv, command by command
```

The parity check needs `bv` on the PATH. Without it every comparison is
reported as *skipped* rather than passing, so a missing `bv` cannot look like
agreement. It exits non-zero when any comparable command differs, or when a
command it declares is not implemented.

Biome is not configured here (no `package.json`, and Biome does not format
Markdown). Go is formatted with `gofmt`.
