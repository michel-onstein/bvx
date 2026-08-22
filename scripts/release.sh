#!/usr/bin/env bash
#
# Takes a tag all the way to a Homebrew-installable release.
#
#   ./scripts/release.sh --dry-run           # prove the plan, build nothing
#   ./scripts/release.sh --tag v0.2.0        # tag, build, package, render cask
#   ./scripts/release.sh                     # same, for the tag HEAD already has
#   ./scripts/release.sh --publish           # ...and push the tag + GitHub release
#   ./scripts/release.sh --lint-cask         # brew style + audit the cask, build nothing
#
# What this exists to prevent is a cask that cannot work. A cask points at one
# versioned URL with one checksum, and three separate things have to line up
# with it: the version the app reports, the artefact actually published, and the
# `sha256` in the cask file. Any of them edited by hand drifts, and the symptom
# is a user's `brew install` failing on a checksum mismatch — or worse,
# succeeding and installing something that cannot launch.
#
# So every one of them is derived here, in one pass, from the tag:
#
#   scripts/version.sh   the tag -> CFBundleShortVersionString
#   build-app.sh --dmg   universal, Developer ID signed, notarized, stapled
#   shasum               the checksum of the file that will be uploaded
#   the cask template    rendered with all three
#
# Notarization is not optional here. `--no-notarize` exists for local builds;
# a cask installing an un-notarized app gives every user a Gatekeeper block, so
# this script refuses to produce one and fails rather than warns if the ticket
# did not staple.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/.build/dist"
TEMPLATE="$ROOT/packaging/homebrew/vbx.rb.template"

TAG=""
DRY_RUN=0
PUBLISH=0
LINT_CASK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --lint-cask) LINT_CASK=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

say() { echo "$@"; }
fail() { echo "error: $*" >&2; exit 1; }

# Derived from the remote so a fork does not publish a cask pointing at this
# repository's releases.
cask_repo() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  printf '%s' "$remote" | sed -E 's#^.*github\.com[:/]##; s#\.git$##'
}

# render_cask <version> <sha256> <destination>
render_cask() {
  local version="$1" sha="$2" dest="$3" repo homepage url
  repo="$(cask_repo)"
  [[ -n "$repo" ]] || fail "could not read owner/repo from the origin remote"
  homepage="https://github.com/$repo"
  url="$homepage/releases/download/v$version/vbx-$version.dmg"
  mkdir -p "$(dirname "$dest")"
  sed -e "s|@VERSION@|$version|g" \
      -e "s|@SHA256@|$sha|g" \
      -e "s|@URL@|$url|g" \
      -e "s|@REPO@|$repo|g" \
      -e "s|@HOMEPAGE@|$homepage|g" \
      "$TEMPLATE" > "$dest"
}

# ---------------------------------------------------------------------------
# --lint-cask: the mechanical checks, without a release
# ---------------------------------------------------------------------------
#
# `brew install --cask` on a clean Mac is the check that matters and it cannot
# be run here — it needs a published release and a machine that has never seen
# the build. `brew style` and `brew audit` are what catch the problems that can
# be caught early, and they caught four on the first run: a missing
# frozen-string comment, "macOS" in a cask description, mis-grouped stanzas and
# an unsorted `zap` array. None of those needed a build to find, so this does
# not require one.
#
# The checksum is a placeholder: the linters check the file's shape, and a real
# checksum would mean building a real disk image to compute it.
if [[ $LINT_CASK -eq 1 ]]; then
  command -v brew >/dev/null 2>&1 || fail "brew is not on the PATH"
  [[ -f "$TEMPLATE" ]] || fail "missing $TEMPLATE"

  LINT_VERSION="$("$ROOT/scripts/version.sh")"
  LINT_SHA="$(printf '0%.0s' {1..64})"
  # A tap-shaped directory: Homebrew picks its cask-specific cops from the
  # Casks/ path, and a file outside one is linted as plain Ruby.
  LINT_TAP="$DIST/lint/homebrew-tap"
  rm -rf "$LINT_TAP"
  render_cask "$LINT_VERSION" "$LINT_SHA" "$LINT_TAP/Casks/vbx.rb"

  say "==> brew style"
  brew style "$LINT_TAP/Casks/vbx.rb"

  say ""
  say "Linted ${LINT_TAP#"$ROOT"/}/Casks/vbx.rb (version $LINT_VERSION, placeholder checksum)."
  say ""
  say "brew audit is not run here: it takes a cask *name*, which only resolves"
  say "for an installed tap, and installing one is more than a linter should do."
  say "It belongs to the tap repository, once the cask is in it:"
  say "  brew audit --cask --new michel-onstein/tap/vbx"
  say ""
  say "The check that cannot be run anywhere but a clean Mac, after a release:"
  say "  brew install --cask vbx && open -a vbx"
  exit 0
fi
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    say "  would run: $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
#
# Everything that can be checked before anything is built, is. A release that
# fails after notarization has already burned several minutes of Apple's queue
# and, if a tag was pushed, has left a version number spent.

if [[ -n "$TAG" ]]; then
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "a release tag is vX.Y.Z (got \"$TAG\")"
fi

say "==> Preflight"

[[ -f "$TEMPLATE" ]] || fail "missing $TEMPLATE"

for tool in git shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on the PATH"
done
if [[ $PUBLISH -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || fail "gh is not on the PATH; it is what --publish uses"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  git status --short >&2
  fail "the working tree is dirty; a release must be reproducible from its tag"
fi

# The signing and notarization configuration, asked about now rather than
# discovered forty minutes into a build. Not wrapped in `run`: a dry run whose
# whole purpose is to prove the plan must actually check this, and unconfigured
# signing is the plan being proven false.
"$ROOT/scripts/package-app.sh" --check

if [[ -n "$TAG" ]]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG already exists; a published version is never re-cut"
  fi
  say "==> Tagging $TAG"
  run git tag -a "$TAG" -m "vbx $TAG"
fi

# In a dry run the tag was not actually created, so the check below would fail
# on the very thing the run is rehearsing. Reported instead.
if [[ $DRY_RUN -eq 1 && -n "$TAG" ]]; then
  VERSION="${TAG#v}"
  say "  release point: $TAG (would be created at $(git rev-parse --short HEAD))"
else
  "$ROOT/scripts/version.sh" --check
  VERSION="$("$ROOT/scripts/version.sh")"
fi

DMG="$DIST/vbx-$VERSION.dmg"
say "  version $VERSION -> ${DMG#"$ROOT"/}"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
#
# --dmg implies --release and --universal. Stated rather than passed, so that
# reading this does not require reading build-app.sh to know what ships.

say "==> Building a universal, signed, notarized disk image"
if [[ $DRY_RUN -eq 1 ]]; then
  "$ROOT/scripts/build-app.sh" --dmg --dry-run
else
  "$ROOT/scripts/build-app.sh" --dmg
fi

# ---------------------------------------------------------------------------
# Verify the artefact, not the flags
# ---------------------------------------------------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
  say "==> Verifying the disk image"
  [[ -f "$DMG" ]] || fail "expected $DMG; package-app.sh named it something else"

  # Stapling is the difference between an app that opens and one that shows
  # "cannot be opened because Apple cannot check it for malicious software" on a
  # machine that is offline or behind a proxy.
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || \
    fail "the notarization ticket is not stapled to $DMG"
  say "  notarization ticket: stapled"

  # Gatekeeper's own verdict, which is what the user's Mac will reach.
  spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/  /'

  SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
  say "  sha256 $SHA256"
else
  SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  say "==> Skipping artefact verification (dry run); the checksum below is a placeholder"
fi

# ---------------------------------------------------------------------------
# The cask
# ---------------------------------------------------------------------------

CASK="$DIST/vbx.rb"
render_cask "$VERSION" "$SHA256" "$CASK"

# Linted here too, not only under --lint-cask: this is the copy that gets
# pasted into the tap, and a cask that fails `brew style` is one the tap's own
# CI will reject after the release has already been published.
if command -v brew >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
  say "==> brew style"
  brew style "$CASK" || fail "the rendered cask fails brew style"
fi

say ""
say "==> Cask written to ${CASK#"$ROOT"/}"
say ""
sed 's/^/    /' "$CASK"
say ""

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

if [[ $PUBLISH -eq 1 ]]; then
  say "==> Pushing $([[ -n "$TAG" ]] && echo "$TAG" || echo "v$VERSION")"
  run git push origin "v$VERSION"
  say "==> Creating the GitHub release"
  run gh release create "v$VERSION" "$DMG" \
    --title "vbx $VERSION" --generate-notes
else
  say "Not published. To publish:"
  say "  git push origin v$VERSION"
  say "  gh release create v$VERSION ${DMG#"$ROOT"/} --title \"vbx $VERSION\" --generate-notes"
fi

say ""
say "Then, in the tap repository (michel-onstein/homebrew-tap):"
say "  cp ${CASK#"$ROOT"/} Casks/vbx.rb && brew audit --cask --new Casks/vbx.rb && brew style Casks/vbx.rb"
say "  git commit -am \"vbx $VERSION\" && git push"
say ""
say "The check that cannot be run here — on a Mac that has never seen this build:"
say "  brew tap michel-onstein/tap && brew install --cask vbx && open -a vbx"
