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

# ── On-device transcription ─────────────────────────────────────────────────
#
# Off unless AI=1, because it pulls whisper.cpp (and with AI=2, llama.cpp) — a
# slow C++ build a plain SIP build should not pay for.
#
#   AI=1 ./build-rust.sh    transcription
#   AI=2 ./build-rust.sh    transcription + on-device summaries
#
# Device only. The simulator stays a plain SIP build: it is x86-or-arm on a Mac,
# nobody benchmarks a model there, and `ai_available()` reports false at runtime.
AI="${AI:-0}"
case "$AI" in
    2) AI_FEATURES="--features ai-summaries" ;;
    1) AI_FEATURES="--features ai" ;;
    *) AI_FEATURES="" ;;
esac
if [ -n "$AI_FEATURES" ]; then
    echo "On-device AI enabled for device build: $AI_FEATURES"
    # Rust defaults aarch64-apple-ios to a 10.0 deployment target, but
    # whisper.cpp compiles against the current SDK and emits __chkstk_darwin,
    # which does not exist that far back — the link then fails with
    # "Undefined symbols for architecture arm64". The app targets iOS 16.
    export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
fi

# Build static libraries for all iOS targets
echo "Building aarch64-apple-ios (device)..."
cargo rustc $CARGO_FLAGS $AI_FEATURES --manifest-path "$RUST_DIR/Cargo.toml" \
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
