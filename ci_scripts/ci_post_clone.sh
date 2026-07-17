#!/bin/sh
# Xcode Cloud post-clone: a clean cloud checkout has no OuraCore.xcframework and no
# OuraApp.xcodeproj (both gitignored), so build the Rust UniFFI xcframework and
# generate the MODEL-FREE Xcode project the workflow archives. The torch models
# (libtorch + .ptl) are NOT part of CI — they live only in the local project.yml.
set -e
echo "=== ci_post_clone: Rust xcframework + xcodegen (model-free) ==="

# xcodegen, to generate the project from project-ci.yml. Idempotent: newer Xcode
# Cloud images may already provide it, and `brew install` on an existing formula
# is fine, but skip it when present to avoid brew hiccups failing the clone.
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

# Rust toolchain + the iOS targets build-xcframework.sh links. Idempotent: recent
# Xcode Cloud base images ship Rust, and `rustup-init -y` EXITS NON-ZERO when rustup
# is already installed (this was the ci_post_clone failure). Only install if missing.
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# put cargo/rustup on PATH whether freshly installed or image-provided
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
rustup default stable 2>/dev/null || true
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}"

# OuraCore.xcframework (device + sim) from the committed UniFFI bindings
bash "$REPO/apps/ios/build-xcframework.sh"

# the model-free Xcode project the Xcode Cloud workflow builds + archives
cd "$REPO/apps/ios/OuraApp"
xcodegen generate --spec project-ci.yml

echo "=== ci_post_clone done ==="
