#!/bin/bash
# Build CCUsageBar.app using only the Command Line Tools (no Xcode required).
# Usage:
#   ./build.sh          build into ./build/CCUsageBar.app
#   ./build.sh --run    build, then (re)launch the app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/CCUsageBar/CCUsageBar"
OUT="$ROOT/build"
BUILD_DIR="${CCUSAGEBAR_BUILD_DIR:-$OUT}"
APP="$BUILD_DIR/CCUsageBar.app"
ENTITLEMENTS="$SRC/CCUsageBar.entitlements"

echo "› Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build the Swift executable through SwiftPM so package dependencies are
# resolved even when using only the Command Line Tools.
if [[ -n "${CCUSAGEBAR_ARCH:-}" ]]; then
  swift build -c release --product CCUsageBar --triple "${CCUSAGEBAR_ARCH}-apple-macosx12.0"
  cp "$ROOT/.build/${CCUSAGEBAR_ARCH}-apple-macosx/release/CCUsageBar" "$APP/Contents/MacOS/CCUsageBar"
else
  swift build -c release --product CCUsageBar
  cp "$ROOT/.build/release/CCUsageBar" "$APP/Contents/MacOS/CCUsageBar"
fi

# Build AppIcon.icns from the asset-catalog PNGs (Xcode would normally do this).
ICONSRC="$SRC/Assets.xcassets/AppIcon.appiconset"
if [[ -f "$ICONSRC/icon_512.png" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  cp "$ICONSRC/icon_16.png"   "$ICONSET/icon_16x16.png"
  cp "$ICONSRC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
  cp "$ICONSRC/icon_32.png"   "$ICONSET/icon_32x32.png"
  cp "$ICONSRC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
  cp "$ICONSRC/icon_128.png"  "$ICONSET/icon_128x128.png"
  cp "$ICONSRC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
  cp "$ICONSRC/icon_256.png"  "$ICONSET/icon_256x256.png"
  cp "$ICONSRC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
  cp "$ICONSRC/icon_512.png"  "$ICONSET/icon_512x512.png"
  cp "$ICONSRC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "✓ Built app icon"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CCUsageBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.lionhylra.CCUsageBar</string>
  <key>CFBundleName</key><string>CCUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "APPL" > "$APP/Contents/PkgInfo"

echo "› Signing (ad-hoc)…"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"

echo "✓ Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  # Quit any running instance first so we don't stack menu-bar icons.
  pkill -f "CCUsageBar.app/Contents/MacOS/CCUsageBar" 2>/dev/null || true
  sleep 0.5
  open "$APP"
  echo "✓ Launched (look for the bar-chart icon in the menu bar)"
fi
