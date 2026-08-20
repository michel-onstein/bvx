#!/usr/bin/env bash
#
# Assembles bvx.app from the SwiftPM executable.
#
#   ./scripts/build-app.sh              # debug build
#   ./scripts/build-app.sh --release    # optimised
#   ./scripts/build-app.sh --run        # build, then open the demo fixture
#
# SwiftPM produces a bare Mach-O; macOS needs a bundle with an Info.plist for
# the app to get a Dock icon, a menu bar, and normal activation. The CLI
# binary is placed inside the bundle too, mirroring how Xcode ships `xcodebuild`
# so "Install Command Line Tool" can symlink it later.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
RUN=0

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

if [[ ! -f Engine/build/libbvxengine.a ]]; then
  echo "==> Engine archive missing; building it first"
  ./scripts/build-engine.sh
fi

echo "==> Building bvx ($CONFIG)"
swift build -c "$CONFIG" --product bvx
swift build -c "$CONFIG" --product bvx-cli

BIN_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/bvx.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/bvx" "$APP/Contents/MacOS/bvx"
cp "$BIN_DIR/bvx-cli" "$APP/Contents/MacOS/bvx-cli"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>bvx</string>
    <key>CFBundleDisplayName</key>     <string>bvx</string>
    <key>CFBundleIdentifier</key>      <string>com.qjam.bvx</string>
    <key>CFBundleExecutable</key>      <string>bvx</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>    <string>bvx workspace</string>
            <key>CFBundleURLSchemes</key> <array><string>bvx</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so the app launches locally without a Developer ID.
codesign --force --sign - "$APP" 2>/dev/null || \
  echo "  (ad-hoc signing skipped)"

echo "==> Built $APP"

if [[ $RUN -eq 1 ]]; then
  echo "==> Launching with the demo fixture"
  open -a "$APP" --args "$ROOT/Fixtures/demo"
fi
