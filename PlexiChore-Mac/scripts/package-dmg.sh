#!/usr/bin/env bash
# Packages a built PlexiChore.app into a compressed, drag-to-Applications DMG.
#
#   ./scripts/package-dmg.sh                          # uses build/PlexiChore.app → build/PlexiChore-<ver>.dmg
#   ./scripts/package-dmg.sh path/to/PlexiChore.app   # explicit app
#   OUT_DIR=/some/dir ./scripts/package-dmg.sh
#   SIGN_IDENTITY="Developer ID Application: PNT Apps (TEAMID)" ./scripts/package-dmg.sh   # also sign the DMG
#
# Typical release:
#   SIGN_IDENTITY="Developer ID Application: …" UNIVERSAL=1 ./scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-dmg.sh
#   ./scripts/notarize.sh build/PlexiChore-<ver>.dmg
#
# The DMG is not notarized here; run scripts/notarize.sh on it afterwards (it staples the DMG).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_IN="${1:-$ROOT/build/PlexiChore.app}"
[[ -d "$APP_IN/Contents/MacOS" ]] || { echo "error: no app at $APP_IN (run scripts/build-app.sh first)" >&2; exit 1; }
APP_IN="$(cd "$APP_IN" && pwd)"
OUT_DIR="${OUT_DIR:-$(dirname "$APP_IN")}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_IN/Contents/Info.plist")"
VOLNAME="PlexiChore $VER"
DMG="$OUT_DIR/PlexiChore-$VER.dmg"

codesign --verify --strict "$APP_IN" || { echo "error: $APP_IN is not validly signed" >&2; exit 1; }

# Stage outside synced folders (iCloud/File Provider add xattrs that break signatures).
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root"
ditto "$APP_IN" "$STAGE/root/PlexiChore.app"
ln -s /Applications "$STAGE/root/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE/root" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$STAGE/PlexiChore.dmg" >/dev/null
ditto "$STAGE/PlexiChore.dmg" "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
  echo "==> Signing DMG with: $SIGN_IDENTITY"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

hdiutil verify "$DMG" >/dev/null
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "==> Done: $DMG"
