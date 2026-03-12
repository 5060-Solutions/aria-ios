#!/bin/bash
# Build aria-mobile-core for iOS targets and generate UniFFI Swift bindings.
#
# Prerequisites:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Usage:
#   ./build-rust.sh [debug|release]

set -euo pipefail

MODE="${1:-release}"
RUST_DIR="../aria-mobile-core"
OUT_DIR="AriaSoftphone/Bridge"
FRAMEWORK_DIR="AriaMobileCore.xcframework"

cd "$(dirname "$0")"

echo "=== Building aria-mobile-core for iOS ($MODE) ==="

CARGO_FLAGS=""
TARGET_DIR="debug"
if [ "$MODE" = "release" ]; then
    CARGO_FLAGS="--release"
    TARGET_DIR="release"
fi

# Build for all iOS targets
echo "Building aarch64-apple-ios (device)..."
cargo build $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-ios

echo "Building aarch64-apple-ios-sim (simulator ARM64)..."
cargo build $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim

echo "Building x86_64-apple-ios (simulator x86_64)..."
cargo build $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" \
    --target x86_64-apple-ios

# Create universal simulator library
echo "Creating universal simulator library..."
SIMULATOR_LIB="$RUST_DIR/target/universal-ios-sim/$TARGET_DIR"
mkdir -p "$SIMULATOR_LIB"
lipo -create \
    "$RUST_DIR/target/aarch64-apple-ios-sim/$TARGET_DIR/libaria_mobile_core.a" \
    "$RUST_DIR/target/x86_64-apple-ios/$TARGET_DIR/libaria_mobile_core.a" \
    -output "$SIMULATOR_LIB/libaria_mobile_core.a"

# Generate UniFFI Swift bindings
echo "Generating UniFFI Swift bindings..."
cargo run --manifest-path "$RUST_DIR/Cargo.toml" \
    --features uniffi/cli -- \
    uniffi-bindgen generate "$RUST_DIR/src/aria_mobile.udl" \
    --language swift \
    --out-dir "$OUT_DIR"

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR"
xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/$TARGET_DIR/libaria_mobile_core.a" \
    -headers "$OUT_DIR" \
    -library "$SIMULATOR_LIB/libaria_mobile_core.a" \
    -headers "$OUT_DIR" \
    -output "$FRAMEWORK_DIR"

echo "=== Done ==="
echo "XCFramework: $FRAMEWORK_DIR"
echo "Swift bindings: $OUT_DIR/aria_mobile.swift"
echo ""
echo "Add the XCFramework to your Xcode project and replace the stubs in"
echo "AriaMobileCore.swift with: #define UNIFFI_GENERATED"
