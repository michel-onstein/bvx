#!/usr/bin/env bash
#
# Builds bv's Go engine into a static archive that the Swift app links against.
#
#   ./scripts/build-engine.sh            # build for the host architecture
#   ./scripts/build-engine.sh --universal  # arm64 + x86_64, lipo'd together
#   ./scripts/build-engine.sh --check    # build, then run the C ABI smoke test
#
# The archive is intentionally not committed: it is ~25 MB and reproducible
# from the pinned beads_viewer module version in Engine/bridge/go.mod.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/Engine/bridge"
BUILD="$ROOT/Engine/build"
OUT="$BUILD/libbvxengine.a"
HEADER_DEST="$ROOT/Sources/CBVXEngine/include/libbvxengine.h"

UNIVERSAL=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --check) CHECK=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$BUILD"
cd "$BRIDGE"

build_slice() {
  local arch="$1" out="$2"
  echo "  building darwin/$arch"
  CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" \
    go build -buildmode=c-archive -trimpath -o "$out" ./cbridge
}

echo "==> Building bvx engine archive"
if [[ $UNIVERSAL -eq 1 ]]; then
  build_slice arm64 "$BUILD/libbvxengine-arm64.a"
  build_slice amd64 "$BUILD/libbvxengine-amd64.a"
  echo "  lipo -> universal"
  lipo -create "$BUILD/libbvxengine-arm64.a" "$BUILD/libbvxengine-amd64.a" -output "$OUT"
  # Both slices generate the same header; keep the arm64 one.
  cp "$BUILD/libbvxengine-arm64.h" "$BUILD/libbvxengine.h"
  rm -f "$BUILD"/libbvxengine-{arm64,amd64}.{a,h}
else
  build_slice "$(go env GOARCH)" "$OUT"
fi

# The Swift C target reads the header from its include directory, so keep the
# committed copy in step with whatever the build just generated.
cp "$BUILD/libbvxengine.h" "$HEADER_DEST"

echo "==> Built $(du -h "$OUT" | cut -f1) archive"
lipo -info "$OUT" 2>/dev/null || true

# SwiftPM does not treat the archive as a build input, so a rebuilt engine on
# its own does NOT trigger a relink — `swift test` happily keeps running the
# previous archive. That failure mode is genuinely confusing: the Go tests pass,
# the Swift ones fail, and the fix appears not to have taken. Touching a source
# file in the target that links it forces the relink.
touch "$ROOT/Sources/BVXEngine/BeadsEngine.swift"

if [[ $CHECK -eq 1 ]]; then
  echo "==> Running C ABI smoke test"
  cc -o "$BUILD/smoke" "$ROOT/Engine/smoke/smoke.c" "$OUT" \
    -I"$BUILD" -framework CoreFoundation -framework Security
  "$BUILD/smoke" "$ROOT/Fixtures/demo"
fi
