#!/bin/bash
# Builds Mind.app from the Swift package.
#
#   ./build.sh                 release build -> dist/Mind.app
#   ./build.sh --debug         faster build, unoptimised
#   ./build.sh --universal     arm64 + x86_64
#   ./build.sh --run           launch it when the build finishes
#   ./build.sh --install       also copy into /Applications
#   ./build.sh --version 1.2.0 stamp a version into the bundle
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
BUNDLE_ID="com.joedesigns.mind"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug) CONFIGURATION="debug" ;;
		--universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
		--run) RUN=1 ;;
		--install) INSTALL=1 ;;
		--version) VERSION="${2:-}"; shift ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

APP="dist/Mind.app"
CONTENTS="$APP/Contents"

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

# An ad-hoc signature has no stable identity: every rebuild looks like a new
# app to macOS, which revokes calendar access and re-prompts. Any real signing
# identity avoids that, so prefer one when the machine has it.
#
# Override with MIND_SIGN_IDENTITY="Some Identity", or "-" to force ad-hoc.
if [[ -n "${MIND_SIGN_IDENTITY:-}" ]]; then
	IDENTITY="$MIND_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
	IDENTITY="$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Mind Dev"; then
	IDENTITY="Mind Dev"
else
	IDENTITY="-"
fi

if [[ "$IDENTITY" == "-" ]]; then
	echo "==> Signing (ad-hoc — calendar access will be revoked on each rebuild)"
	echo "    Run ./scripts/make-dev-cert.sh once to stop that happening."
	codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
	echo "==> Signing as: $IDENTITY"
	# Hardened runtime so the same command works for notarised distribution.
	codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
		--options runtime --timestamp "$APP"
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
