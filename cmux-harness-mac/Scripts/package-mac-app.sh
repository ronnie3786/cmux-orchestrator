#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
BUILD_DIR="$APP_DIR/.build/release"
DIST_DIR="$APP_DIR/.build/dist"
APP_BUNDLE="$DIST_DIR/cmux Harness.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PYTHON_RESOURCES="$RESOURCES/Python"

cd "$APP_DIR"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$APP_DIR/.build/module-cache}" swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$PYTHON_RESOURCES"

cp "$BUILD_DIR/cmux-harness-mac" "$MACOS/cmux-harness-mac"
cp "$REPO_ROOT/dashboard.py" "$PYTHON_RESOURCES/dashboard.py"
rsync -a \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$REPO_ROOT/cmux_harness" \
  "$PYTHON_RESOURCES/"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>cmux-harness-mac</string>
  <key>CFBundleIdentifier</key>
  <string>dev.ronnierocha.cmux-harness.mac</string>
  <key>CFBundleName</key>
  <string>cmux Harness</string>
  <key>CFBundleDisplayName</key>
  <string>cmux Harness</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Expose the cmux harness server to local browser and iPhone clients.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
  <key>NSMicrophoneUsageDescription</key>
  <string>Record voice notes to attach to cmux session messages.</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS/cmux-harness-mac"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi
echo "$APP_BUNDLE"
