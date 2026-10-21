#!/usr/bin/env bash
# Builds PlexiChore.app (menu-bar app, LSUIElement) from the Swift package.
#
#   ./scripts/build-app.sh                       # release, host architecture, dev/ad-hoc signed
#   UNIVERSAL=1 ./scripts/build-app.sh           # arm64 + x86_64 (what a release ships)
#   SIGN_IDENTITY="Developer ID Application: PNT Apps (TEAMID)" UNIVERSAL=1 ./scripts/build-app.sh
#   SIGN_IDENTITY=- ./scripts/build-app.sh       # force ad-hoc (CI / "unsigned")
#   CONFIG=debug ./scripts/build-app.sh
#   OUT_DIR=/some/dir SCRATCH_PATH=/some/.build ./scripts/build-app.sh
#   VERSION=1.2.0 BUILD_NUMBER=42 ./scripts/build-app.sh   # override the version stamped into the bundle
#   INSTALL=1 ./scripts/build-app.sh             # also copy to ~/Applications/PlexiChore.app
#   (run ./scripts/make-dev-cert.sh once so permission grants survive rebuilds)
#
# Version: the single source of truth is CFBundleShortVersionString / CFBundleVersion in
# Resources/Info.plist. VERSION / BUILD_NUMBER only override the copy inside the built bundle.
#
# Signing: hardened runtime + Resources/PlexiChore.entitlements (no App Sandbox). Identity order:
# SIGN_IDENTITY if set, else the "PlexiChore Local Dev" identity from make-dev-cert.sh, else ad-hoc.
# "Developer ID Application" identities (or TIMESTAMP=1, e.g. when SIGN_IDENTITY is a SHA-1 hash)
# get a secure timestamp, which notarization requires.
#
# Output: $OUT_DIR/PlexiChore.app (+ PlexiChore.app.dSYM for release builds). Default OUT_DIR=build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
OUT="$OUT_DIR/PlexiChore.app"
PLIST_SRC="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/PlexiChore.entitlements"

DEV_KEYCHAIN="$HOME/Library/Keychains/plexichore-dev.keychain-db"
KEYCHAIN_ARGS=()
if [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_KEYCHAIN" ]]; then
  # Local dev identity from scripts/make-dev-cert.sh: stable signature → TCC grants survive rebuilds.
  security unlock-keychain -p plexichore-dev "$DEV_KEYCHAIN" 2>/dev/null || true
  SIGN_IDENTITY="$(security find-identity -p codesigning "$DEV_KEYCHAIN" | awk '/PlexiChore Local Dev/{print $2; exit}')"
  [[ -n "$SIGN_IDENTITY" ]] && KEYCHAIN_ARGS=(--keychain "$DEV_KEYCHAIN")
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"     # "-" = ad-hoc (permissions reset on every rebuild)

# Assemble + sign outside the repo: iCloud Drive / File Provider folders (e.g. ~/Documents) keep
# re-adding com.apple.FinderInfo, which codesign rejects ("detritus not allowed").
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/PlexiChore.app"

SWIFT_ARGS=(-c "$CONFIG")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
fi
if [[ -n "${SCRATCH_PATH:-}" ]]; then
  SWIFT_ARGS+=(--scratch-path "$SCRATCH_PATH")
fi

echo "==> swift build ${SWIFT_ARGS[*]}"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PlexiChore" "$APP/Contents/MacOS/PlexiChore"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
[[ -n "${VERSION:-}" ]] && $PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && $PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  $PB -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || $PB -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi
# SwiftPM resource bundles (none today) would otherwise be missing at runtime.
for b in "$BIN_DIR"/*.bundle; do
  [[ -e "$b" ]] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM adds an LC_RPATH into the build machine's Xcode toolchain (…/usr/lib/swift-x.y/macosx).
# Nothing links @rpath today, but a shipped binary must not search the build machine's Xcode.
EXE="$APP/Contents/MacOS/PlexiChore"
otool -l "$EXE" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | sort -u \
  | grep -E '/Xcode[^/]*\.app/|/Toolchains/' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$EXE" 2>/dev/null
  done || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null

SHORT_VER="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VER="$($PB -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
BUNDLE_ID="$($PB -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

TIMESTAMP_ARG=(--timestamp=none)
if [[ "${TIMESTAMP:-0}" == "1" || "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
  TIMESTAMP_ARG=(--timestamp)            # notarization requires a secure timestamp
fi

echo "==> Signing with identity: $SIGN_IDENTITY (hardened runtime)"
xattr -cr "$APP"
codesign ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --force --options runtime "${TIMESTAMP_ARG[@]}" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$OUT"
ditto "$APP" "$OUT"
if [[ -d "$BIN_DIR/PlexiChore.dSYM" ]]; then
  rm -rf "$OUT.dSYM"
  ditto "$BIN_DIR/PlexiChore.dSYM" "$OUT.dSYM"
fi
if [[ "${INSTALL:-0}" == "1" ]]; then
  # Running from a non-synced location keeps TCC (Screen Recording / Accessibility) happy.
  rm -rf "$HOME/Applications/PlexiChore.app"
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$HOME/Applications/PlexiChore.app"
  echo "==> Installed: $HOME/Applications/PlexiChore.app"
fi

echo "==> Done: $OUT"
echo "    $BUNDLE_ID $SHORT_VER ($BUILD_VER) — $(lipo -archs "$OUT/Contents/MacOS/PlexiChore")," \
  "$(vtool -show-build "$OUT/Contents/MacOS/PlexiChore" 2>/dev/null | awk '/minos|sdk/ && !seen[$1]++ {printf "%s %s ", $1, $2}' | sed 's/ $//')"
echo "    Tip: move it to /Applications before enabling 'Open at login'."
