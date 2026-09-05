#!/bin/bash
# Prints the best available code-signing identity, or "-" for ad-hoc.
#
#   IDENTITY="$(./scripts/signing-identity.sh)"
#
# An ad-hoc signature has no stable identity: every rebuild looks like a new
# app to macOS, which revokes calendar access and re-prompts. Any real signing
# identity avoids that, so prefer one when the machine has it.
#
# Override with MIND_SIGN_IDENTITY="Some Identity", or "-" to force ad-hoc.
#
# Shared by build.sh and make-dmg.sh so the app and the disk image around it
# cannot end up signed by two different identities.

set -euo pipefail

if [[ -n "${MIND_SIGN_IDENTITY:-}" ]]; then
	printf '%s\n' "$MIND_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
	security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/'
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Mind Dev"; then
	printf 'Mind Dev\n'
else
	printf -- '-\n'
fi
