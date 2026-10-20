#!/usr/bin/env bash
# Builds PlexiChore.app from the Swift package.
#
#   ./scripts/build-app.sh                       # release, ad-hoc signed, host architecture
#   UNIVERSAL=1 ./scripts/build-app.sh           # arm64 + x86_64 (needs full Xcode)
#   SIGN_IDENTITY="Apple Development: Jane Doe (TEAMID)" ./scripts/build-app.sh
#   CONFIG=debug ./scripts/build-app.sh
#
# Output: build/PlexiChore.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"     # "-" = ad-hoc
APP="$ROOT/build/PlexiChore.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PlexiChore" "$APP/Contents/MacOS/PlexiChore"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "$ROOT/Resources/PlexiChore.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Done: $APP"
echo "    Tip: move it to /Applications before enabling 'Open at login'."
