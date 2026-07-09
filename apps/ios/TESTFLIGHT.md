# Shipping OpenOura to TestFlight

The iOS app lives in this repo at `apps/ios/`. It keeps the existing bundle id
`md.thomas.openoura`.

Before each TestFlight upload, increment `CURRENT_PROJECT_VERSION` in
`apps/ios/project.yml`; App Store Connect rejects duplicate build numbers for the
same marketing version.

## One-time

- Apple Developer Program membership.
- Register the App ID `md.thomas.openoura` and create the app in App Store Connect.
- Install xcodegen: `brew install xcodegen`.

## Build & Upload

```bash
./apps/ios/build-rust.sh
cd apps/ios
xcodegen generate
open OpenOura.xcodeproj
```

In Xcode, select the `OpenOura` scheme and use Product -> Archive -> Distribute App
-> TestFlight & App Store.

If `notes/models/mobile/*.ptl` exists locally, the Xcode build phase bundles these
private models into `OpenOura.app`. The model files stay gitignored and are not
committed.

The simulator has no usable Bluetooth for ring features, so TestFlight/device
validation needs a real iPhone.
