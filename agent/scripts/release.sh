#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes and staples Blueberry.dmg.
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates).
#   2. xcrun notarytool store-credentials blueberry-notary --apple-id <you> --team-id <TEAM> --password <app-specific-password>
# Usage: DEVELOPMENT_TEAM=<TEAM> scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your 10-character Apple team id}"
NOTARY_PROFILE="${NOTARY_PROFILE:-blueberry-notary}"
BUILD=build
rm -rf "$BUILD" && mkdir -p "$BUILD"

xcodegen generate --quiet
xcodebuild -project Blueberry.xcodeproj -scheme Blueberry -configuration Release \
  -archivePath "$BUILD/Blueberry.xcarchive" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" archive | xcbeautify 2>/dev/null || true
test -d "$BUILD/Blueberry.xcarchive" || { echo "archive failed"; exit 1; }

cat > "$BUILD/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$BUILD/Blueberry.xcarchive" -exportPath "$BUILD/export" -exportOptionsPlist "$BUILD/export.plist"

APP="$BUILD/export/Blueberry.app"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$BUILD/dmg" && cp -R "$APP" "$BUILD/dmg/" && ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname Blueberry -srcfolder "$BUILD/dmg" -ov -format UDZO "$BUILD/Blueberry.dmg"
codesign --sign "Developer ID Application" --timestamp "$BUILD/Blueberry.dmg"

xcrun notarytool submit "$BUILD/Blueberry.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$BUILD/Blueberry.dmg"
spctl --assess --type open --context context:primary-signature -v "$BUILD/Blueberry.dmg"
echo "✅ $BUILD/Blueberry.dmg"
