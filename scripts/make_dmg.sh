#!/bin/bash
# Builds the universal app and packages it as dist/LocalFlow-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh --no-install

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/LocalFlow.app/Contents/Info.plist)
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R build/LocalFlow.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/LEGGIMI.txt "$STAGE/LEGGIMI - Installazione.txt"

DMG="dist/LocalFlow-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "LocalFlow $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
IDENTITY="LocalFlow Code Signing"
security find-identity -p codesigning | grep -q "$IDENTITY" && codesign --force --sign "$IDENTITY" "$DMG"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
