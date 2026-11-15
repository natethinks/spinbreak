#!/bin/sh
# Builds SpinBreak.app next to the source, for working on it, with the system Swift compiler. No packages.
# ./package.sh builds the same app as a universal binary in a DMG, for everyone else.
set -e
cd "$(dirname "$0")"
APP=SpinBreak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp SpinBreak.icns "$APP/Contents/Resources/SpinBreak.icns"
swiftc -O -swift-version 5 -parse-as-library SpinBreak.swift Settings.swift Starter.swift Household.swift AISetup.swift Brief.swift Engine.swift -o "$APP/Contents/MacOS/SpinBreak"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SpinBreak</string>
  <key>CFBundleIdentifier</key><string>com.nate.spinbreak</string>
  <key>CFBundleExecutable</key><string>SpinBreak</string>
  <key>CFBundleIconFile</key><string>SpinBreak</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>SpinBreak sets a reminder so your iPhone and Apple Watch ding when your break is over.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>SpinBreak fits breaks around your meetings and puts the current break on your calendar so your watch shows the time left.</string>
  <key>NSCalendarsUsageDescription</key><string>SpinBreak fits breaks around your meetings and puts the current break on your calendar so your watch shows the time left.</string>
  <key>NSRemindersUsageDescription</key><string>SpinBreak sets a reminder so your iPhone and Apple Watch ding when your break is over.</string>
</dict></plist>
PLIST
# Sign with the Apple Development identity if present (keeps Reminders permission across rebuilds), else ad-hoc.
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "Built $(pwd)/$APP ($(du -sh "$APP" | cut -f1))"
