#!/bin/zsh
# Checks the build in dist/ (from scripts/dist.sh) before publishing: architectures, signatures, versions
# against the appcast, DMG layout, and that nothing meant for testing is left in the app.
# Usage: scripts/test/release-check.sh
set -uo pipefail
cd "${0:A:h}/../.."
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); print "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); print "  ✗ $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }
DMG=dist/Essais.dmg; ZIP=dist/Essais.zip

print "Source"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)
print "  Info.plist: $VERSION ($BUILD), macOS $MIN_OS+"
APPCAST_BUILD=$(grep -oE "<sparkle:version>[0-9]+" docs/appcast.xml | head -1 | grep -oE "[0-9]+")
if [[ -z "$APPCAST_BUILD" ]]; then
  print "  appcast still empty (first release)"
else
  check "this build is newer than the appcast's newest ($APPCAST_BUILD)" "(( BUILD >= APPCAST_BUILD ))"
fi
check "minimum macOS matches Package.swift ($MIN_OS)" "grep -q 'macOS(\"$MIN_OS\")' Package.swift"
check "Info.plist has Sparkle's public key" "/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Resources/Info.plist"
check "Info.plist has a feed URL" "/usr/libexec/PlistBuddy -c 'Print SUFeedURL' Resources/Info.plist"

print "DMG"
[[ -f $DMG ]] || { bad "no $DMG (run scripts/dist.sh)"; print "$PASS passed, $FAIL failed"; exit 1; }
MNT=$(mktemp -d)
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint $MNT $DMG >/dev/null 2>&1 || { bad "DMG doesn't mount"; print "$PASS passed, $FAIL failed"; exit 1; }
APP=$MNT/Essais.app
BIN=$APP/Contents/MacOS/Essais
check "Essais.app inside" "[[ -d $APP ]]"
check "Applications link" "[[ -L $MNT/Applications ]]"
check "background image" "[[ -f $MNT/.background/bg.tiff ]]"
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $APP/Contents/Info.plist 2>/dev/null)
check "app version is $VERSION (got $V)" "[[ $V == $VERSION ]]"
archs=$(lipo -archs $BIN 2>/dev/null)
check "universal binary ($archs)" "[[ '$archs' == *x86_64* && '$archs' == *arm64* ]]"
check "signature valid" "codesign --verify --strict $APP"
# Sparkle from SwiftPM comes signed ad hoc (see build.sh): the signature only has to be intact.
check "Sparkle's signature valid" "codesign --verify --deep --strict $APP/Contents/Frameworks/Sparkle.framework"
for f in en.lproj/Localizable.strings es.lproj/Localizable.strings AppIcon.icns Assets.car; do
  check "resource $f" "[[ -f $APP/Contents/Resources/$f ]]"
done
check "no test hooks in the app" "! strings $BIN | grep -qE -- '--size-walk|--snapshot|debugTail'"
check "no sample text in the app" "! strings $BIN | grep -q 'Domingo lento'"
size=$(du -sm $APP | cut -f1); print "  app size: ${size} MB"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  check "x86_64 slice starts" "arch -x86_64 $BIN --version & P=\$!; sleep 3; kill \$P"
else
  print "  Rosetta not installed: Intel not run"
fi
hdiutil detach $MNT >/dev/null 2>&1

print "Update archive"
if [[ -f $ZIP ]]; then
  Z=$(mktemp -d); ditto -x -k $ZIP $Z
  check "zip contains a validly signed app" "codesign --verify --strict $Z/Essais.app"
else
  print "  no $ZIP yet (release.sh makes it)"
fi
print "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
