#!/bin/bash
# Builds a Release Openline.app and an optional DMG into build/release.
# Signs ad hoc unless SIGN_IDENTITY names a Developer ID certificate.
# NOTARY_PROFILE (a `notarytool store-credentials` name) also notarizes the DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
cd "$ROOT"
./scripts/build-native-deps.sh
xcodegen generate
xcodebuild -project Openline.xcodeproj -scheme Openline -configuration Release -derivedDataPath build/DerivedData \
    -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="${SIGN_IDENTITY:--}" build
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R build/DerivedData/Build/Products/Release/Openline.app "$OUT/"
hdiutil create -volname Openline -srcfolder "$OUT/Openline.app" -ov -format UDZO "$OUT/Openline.dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT/Openline.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT/Openline.dmg"
fi
codesign -dv "$OUT/Openline.app" 2>&1 | grep -E 'Signature|Authority' || true
