#!/usr/bin/env bash
#
# Assembles vbx.app from the SwiftPM executable.
#
#   ./scripts/build-app.sh              # debug build
#   ./scripts/build-app.sh --release    # optimised
#   ./scripts/build-app.sh --run        # build, then open the demo fixture
#
# Distribution builds — see scripts/package-app.sh, which these hand off to:
#
#   ./scripts/build-app.sh --release --dmg        # signed, notarized .dmg
#   ./scripts/build-app.sh --release --app-store  # sandboxed .pkg for the App Store
#   ./scripts/build-app.sh --release --sign       # Developer ID signature, no package
#
# SwiftPM produces a bare Mach-O; macOS needs a bundle with an Info.plist for
# the app to get a Dock icon, a menu bar, and normal activation. The CLI
# binary is placed inside the bundle too, mirroring how Xcode ships `xcodebuild`
# so "Install Command Line Tool" can symlink it later.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
RUN=0
PACKAGE_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --run) RUN=1 ;;
    # Forwarded verbatim. The signing configuration and the redaction that
    # keeps account identifiers out of the log both live in one place rather
    # than being half-implemented here as well.
    --sign|--dmg|--app-store|--dry-run|--no-notarize) PACKAGE_ARGS+=("$arg") ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A distribution build is always optimised. Shipping a debug binary because the
# flag was forgotten is a mistake that survives all the way to a user.
if [[ ${#PACKAGE_ARGS[@]} -gt 0 && "$CONFIG" != release ]]; then
  echo "==> Distribution build implies --release"
  CONFIG=release
fi

cd "$ROOT"

if [[ ! -f Engine/build/libvbxengine.a ]]; then
  echo "==> Engine archive missing; building it first"
  ./scripts/build-engine.sh
fi

echo "==> Building vbx ($CONFIG)"
swift build -c "$CONFIG" --product vbx
swift build -c "$CONFIG" --product vbx-cli

BIN_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/vbx.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/vbx" "$APP/Contents/MacOS/vbx"
cp "$BIN_DIR/vbx-cli" "$APP/Contents/MacOS/vbx-cli"

if [[ -f "$ROOT/Resources/vbx.icns" ]]; then
  cp "$ROOT/Resources/vbx.icns" "$APP/Contents/Resources/vbx.icns"
else
  # Without the icon the app still runs; it just gets the generic Dock tile.
  echo "  (no Resources/vbx.icns — run ./scripts/build-icon.sh)"
fi

# The third-party licence notices the About window displays. Several of the
# engine's dependencies require their notice to be carried with the binary, and
# beads_viewer's rider must travel unmodified, so a bundle without this file is
# not distributable — hence the hard failure rather than a warning.
if [[ -f "$ROOT/Resources/ACKNOWLEDGEMENTS.md" ]]; then
  cp "$ROOT/Resources/ACKNOWLEDGEMENTS.md" "$APP/Contents/Resources/ACKNOWLEDGEMENTS.md"
else
  echo "Resources/ACKNOWLEDGEMENTS.md is missing; run ./scripts/build-notices.py" >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- The product is "Visual Beads"; `vbx` is the short form that names the
         executable, the CLI, the bundle identifier and the URL scheme.
         CFBundleName is what the menu bar shows, so it carries the real name
         rather than the abbreviation. -->
    <key>CFBundleName</key>            <string>Visual Beads</string>
    <key>CFBundleDisplayName</key>     <string>Visual Beads</string>
    <key>CFBundleIdentifier</key>      <string>com.qjam.vbx</string>
    <key>CFBundleExecutable</key>      <string>vbx</string>
    <key>CFBundleIconFile</key>        <string>vbx</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Required for an App Store submission, and harmless otherwise. -->
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <!-- vbx uses no encryption beyond what macOS itself provides; declaring it
         here is what skips the export-compliance questionnaire on every
         upload rather than answering it identically each time. -->
    <key>ITSAppUsesNonExemptEncryption</key> <false/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>    <string>Visual Beads workspace</string>
            <key>CFBundleURLSchemes</key> <array><string>vbx</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so the app launches locally without a Developer ID.
#
# Skipped for a distribution build: package-app.sh signs a staged copy with a
# real certificate, and an ad-hoc signature here would only be thrown away.
if [[ ${#PACKAGE_ARGS[@]} -eq 0 ]]; then
  codesign --force --sign - "$APP" 2>/dev/null || \
    echo "  (ad-hoc signing skipped)"
fi

echo "==> Built $APP"

if [[ ${#PACKAGE_ARGS[@]} -gt 0 ]]; then
  exec "$ROOT/scripts/package-app.sh" --app "$APP" "${PACKAGE_ARGS[@]}"
fi

if [[ $RUN -eq 1 ]]; then
  echo "==> Launching with the demo fixture"
  open -a "$APP" --args "$ROOT/Fixtures/demo"
fi
