#!/bin/bash
# Prints the body of a GitHub release to stdout.
#
#   ./scripts/release-notes.sh <channel> <version> <dmg-name> <sha256> [commit]
#
# Channel is "release" or "nightly". They want to say opposite things: a
# release should tell someone how to install the app, a nightly should warn
# them that the file behind the link changes without notice.
#
# This lives in a script rather than inline in the workflow so it can be run
# and read without pushing anything:
#
#   ./scripts/release-notes.sh nightly 1.1.0-main.7 Mind-1.1.0-main.7.dmg abc123

set -euo pipefail

CHANNEL="${1:?usage: $0 <channel> <version> <dmg-name> <sha256> [commit]}"
VERSION="${2:?missing version}"
DMG_NAME="${3:?missing dmg name}"
SHA="${4:?missing sha256}"
COMMIT="${5:-${GITHUB_SHA:-}}"
REPO="${GITHUB_REPOSITORY:-wes/mind}"

if [[ "$CHANNEL" == "nightly" ]]; then
	cat <<-TXT
	The latest build of \`main\`, signed and notarized exactly like a real
	release. It is replaced every time \`main\` moves, so this link is stable but
	what sits behind it is not.

	If you want a build that stays put, use the
	[latest release](https://github.com/$REPO/releases/latest) instead.
	TXT
else
	cat <<-TXT
	## Install

	Download **$DMG_NAME**, open it, and drag Mind to your Applications folder.
	It is signed with a Developer ID and notarized by Apple, so it opens without
	any warnings to click through.

	Mind asks for calendar access on first launch. It only ever reads your
	calendar — it never creates, edits, or deletes anything, and nothing leaves
	your Mac.
	TXT
fi

echo
echo "---"
echo

if [[ -n "$COMMIT" ]]; then
	echo "Built from [\`${COMMIT:0:7}\`](https://github.com/$REPO/commit/$COMMIT) by"
	echo "[GitHub Actions](https://github.com/$REPO/actions), universal (Apple silicon"
	echo "and Intel), requires macOS 14 or newer."
	echo
fi

echo "Verify what you downloaded:"
echo
echo '```'
echo "shasum -a 256 $DMG_NAME"
echo "$SHA"
echo
echo "xcrun stapler validate $DMG_NAME"
echo '```'
