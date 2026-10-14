#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain so that the
# Accessibility permission granted to macrx survives rebuilds (TCC keys the grant on
# the code signature; SwiftPM's ad-hoc signature changes every build).
#
# Usage: scripts/dev-cert.sh [identity-name]   (default: macrx-dev)
set -euo pipefail

NAME="${1:-macrx-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:macrx >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/cert.p12" -passout pass:macrx

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P macrx -T /usr/bin/codesign -T /usr/bin/security
# Trust the certificate for code signing (prompts for your login password once).
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || echo "note: could not mark the certificate trusted automatically; open Keychain Access → '$NAME' → Trust → Code Signing: Always Trust"
# Let codesign use the key without a UI prompt each build.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "created identity '$NAME'. Now: just run"
