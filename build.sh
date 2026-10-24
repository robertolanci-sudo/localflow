#!/bin/bash
# Builds a universal (Apple Silicon + Intel) LocalFlow.app and installs it into /Applications.
#   ./build.sh               build + install
#   ./build.sh --no-install  build only (build/LocalFlow.app)
set -euo pipefail
cd "$(dirname "$0")"

# Pick the newest SDK compatible with the installed Swift compiler (SDK 26 needs Swift 6.2+).
SDK=""
for candidate in MacOSX15.5.sdk MacOSX15.4.sdk MacOSX15.sdk MacOSX.sdk; do
  if [ -d "/Library/Developer/CommandLineTools/SDKs/$candidate" ]; then SDK="/Library/Developer/CommandLineTools/SDKs/$candidate"; break; fi
done
[ -n "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

mkdir -p build
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos13.0" -swift-version 5 -lsqlite3 \
    -o "build/LocalFlow-$ARCH" Sources/LocalFlow/*.swift
done
lipo -create build/LocalFlow-arm64 build/LocalFlow-x86_64 -output build/LocalFlow

# Universal whisper-server (static, Metal embedded): built by scripts/build_whisper.sh.
if [ ! -x vendor/bin/whisper-server ]; then
  ./scripts/build_whisper.sh
fi

APP=build/LocalFlow.app
VERSION="1.2"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/Licenses"
cp build/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp vendor/bin/whisper-server "$APP/Contents/Resources/bin/whisper-server"
cp vendor/whisper.cpp/LICENSE "$APP/Contents/Resources/Licenses/whisper.cpp-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/Licenses/LocalFlow-LICENSE.txt"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LocalFlow</string>
  <key>CFBundleDisplayName</key><string>LocalFlow</string>
  <key>CFBundleIdentifier</key><string>local.localflow.app</string>
  <key>CFBundleExecutable</key><string>LocalFlow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>LocalFlow trascrive la tua voce in locale. / LocalFlow transcribes your voice locally.</string>
  <key>NSAppleEventsUsageDescription</key><string>LocalFlow silenzia l'audio durante la dettatura. / LocalFlow mutes audio while dictating.</string>
</dict>
</plist>
PLIST

# A stable local certificate keeps the Accessibility permission valid across rebuilds;
# fall back to ad-hoc signing when it is missing.
IDENTITY="LocalFlow Code Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then SIGN="$IDENTITY"; else
  echo "warning: '$IDENTITY' not found, using ad-hoc signature (Accessibility must be re-granted after each build)"
  SIGN="-"
fi
codesign --force --sign "$SIGN" "$APP/Contents/Resources/bin/whisper-server"
codesign --force --sign "$SIGN" --identifier local.localflow.app "$APP"

if [ "${1:-}" != "--no-install" ]; then
  pkill -x LocalFlow 2>/dev/null || true
  rm -rf /Applications/LocalFlow.app
  cp -R "$APP" /Applications/LocalFlow.app
  echo "Installed /Applications/LocalFlow.app"
fi
