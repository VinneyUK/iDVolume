#!/bin/bash
# One-time setup: create a self-signed code-signing certificate called "iDVolume Release"
# in your login keychain. Signing every build and release with it keeps the app's identity
# the same across updates, so macOS keeps its Accessibility permission.
# It contains no personal details. Keep it: if you delete it, the next release will need
# permission granting again.
set -euo pipefail
NAME="iDVolume Release"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:idvolume 2>/dev/null
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P idvolume -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ Created \"$NAME\" (valid 10 years) in your login keychain."
  echo "  build.sh and release.sh will now use it automatically."
  echo "  If macOS asks whether codesign may use the key, choose Always Allow."
else
  echo "✗ The certificate didn't appear as a signing identity. Tell Claude what this printed:"
  security find-identity -p codesigning
  exit 1
fi
