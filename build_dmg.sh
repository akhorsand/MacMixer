#!/bin/bash
# Builds App Audio Mixer and packages it into a DMG.
# Run on macOS 14.4+ with Xcode (or Command Line Tools) installed:
#   ./build_dmg.sh
# Output: build/AppAudioMixer.dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="App Audio Mixer"
EXECUTABLE="AppAudioMixer"
BUNDLE="build/${APP_NAME}.app"

echo "==> Building (release, native arch)..."
swift build -c release

echo "==> Assembling ${APP_NAME}.app..."
rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp ".build/release/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"

echo "==> Code signing (ad-hoc)..."
codesign --force --options runtime --sign - "${BUNDLE}"

echo "==> Creating DMG..."
STAGING="build/dmg-staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${BUNDLE}" "${STAGING}/"
ln -sfn /Applications "${STAGING}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING}" \
    -ov -format UDZO \
    "build/AppAudioMixer.dmg"

rm -rf "${STAGING}"

echo ""
echo "Done: $(pwd)/build/AppAudioMixer.dmg"
echo "Open the DMG and drag '${APP_NAME}' into Applications."
echo "First launch: right-click the app > Open (it's ad-hoc signed, not notarized)."
