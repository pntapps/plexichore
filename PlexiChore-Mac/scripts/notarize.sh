#!/usr/bin/env bash
# Notarizes and staples a Developer ID–signed PlexiChore.app or DMG with Apple's notary service.
# Not run by CI. Needs: Xcode 14+, an Apple Developer account, a "Developer ID Application" signature
# with hardened runtime + secure timestamp (scripts/build-app.sh does this for Developer ID identities).
#
# One-time setup (stores an app-specific password in your login keychain; nothing goes in the repo):
#   xcrun notarytool store-credentials plexichore-notary \
#       --apple-id "<apple id>" --team-id "<TEAMID>" --password "<app-specific password>"
#   (or with an App Store Connect API key: --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>)
#
# Usage:
#   ./scripts/notarize.sh build/PlexiChore-1.0.0.dmg        # preferred: notarize + staple the DMG
#   ./scripts/notarize.sh build/PlexiChore.app              # zips the app, submits, staples the app
#   NOTARY_PROFILE=other-profile ./scripts/notarize.sh …
#
# On rejection the notary log is printed (common causes: ad-hoc/dev signature, missing
# --timestamp, missing hardened runtime, unsigned nested binary).
set -euo pipefail

TARGET="${1:?usage: notarize.sh <PlexiChore.app | PlexiChore-x.y.z.dmg>}"
PROFILE="${NOTARY_PROFILE:-plexichore-notary}"
[[ -e "$TARGET" ]] || { echo "error: $TARGET not found" >&2; exit 1; }

# Refuse obviously un-notarizable input early (saves a slow round-trip to Apple):
# the app must carry a Developer ID Application signature, the hardened runtime and a secure timestamp.
check_app() {   # $1 = path to PlexiChore.app
  local info
  info="$(codesign -dvvv "$1" 2>&1)" || { echo "error: $1 is not signed" >&2; return 1; }
  grep -q "Authority=Developer ID Application" <<<"$info" \
    || { echo "error: $1 is not signed with a Developer ID Application identity" >&2; return 1; }
  grep -Eq "flags=0x[0-9a-f]*\(.*runtime.*\)" <<<"$info" \
    || { echo "error: $1 is signed without the hardened runtime (--options runtime)" >&2; return 1; }
  grep -q "^Timestamp=" <<<"$info" \
    || { echo "error: $1 has no secure timestamp (sign with --timestamp / TIMESTAMP=1)" >&2; return 1; }
  codesign --verify --deep --strict "$1" || { echo "error: $1 fails codesign --verify --deep --strict" >&2; return 1; }
}

if [[ "$TARGET" == *.app ]]; then
  check_app "$TARGET"
else
  # Check the app inside the DMG; the DMG itself only needs a signature for the stapled ticket to be trusted offline.
  MNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$TARGET" >/dev/null
  rc=0; check_app "$MNT/PlexiChore.app" || rc=$?
  hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
  [[ $rc -eq 0 ]] || exit 1
  dmg_info="$(codesign -dv "$TARGET" 2>&1 || true)"
  if ! grep -q "Authority=Developer ID Application" <<<"$dmg_info"; then
    echo "warning: the DMG itself is not Developer ID signed (set SIGN_IDENTITY for package-dmg.sh)" >&2
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$TMP/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "==> notarytool submit $(basename "$SUBMIT") (profile: $PROFILE)"
# Don't let set -e abort on a non-zero notarytool exit: we still want the status and the log.
rc=0
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json \
  > "$TMP/result.json" || rc=$?
cat "$TMP/result.json"; echo
[[ $rc -eq 0 ]] || echo "warning: notarytool exited with $rc" >&2
STATUS="$(/usr/bin/plutil -extract status raw -o - "$TMP/result.json" 2>/dev/null || echo unknown)"
ID="$(/usr/bin/plutil -extract id raw -o - "$TMP/result.json" 2>/dev/null || echo "")"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization status: $STATUS" >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

echo "==> stapler staple $TARGET"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET" || true
fi
echo "==> Notarized: $TARGET"
