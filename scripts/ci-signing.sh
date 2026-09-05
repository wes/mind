#!/bin/bash
# Loads a Developer ID certificate into a throwaway keychain so CI can sign.
#
#   ./scripts/ci-signing.sh            import and select the identity
#   ./scripts/ci-signing.sh --cleanup  delete the keychain again
#
# Reads two environment variables, both of which are repo secrets:
#
#   MACOS_CERTIFICATE_P12       base64 of a .p12 holding the Developer ID
#                               Application certificate and its private key
#   MACOS_CERTIFICATE_PASSWORD  the password that .p12 was exported with
#
# A dedicated keychain rather than the login one, because the runner's login
# keychain is unlocked interactively and CI has nobody to type a password. The
# keychain lives in the runner's temp directory and dies with the job; the
# --cleanup path exists so a self-hosted runner doesn't accumulate them.
#
# On success this exports MIND_SIGN_IDENTITY (and writes it to GITHUB_ENV), so
# the build.sh that runs afterwards signs with the real certificate instead of
# quietly falling back to ad-hoc.

set -euo pipefail

KEYCHAIN="${RUNNER_TEMP:-/tmp}/mind-signing.keychain-db"

if [[ "${1:-}" == "--cleanup" ]]; then
	security delete-keychain "$KEYCHAIN" 2>/dev/null || true
	echo "==> Signing keychain removed"
	exit 0
fi

: "${MACOS_CERTIFICATE_P12:?set MACOS_CERTIFICATE_P12 (base64 of the Developer ID .p12)}"
: "${MACOS_CERTIFICATE_PASSWORD:?set MACOS_CERTIFICATE_PASSWORD}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# A random password for a keychain that exists for the length of one job. It
# never leaves this process, so it does not need to be a secret anyone knows.
KEYCHAIN_PASSWORD="$(uuidgen)"

echo "==> Creating a temporary signing keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# No auto-lock: the default relocks after five minutes of idle, and a long
# universal build plus a notarization wait comfortably exceeds that.
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "==> Importing the certificate"
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$WORK/certificate.p12"
security import "$WORK/certificate.p12" \
	-k "$KEYCHAIN" \
	-P "$MACOS_CERTIFICATE_PASSWORD" \
	-T /usr/bin/codesign -T /usr/bin/security \
	-f pkcs12 >/dev/null

# Without this, codesign can read the key but macOS pops a GUI prompt to
# authorise the access — which in CI simply hangs until the job times out.
security set-key-partition-list \
	-S apple-tool:,apple:,codesign: \
	-s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Prepend to the search list rather than replacing it: `find-identity` only
# looks at keychains that are actually in the list.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
	| grep -m1 "Developer ID Application" \
	| sed -E 's/.*"(.*)"/\1/' || true)"

if [[ -z "$IDENTITY" ]]; then
	echo "::error::No 'Developer ID Application' identity in the imported certificate." >&2
	echo "Found instead:" >&2
	security find-identity -v -p codesigning "$KEYCHAIN" >&2
	echo >&2
	echo "Export the *Developer ID Application* certificate from Keychain Access" >&2
	echo "as a .p12 including its private key. See docs/releasing.md." >&2
	exit 1
fi

echo "==> Ready to sign as: $IDENTITY"
export MIND_SIGN_IDENTITY="$IDENTITY"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "MIND_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
fi
