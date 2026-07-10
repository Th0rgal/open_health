# Shipping OuraApp to TestFlight

The simulator dev harness (`OuraApp/build_run.sh`) is for quick local runs. TestFlight
needs a **signed device archive**. Everything below the signing step is scaffolded;
signing requires *your* Apple Developer account.

## One-time
- **Apple Developer Program** membership ($99/yr).
- Register the App ID **`md.thomas.openoura`** and create the app in App Store Connect.
- Install xcodegen: `brew install xcodegen`.

## Build & upload
Current upload version is configured as **0.1.1 (3)** in
`OuraApp/project.yml` and `OuraApp/project-ci.yml`.

```bash
# 1. shared Rust core → both device + simulator slices
./apps/ios/build-xcframework.sh

# 2. generate the Xcode project from project.yml
cd apps/ios/OuraApp && xcodegen generate

# 3. open it, set your Team under Signing & Capabilities (or DEVELOPMENT_TEAM in project.yml)
open OuraApp.xcodeproj
#    then: Product → Archive → Distribute App → TestFlight & App Store
```
Or headless once a Team is set:
```bash
xcodebuild -project OuraApp.xcodeproj -scheme OuraApp -sdk iphoneos \
  -configuration Release archive -archivePath build/OuraApp.xcarchive
xcodebuild -exportArchive -archivePath build/OuraApp.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export   # then upload with `xcrun altool`/Transporter
```

## Already handled
- App icon (`Assets.xcassets/AppIcon.appiconset`, 1024²).
- `Info.plist`: Bluetooth usage strings; `ITSAppUsesNonExemptEncryption=false` (AES ring
  auth is exempt); simulator platform pin removed so a device archive is valid.
- Device (`ios-arm64`) **and** simulator slices in `OuraCore.xcframework`.
- Both sim and device Release builds verified to compile + link.

## Still on you
- **Signing**: Team ID + a distribution provisioning profile (only you can do this).
- **Version bumps**: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- **Data**: the local `project.yml` build bundles `oura.db` when that gitignored file is
  present, which is useful for a personal TestFlight. The Xcode Cloud `project-ci.yml`
  build does not bundle `oura.db`, `.ptl` models, or LibTorch.
