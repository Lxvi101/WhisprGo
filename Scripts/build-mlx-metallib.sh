#!/bin/zsh
set -euo pipefail

# SwiftPM's command-line build compiles MLX's C++ but not its Metal kernels.
# Compile the kernels mlx-swift ships for its JIT build into one metallib and
# print its path. MLX loads it from mlx-swift_Cmlx.bundle at runtime.

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
KERNELS_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUTPUT_DIR="$PROJECT_DIR/.build/mlx-metallib"
OUTPUT="$OUTPUT_DIR/mlx.metallib"
DEPLOYMENT_TARGET="14.0"

if [[ ! -d "$KERNELS_DIR" ]]; then
    print -u2 "Missing mlx-swift kernels. Run 'swift package resolve' first."
    exit 1
fi

# The Metal compiler ships with Xcode, not the Command Line Tools.
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    print -u2 "The Metal compiler is unavailable. Install Xcode (and its Metal toolchain)."
    exit 1
fi

KERNELS=("$KERNELS_DIR"/**/*.metal(N))
if (( ${#KERNELS} == 0 )); then
    print -u2 "No Metal kernels found in $KERNELS_DIR"
    exit 1
fi

# Rebuild only when the kernels or the compiler change.
FINGERPRINT="$(
    {
        xcrun -sdk macosx metal --version 2>&1
        print "$DEPLOYMENT_TARGET"
        find "$KERNELS_DIR" -type f \( -name '*.metal' -o -name '*.h' \) -print0 \
            | sort -z | xargs -0 shasum -a 256
    } | shasum -a 256 | cut -d ' ' -f 1
)"
if [[ -f "$OUTPUT" && "$(cat "$OUTPUT_DIR/fingerprint" 2>/dev/null)" == "$FINGERPRINT" ]]; then
    echo "$OUTPUT"
    exit 0
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/air"
AIR_FILES=()
for KERNEL in "${KERNELS[@]}"; do
    AIR="$OUTPUT_DIR/air/${${KERNEL#$KERNELS_DIR/}//\//_}.air"
    xcrun -sdk macosx metal \
        -x metal -Wall -Wextra -fno-fast-math \
        -Wno-c++17-extensions -Wno-c++20-extensions \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -c "$KERNEL" -I "$KERNELS_DIR" -o "$AIR" >&2
    AIR_FILES+=("$AIR")
done
xcrun -sdk macosx metal -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    "${AIR_FILES[@]}" -o "$OUTPUT" >&2
print -r -- "$FINGERPRINT" > "$OUTPUT_DIR/fingerprint"
echo "$OUTPUT"
