#!/bin/bash
# Build the native app: swift build + assemble Token Monitor.app + ad-hoc sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/native-app"
BUNDLE="$ROOT/dist/Token Monitor.app"

# Redirect SwiftPM's temp/module caches into the workspace (the DSH file
# sandbox blocks writes to /var/folders) and disable SwiftPM's own
# sandbox-exec (it cannot nest inside the harness sandbox).
export TMPDIR="$APP_DIR/.tmp"
export SWIFTPM_MODULECACHE_OVERRIDE="$APP_DIR/.cache"
mkdir -p "$TMPDIR" "$SWIFTPM_MODULECACHE_OVERRIDE"
# Build only the app product: the fixture checker needs a debug build with
# -enable-testing (see Package.swift), which a release build does not do.
swift build -c release --product TokenMonitor --package-path "$APP_DIR" --disable-sandbox

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$APP_DIR/.build/release/TokenMonitor" "$BUNDLE/Contents/MacOS/TokenMonitor"
# 原生 AppKit UI：不再打包渲染层 www/ 与 bridge.js（WKWebView 已移除）。
cp "$ROOT/assets/icons/tray-token-monitor.png" "$BUNDLE/Contents/Resources/tray-token-monitor.png"
cp "$ROOT/assets/icon.png" "$BUNDLE/Contents/Resources/icon.png"

# Bundled helper: the tokscale Rust scanner (vendored from
# @tokscale/cli-darwin-arm64 4.13.0, see Vendor/tokscale/NOTICE).
# zstd decompression for DeepSeek Harness transcripts is compiled into the
# app via the vendored static libzstd.
cp "$APP_DIR/Vendor/tokscale/tokscale" "$BUNDLE/Contents/Resources/tokscale"
chmod +x "$BUNDLE/Contents/Resources/tokscale"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Token Monitor</string>
  <key>CFBundleDisplayName</key>
  <string>Token Monitor</string>
  <key>CFBundleIdentifier</key>
  <string>com.javis.tokenmonitor</string>
  <key>CFBundleExecutable</key>
  <string>TokenMonitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.44.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>icon</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Strip symbol info, then ad-hoc sign (local use; no notarization needed)
strip -x "$BUNDLE/Contents/MacOS/TokenMonitor" 2>/dev/null || true
codesign --force --deep -s - "$BUNDLE"

echo "built: $BUNDLE"
