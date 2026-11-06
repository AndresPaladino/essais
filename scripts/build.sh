#!/bin/zsh
# Builds Essais.app and signs it. Build output stays out of the project folder: in iCloud Drive, the
# extended attributes iCloud adds make codesign fail.
# Usage: scripts/build.sh [--run | --install | --qa]
# --qa builds a separate copy with the test hooks in its own folder. The app people use
# has none of them, and building the QA copy never touches the installed app.
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="Notch Island Dev"
SCRATCH="$HOME/Library/Caches/essais-build"
FLAGS=()
if [[ "${1:-}" == "--qa" ]]; then
  SCRATCH="$HOME/Library/Caches/essais-build-qa"
  FLAGS=(-Xswiftc -DQA)
fi
# .noindex keeps this copy out of Spotlight and Launchpad.
APP="$SCRATCH/app.noindex/Essais.app"

swift build -c release --scratch-path "$SCRATCH" $FLAGS

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$SCRATCH/release/Essais" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Sparkle, for updates. SwiftPM's copy comes signed ad hoc and keeps that signature: updates are
# verified with EdDSA, not with code signing.
ditto "$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
  "$APP/Contents/Frameworks/Sparkle.framework"

xattr -cr "$APP"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
else
  SIGN="-"
fi
codesign --force --sign "$SIGN" "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  # Asks it to quit, so it saves; pkill only for what didn't.
  osascript -e 'quit app id "com.andrespaladino.essais"' 2>/dev/null || true
  sleep 1.5
  pkill -x Essais 2>/dev/null || true
  rm -rf "/Applications/Essais.app"
  ditto "$APP" "/Applications/Essais.app"
  open "/Applications/Essais.app"
  echo "Installed in /Applications"
elif [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
