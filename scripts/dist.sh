#!/bin/zsh
# Builds a universal Essais.app (Apple silicon and Intel) and packs it in dist/Essais.dmg.
# The release asset keeps that name so releases/latest/download/Essais.dmg always works.
# Usage: scripts/dist.sh
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
SCRATCH="$HOME/Library/Caches/essais-build"
APP="$SCRATCH/app.noindex/Essais.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Intel slice first, then the regular build (Apple silicon), then merge them.
swift build -c release --triple x86_64-apple-macosx26.0 --scratch-path "$SCRATCH"
cp "$SCRATCH/release/Essais" "$TMP/Essais-x86_64"
./scripts/build.sh
lipo -create "$APP/Contents/MacOS/Essais" "$TMP/Essais-x86_64" -output "$TMP/Essais"
cp "$TMP/Essais" "$APP/Contents/MacOS/Essais"

IDENTITY="Notch Island Dev"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && SIGN="$IDENTITY" || SIGN="-"
codesign --force --sign "$SIGN" "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Essais")"

# Writable image first so Finder can lay out the window, then compress it.
# scripts/dmg/background.tiff is rendered from scripts/dmg/background.html at 1x and 2x.
STAGE="$TMP/stage"
VOL="Essais $VERSION"
mkdir -p "$STAGE/.background" dist
ditto "$APP" "$STAGE/Essais.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg/background.tiff "$STAGE/.background/bg.tiff"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP/rw.dmg" | awk '/Apple_HFS/{print $1}')
sleep 1
# The first run asks for permission to let the terminal control Finder.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Essais.app" of container window to {160, 170}
    set position of item "Applications" of container window to {440, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "$DEV" >/dev/null
rm -f dist/Essais.dmg
hdiutil convert "$TMP/rw.dmg" -format UDZO -o dist/Essais.dmg >/dev/null
echo "Built dist/Essais.dmg"
