#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/Info.plist")"
DMG_PATH="${1:-$PROJECT_DIR/.build/WhisprGo-$VERSION.dmg}"
SPARKLE_TOOL="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
ACCOUNT="${WHISPRGO_SPARKLE_ACCOUNT:-com.whisprgo.app}"
TAG="v$VERSION"
RELEASE_URL="https://github.com/Lxvi101/WhisprGo/releases/tag/$TAG"
DOWNLOAD_PREFIX="https://github.com/Lxvi101/WhisprGo/releases/download/$TAG/"
TEMP_DIR="$(mktemp -d /tmp/whisprgo-appcast.XXXXXX)"

cleanup() {
    if [[ "$TEMP_DIR" == /tmp/whisprgo-appcast.* ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

if [[ ! -f "$DMG_PATH" ]]; then
    print -u2 "Missing update archive: $DMG_PATH"
    exit 1
fi

if [[ ! -x "$SPARKLE_TOOL" ]]; then
    print -u2 "Missing Sparkle tools. Run 'swift package resolve' first."
    exit 1
fi

ditto "$DMG_PATH" "$TEMP_DIR/${DMG_PATH:t}"
if [[ -f "$PROJECT_DIR/appcast.xml" ]]; then
    cp "$PROJECT_DIR/appcast.xml" "$TEMP_DIR/appcast.xml"
fi

"$SPARKLE_TOOL" \
    --account "$ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "$RELEASE_URL" \
    --maximum-deltas 0 \
    --maximum-versions 3 \
    -o "$TEMP_DIR/appcast.xml" \
    "$TEMP_DIR"

ditto "$TEMP_DIR/appcast.xml" "$PROJECT_DIR/appcast.xml"
print "$PROJECT_DIR/appcast.xml"
