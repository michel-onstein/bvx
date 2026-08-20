# Key Facts

Project configuration and references. Never secrets.

## What this is

`bvx` — a native macOS app for beads issue graphs, implementing
[`bv`](https://github.com/Dicklesworthstone/beads_viewer) with a SwiftUI front
end over bv's own Go analysis engine.

## Document inventory

| Document | Purpose |
|---|---|
| `README.md` | Build, run, test; what works today |
| `docs/README.md` | Docs index and reading order |
| `docs/BVX_DESIGN.md` | Architecture and design specification |
| `docs/FEATURE_PARITY.md` | Every bv capability mapped to a bvx surface |
| `docs/project_notes/BUGS.md` | Bug log with regression tests |
| `docs/project_notes/DECISIONS.md` | ADRs |
| `docs/project_notes/KEY_FACTS.md` | This file |
| `docs/project_notes/WORK_LOG.md` | Work log |
| `docs/html/` | Generated static HTML of `docs/*.md` |

## Toolchain

| Tool | Version verified |
|---|---|
| Swift | 6.3.3 (Xcode 26.6), package builds in language mode 5 |
| Go | 1.26.6 (`darwin/arm64`) |
| Minimum macOS | 14.0 |
| Upstream `bv` | `github.com/Dicklesworthstone/beads_viewer v0.20.0` |

Biome is referenced by the global conventions but is **not configured in this
repo** — there is no `package.json`, and Biome does not format Markdown. Go is
formatted with `gofmt`.

## Build and test commands

```bash
./scripts/build-engine.sh --check   # Go archive + C ABI smoke test
./scripts/build-app.sh --run        # bvx.app, opened on the demo fixture
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
python3 scripts/build-docs.py       # regenerate docs/html
```

`BVX_SNAPSHOT_DIR=/tmp/bvx-snaps swift test --filter BVXUITests` keeps rendered
view snapshots for inspection.

## Layout

| Path | Contents |
|---|---|
| `Engine/bridge/engine` | Go session wrapper over bv's `pkg/*`, plus a SQLite reader |
| `Engine/bridge/cbridge` | C ABI (`bvx_open` / `bvx_call` / `bvx_close` / `bvx_free`) |
| `Engine/smoke` | C ABI smoke test |
| `Engine/build` | Generated archive — **gitignored**, rebuild with the script |
| `Sources/BVXCore` | Value types, filtering, fuzzy search, graph layout |
| `Sources/BVXEngine` | async/await facade over the C ABI |
| `Sources/BVXAppCore` | `ProjectStore`, `FileWatchService` |
| `Sources/BVXUI` | SwiftUI views |
| `Sources/bvx`, `Sources/bvx-cli` | App shell and CLI |
| `Fixtures/demo` | 18-bead workspace used by tests and demos |

## Gotchas

- **The engine archive is not committed.** ~29 MB and reproducible; a fresh
  clone must run `./scripts/build-engine.sh` before `swift build`. The generated
  *header* is committed, because the Swift C target needs it to compile.
- **This repo's own `.beads` store is empty** (0 issues). Point bvx at
  `Fixtures/demo` for anything with a real dependency graph.
- **Swift Testing exports its own `Issue` type**, which collides with the model.
  Test files alias it: `private typealias Bead = BVXCore.Issue`.
- **No git remote is configured**; all commits are local.
- **GUI rendering of the live window is unverified** — `screencapture`, the
  accessibility API and `CGWindowList` are permission-gated for background
  sessions. Offscreen view snapshots are the substitute.
