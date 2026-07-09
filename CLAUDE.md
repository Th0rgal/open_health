# open_oura — repo guide for agents

Independent, cloud-free client for the Oura ring: BLE sync + decode in Rust, the daily
health computations in Rust, the ML models (sleep / CVA / activity) as decrypted
TorchScript. See `README.md` and `docs/` for the reverse-engineering details.

## ⚠️ Two clients render the same data — keep them in sync

There are **two user-facing apps** and a change usually belongs in **both**:

- **Web dashboard** — `dashboard/web/` (vanilla JS) served by `crates/oura-cli/src/dashboard.rs`.
- **Native iOS app** — `apps/ios/OpenOura/` (SwiftUI) using `crates/oura-ffi` (C ABI).

Both render the JSON from the **single shared brain `crates/oura-summary` (`build_summary`)**.

Before you finish a feature, check it against **`docs/clients-web-and-ios.md`** (the
feature ↔ feature map) and apply it where it belongs:

- **New computed metric/field** → add once in `oura-summary`; render in **both** `app.js`
  **and** `OpenOuraApp.swift`.
- **New visualization/UI** → do it in **both** `app.js` **and** `OpenOuraApp.swift`.
- **New model** → wire **both** a `tools/run_*_model.py` (web `PythonRunner`) **and** the
  iOS path under `apps/ios/OpenOura/`.

If you intentionally do only one client, say so and note it in the "Known gaps" section of
`docs/clients-web-and-ios.md`.

## Building / running

- Web dashboard: `oura dashboard` (see `dashboard/README.md`).
- iOS: `apps/ios/build-rust.sh`, then `cd apps/ios && xcodegen generate && open OpenOura.xcodeproj`.
  TestFlight: `apps/ios/TESTFLIGHT.md`.
- Local databases and auth keys are gitignored — never commit them.
