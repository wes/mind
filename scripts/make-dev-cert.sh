#!/bin/bash
# Creates a self-signed code-signing certificate for local development.
#
#   ./scripts/make-dev-cert.sh
#
# Why: an ad-hoc signature (`codesign -s -`) has no stable identity, so every
# rebuild looks like a different app to macOS and calendar access is revoked.
# You end up re-approving the permission prompt after every single build, and
# any build you forget to approve silently sees an empty calendar.
#
# A certificate fixes that. macOS keys the permission to the signing identity
# rather than the binary's hash, so the grant survives rebuilds — approve once,
# never again. The certificate lives only in your login keychain and is only
# useful on this machine; it is not a substitute for a Developer ID when you
# want to distribute the app to anyone else.
#
# If you already have a Developer ID certificate you do not need this at all —
# build.sh prefers a Developer ID automatically.
#
# Safe to run repeatedly: it does nothing if the identity already exists.

set -euo pipefail

NAME="${1:-Mind Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
	echo "==> '$NAME' already exists in your keychain, nothing to do"
	security find-identity -v -p codesigning | grep "$NAME" || true
	exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

echo "==> Generating a self-signed code-signing certificate: $NAME"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-subj "/CN=$NAME/O=Mind/C=US" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	2>/dev/null

# -macalg sha1 and the old PBE ciphers: OpenSSL 3 defaults to a PKCS#12 MAC
# that Apple's `security import` cannot verify, which fails with a misleading
# "wrong password?" error.
#
# -legacy is needed to reach those ciphers on OpenSSL 3, but it does not exist
# on the LibreSSL that ships with macOS, which rejects the whole command. Which
# `openssl` is first in PATH varies from Mac to Mac, so ask rather than assume.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
	LEGACY=(-legacy)
fi

openssl pkcs12 -export -out "$WORK/identity.p12" \
	-inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	${LEGACY[@]+"${LEGACY[@]}"} -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
	-passout pass: 2>/dev/null

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign pre-authorises codesign to use the key, so you are not
# prompted on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
	-T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Trusting it for code signing"
# User-domain trust only: no sudo, no system-wide effect.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null \
	|| echo "    (trust settings unchanged — if signing fails, open Keychain Access,"
	     echo "     find '$NAME', and set Code Signing to Always Trust)"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "==> Ready. build.sh will use '$NAME' automatically."
	echo "    macOS will ask for calendar access once more, because the app's"
	echo "    identity has changed. That should be the last time."
else
	echo "==> Certificate imported, but it isn't showing as a valid signing identity."
	echo "    Open Keychain Access, find '$NAME', expand Trust, and set"
	echo "    'Code Signing' to 'Always Trust'."
	exit 1
fi
