#!/usr/bin/env bash
# Creates a self-signed "PlexiChore Local Dev" code-signing identity in its own keychain
# (~/Library/Keychains/plexichore-dev.keychain-db; the login keychain is not touched).
# build-app.sh signs with it automatically, so the designated requirement stays stable across
# rebuilds and macOS keeps the Screen Recording / Accessibility grants.
set -euo pipefail

KC="$HOME/Library/Keychains/plexichore-dev.keychain-db"
PASS="plexichore-dev"
NAME="PlexiChore Local Dev"

if [[ -f "$KC" ]] && security find-identity -p codesigning "$KC" | grep -q "$NAME"; then
  echo "Identity already exists in $KC"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout "pass:$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS"

[[ -f "$KC" ]] || security create-keychain -p "$PASS" "$KC"
security unlock-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"     # no auto-lock
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null 2>&1 || true
security find-identity -p codesigning "$KC"
