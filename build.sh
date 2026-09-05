#!/bin/bash
# Builds Mind.app from the Swift package.
#
#   ./build.sh                 release build -> dist/Mind.app
#   ./build.sh --debug         faster build, unoptimised
#   ./build.sh --universal     arm64 + x86_64
#   ./build.sh --run           launch it when the build finishes
#   ./build.sh --install       also copy into /Applications
#   ./build.sh --version 1.2.0 stamp a version into the bundle
#   ./build.sh --require-signing  fail rather than fall back to ad-hoc
#
# The bundle is ad-hoc signed so macOS will grant it calendar access. Note that
# an ad-hoc signature changes identity on every rebuild, so macOS may ask for
# calendar permission again after a rebuild — that's expected, not a bug.

set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="release"
ARCH_FLAGS=()
RUN=0
INSTALL=0
VERSION=""
REQUIRE_SIGNING=0
BUNDLE_ID="com.joedesigns.mind"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug) CONFIGURATION="debug" ;;
		--universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
		--run) RUN=1 ;;
		--install) INSTALL=1 ;;
		--version) VERSION="${2:-}"; shift ;;
		--require-signing) REQUIRE_SIGNING=1 ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

APP="dist/Mind.app"
CONTENTS="$APP/Contents"

# Shared with make-dmg.sh, so the app and the disk image around it cannot end
# up signed by two different identities. Honours MIND_SIGN_IDENTITY.
IDENTITY="$(scripts/signing-identity.sh)"

# A release must be signed with a Developer ID and nothing else. Ad-hoc cannot
# be notarized at all, and the self-signed "Mind Dev" certificate is trusted
# only on the machine that made it — either one would publish a DMG that nobody
# else can open. Failing here, where the cause is obvious, beats finding out
# from a stranger's bug report.
if [[ $REQUIRE_SIGNING -eq 1 && "$IDENTITY" != *"Developer ID"* ]]; then
	if [[ "$IDENTITY" == "-" ]]; then
		FOUND="no signing identity at all"
	else
		FOUND="'$IDENTITY', which is not a Developer ID"
	fi
	echo "==> ERROR: --require-signing needs a Developer ID certificate; found $FOUND." >&2
	echo "    Set MIND_SIGN_IDENTITY, or import a Developer ID certificate first." >&2
	echo "    In CI that is scripts/ci-signing.sh; see docs/releasing.md." >&2
	exit 1
fi

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/Mind" "$CONTENTS/MacOS/Mind"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -n "$VERSION" ]]; then
	echo "==> Stamping version $VERSION"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-$VERSION}" "$CONTENTS/Info.plist"
fi

echo "==> Drawing icon"
ICONSET="dist/AppIcon.iconset"
rm -rf "$ICONSET"
if "$BIN_DIR/MindIconGen" "$ICONSET" >/dev/null; then
	iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
	rm -rf "$ICONSET"
else
	echo "    (icon generation failed; shipping without one)"
fi

if [[ "$IDENTITY" == "-" ]]; then
	echo "==> Signing (ad-hoc — calendar access will be revoked on each rebuild)"
	echo "    Run ./scripts/make-dev-cert.sh once to stop that happening."
	codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
	echo "==> Signing as: $IDENTITY"
	# Hardened runtime so the same command works for notarised distribution.
	# The entitlement is mandatory under the hardened runtime: without it macOS
	# will not even display the calendar permission prompt.
	codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
		--options runtime --timestamp \
		--entitlements Resources/Mind.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    signature ok"

if [[ $INSTALL -eq 1 ]]; then
	echo "==> Installing to /Applications"
	rm -rf "/Applications/Mind.app"
	cp -R "$APP" "/Applications/Mind.app"
	APP="/Applications/Mind.app"
fi

echo "==> Done: $APP"

if [[ $RUN -eq 1 ]]; then
	echo "==> Launching"
	pkill -x Mind 2>/dev/null || true
	sleep 0.5
	open "$APP"
fi
