#!/bin/bash
# A local signing identity preserves this Mac's Accessibility grant on rebuild.
set -euo pipefail
if security find-identity -p codesigning 2>/dev/null | grep -q "Murmur Dev"; then
  echo "Local Sona signing identity already exists."
  exit 0
fi
umask 077
SONA_CERT_TEMP=$(mktemp -d)
cleanup() {
  for SONA_CERT_FILE in key.pem cert.pem cert.p12 openssl.cnf password; do
    if [ -f "$SONA_CERT_TEMP/$SONA_CERT_FILE" ]; then
      rm -f "$SONA_CERT_TEMP/$SONA_CERT_FILE"
    fi
  done
  rmdir "$SONA_CERT_TEMP" 2>/dev/null || true
}
trap cleanup EXIT
cat > "$SONA_CERT_TEMP/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Murmur Dev
O = Sona
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
openssl req -x509 -newkey rsa:2048 -keyout "$SONA_CERT_TEMP/key.pem" \
  -out "$SONA_CERT_TEMP/cert.pem" -days 3650 -nodes -config "$SONA_CERT_TEMP/openssl.cnf" 2>/dev/null
openssl rand -hex 24 > "$SONA_CERT_TEMP/password"
SONA_OPENSSL_ARGS=()
if openssl version | grep -q '^OpenSSL 3'; then SONA_OPENSSL_ARGS=(-legacy); fi
openssl pkcs12 -export "${SONA_OPENSSL_ARGS[@]}" -out "$SONA_CERT_TEMP/cert.p12" \
  -inkey "$SONA_CERT_TEMP/key.pem" -in "$SONA_CERT_TEMP/cert.pem" \
  -passout "file:$SONA_CERT_TEMP/password" -name 'Murmur Dev' 2>/dev/null
security import "$SONA_CERT_TEMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$(cat "$SONA_CERT_TEMP/password")" -T /usr/bin/codesign
printf 'Created a local signing identity. macOS may ask to allow codesign to use it.\n'
