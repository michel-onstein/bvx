#!/usr/bin/env bash
#
# The one place vbx's version comes from.
#
#   ./scripts/version.sh            # marketing version, e.g. 0.2.0
#   ./scripts/version.sh --build    # build number, e.g. 137
#   ./scripts/version.sh --check    # fail unless HEAD is a clean release tag
#
# Derived from the git tag rather than written down, because it has to agree in
# three places at once: `CFBundleShortVersionString`, the `.dmg` filename, and a
# Homebrew cask's `version`. A cask whose version disagrees with what the app
# reports cannot be upgraded — `brew` compares the two and concludes the
# installed copy is already current — and `brew info` then contradicts the About
# window. One source removes the class of mistake rather than one instance.
#
# Tags are `vX.Y.Z`. The leading `v` is a git convention and is stripped: Apple
# requires `CFBundleShortVersionString` to be dotted digits, and Homebrew's
# `version` is compared as a version string, not matched literally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Something has to be produced for an untagged checkout — a development build
# must not fail for want of a release — but it must not look like a release
# either. 0.0.0 sorts below every real tag, so a cask could never be written
# against it by accident.
UNTAGGED=0.0.0

git_available() {
  git rev-parse --git-dir >/dev/null 2>&1
}

# The most recent vX.Y.Z reachable from HEAD, with the `v` removed.
marketing_version() {
  local tag
  if ! git_available; then
    echo "$UNTAGGED"
    return
  fi
  tag="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    echo "$UNTAGGED"
    return
  fi
  echo "${tag#v}"
}

# A number that only ever increases, which is all CFBundleVersion has to be.
#
# The commit count rather than the tag: two builds of the same tag with a fix
# between them are different builds, and macOS uses this to tell them apart when
# the marketing version is identical.
build_number() {
  if ! git_available; then
    echo 1
    return
  fi
  git rev-list --count HEAD 2>/dev/null || echo 1
}

# assert_release_point refuses anything a published artefact must not be built
# from.
#
# Two separate failures, because they mislead in different ways: a dirty tree
# ships code that is in no commit, and a HEAD that has moved past its tag ships
# something the tag does not name while calling itself that version.
assert_release_point() {
  local version tag
  git_available || { echo "not a git checkout; cannot verify a release point" >&2; exit 1; }

  version="$(marketing_version)"
  if [[ "$version" == "$UNTAGGED" ]]; then
    echo "no vX.Y.Z tag is reachable from HEAD — tag the release first" >&2
    exit 1
  fi

  tag="$(git describe --tags --match 'v[0-9]*' --exact-match 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    echo "HEAD is not at a release tag (nearest is v$version)" >&2
    echo "a published version must name the commit it was built from" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "the working tree is dirty; a release must be reproducible from the tag" >&2
    git status --short >&2
    exit 1
  fi

  echo "  release point: $tag ($(git rev-parse --short HEAD)), clean tree"
}

case "${1-}" in
  "") marketing_version ;;
  --build) build_number ;;
  --check) assert_release_point ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
