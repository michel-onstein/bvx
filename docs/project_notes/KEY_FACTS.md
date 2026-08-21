# Key Facts

Project configuration and references. Never secrets.

## What this is

`vbx` — a native macOS app for beads issue graphs, implementing
[`bv`](https://github.com/Dicklesworthstone/beads_viewer) with a SwiftUI front
end over bv's own Go analysis engine.

## Document inventory

| Document | Purpose |
|---|---|
| `README.md` | Build, run, test; what works today |
| `LICENSE` | MIT plus an AI-training rider; reserved-rights terms |
| `docs/README.md` | Docs index and reading order |
| `docs/VBX_DESIGN.md` | Architecture and design specification |
| `docs/FEATURE_PARITY.md` | Every bv capability mapped to a vbx surface |
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
./scripts/build-icon.sh --check     # committed .icns + README PNG are intact
./scripts/build-icon.sh             # regenerate the icon (needs rsvg-convert)
./scripts/build-app.sh --run        # vbx.app, opened on the demo fixture
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
python3 scripts/test-packaging.py   # signing config, redaction, leak guard
python3 scripts/build-docs.py       # regenerate docs/html
```

Distribution:

```bash
./scripts/package-app.sh --check              # what is configured, what is ready
./scripts/build-app.sh --release --dmg        # Developer ID, notarized, stapled
./scripts/build-app.sh --release --app-store  # sandboxed .pkg for App Store Connect
VBX_DEVELOPER_ID_APP=- ./scripts/build-app.sh --dmg --no-notarize   # ad-hoc, local only
```

`VBX_SNAPSHOT_DIR=/tmp/vbx-snaps swift test --filter VBXUITests` keeps rendered
view snapshots for inspection.

## Layout

| Path | Contents |
|---|---|
| `Engine/bridge/engine` | Go session wrapper over bv's `pkg/*`, plus a SQLite reader |
| `Engine/bridge/cbridge` | C ABI (`vbx_open` / `vbx_call` / `vbx_close` / `vbx_free` / `vbx_probe`) |
| `Engine/smoke` | C ABI smoke test |
| `Engine/build` | Generated archive — **gitignored**, rebuild with the script |
| `Sources/VBXCore` | Value types, filtering, fuzzy search, graph layout |
| `Sources/VBXEngine` | async/await facade over the C ABI |
| `Sources/VBXAppCore` | `ProjectStore`, `FileWatchService` |
| `Sources/VBXUI` | SwiftUI views |
| `Sources/vbx`, `Sources/vbx-cli` | App shell and CLI |
| `Fixtures/demo` | 18-bead workspace used by tests and demos |
| `Resources` | App icon: generated `vbx-icon.svg` and the committed `vbx.icns` |
| `Resources/entitlements` | Developer ID entitlements, plus the App Store *template* |
| `docs/images` | `vbx-icon.png`, the same artwork at 512px for the README |
| `scripts/signing.env` | Signing configuration — **gitignored**, from `signing.env.example` |

## Gotchas

- **The engine archive is not committed.** ~29 MB and reproducible; a fresh
  clone must run `./scripts/build-engine.sh` before `swift build`. The generated
  *header* is committed, because the Swift C target needs it to compile.
- **The app icon is generated, and the `.icns` is committed.** Edit the
  control points in `scripts/make-icon.py`, never `Resources/vbx-icon.svg`.
  Unlike the engine archive the `.icns` *is* committed, because rasterising it
  needs `rsvg-convert` (`brew install librsvg`) and `build-app.sh` must be able
  to bundle an icon without it. The same run also emits
  `docs/images/vbx-icon.png` for the README, so the two cannot drift — a test
  asserts they are pixel-identical. `scripts/make-icon.py <dir> --variants`
  re-renders the palettes that were considered. See ADR-008.
- **This repo's own `.beads` store is empty** (0 issues). Point vbx at
  `Fixtures/demo` for anything with a real dependency graph.
- **Swift Testing exports its own `Issue` type**, which collides with the model.
  Test files alias it: `private typealias Bead = VBXCore.Issue`.
- **The remote is `origin` (github.com/michel-onstein/vbx)**; work lands on a
  branch and is integrated by PR, never pushed to `main` directly.
- **GUI rendering of the live window is unverified** — `screencapture`, the
  accessibility API and `CGWindowList` are permission-gated for background
  sessions. Offscreen view snapshots are the substitute.
- **App Intents are not discoverable from a `swift build`.** Shortcuts finds
  intents through a metadata bundle produced by Xcode's
  `appintentsmetadataprocessor`. SwiftPM does not run it, so the intents in
  `Sources/vbx/Intents.swift` compile and execute correctly but are only *listed*
  in Shortcuts when the app is built through Xcode, or when that step is added
  to `scripts/build-app.sh`.
- **`CSSearchableIndex.default()` and `UNUserNotificationCenter.current()` both
  raise in a process with no bundle identifier** — which is how the test suite
  and the CLI run. Availability is checked before the call, never around it,
  and both subsystems degrade to doing nothing.
- **The engine writes into `<project>/.bv/`**: the semantic search index, a
  saved baseline, drift configuration and project recipes. The first two are
  gitignored (a rebuildable cache and a local reference point); `recipes.yaml`
  is deliberately not, because it is shared configuration that `bv --recipe`
  reads too.
- **No signing identifier is in this repository, and none may be.** It is
  public. Configuration lives in the gitignored `scripts/signing.env` or the
  environment; the App Store entitlements are a template expanded into
  `.build/dist/`; and everything `package-app.sh` prints is masked, because
  `codesign -dvvv` and `security find-identity` echo the Team ID and build logs
  get pasted into issues. `scripts/test-packaging.py` asserts all three, and
  scans tracked files for the values configured locally. See ADR-009.
- **The two channels ship different apps.** `--dmg` is unsandboxed and keeps
  `vbx-cli`; `--app-store` is sandboxed and removes it, because a sandboxed app
  cannot symlink it into `/usr/local/bin`. See ADR-010.
- **`VBX_DEVELOPER_ID_APP=-` signs ad-hoc**, which makes the whole packaging
  path runnable with no certificates. It produces nothing distributable and
  says so; notarizing it is refused rather than attempted.
- **Discovery does not walk upwards.** bv's `GetBeadsDir` checks `<path>/.beads`
  and, for a linked checkout, the main repository's — nothing else. A folder
  *below* a project root is therefore not openable, which is why the Open
  panel's guard asks `vbx_probe` rather than testing for `.beads` itself: the
  set of openable paths is wider in one direction (a workspace root holds
  `.bv/workspace.yaml` and no `.beads`) and narrower in another.
- **Tests that write into a workspace must use `Fixture.writableStore()`**,
  which copies the fixture to a temporary directory. Swift Testing runs tests
  in parallel, and two of them writing to the shared fixture interfered — see
  BUGS.md.
