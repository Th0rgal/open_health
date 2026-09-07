# open_oura — repo guide for agents

Independent, cloud-free client for the Oura ring: BLE sync + decode in Rust, the daily
health computations in Rust, the ML models (sleep / CVA / activity) as decrypted
TorchScript. See `README.md` and `docs/` for the reverse-engineering details.

## ⚠️ Three clients render the same data — keep them in sync

There are **three user-facing apps** and a change usually belongs in **all of them**:

- **Web dashboard** — `dashboard/web/` (vanilla JS) served by `crates/oura-cli/src/dashboard.rs`.
- **Native iOS app** — `apps/ios/OuraApp/` (SwiftUI) on `crates/oura-core` (UniFFI).
- **Native Android app** — `apps/android/app/` (Compose) on `crates/oura-core` (UniFFI).

All three render the JSON from the **single shared brain `crates/oura-summary`
(`build_summary`)**. The two native clients share the *same* UniFFI surface — only the
bindings language differs (`--language swift` vs `--language kotlin`).

Before you finish a feature, check it against **`docs/clients.md`** (the
feature ↔ feature map) and apply it where it belongs:

- **New computed metric/field** → add once in `oura-summary`; render in **`app.js`,
  `OuraApp.swift` and `ui/RootScreen.kt`**.
- **New visualization/UI** → do it in **all three**.
- **New model** → wire a `tools/run_*_model.py` (web `PythonRunner`), the iOS on-device path
  (`apps/ios/OuraApp/TorchBridge.mm` + a `*Model.swift`), **and** the Android one
  (`apps/android/app/src/main/cpp/torch_bridge.cpp` + a `models/*.kt`).

Some logic is deliberately duplicated across clients (sleep metrics, sleep debt,
autonomic-by-stage, the ring-clock epoch mapping). `docs/clients.md` lists every such pair;
the Android copies carry JVM unit tests, which run headlessly and are the cheapest place to
pin a definition before changing it elsewhere.

If you intentionally do only one client, say so and note it in the "Known gaps" section of
`docs/clients.md`.

## Building / running

- Web dashboard: `oura dashboard` (see `dashboard/README.md`).
- iOS (simulator): `apps/ios/OuraApp/build_run.sh` (model-free) or `build_run_torch.sh`
  (on-device torch models). TestFlight: `apps/ios/TESTFLIGHT.md`.
- Android: `apps/android/build-jni-libs.sh` (Rust core → `jniLibs/` + Kotlin bindings), then
  `./gradlew :app:assembleLiteDebug` (model-free) or `assembleFullDebug` (on-device torch).
  Needs a JDK 21 — AGP does not run on 25. See `apps/android/GOAL.md`.
- Models, `libtorch`, `oura.db`, and auth keys are gitignored — never commit them.
