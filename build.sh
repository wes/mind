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

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
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
