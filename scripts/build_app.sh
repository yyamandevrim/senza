#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/Senza.app}"
ICON_PNG="$ROOT_DIR/assets/icon.png"
ICONSET_DIR="$ROOT_DIR/build/Senza.iconset"
SWIFT_SRCS=("$ROOT_DIR"/native/gui/Sources/*.swift)
# Single version source: senza/__init__.py
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT_DIR/senza/__init__.py")"
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
# Extra swiftc flags, e.g. SWIFT_FLAGS=-warnings-as-errors in CI
read -r -a EXTRA_SWIFT_FLAGS <<< "${SWIFT_FLAGS:-}"

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

# Dev installs (`make install-app`) keep using the live repo CLI; release builds are self-contained.
REPO_ROOT_PLIST=""
if [[ "${SENZA_DEV_LINK:-0}" == "1" ]]; then
  REPO_ROOT_PLIST="  <key>SenzaRepoRoot</key>
  <string>${ROOT_DIR}</string>
"
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
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
${REPO_ROOT_PLIST}  <key>LSMinimumSystemVersion</key>
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
  ${EXTRA_SWIFT_FLAGS[@]+"${EXTRA_SWIFT_FLAGS[@]}"} \
  "${SWIFT_SRCS[@]}" \
  -o "$APP_DIR/Contents/MacOS/Senza"

chmod +x "$APP_DIR/Contents/MacOS/Senza"

# 4. Embed the CLI payload, laid out like the repo so the Python package's paths work unchanged:
#    Resources/{bin/senza, senza/, build/libsenza_*.dylib, profiles/, assets/icon.png}
RES="$APP_DIR/Contents/Resources"
for lib in libsenza_sony.dylib libsenza_chiaki.dylib; do
  if [[ ! -f "$ROOT_DIR/build/$lib" ]]; then
    echo "error: build/$lib missing; run \`make build\` first" >&2
    exit 1
  fi
done
mkdir -p "$RES/bin" "$RES/build" "$RES/profiles" "$RES/assets"
rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "$ROOT_DIR/senza/" "$RES/senza/"
cp "$ROOT_DIR/bin/senza" "$RES/bin/senza"
chmod +x "$RES/bin/senza" "$RES/senza/resources/senza-priv"
cp "$ROOT_DIR/build/libsenza_sony.dylib" "$ROOT_DIR/build/libsenza_chiaki.dylib" "$RES/build/"
cp "$ROOT_DIR"/profiles/*.json "$RES/profiles/"
cp "$ROOT_DIR/assets/icon.png" "$RES/assets/icon.png"
cp "$ROOT_DIR/LICENSE" "$RES/LICENSE"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built native macOS GUI app bundle: $APP_DIR"
