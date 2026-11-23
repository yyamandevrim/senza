#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/DualMac.app}"
ICON_PNG="$ROOT_DIR/assets/icon.png"
ICONSET_DIR="$ROOT_DIR/build/DualMac.iconset"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Generate native macOS .icns from assets/icon.png
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
  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/DualMac.icns"
  rm -rf "$ICONSET_DIR"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>DualMac</string>
  <key>CFBundleExecutable</key>
  <string>DualMac</string>
  <key>CFBundleIconFile</key>
  <string>DualMac.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.yyamandevrim.dualmac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>DualMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cat > "$APP_DIR/Contents/MacOS/DualMac" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
LOG_DIR="\$HOME/.local/share/dualmac"
mkdir -p "\$LOG_DIR"
exec "$ROOT_DIR/bin/dualmac" start --client sony --profile gta6 >>"\$LOG_DIR/app-launch.log" 2>&1
EOF

chmod +x "$APP_DIR/Contents/MacOS/DualMac"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
echo "Built macOS app bundle: $APP_DIR"
