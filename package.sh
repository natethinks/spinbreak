#!/bin/sh
# Builds SpinBreak as a universal app and wraps it in a DMG you can send to anyone.
#   ./package.sh            -> dist/SpinBreak-<version>.dmg
#
# Signing: uses a "Developer ID Application" certificate if you have one, and notarizes + staples when a
# notarytool keychain profile named "spinbreak" exists:
#   xcrun notarytool store-credentials spinbreak --apple-id <you> --team-id <your team id>
# Without them it ad-hoc signs, and people allow it once in System Settings › Privacy & Security (see the README in the DMG).
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-1.3.0}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
OUT=dist
APP="$OUT/SpinBreak.app"
SRC="SpinBreak.swift Settings.swift Starter.swift Household.swift AISetup.swift Brief.swift Engine.swift"
MIN=14.0

rm -rf "$OUT/SpinBreak.app" "$OUT/stage" "$OUT/SpinBreak-$VERSION.dmg"      # older versions' DMGs stay
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"
cp SpinBreak.icns "$APP/Contents/Resources/SpinBreak.icns"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos$MIN" $SRC -o "$OUT/obj/SpinBreak-$ARCH"
done
lipo -create "$OUT/obj/SpinBreak-arm64" "$OUT/obj/SpinBreak-x86_64" -output "$APP/Contents/MacOS/SpinBreak"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SpinBreak</string>
  <key>CFBundleDisplayName</key><string>SpinBreak</string>
  <key>CFBundleIdentifier</key><string>com.nate.spinbreak</string>
  <key>CFBundleExecutable</key><string>SpinBreak</string>
  <key>CFBundleIconFile</key><string>SpinBreak</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. github.com/natethinks/spinbreak</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>SpinBreak sets a reminder so your iPhone and Apple Watch ding when your break is over.</string>
  <key>NSRemindersUsageDescription</key><string>SpinBreak sets a reminder so your iPhone and Apple Watch ding when your break is over.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>SpinBreak ends breaks before your meetings and puts the current break on your calendar.</string>
  <key>NSCalendarsUsageDescription</key><string>SpinBreak ends breaks before your meetings and puts the current break on your calendar.</string>
</dict></plist>
PLIST

# Hardened runtime needs an explicit entitlement for Calendar (EventKit covers Reminders through it too).
cat > "$OUT/obj/entitlements.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.personal-information.calendars</key><true/>
</dict></plist>
ENT

ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "$ID" ]; then
  codesign --force --options runtime --timestamp --entitlements "$OUT/obj/entitlements.plist" --sign "$ID" "$APP"
  SIGNED=developer-id
else
  codesign --force --options runtime --entitlements "$OUT/obj/entitlements.plist" --sign - "$APP"
  SIGNED=adhoc
fi
codesign --verify --strict "$APP"

# DMG: the app, an Applications shortcut, and the read-me.
mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/"
ln -s /Applications "$OUT/stage/Applications"
cp dist-readme.txt "$OUT/stage/Read Me First.txt"
DMG="$OUT/SpinBreak-$VERSION.dmg"
hdiutil create -quiet -volname "SpinBreak" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/stage" "$OUT/obj"

if [ "$SIGNED" = developer-id ]; then
  codesign --force --timestamp --sign "$ID" "$DMG"
  if xcrun notarytool history --keychain-profile spinbreak >/dev/null 2>&1; then
    xcrun notarytool submit "$DMG" --keychain-profile spinbreak --wait
    xcrun stapler staple "$DMG"
    SIGNED=notarized
  fi
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1)) · signing: $SIGNED"
