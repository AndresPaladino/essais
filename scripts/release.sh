#!/bin/zsh
# Publishes a release: builds dist/Essais.dmg, zips the app for Sparkle, signs the zip with the EdDSA key
# from the login keychain (account "essais"), creates the GitHub release and adds the update to
# docs/appcast.xml. Before running it, bump CFBundleShortVersionString and CFBundleVersion in
# Resources/Info.plist, commit and push. Sparkle compares CFBundleVersion: it goes up with every release.
# Usage: scripts/release.sh <notes.md>   (notes: one "- " line per change)
set -euo pipefail
cd "${0:A:h}/.."

NOTES=${1:?usage: scripts/release.sh <notes.md>}
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)
TAG="v$VERSION"
REPO="AndresPaladino/essais"
SCRATCH="$HOME/Library/Caches/essais-build"
APP="$SCRATCH/app.noindex/Essais.app"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first."; exit 1; }
! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || { echo "$TAG already exists."; exit 1; }
! grep -q "<sparkle:version>$BUILD</sparkle:version>" docs/appcast.xml || { echo "Build $BUILD is already in the appcast. Bump CFBundleVersion."; exit 1; }

./scripts/dist.sh
ZIP="dist/Essais.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$SCRATCH/artifacts/sparkle/Sparkle/bin/sign_update" --account essais "$ZIP")

gh release create "$TAG" dist/Essais.dmg "$ZIP" --repo "$REPO" --title "Essais $VERSION" --notes-file "$NOTES"

# The notes become the list Sparkle shows in its update window.
ITEMS=$(sed -n 's/^- //p' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|        <li>&</li>|')
ITEM="    <item>
      <title>Essais $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
      <ul>
$ITEMS
      </ul>
      ]]></description>
      <enclosure url=\"https://github.com/$REPO/releases/download/$TAG/Essais.zip\" type=\"application/octet-stream\" $SIGNATURE/>
    </item>"
# Newest first, right under the marker.
ITEM="$ITEM" perl -0pi -e 's/(    <!-- items -->\n)/$1$ENV{ITEM}\n/' docs/appcast.xml

git add docs/appcast.xml
git commit -q -m "Appcast: Essais $VERSION"
git push -q origin main
echo "Released Essais $VERSION: https://github.com/$REPO/releases/tag/$TAG"
