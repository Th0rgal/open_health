# Open Health AppImage Packaging

This directory contains scripts and metadata to package Open Health as a portable Linux [AppImage](https://appimage.org/).

## Features
- **Self-contained**: Bundles the `oura` binary, web dashboard assets, and desktop integration into a single executable file.
- **Desktop Window**: When launched, automatically spawns a dedicated desktop web application window (via Chromium `--app` mode, or system default browser) displaying the health dashboard.
- **Server Lifecycle**: Automatically starts the local dashboard server on an available port, and terminates it when the window is closed (no orphaned background processes).
- **Auto-Discovery**: Resolves database (`OURA_DB_FILE`) and authentication key (`OURA_KEY_FILE`) from environment variables or standard locations (`~/.local/share/open_health/` or `~/Dropbox/open_health/`).

## Building the AppImage

Prerequisites:
- Rust toolchain (`cargo`, `rustc`)
- `curl`

To build:
```bash
./packaging/appimage/build_appimage.sh
```

By default, the resulting `OpenHealth.AppImage` will be placed in `~/Applications/` and registered with the desktop launcher under `~/.local/share/applications/open-health.desktop`.
