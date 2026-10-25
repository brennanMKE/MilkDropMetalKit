#!/bin/zsh
# make-dmg.sh — build MilkDrop Gallery and package it as a drag-to-Applications DMG to share.
#
# Usage: scripts/make-dmg.sh [--identity NAME] [--notary-profile PROFILE] [--arch native|universal]
#   --identity NAME          codesign identity (default: the first "Developer ID Application" in the keychain)
#   --notary-profile PROFILE notarize and staple with this `xcrun notarytool store-credentials` profile. Without it
#                            the DMG is signed but not notarized: on another Mac, Gatekeeper blocks the first open
#                            until the user allows it in System Settings > Privacy & Security.
#   --arch                   passed to build-app.sh (default universal)
# Output: build/dist/MilkDrop-Gallery-<version>.dmg
#
# Notarizing uploads the DMG to Apple's notary service. No secret is passed on a command line: the credentials
# live in the keychain profile.

set -euo pipefail
if [[ -o xtrace ]]; then print -u2 "make-dmg.sh: refusing to run with xtrace on"; exit 2; fi

REPO=${0:A:h:h}
IDENTITY=""
NOTARY_PROFILE=""
ARCH=universal
while (( $# )); do
  case $1 in
    --identity) IDENTITY=${2:?--identity needs a name}; shift 2 ;;
    --notary-profile) NOTARY_PROFILE=${2:?--notary-profile needs a name}; shift 2 ;;
    --arch) ARCH=${2:?--arch needs native or universal}; shift 2 ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -u2 "make-dmg.sh: unknown option $1"; exit 2 ;;
  esac
done
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  [[ -n "$IDENTITY" ]] || { print -u2 "make-dmg.sh: no Developer ID Application identity; pass --identity"; exit 1 }
fi
if [[ -n "$NOTARY_PROFILE" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  print -u2 "make-dmg.sh: notarytool profile '$NOTARY_PROFILE' is missing or invalid"
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/milkdrop-dmg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/stage"
"$REPO/scripts/build-app.sh" --identity "$IDENTITY" --arch "$ARCH" --out "$WORK/stage"
APP="$WORK/stage/MilkDrop Gallery.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

ln -s /Applications "$WORK/stage/Applications"
mkdir -p "$REPO/build/dist"
# Notarize under a name equal to the volume name: macOS can rename a DMG whose file and volume names differ during
# the notary round trip. The versioned name is applied once, after stapling.
DMG="$WORK/MilkDrop Gallery.dmg"
FINAL="$REPO/build/dist/MilkDrop-Gallery-$VERSION.dmg"
print "==> Creating the DMG"
hdiutil create -quiet -volname "MilkDrop Gallery" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  print "==> Notarizing (this can take a few minutes)"
  result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
  sub_id=$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$result" 2>/dev/null || true)
  nstatus=$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$result" 2>/dev/null || true)
  print "==> Notarization $sub_id: $nstatus"
  if [[ "$nstatus" != "Accepted" ]]; then
    if [[ -n "$sub_id" ]]; then
      xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE" "$REPO/build/dist/notary-log.json" >/dev/null
      print -u2 "make-dmg.sh: notarization $nstatus; log in build/dist/notary-log.json"
    fi
    exit 1
  fi
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"
fi

mv -f "$DMG" "$FINAL"
print "==> DMG  $FINAL"
print "==> Signed by $IDENTITY$([[ -n "$NOTARY_PROFILE" ]] && print ', notarized and stapled' || print ', not notarized')"
spctl --assess --type open --context context:primary-signature -v "$FINAL" 2>&1 | sed 's/^/    /' || true
