#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.build/WhisprGo.app"
CONTENTS_DIR="$APP_DIR/Contents"
SPARKLE_SOURCE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SIGNING_IDENTITY="${WHISPRGO_SIGNING_IDENTITY:-}"

cd "$PROJECT_DIR"
swift build -c release --product WhisprGo
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
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

if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    print -u2 "Missing Sparkle.framework. Run 'swift package resolve' first."
    exit 1
fi

# ditto preserves Sparkle's versioned-framework symlinks and executable bits.
SPARKLE_FRAMEWORK="$CONTENTS_DIR/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE_FRAMEWORK"

# WhisprGo is not sandboxed, so Sparkle's sandbox-only XPC services are not
# needed. Removing them also avoids shipping privileged helpers the app cannot
# use.
rm -rf "$SPARKLE_FRAMEWORK/Versions/B/XPCServices"
rm -f "$SPARKLE_FRAMEWORK/XPCServices"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
        print -u2 "No usable code-signing identity matches: $SIGNING_IDENTITY"
        exit 1
    fi
    SIGN_ARGS+=(--timestamp --options runtime)
fi

# Sign nested code from the inside out. Do not use --deep for signing because
# it can apply the wrong entitlements to Sparkle's helper tools.
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK"
codesign "${SIGN_ARGS[@]}" \
    --entitlements "$PROJECT_DIR/Packaging/WhisprGo.entitlements" \
    "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
