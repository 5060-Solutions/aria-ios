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

export CMAKE_POLICY_VERSION_MINIMUM=3.5

# Build static libraries for all iOS targets
echo "Building aarch64-apple-ios (device)..."
cargo rustc $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-ios --lib --crate-type staticlib

echo "Building aarch64-apple-ios-sim (simulator ARM64)..."
cargo rustc $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-ios-sim --lib --crate-type staticlib

# Create universal simulator library (skip x86_64 — modern Macs are all ARM)
SIMULATOR_LIB="$RUST_DIR/target/universal-ios-sim/$TARGET_DIR"
mkdir -p "$SIMULATOR_LIB"
cp "$RUST_DIR/target/aarch64-apple-ios-sim/$TARGET_DIR/libaria_mobile_core.a" \
    "$SIMULATOR_LIB/libaria_mobile_core.a"

# Generate UniFFI Swift bindings
echo "Generating UniFFI Swift bindings..."
cargo run --manifest-path "$RUST_DIR/Cargo.toml" \
    --features uniffi/cli -- \
    generate "$RUST_DIR/src/aria_mobile.udl" \
    --language swift \
    --out-dir "$OUT_DIR"

# Prepare headers directory for xcframework (C header + modulemap only)
HEADERS_DIR="$RUST_DIR/target/xcframework-headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$OUT_DIR/aria_mobileFFI.h" "$HEADERS_DIR/"
cp "$OUT_DIR/aria_mobileFFI.modulemap" "$HEADERS_DIR/module.modulemap"

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "$FRAMEWORK_DIR"
xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/$TARGET_DIR/libaria_mobile_core.a" \
    -headers "$HEADERS_DIR" \
    -library "$SIMULATOR_LIB/libaria_mobile_core.a" \
    -headers "$HEADERS_DIR" \
    -output "$FRAMEWORK_DIR"

echo "=== Done ==="
echo "XCFramework: $FRAMEWORK_DIR"
echo "Swift bindings: $OUT_DIR/aria_mobile.swift"
