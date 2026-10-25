#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$REPO_ROOT"

echo "==> Building release binary for oura-cli with native embedded webview..."
cargo build --release --features appimage -p oura-cli

BUILD_DIR="$REPO_ROOT/target/appimage"
APPDIR="$BUILD_DIR/OpenHealth.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps"

echo "==> Setting up AppDir payload..."
cp "$REPO_ROOT/target/release/oura" "$APPDIR/usr/bin/oura"
cp "$SCRIPT_DIR/AppRun" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "$SCRIPT_DIR/open-health.desktop" "$APPDIR/open-health.desktop"
cp "$SCRIPT_DIR/open-health.desktop" "$APPDIR/usr/share/applications/open-health.desktop"

# Icon
ICON_SRC="$REPO_ROOT/apps/ios/OuraApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APPDIR/open-health.png"
    cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/512x512/apps/open-health.png"
    ln -sf open-health.png "$APPDIR/.DirIcon"
fi

# Locate or download appimagetool
APPIMAGETOOL="${APPIMAGETOOL:-appimagetool}"
if ! command -v "$APPIMAGETOOL" >/dev/null 2>&1; then
    APPIMAGETOOL="$HOME/.local/bin/appimagetool"
    if [ ! -x "$APPIMAGETOOL" ]; then
        echo "==> Downloading appimagetool..."
        mkdir -p "$(dirname "$APPIMAGETOOL")"
        curl -L -o "$APPIMAGETOOL" https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
        chmod +x "$APPIMAGETOOL"
    fi
fi

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Applications}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/OpenHealth.AppImage"

echo "==> Packaging AppImage to $OUTPUT_FILE..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT_FILE"

# Install desktop entry if running for local user
if [ -d "$HOME/.local/share/applications" ]; then
    echo "==> Updating desktop launcher and icon..."
    mkdir -p "$HOME/.local/share/icons/hicolor/512x512/apps"
    cp "$APPDIR/open-health.png" "$HOME/.local/share/icons/hicolor/512x512/apps/open-health.png"
    sed "s|^Exec=AppRun|Exec=$OUTPUT_FILE|" "$APPDIR/open-health.desktop" > "$HOME/.local/share/applications/open-health.desktop"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi

echo "==> Done: $OUTPUT_FILE generated"
