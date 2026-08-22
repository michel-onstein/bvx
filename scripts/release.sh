#!/usr/bin/env bash
#
# Takes a tag all the way to a Homebrew-installable release.
#
#   ./scripts/release.sh --dry-run           # prove the plan, build nothing
#   ./scripts/release.sh --tag v0.2.0        # tag, build, package, render cask
#   ./scripts/release.sh                     # same, for the tag HEAD already has
#   ./scripts/release.sh --publish           # ...and push the tag + GitHub release
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

say() { echo "$@"; }
fail() { echo "error: $*" >&2; exit 1; }
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

# Derived from the remote so a fork does not publish a cask pointing at this
# repository's releases.
REMOTE="$(git remote get-url origin 2>/dev/null || true)"
REPO="$(printf '%s' "$REMOTE" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
[[ -n "$REPO" ]] || fail "could not read owner/repo from the origin remote"
HOMEPAGE="https://github.com/$REPO"
URL="$HOMEPAGE/releases/download/v$VERSION/vbx-$VERSION.dmg"

CASK="$DIST/vbx.rb"
mkdir -p "$DIST"
sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SHA256@|$SHA256|g" \
    -e "s|@URL@|$URL|g" \
    -e "s|@REPO@|$REPO|g" \
    -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
    "$TEMPLATE" > "$CASK"

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
