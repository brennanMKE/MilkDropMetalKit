#!/bin/zsh
# build-app.sh — build MilkDrop Gallery and assemble it as a signed .app bundle.
#
# Usage: scripts/build-app.sh [--identity NAME] [--arch native|universal] [--out DIR]
#   --identity NAME  codesign identity. Default: the first "Developer ID Application" in the keychain, or "-" (ad hoc)
#                    when there is none, which runs only on this Mac and in the test VM.
#   --arch           universal (default; arm64 + x86_64) or native
#   --out DIR        where the bundle goes (default build/app)
# Output: <out>/MilkDrop Gallery.app. Never launches the app.
#
# The bundle: Contents/MacOS/MilkDropGallery (release build), Contents/Resources/Presets (Presets/*.milk and
# gallery.json), AppIcon.icns from Design/AppIcon.png, and an Info.plist written here. Signed with the hardened
# runtime and a secure timestamp, so it's ready to notarize; it needs no entitlements.

set -euo pipefail

APP_NAME="MilkDrop Gallery"
EXECUTABLE="MilkDropGallery"
BUNDLE_ID="co.sstools.MilkDropGallery"
VERSION="0.1.0"
# Build number: UTC date and time, so every build is newer than the last.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)

REPO=${0:A:h:h}
IDENTITY=""
ARCH=universal
OUT="$REPO/build/app"
while (( $# )); do
  case $1 in
    --identity) IDENTITY=${2:?--identity needs a name}; shift 2 ;;
    --arch) ARCH=${2:?--arch needs native or universal}; shift 2 ;;
    --out) OUT=${2:?--out needs a directory}; OUT=${OUT:A}; shift 2 ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -u2 "build-app.sh: unknown option $1"; exit 2 ;;
  esac
done
[[ $ARCH == native || $ARCH == universal ]] || { print -u2 "build-app.sh: --arch is native or universal"; exit 2 }
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  IDENTITY=${IDENTITY:--}
fi

cd "$REPO"
print "==> Building $EXECUTABLE ($ARCH, release)"
if [[ $ARCH == universal ]]; then
  swift build -c release --product "$EXECUTABLE" --arch arm64 --arch x86_64
  BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
  swift build -c release --product "$EXECUTABLE"
  BIN_DIR=$(swift build -c release --show-bin-path)
fi

APP="$OUT/$APP_NAME.app"
print "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Presets"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Presets/*.milk Presets/gallery.json "$APP/Contents/Resources/Presets/"

if [[ -f Design/AppIcon.png ]]; then
  ICONSET=$(mktemp -d "${TMPDIR:-/tmp}/milkdrop-icon.XXXXXX")/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Design/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $(( size * 2 )) $(( size * 2 )) Design/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "${ICONSET:h}"
else
  print "==> note: no Design/AppIcon.png; the app gets the generic icon"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Presets by the MilkDropMetalKit authors.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
EOF
plutil -lint -s "$APP/Contents/Info.plist"

print "==> Signing with ${IDENTITY/#-/ad hoc (-)}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

print "==> $APP"
print "==> Version $VERSION ($BUILD_NUMBER), $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
