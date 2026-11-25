#!/usr/bin/env bash
# Package build/Senza.app (self-contained release build) into build/dist/:
#   Senza-<version>-macOS-arm64.zip   (ditto, keeps signatures and symlinks)
#   Senza-<version>-macOS-arm64.dmg   (drag to Applications)
#   SHA256SUMS.txt
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/build/Senza.app"
DIST="$ROOT_DIR/build/dist"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT_DIR/senza/__init__.py")"
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] || { echo "error: release builds are Apple Silicon (arm64) only" >&2; exit 1; }
NAME="Senza-${VERSION}-macOS-${ARCH}"

[[ -d "$APP" ]] || { echo "error: $APP missing; run \`make app\` first" >&2; exit 1; }
if /usr/libexec/PlistBuddy -c "Print :SenzaRepoRoot" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: $APP is a dev build linked to a repo checkout; build it with \`make app\`" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
for f in bin/senza senza/cli.py build/libsenza_sony.dylib build/libsenza_chiaki.dylib profiles/gta6.json; do
  [[ -e "$APP/Contents/Resources/$f" ]] || { echo "error: payload file $f missing from $APP" >&2; exit 1; }
done

mkdir -p "$DIST"
find "$DIST" -mindepth 1 -maxdepth 1 -name "Senza-*" -delete
rm -f "$DIST/SHA256SUMS.txt"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Senza.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Senza $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/$NAME.dmg"

(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
echo "Packaged:"
ls -lh "$DIST"
