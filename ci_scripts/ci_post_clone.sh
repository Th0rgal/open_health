#!/bin/sh
# Xcode Cloud post-clone: a clean cloud checkout has no OuraFFI.xcframework and no
# OpenOura.xcodeproj (both gitignored), so build the Rust C-ABI xcframework and
# generate the Xcode project the workflow archives.
set -e
echo "=== ci_post_clone: Rust xcframework + xcodegen ==="

# xcodegen, to generate the project from project.yml.
brew install xcodegen

# Rust toolchain + the iOS targets build-rust.sh links.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
. "$HOME/.cargo/env"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}"

# OuraFFI.xcframework (device + sim).
bash "$REPO/apps/ios/build-rust.sh"

# The Xcode project the Xcode Cloud workflow builds + archives.
cd "$REPO/apps/ios"
xcodegen generate

echo "=== ci_post_clone done ==="
