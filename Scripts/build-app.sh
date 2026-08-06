#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.build/WhisprGo.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c release --product WhisprGo
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/WhisprGo" "$CONTENTS_DIR/MacOS/WhisprGo"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/WhisprGo.svg" "$CONTENTS_DIR/Resources/WhisprGo.svg"
cp "$PROJECT_DIR/Packaging/WaveformMark.png" "$CONTENTS_DIR/Resources/WaveformMark.png"
cp "$PROJECT_DIR/Packaging/MenuBarIconTemplate.png" "$CONTENTS_DIR/Resources/MenuBarIconTemplate.png"

# Keep dependency resource bundles inside the conventional signed Resources
# directory. Gemma carries its own tokenizer configuration; the bundled GPT-2
# and T5 files remain available for the transcription stack's fallbacks.
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle(N); do
    ditto "$RESOURCE_BUNDLE" "$CONTENTS_DIR/Resources/${RESOURCE_BUNDLE:t}"
done

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
