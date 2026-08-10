#!/bin/bash
# Builds Quire.app. Needs only the Command Line Tools (swiftc) and Node for the
# one-off asset bundle — no Xcode.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/Quire.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
WEB="$RES/app"

VERSION="0.1.0"
BUILD_NUMBER="1"
BUNDLE_ID="com.timbode.quire"
MIN_MACOS="14.0"

ESBUILD="$ROOT/node_modules/.bin/esbuild"
KATEX="$ROOT/node_modules/katex/dist"

if [ ! -x "$ESBUILD" ]; then
  echo "error: dependencies missing — run 'npm install' first" >&2
  exit 1
fi

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$WEB/katex/fonts"

echo "==> Bundling web assets"
"$ESBUILD" "$ROOT/Web/preview-entry.js" \
  --bundle --minify --format=iife --target=safari17 \
  --outfile="$WEB/preview.js" \
  --log-level=warning

cp "$ROOT/Web/index.html" "$ROOT/Web/style.css" "$WEB/"
cp "$KATEX/katex.min.css" "$WEB/katex/"
# woff2 only: WebKit prefers it and it is listed first in KaTeX's @font-face
# stacks, so shipping woff/ttf as well would just be dead weight.
cp "$KATEX"/fonts/*.woff2 "$WEB/katex/fonts/"

echo "==> Compiling Swift"
swiftc -O -parse-as-library \
  -target "arm64-apple-macos$MIN_MACOS" \
  -o "$CONTENTS/MacOS/Quire" \
  "$ROOT"/Sources/*.swift

echo "==> Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quire</string>
  <key>CFBundleDisplayName</key><string>Quire</string>
  <key>CFBundleExecutable</key><string>Quire</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <!-- Alternate, not Default: Quire offers itself in "Open With" without
           quietly taking over every .md on the machine. -->
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "==> Adding icon"
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
du -sh "$APP" | sed 's/^/    /'
