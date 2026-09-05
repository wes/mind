#!/bin/bash
# Sends a signed app or disk image to Apple, waits for the verdict, and staples
# the ticket to it.
#
#   ./scripts/notarize.sh dist/Mind.app
#   ./scripts/notarize.sh dist/Mind-1.1.0.dmg
#
# Stapling matters: without a stapled ticket, Gatekeeper has to ask Apple over
# the network on first launch, so anyone offline — or behind a firewall that
# blocks Apple — sees the same scary "cannot be opened" dialog as an unsigned
# app. With one, the approval travels inside the file.
#
# Both the app and the DMG get their own ticket. Notarizing the DMG alone
# covers the copy inside it, but once that copy is dragged to /Applications it
# is a separate file with no ticket of its own.
#
# Credentials, in order of preference:
#
#   App Store Connect API key (what CI uses)
#     APPLE_API_KEY_ID      the key's 10-character ID
#     APPLE_API_ISSUER_ID   the issuer UUID from App Store Connect
#     APPLE_API_KEY_P8      base64 of the .p8 file you downloaded
#
#   A stored keychain profile (convenient locally)
#     MIND_NOTARY_PROFILE   defaults to "mind"; create it once with
#                           xcrun notarytool store-credentials mind ...

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"
if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
	echo "usage: $0 <path-to-.app-or-.dmg>" >&2
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# --- credentials ------------------------------------------------------------

CREDENTIALS=()
if [[ -n "${APPLE_API_KEY_P8:-}" ]]; then
	: "${APPLE_API_KEY_ID:?APPLE_API_KEY_P8 is set, so APPLE_API_KEY_ID must be too}"
	: "${APPLE_API_ISSUER_ID:?APPLE_API_KEY_P8 is set, so APPLE_API_ISSUER_ID must be too}"
	printf '%s' "$APPLE_API_KEY_P8" | base64 --decode > "$WORK/key.p8"
	CREDENTIALS=(--key "$WORK/key.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
	echo "==> Notarizing with App Store Connect key $APPLE_API_KEY_ID"
else
	PROFILE="${MIND_NOTARY_PROFILE:-mind}"
	if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
		cat >&2 <<-MSG
		No notarization credentials found.

		For CI, set APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_KEY_P8.

		Locally, store a profile once:

		  xcrun notarytool store-credentials $PROFILE \\
		      --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \\
		      --key-id XXXXXXXXXX \\
		      --issuer <issuer-uuid>

		See docs/releasing.md for where those values come from.
		MSG
		exit 1
	fi
	CREDENTIALS=(--keychain-profile "$PROFILE")
	echo "==> Notarizing with keychain profile '$PROFILE'"
fi

# --- the thing we actually upload -------------------------------------------

# notarytool takes a .zip, .dmg or .pkg. An .app has to be zipped first, and it
# has to be `ditto`, not `zip`: the symlinks and the code signature inside a
# bundle do not survive a plain zip, and Apple rejects the result.
case "$TARGET" in
	*.app)
		UPLOAD="$WORK/$(basename "${TARGET%.app}").zip"
		echo "==> Packing $(basename "$TARGET") for upload"
		ditto -c -k --keepParent --sequesterRsrc "$TARGET" "$UPLOAD"
		;;
	*.dmg|*.pkg|*.zip)
		UPLOAD="$TARGET"
		;;
	*)
		echo "don't know how to notarize $TARGET" >&2
		exit 1
		;;
esac

# --- submit -----------------------------------------------------------------

echo "==> Uploading $(du -h "$UPLOAD" | cut -f1 | tr -d ' ') and waiting for Apple"
# Capture stdout only. notarytool writes clean JSON there, but it also writes
# progress and warnings to stderr, and folding the two together would corrupt
# the JSON and make a perfectly good submission look like a failure.
set +e
RESULT="$(xcrun notarytool submit "$UPLOAD" "${CREDENTIALS[@]}" \
	--wait --timeout 30m --output-format json)"
SUBMIT_STATUS=$?
set -e

read_field() {
	/usr/bin/python3 -c 'import json,sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], ""))
except Exception:
    print("")' "$RESULT" "$1" 2>/dev/null || true
}

STATUS="$(read_field status)"
SUBMISSION_ID="$(read_field id)"

# `notarytool submit --wait` exits 0 for a submission that Apple rejected, so
# the status field is the thing that decides, not the exit code.
if [[ "$STATUS" != "Accepted" ]]; then
	echo "::error::Notarization failed: ${STATUS:-no status returned}" >&2
	echo "notarytool exited $SUBMIT_STATUS" >&2
	echo "$RESULT" >&2
	if [[ -n "$SUBMISSION_ID" ]]; then
		echo >&2
		echo "==> Apple's rejection log:" >&2
		xcrun notarytool log "$SUBMISSION_ID" "${CREDENTIALS[@]}" >&2 || true
	fi
	# Deliberately not $SUBMIT_STATUS: that is 0 in exactly the case this
	# branch exists to catch, and exiting 0 here would let the build carry on
	# and publish something Apple refused.
	exit 1
fi

echo "==> Accepted (submission $SUBMISSION_ID)"

# --- staple and verify ------------------------------------------------------

echo "==> Stapling the ticket to $(basename "$TARGET")"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# The last word on whether a real Mac will open this. `-t open` with the
# primary-signature context is how Gatekeeper judges a downloaded disk image;
# an app is judged as something to execute.
echo "==> Gatekeeper check"
case "$TARGET" in
	*.dmg) spctl --assess -t open --context context:primary-signature -vv "$TARGET" ;;
	*)     spctl --assess -t exec -vv "$TARGET" ;;
esac

echo "==> $(basename "$TARGET") is notarized and stapled"
