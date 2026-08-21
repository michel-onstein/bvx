#!/usr/bin/env bash
#
# Turns the icon artwork into the .icns the app bundle carries.
#
#   ./scripts/build-icon.sh           # regenerate Resources/vbx.icns from the SVG
#   ./scripts/build-icon.sh --check   # verify the committed .icns without rewriting it
#
# Regenerating needs `rsvg-convert` (brew install librsvg); --check needs only
# the macOS tools, so a fresh clone can verify the committed icon even without
# librsvg installed. That is why vbx.icns is committed while the engine archive
# is not: `build-app.sh` must be able to bundle an icon on a bare machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/Resources/vbx-icon.svg"
ICNS="$ROOT/Resources/vbx.icns"
# The README cannot display an .icns, so the same artwork is also emitted as a
# PNG. It is generated here rather than exported by hand so it cannot drift.
PNG="$ROOT/docs/images/vbx-icon.png"
PNG_PX=512
CHECK=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# name:pixels — the ten representations macOS expects in an .icns.
REPS=(
  "icon_16x16:16"      "icon_16x16@2x:32"
  "icon_32x32:32"      "icon_32x32@2x:64"
  "icon_128x128:128"   "icon_128x128@2x:256"
  "icon_256x256:256"   "icon_256x256@2x:512"
  "icon_512x512:512"   "icon_512x512@2x:1024"
)

if [[ $CHECK -eq 1 ]]; then
  [[ -f "$ICNS" ]] || { echo "missing $ICNS — run ./scripts/build-icon.sh" >&2; exit 1; }
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # Expanding the committed .icns and measuring each PNG checks the shape of
  # the file rather than its bytes, so a different librsvg version on another
  # machine cannot make an intact icon look stale.
  iconutil --convert iconset --output "$TMP/vbx.iconset" "$ICNS"
  fail=0
  for rep in "${REPS[@]}"; do
    name="${rep%%:*}"; px="${rep##*:}"
    png="$TMP/vbx.iconset/$name.png"
    if [[ ! -f "$png" ]]; then
      echo "  missing representation: $name" >&2; fail=1; continue
    fi
    got_w="$(sips -g pixelWidth "$png" | awk '/pixelWidth/{print $2}')"
    got_h="$(sips -g pixelHeight "$png" | awk '/pixelHeight/{print $2}')"
    if [[ "$got_w" != "$px" || "$got_h" != "$px" ]]; then
      echo "  $name is ${got_w}x${got_h}, expected ${px}x${px}" >&2; fail=1
    fi
  done
  if [[ ! -f "$PNG" ]]; then
    echo "  missing $PNG — run ./scripts/build-icon.sh" >&2
    fail=1
  else
    got="$(sips -g pixelWidth "$PNG" | awk '/pixelWidth/{print $2}')"
    [[ "$got" == "$PNG_PX" ]] || {
      echo "  docs/images/vbx-icon.png is ${got}px, expected ${PNG_PX}px" >&2
      fail=1
    }
  fi
  [[ $fail -eq 0 ]] || { echo "==> icon check FAILED" >&2; exit 1; }
  echo "==> icon check ok (10 representations, 16px through 1024px, plus the README PNG)"
  exit 0
fi

command -v rsvg-convert >/dev/null || {
  echo "rsvg-convert not found; install it with: brew install librsvg" >&2
  exit 1
}

echo "==> Generating $SVG"
python3 "$ROOT/scripts/make-icon.py" "$ROOT/Resources" >/dev/null

ICONSET="$(mktemp -d)/vbx.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

echo "==> Rasterising 10 representations"
for rep in "${REPS[@]}"; do
  name="${rep%%:*}"; px="${rep##*:}"
  rsvg-convert -w "$px" -h "$px" "$SVG" -o "$ICONSET/$name.png"
done

iconutil --convert icns --output "$ICNS" "$ICONSET"
echo "==> Built $ICNS ($(du -h "$ICNS" | cut -f1))"

mkdir -p "$(dirname "$PNG")"
rsvg-convert -w "$PNG_PX" -h "$PNG_PX" "$SVG" -o "$PNG"
echo "==> Built $PNG (${PNG_PX}px, for the README)"
