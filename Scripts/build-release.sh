#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_PATH="$BUILD_DIR/WhisprGo.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/Info.plist")"
DMG_PATH="$BUILD_DIR/WhisprGo-$VERSION.dmg"
NOTARIZATION_ZIP="$BUILD_DIR/WhisprGo-$VERSION-notarization.zip"
SIGNING_IDENTITY="${WHISPRGO_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${WHISPRGO_NOTARY_PROFILE:-WhisprGo-notary}"

if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
    print -u2 "No usable Developer ID identity matches: $SIGNING_IDENTITY"
    print -u2 "Import the certificate together with its private key, or set WHISPRGO_SIGNING_IDENTITY."
    exit 1
fi

export WHISPRGO_SIGNING_IDENTITY="$SIGNING_IDENTITY"

zsh "$SCRIPT_DIR/build-app.sh"

rm -f "$NOTARIZATION_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZATION_ZIP"
xcrun notarytool submit "$NOTARIZATION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

zsh "$SCRIPT_DIR/build-dmg.sh"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

print "$DMG_PATH"
