#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/Senza.app}"
ICON_PNG="$ROOT_DIR/assets/icon.png"
ICONSET_DIR="$ROOT_DIR/build/Senza.iconset"
SWIFT_SRC="$ROOT_DIR/native/gui/SenzaApp.swift"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 1. Generate native macOS .icns from assets/icon.png
if [[ -f "$ICON_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$ICON_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    if [[ "$sz2" -le 512 ]]; then
      sips -z "$sz2" "$sz2" "$ICON_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
    else
      cp "$ICON_PNG" "$ICONSET_DIR/icon_${sz}x${sz}@2x.png"
    fi
  done
  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/Senza.icns"
  rm -rf "$ICONSET_DIR"
fi

# 2. Write Info.plist (regular Dock + Menu Bar macOS app)
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Senza</string>
  <key>CFBundleExecutable</key>
  <string>Senza</string>
  <key>CFBundleIconFile</key>
  <string>Senza.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.yyamandevrim.senza</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Senza</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>SenzaRepoRoot</key>
  <string>${ROOT_DIR}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# 3. Compile native SwiftUI + AppKit Senza GUI binary
ARCH="$(uname -m)"
swiftc \
  -O \
  -parse-as-library \
  -target "${ARCH}-apple-macosx13.0" \
  -framework AppKit \
  -framework SwiftUI \
  -framework GameController \
  "$SWIFT_SRC" \
  -o "$APP_DIR/Contents/MacOS/Senza"

chmod +x "$APP_DIR/Contents/MacOS/Senza"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
echo "Built native macOS GUI app bundle: $APP_DIR"
