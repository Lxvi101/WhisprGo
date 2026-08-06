#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_PATH="$BUILD_DIR/WhisprGo.app"
BACKGROUND_PATH="$PROJECT_DIR/Packaging/DMGBackground.png"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/Info.plist")"
OUTPUT_PATH="$BUILD_DIR/WhisprGo-$VERSION.dmg"
VOLUME_NAME="WhisprGo"
SIGNING_IDENTITY="${WHISPRGO_SIGNING_IDENTITY:-}"

TEMP_DIR="$(mktemp -d /tmp/whisprgo-dmg.XXXXXX)"
STAGING_DIR="$TEMP_DIR/staging"
MOUNT_DIR=""
READ_WRITE_IMAGE="$TEMP_DIR/WhisprGo-rw.dmg"
COMPRESSED_IMAGE="$TEMP_DIR/WhisprGo.dmg"
DEVICE=""

cleanup() {
    if [[ -n "$DEVICE" ]]; then
        hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true
    fi
    if [[ "$TEMP_DIR" == /tmp/whisprgo-dmg.* ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "Missing $APP_PATH. Run Scripts/build-app.sh first."
    exit 1
fi

if [[ ! -f "$BACKGROUND_PATH" ]]; then
    print -u2 "Missing $BACKGROUND_PATH."
    exit 1
fi

mkdir -p "$STAGING_DIR/.background"
ditto "$APP_PATH" "$STAGING_DIR/WhisprGo.app"
cp "$BACKGROUND_PATH" "$STAGING_DIR/.background/DMGBackground.png"
ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/SetFile -a E "$STAGING_DIR/WhisprGo.app"
/usr/bin/SetFile -a V "$STAGING_DIR/.background"

hdiutil create \
    -quiet \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -fs HFS+ \
    -ov \
    "$READ_WRITE_IMAGE"

ATTACH_OUTPUT="$(hdiutil attach "$READ_WRITE_IMAGE" -readwrite -noverify -noautoopen)"
DEVICE="$(print -r -- "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT_DIR="$(print -r -- "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS/ {print $NF; exit}')"
if [[ -z "$DEVICE" || -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    print -u2 "Could not determine the mounted disk device or volume path."
    exit 1
fi

/usr/bin/SetFile -a V "$MOUNT_DIR/.background"
if [[ -d "$MOUNT_DIR/.fseventsd" ]]; then
    /usr/bin/SetFile -a V "$MOUNT_DIR/.fseventsd"
fi

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1

        set diskWindow to container window
        set current view of diskWindow to icon view
        set toolbar visible of diskWindow to false
        set statusbar visible of diskWindow to false
        set pathbar visible of diskWindow to false
        set bounds of diskWindow to {120, 120, 780, 520}

        set viewOptions to icon view options of diskWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:DMGBackground.png"

        set position of item "WhisprGo.app" to {170, 241}
        set position of item "Applications" to {490, 241}
        try
            set position of item ".background" to {900, 900}
        end try
        try
            set position of item ".fseventsd" to {980, 900}
        end try

        update without registering applications
        delay 2
        close diskWindow
        open
        delay 2
        close container window
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

hdiutil convert \
    "$READ_WRITE_IMAGE" \
    -quiet \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$COMPRESSED_IMAGE"

hdiutil verify "$COMPRESSED_IMAGE" -quiet
mkdir -p "$BUILD_DIR"
mv -f "$COMPRESSED_IMAGE" "$OUTPUT_PATH"

if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_PATH"
    codesign --verify --verbose=2 "$OUTPUT_PATH"
fi

print "$OUTPUT_PATH"
