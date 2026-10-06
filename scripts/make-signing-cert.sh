#!/bin/bash
# Creates a self-signed code-signing identity "FinderPin Self-Signed" in the login
# keychain so rebuilds keep their privacy permissions. It is not trusted system-wide
# (no admin prompt) and is only usable by /usr/bin/codesign.
set -euo pipefail
NAME="FinderPin Self-Signed"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
umask 077
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\""
