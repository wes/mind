#!/bin/bash
# Packages dist/Mind.app into a distributable disk image.
#
#   ./scripts/make-dmg.sh [version]
#
# Produces dist/Mind-<version>.dmg containing Mind.app next to an /Applications
# symlink, which is all the "installer" a menu bar app needs. If the app hasn't
# been built yet, this builds it first.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
APP="dist/Mind.app"

if [[ -z "$VERSION" ]]; then
	VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
fi

if [[ ! -d "$APP" ]]; then
	echo "==> Mind.app not found, building it"
	./build.sh
fi

STAGING="dist/dmg-staging"
DMG="dist/Mind-$VERSION.dmg"

echo "==> Staging $VERSION"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Mind.app"
ln -s /Applications "$STAGING/Applications"

# A short read-me in the image itself. What the first launch feels like depends
# entirely on how the app was signed, so ask the bundle rather than guessing.
# The three cases are genuinely different for whoever opens this: a notarised
# build just launches, a Developer ID build needs one trip to System Settings,
# and an ad-hoc build needs that trip after every single update.
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
	FIRST_LAUNCH='2. Double-click Mind. It is signed and notarised by Apple, so it opens
   straight away with no warnings to click through.'
elif codesign -dv "$APP" 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; then
	FIRST_LAUNCH='2. macOS will refuse the first launch because this build is signed but not
   notarised. Open System Settings -> Privacy & Security, scroll to the note
   about Mind, and click "Open Anyway". You only have to do this once.'
else
	FIRST_LAUNCH='2. This build is ad-hoc signed, so macOS will refuse to launch it and will
   re-ask for calendar access after every update. Open System Settings ->
   Privacy & Security and click "Open Anyway" to get past the first launch.'
fi

cat > "$STAGING/Read Me.txt" <<TXT
Mind

1. Drag Mind.app onto the Applications folder.
$FIRST_LAUNCH
3. Mind will ask for calendar access. It only ever reads your calendar.

Mind lives in the menu bar and in a small floating panel. Drag the panel to move
it, drag its bottom-right grip to resize, right-click it for options.

If the panel says nothing is coming up and you disagree, run:

  open -n --env MIND_DIAGNOSE=/tmp/mind.txt /Applications/Mind.app
  cat /tmp/mind.txt

It prints every event in the window and why each one was kept or dropped.
TXT

echo "==> Building $DMG"
hdiutil create \
	-volname "Mind $VERSION" \
	-srcfolder "$STAGING" \
	-ov \
	-format UDZO \
	-imagekey zlib-level=9 \
	"$DMG" >/dev/null

rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

echo "==> Done: $DMG ($SIZE)"
echo "    sha256: $SHA"

# Handy for CI, which reads these back out of the step output.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "dmg=$DMG"
		echo "version=$VERSION"
		echo "sha256=$SHA"
		echo "size=$SIZE"
	} >> "$GITHUB_OUTPUT"
fi
